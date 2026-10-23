# Architecture and implementation strategy

## 1. Module map

| File | Module | Domain | Function |
|---|---|---|---|
| `rtl/qm_herald_latch.sv` | `qm_herald_latch` | **herald (async)** | Path A kill flops, `fired`, Gray edge counter |
| `rtl/qm_core.sv` | `qm_core` | both | Output LUTs, integration, timebase |
| `rtl/qm_edge_capture.sv` | `qm_edge_capture` | clk_sys | 1 ns edge detection / timestamp from serdes words |
| `rtl/qm_sequencer.sv` | `qm_sequencer` | clk_sys | Arm/clear protocol, accept/reject, scheduling, restore |
| `rtl/qm_pulse_unit.sv` | `qm_pulse_unit` | clk_sys | Wrap-safe 1 ns pulse → serdes word |
| `rtl/qm_regs.sv`, `qm_fifo.sv` | | clk_sys | Configuration, status, counters, timestamp FIFO |
| `rtl/qm_uart.sv` | `qm_uart_*` | clk_sys | Host register access (1 Mbaud) |
| `rtl/qm_sync.sv` | `qm_sync` | clk_sys | ASYNC_REG synchronizers |
| `rtl/vendor/xilinx7/qm_xilinx7_io.sv` | `qm_clocking`, `qm_in_serdes`, `qm_out_serdes`, `qm_diff_out` | – | **All** AMD primitives (MMCM, BUFG, IBUFDS(_GTE2), ISERDESE2, OSERDESE2, OBUFDS) |
| `sim/models/qm_io_models.sv` | same names | – | Behavioral models for simulation |
| `rtl/qm_top.sv` | `qm_top` | – | Kasli 2.0 + DIO-MCX pin-level top |

Porting to another FPGA family means replacing the one vendor file and the XDC.

## 2. Path A: clock-free herald reaction

```text
herald pad ─► IBUFDS ─► ISERDESE2 (D→O bypass) ─► [BUFG] ─► FDCE.C ──Q──► LUT ─► OBUFDS ─► pad
                                                    ▲   ▲              ▲
                                     CE = arm (clk_sys FF)   CLR = clr_kill (clk_sys FF)
                                                                  on/imm/pol (static clk_sys FFs)
```

The herald net is used as a **clock**. The synthesis tools insert a global
clock buffer on it (Yosys `clkbufmap`, and Vivado's default BUFG inference); the
routed open-flow netlist goes via the MRCC pin's CCIO to a BUFGCTRL (docs/05).
A rising edge sets the flop one clock-to-Q
later. The state persists after the pulse because it is stored in a flop. A
combinational `herald & arm` would release the outputs when the 10 ns pulse ends;
the testbench mutation M1 demonstrates exactly that failure (docs/03 §1.3).

Why this structure, and not the alternatives:

| Alternative | Problem |
|---|---|
| Combinational `pump = ~(herald & arm)` | Not persistent |
| SR latch from LUT feedback | Combinational loop. Timing is not analyzable, and Vivado flags it (`LUTLP`). |
| FDPE with herald on the async PRESET | Level-sensitive: a herald that is *already high* when arm rises leaves a runt pulse on PRE. Window ≈ herald width (10 ns) instead of the setup/hold window (~0.1 ns). |
| Synchronize herald, then react | Adds 1–3 clock periods of latency and ±½ period of jitter. Violates the requirement. |
| **Herald as clock, arm on CE** (chosen) | Edge-sensitive. The race window shrinks to the FDCE setup/hold window, and Vivado can analyze it (clock-to-out, CDC constraints). |

### 2.1 Asynchronous-design rules (enforced in RTL, asserted in the testbench)

1. `arm` and `clr_*` are flop outputs, so they are glitch free.
2. A clear is asserted and released **only while `arm` is low**. A herald edge that
   collides with CLR release clocks `CE = 0` and cannot change Q, so a
   recovery/removal violation there is harmless. Assertions
   `a_no_arm_with_clear` and `a_clear_changes_unarmed` check this.
3. **The only real race** is a herald edge inside the setup/hold window of the `arm`
   rising edge at CE.
   - Q may go metastable. In that rare case the immediate outputs may show extra
     settling delay.
   - Path B treats the synchronized `fired` flag as the single truth, so the two
     paths cannot disagree about whether the attempt started.
   - The serdes timestamp is paired with the attempt only if the latch fired.
   - An edge that the serdes saw but the latch did not take is counted as a
     **race** (`CNT_RACE`).
   - A latch that fired without a serdes edge (pulse < 1 ns, or clock stopped) is
     counted as **no-edge** (`CNT_NOEDGE`), and the cycle is aborted safely.
4. Herald minimum pulse width at the flop is the device clock minimum pulse width
   (DS181 T_MPW). Shorter pulses are not guaranteed to set it.
5. The herald clock is constrained at 20 ns. The SPAD dead time is ≥ 22 ns.

### 2.2 Latency estimate (to be replaced by measurement)

Elements: DIO-MCX input buffer and LVDS driver, EEM cable, IBUFDS, ISERDES bypass,
local route, FDCE clock-to-Q, LUT, OBUFDS, EEM cable, DIO-MCX LVDS receiver and
output driver. The FPGA part is bounded by STA (`path_a.rpt`, XDC requirement
≤ 10 ns). The board buffers are unknown until measured. The expected total is
10–25 ns, comparable to the T564's 21 ns. **This is an estimate, not a result.**

## 3. Path B: capture, timestamp, accounting

- **Serdes timestamp.** 1 GS/s samples, 1 ns resolution, ±0.5 ns quantization
  (289 ps RMS). Timestamps are in the "phys ns" frame defined in `qm_pkg.sv`.
- **Raw edge counter.** A 4-bit Gray counter clocked by the herald itself counts
  *every* edge, including sub-nanosecond pulses and edges while the system clock is
  stopped. It is synchronized to clk_sys (only one bit changes per edge).
- **Accounting invariant, checked by the testbench:**
  `CNT_EDGE = CNT_ACC + CNT_REJ + CNT_RACE` and `CNT_RAW = CNT_EDGE + CNT_NOEDGE`.
  No herald disappears without a counter changing.
- **FIFO.** 64 entries of accepted-herald timestamps, with an overflow counter.
  The UART (≈ 10 kB/s effective) cannot stream 1.5 × 10⁵ timestamps/s. Science
  data stays on the external time tagger. A faster link (Ethernet, or ARTIQ RTIO
  input events) is future work.

## 4. Precision: what can and cannot be achieved, and the three tiers

### 4.1 Terms

| Term | Meaning here |
|---|---|
| Absolute propagation latency | Herald pad edge → output pad edge, a fixed offset (e.g. "17 ns") |
| Configurable delay | The programmed D (e.g. D_READIN = 270 ns) |
| Resolution | Smallest step of D: 8 ns (FSM events), 1 ns (serdes pulses), 10 ps (MC100EP195 in Tier 2) |
| Clock quantization | Error from aligning an async event to a clock grid. Uniform over one period, RMS = T/√12. **This is jitter**, because the herald phase is random. |
| Deterministic latency | Same latency after every reset/power-up. Requires fixed serdes word alignment and MMCM phase. Verified by repeated power cycles. |
| Cycle-to-cycle jitter | Variation between consecutive events |
| RMS jitter | Standard deviation of the latency over many events |
| Worst-case uncertainty | Peak-to-peak over the measurement, including drift. Report it together with N and the duration. |

### 4.2 Tiers for the control-pulse trigger

| Tier | Mechanism | Added jitter (expected) | Status |
|---|---|---|---|
| **0** | HERALD_FWD (Path A, gated) → existing DDG (T564/DG645) → PPG512 | FPGA async path (few ps, to be measured) + DDG (< 35 ps per T564 spec) | **Available now.** Hardware rejection, arming and diagnostics come from the FPGA. |
| **1** | FPGA serdes: herald sampled at 1 GS/s, CTRL_A/B placed on a 1 ns output grid | ≈ 289 ps RMS (quantization) + serdes/clock jitter | **Implemented, simulated.** Bring-up and non-critical triggers. Not adequate for photon alignment (budget ≤ 100 ps). |
| **2** | Tier 1 plus a carry-chain TDC on the herald (fine phase, ~15–25 ps bins after calibration) and an external **MC100EP195B** programmable delay per output (10 ps steps, parallel load, 10 ns range), loaded per shot with `(1 ns − phase)` | Target ≤ 30 ps RMS, set by TDC nonlinearity and delay-line INL after calibration | **Design only.** Custom EEM board needed. |

Why not use the FPGA's own delay primitives for Tier 2 on Kasli:
- Artix-7 has **no ODELAYE2** (HR banks only), so output fine delay is impossible in
  the FPGA.
- IDELAYE2 (32 taps × 78 ps, 2.5 ns range, needs a 200 MHz IDELAYCTRL reference)
  can only delay inputs. It can calibrate input skew, but it cannot cancel the
  output-side quantization.
- A carry-chain TDC is buildable in Artix-7 fabric. It needs placement constraints
  (fixed CARRY4 column) and code-density calibration. That is a Milestone 7 item.

Synthesizable SystemVerilog does not by itself guarantee any of these numbers.
Sub-nanosecond figures come only from measurement on the built hardware
(docs/03 §3).

### 4.3 Electrical versus optical timing

The controller fixes the edge at the MCX connector. The quantity that matters to
the atoms is when the light changes:
- SOA turn-off (current driver bandwidth, carrier lifetime),
- Pockels-cell HV driver latency (paper: ~140 ns total to source off),
- EOM response, including the ringing reported in the paper,
- fiber and TA propagation.

These latencies are larger than any FPGA contribution and drift independently.
Each output is therefore calibrated optically with a fast photodiode (docs/03 §4),
and the delay registers hold the electrical value that produces the desired optical
timing.

## 5. Sequencer state machine

```text
          run_en                 T_PREP elapsed, cfg ok          3 cycles
  IDLE ───────────► PREP ──────────────────────────────► REL ─────────────► ARMED
   ▲  (beams off)    ▲ beams on, latches cleared          clears released     │ arm = 1
   │                 │                                   (arm still 0)        │
   │                 │ T_END reached (cnt_done)                               │ sync(fired) ∧ edge
   │                 └──────────────────────────────── ACTIVE ◄──────────────┘
   │                                                   arm = 0, schedule pulses,
   │      run_en = 0 / abort / no-edge / late          restore channels at T_REST
   └──────────────────────────── ABORT ◄───────────────(any of ARMED/ACTIVE/REL)
```

Configuration is snapshotted on PREP → REL, so a cycle always runs with one
consistent parameter set. Invalid configurations (pulse beyond T_END, restore
beyond T_END, off after restore) set `cfg_err`. The sequencer then refuses to arm
(error LED).

## 6. Integration with ARTIQ/Sinara (later)

The critical reaction stays in this gateware and never passes through the ARTIQ CPU.
Two integration routes:

1. **Side-by-side (no ARTIQ changes).** Kasli runs this bitstream. ARTIQ on a second
   Kasli/Kasli-SoC receives HERALD_FWD, CTRL and ACTIVE as ordinary TTL inputs
   (timestamped by RTIO) and configures this controller over the UART through a
   small ARTIQ controller driver (NDSP) wrapping `tools/qmctl.py`.
2. **Embedded (one Kasli).** Instantiate `qm_core` as a Migen `Instance` inside the
   ARTIQ Kasli gateware. Config and status registers become an RTIO output/input
   PHY, so kernels write parameters and read counters and timestamps with RTIO
   timestamps. Herald, kill and control outputs still connect directly between
   `qm_core` and the DIO pins. Accepted-herald timestamps can be pushed as RTIO
   input events, which removes the UART bottleneck.
   - Requires: matching ARTIQ's `rtio`/`rtiox4` clocks (also 125 MHz / 500 MHz on
     Kasli), and replacing `qm_clocking` with ARTIQ's clock domains.

## 7. Relationship to the future DSL

Each construct of the illustrative DSL maps onto one hardware mechanism. This is
the contract a compiler would target:

| DSL construct | Hardware | Timing class |
|---|---|---|
| `on rising(herald)` | herald-clocked FDCE + `arm` gate + `fired` truth flag | async, latency = STA-bounded constant |
| `immediate { pump = low; }` | one kill flop per signal, `CHCFG.imm` | async, no clock |
| `at T { x = low }` (slow) | sequencer compare on the 8 ns grid (`T_OFF`, `T_REST`) | sync, ±8 ns |
| `at T { pulse ctrl for W }` | `qm_pulse_unit` + OSERDES (Tier 1) or TDC + fine delay (Tier 2) | 1 ns grid / ~10 ps |
| implicit "busy until end" | ACTIVE state + latch held | – |
| implicit "prepare ≥ 2 µs before next" | PREP timer | sync |

A compiler would need to know which class each statement requires. It would then
either allocate the corresponding resource or reject the program, e.g. a
`pulse … at 270 ns ± 50 ps` without Tier 2 hardware.
