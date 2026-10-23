# Verification, implementation and physical validation

Three different kinds of evidence, kept strictly apart:

| Kind | Question | Tool | Status |
|---|---|---|---|
| Functional verification | Does the logic do the intended thing? | Verilator RTL simulation, assertions | **Done: 800 checks, 0 errors** |
| Timing verification | Does the placed and routed design meet its clock and path constraints? | Vivado STA | **Not done.** Vivado was not available; scripts are prepared. The openXC7 flow passes its (non-sign-off) timing at 125 MHz, see docs/04. |
| Physical validation | What are the real latency, jitter, levels and optical response? | Scope, time tagger, photodiodes | **Not done.** No hardware yet. |

RTL simulation with ideal I/O models proves nothing about picosecond timing.

## 1. Functional verification

### 1.1 Reproduce

```sh
make lint      # Verilator -Wall on all synthesizable RTL (+ I/O models)
make sim       # builds and runs tb/tb_qm_top.sv, writes build/sim_qm_top.log
make yosys     # 7-series technology mapping (no P&R), build/yosys_stat.txt
```

Tested with Verilator 5.052 and Yosys 0.70 on macOS. The testbench needs a
simulator with `--timing` support for `#` delays inside the models and the
testbench. The run takes about 1 s.

### 1.2 What is tested (tb/tb_qm_top.sv)

All configuration and readback goes through the real UART bridge. The testbench
runs it at 16 clocks/bit to keep simulation short; the bitstream uses 125
clocks/bit.

| Test | Requirement covered |
|---|---|
| T1 | Reset, initial output states (beams off, triggers low), ID register, herald in IDLE ignored |
| T2 | Register write/readback. Initialization: beams on in PREP. Herald during preparation rejected. Preparation ≥ T_PREP before arming. |
| T3 | Herald detection; immediate reaction of pump/repump/source/fwd at the herald time; **persistence** 50 ns after the pulse ended; read-in at exactly `ceil_1ns(herald) + D_READIN`; read-out after T_STORE; widths; ordering; restore windows; FWD width |
| T4 | Storage intervals 40 / 160 / 500 ns |
| T5 | Second herald during the active window: no retrigger, no output disturbance |
| T6 | Two heralds 25 ns apart while armed: one experiment, timed from the first |
| T7a | **400 ps** herald between two serdes samples: latch still fires (Path A); Path B flags no-edge, aborts, restores beams, emits no control pulses |
| T7b | 1.2 ns herald: accepted normally |
| T8 | 24 random herald phases relative to the clock (ps resolution): offset always in (0, 1 ns]. Prints quantization statistics. |
| T9 | Herald while clears are released but arm still low: no effect, not accepted |
| T10 | Herald exactly at the arm edge: resolved consistently (accepted ⇔ pulses) |
| T10b | Herald 1.5 ns **before** arm: seen in the guard band, latch not fired, counted as race, still armed |
| T11 | **System clock stopped**: herald still switches pump/repump/source/fwd and the state holds. After restart, the unseen herald is flagged and the system recovers. |
| T12 | Host abort inside the active window: read-out cancelled, beams restored |
| T13/T14 | Delayed (non-immediate) repump at +100 ns; inverted pump polarity |
| T15 | 10 repeated cycles, then the counter invariants: `edge = acc + rej + race`, `raw = edge + noedge`, `done` and `acc` match the testbench's own bookkeeping, FIFO level = accepted |
| T16 | Every FIFO timestamp equals the herald's 1 ns sample time |
| T17 | An inconsistent configuration (read-out beyond T_END) is never armed; cfg_err reported and cleared |
| T18 | Register-map read-back of all configuration registers, LAST_TS, counters; unmapped addresses read `0xDEADBEEF`; the UART reply starts exactly 8 ns after the address byte |
| T2 (regression) | Beams on → ARMED takes exactly T_PREP + 4 cycles |

Concurrent assertions, active throughout:
- arm never high while a clear is active,
- clears change only while disarmed,
- pulse enable only in ACTIVE,
- all beams on while armed.

### 1.3 Does the testbench detect real bugs? (mutation check)

Mutants were built from a scratch copy of the sources (M1–M3 on an earlier revision, M4–M5 on the current one):

| Mutant | Result |
|---|---|
| M1: Path A made combinational (`kill = herald & arm`) | FAILED, 202 errors (persistence, restores …) |
| M2: IN_LAT off by one cycle | FAILED, 70 errors (timing, FIFO) |
| M3: Path A routed through the clk_sys synchronizer (`kill_s`) | FAILED, 244 errors (immediate reaction, clock-stop test) |
| M4: configuration check one cycle slower (latency budget of the pipelined check) | FAILED: T17 (an invalid configuration would be armed) |
| M5: register read one cycle slower (pipelined read path) | FAILED, 37 errors (read-back, unmapped address) |

The assertion `a_pulses_only_active` also caught a real bug during development:
pulses were not cancelled in the abort cycle. It is fixed in `qm_sequencer.sv`.

### 1.4 Simulation result (current)

```text
T8: herald->read-in offset over 24 random phases: mean 436.1 ps, std 266.8 ps
counters: raw=53 edge=51 acc=45 rej=5 race=1 abort=12 noedge=2 done=44 late=0 fifo=45   (before T17)
800 checks, 0 errors
TEST PASSED
```

The T8 spread is the expected 1 ns quantization of Tier 1 (ideal: uniform,
σ = 289 ps). It is a property of the architecture, not a measured jitter.

### 1.5 Model limitations

`sim/models/qm_io_models.sv` uses zero buffer delays, ideal sampling and no
metastability. The real ISERDESE2/OSERDESE2 latencies and the ISERDES bit order
are **assumptions** in `rtl/vendor/xilinx7/qm_xilinx7_io.sv` and must be calibrated
(§3.2). No simulation was run against the Xilinx UNISIM models, because Vivado/xsim
was unavailable. Run it once Vivado is installed:
`xvlog -sv` with `glbl.v` and the unisims library.

## 2. Synthesis and implementation

### 2.1 Done: Yosys technology mapping for XC7 (not the deployment flow)

`make yosys` maps the full design, including the real vendor wrapper, to 7-series
cells.

```text
FDCE 11 (all clocked by the herald net: 3 kill, 1 fired, Gray counter)
FDRE 2642, FDSE 47, LUT2..6 ≈ 2130, CARRY4 533, RAM64M 22, SRL16E 8
(after the timing pipelining of docs/04 §3.3; before it: FDRE 1840, LUT ≈ 2180)
ISERDESE2 1, OSERDESE2 2, MMCME2_BASE 1, BUFG 5, IBUFDS_GTE2 1
```

This is about 3–4 % of an XC7A100T. Most of the logic is the 64-bit timebase,
the counters and the 32-bit wrap-safe comparators. These numbers only show that
the design is synthesizable and that the latch maps to herald-clocked FDCE cells.
**They are not Vivado results and contain no timing information.**

### 2.1b Done: open-source place & route and bitstream (openXC7)

`make openxc7` → see docs/04 §3. Useful as a routability and timing smoke test;
not a substitute for 2.2.

### 2.2 To do: Vivado non-project flow

```sh
make vivado            # = cd build/vivado && vivado -mode batch -source ../../scripts/vivado_build.tcl
```

Part `xc7a100tfgg484-3`, constraints `constr/kasli_v2_0.xdc`. Outputs:
`qm_top.bit`, `qm_top.bin`, and these reports:

| Report | Check |
|---|---|
| `timing_summary.rpt` | WNS/WHS ≥ 0 for clk_sys (125 MHz), clk_fast (500 MHz), herald (20 ns) |
| `path_a.rpt` | herald pad → pump/repump/source/fwd pads, slow and fast corners. Gives the STA min/max latency of the FPGA part of Path A. Requirement ≤ 10 ns. |
| `cdc.rpt`, `clock_interaction.rpt` | Every herald ↔ clk_sys crossing is covered by the datapath-only max-delay constraints. No unexpected unsafe CDC. |
| `methodology.rpt` | Expect TIMING-xx warnings for the herald driving clock pins from a non-clock buffer. Review each one. |
| `drc.rpt` | Confirm that ISERDESE2 output O is allowed to drive fabric clock pins. If not, use the fallback below. |

**Implementation risk to check first:**
- *Herald on clock pins through `ISERDESE2.O`.* If Vivado rejects it or the route is
  poor, the fallback is to drive both the latch and the serdes from two DIO-MCX
  input channels. Fan the SPAD pulse out externally with a low-jitter buffer, use
  ch0 for the latch and ch1 for the serdes, and keep the latch on a clock-capable
  pair with a BUFR.

### 2.3 Programming

```sh
scripts/program_kasli.sh sram  build/vivado/qm_top.bit   # volatile
scripts/program_kasli.sh flash build/vivado/qm_top.bit   # SPI flash
tools/qmctl.py --port /dev/ttyUSB2 status                # FT4232H UART, 1 Mbaud
```

Verify the FT4232H channel assignment (JTAG vs. UART) on your Kasli. ARTIQ
documents the same board.

### 2.4 Board bring-up checklist

1. Set the DIO-MCX DIP switches:
   - bank 0 (ch0–3) INPUT, ch0 50 Ω termination ON;
   - banks 1–2 (ch4–11) OUTPUT;
   - bank 3 INPUT (unused).
2. Kasli revision: if v2.1, add `eem_pwr_en` (U21) driven high, otherwise the EEM
   cards are unpowered.
3. Check the 125 MHz on `clk125` (MMCM lock, LED heartbeat on user_led[1]).
4. `qmctl.py status`: ID = QMC1, state IDLE.
5. With no lasers connected: `run` → outputs ch4–6 go high; `stop` → low.
6. Check every output's polarity at the MCX connector against the device it drives.

## 3. Physical validation plan

### 3.1 Instruments and required specifications

| Measurement | Instrument | Required spec | Why |
|---|---|---|---|
| Test herald | DG645 or T564 | < 25–35 ps RMS output jitter; separate output for the reference | Known edge; its jitter is subtracted |
| Latency, edge shape, levels | Real-time scope ≥ 2.5 GHz, ≥ 10 GS/s | Intrinsic trigger/timebase jitter ≪ target (≤ 1–2 ps) | 3.3 V edges into 50 Ω; mid-level crossing |
| RMS / worst-case jitter, drift | Time tagger, ≤ 5 ps RMS per channel (Time Tagger X ≈ 2 ps) | 10⁶–10⁸ events | The lab's quTAU (81 ps bins) cannot resolve tens of ps |
| Optical response | Si photodiode ≥ 1–2 GHz (DET025A) + scope | – | Electrical edge ≠ light |
| Temperature | Thermocouples on the FPGA heat sink and the DIO-MCX | 0.1 °C | Drift coefficient |

Rule: instrument contributions are measured with a direct cable between the same
two channels and subtracted in quadrature,
σ_DUT = √(σ_meas² − σ_ref²). That is only valid if σ_meas is clearly larger than
σ_ref; otherwise report an upper bound.

### 3.2 Calibration (Tier 1)

1. **Serdes bit order and latency.** DG645 output A goes to herald ch0. Its output B
   (same trigger, fixed offset) goes to the tagger as reference. CTRL_A also goes
   to the tagger. With D_READIN fixed, record t(CTRL_A) − t(ref) for 10⁵ shots.
   The DG645 is free-running against Kasli's clock, so the herald phase is random.
   - Expected: a **1 ns wide uniform** distribution plus the jitter.
   - A distribution about 8 ns wide, or a bimodal one, means the ISERDES bit order
     or word alignment assumption is wrong.
   - The mean minus D_READIN is the fixed insertion offset. Absorb it into the
     D_READIN setting, or into IN_LAT_CYC/OUT_LAT_CYC if it is a whole-cycle error.
2. **Deterministic latency across resets.** Repeat step 1 after 10 power cycles and
   10 MMCM resets. The mean must not move by whole nanoseconds. If it moves,
   serdes word alignment is not deterministic, and a reset-alignment fix is needed.

### 3.3 Path A measurements

| Quantity | Method | Report |
|---|---|---|
| Propagation delay | DG645 A → herald. Tagger: herald copy (DG645 B) vs. pump/repump/source/fwd MCX outputs, each into 50 Ω | mean per channel; compare with `path_a.rpt` + board buffers |
| Repeatability / RMS jitter | Same, 10⁶ events; subtract reference | σ (ps) |
| Worst case | 10⁸ events / ≥ 1 h | peak-to-peak with N |
| Independence from clock phase | Histogram of delay vs. herald phase. Phase is known from the FPGA timestamp mod 8 ns: read the FIFO, or use CTRL_A as a phase marker. | no correlation expected (it is clock free) |
| Arm-race behaviour | Herald rate 10⁵–10⁶/s, many cycles | CNT_RACE rate; no output glitches (scope trigger on runt pulses) |
| Rate dependence | 10³ … 10⁶ heralds/s | latency shift vs. rate |
| Drift | 24 h log, ambient changes; optional ±10 °C | ps/°C |
| Minimum pulse width | DG645 pulse width sweep 0.3 – 3 ns | smallest width that always fires; CNT_NOEDGE behaviour |
| Input threshold | Herald amplitude sweep 1.2 – 3.3 V | firing threshold; latency vs. amplitude (amplitude walk) |

### 3.4 Control-trigger (Tier 1) and device response

- CTRL_A/B vs. herald: distribution width (expected about 1 ns uniform), mean
  vs. D_READIN, and linearity over 0 – 1 µs.
- PPG512 trigger → optical control pulse (photodiode behind the EOM): latency and
  jitter. That latency is subtracted from 270 ns to set D_READIN.
- SOA pump/repump: electrical edge → optical 90 % / 10 % and extinction vs. time.
  This reproduces Fig. 4 features A, B and E.
- Pockels-cell source switch: electrical edge → optical off/on. Reproduces Fig. 4 D
  and F, the paper's ~140 ns.
- Final check, the same as the paper: time-tag signal photons relative to the
  herald and compare the storage/read-out histogram with Fig. 3a/4.

### 3.5 Acceptance criteria (proposal)

| Item | Criterion |
|---|---|
| Path A latency, electrical, herald MCX → output MCX | ≤ 25 ns, stable within ±0.2 ns over 24 h |
| Path A RMS jitter | ≤ 50 ps (it is not alignment-critical; a sanity bound) |
| Tier 0 (FWD → DDG → PPG) added jitter vs. the paper's DDG-only chain | ≤ 20 ps |
| Tier 1 CTRL | 1 ns uniform ± 50 ps, deterministic across power cycles |
| Tier 2 (future) | ≤ 50 ps RMS total controller contribution |
| Counters | invariants hold after 10⁹ heralds; no silent loss |

## 4. Outstanding work (explicit)

1. Run the Vivado flow, achieve timing closure, review the CDC/methodology/DRC
   reports, and confirm ISERDESE2.O → fabric clock legality.
2. Post-synthesis simulation with UNISIM primitives (bit order, latencies).
3. Board bring-up (§2.4). Confirm the DIO-MCX pin and polarity mapping and its input
   threshold against the SPCM-AQRH -1x levels.
4. All measurements in §3. Until they exist, **no latency or jitter figure of this
   controller is known**.
5. Tier 2 design: carry-chain TDC, MC100EP195B EEM board, per-shot correction.
6. Faster host/event link, or ARTIQ RTIO integration (docs/02 §6).
