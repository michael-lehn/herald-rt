# Hardware-readiness review (before first bring-up)

Scope:
- bitstream: `build/openxc7/qm_top.bit` from `make openxc7`, i.e. openXC7 at the
  pins of docs/04, plus the `-nosrl` fix below;
- target: Kasli v2.0.2 + DIO-MCX v1.2.1.

No hardware was available, so every statement below comes from schematics,
datasheets, netlists, the bitstream, or simulation. Nothing here replaces the
measurements in §5.

Sources:
- Kasli v2.0.2 schematic and BOM (sinara-hw/Kasli release v2.0.2);
- DIO-MCX v1.2.1 schematic and v1.1 BOM (sinara-hw/DIO_MCX);
- TI SN65MLVD040 datasheet;
- onsemi 74LVT162245 datasheet;
- AMD DS181 v1.27;
- ARTIQ `ttl_serdes_7series.py`, MiSoC `targets/kasli.py`.

## 1. Verdict

**The current open-flow bitstream is acceptable only for a supervised bench
bring-up with no laboratory equipment connected.** Two board-level facts block
connecting SOA drivers, the Pockels-cell driver or the pulse generator:
1. the missing LVDS input termination (§3.1);
2. undefined DIO-MCX outputs while the FPGA is unconfigured (§3.2).

Each has a defined mitigation. Path A itself is structurally correct and
clock-independent (§2).

## 2. Verified facts

| # | Fact | Evidence |
|---|---|---|
| V1 | Kasli v2.0.2 BOM: **XC7A100T-3FGG484E**, S25FL128S flash (16 MB), FT4232H | Kasli BOM |
| V2 | All 9 used LVDS pairs match the XDC; P/N on the correct `_LxxP/_LxxN` balls, all in bank 34. Herald R4/T4 = EXT0 pair 0 = **IO_L12P/N_T1_MRCC_34** (clock-capable). | Kasli schematic p. 2 |
| V3 | VCCO_34 is on the same rail as VCCO_14 (2.5 V configuration bank); VCCO_35 is 1.5 V (DDR3) | Kasli schematic p. 5 (rail continuity) |
| V4 | Kasli has **no termination** between the FPGA and the EEM connectors | Kasli schematic p. 11 |
| V5 | DIO-MCX: each LVDS pair has **100 Ω across A/B at the SN65MLVD040** | DIO-MCX p. 4 |
| V6 | DIO-MCX M-LVDS receivers are **Type-1** (FSEN strap: R30 10 kΩ up **and** R31 0 Ω to GND, both fitted) | DIO-MCX p. 2, BOM, pick-and-place |
| V7 | DIO-MCX MCX path: switchable 49.9 Ω termination (BSS138, DIP) → 30 Ω → 74LVT162245 A-port (25 Ω internal series on outputs) → B → 22 Ω → M-LVDS. Output source ≈ 55 Ω, so roughly 1.5 V into 50 Ω and roughly 3.3 V into high-Z. | DIO-MCX p. 6, 74LVT162245 DS |
| V8 | 74LVT162245: V_IH 2.0 V / V_IL 0.8 V, t_pd 1.0–4.0 ns, power-up/down high-impedance | onsemi DS |
| V9 | DIO-MCX buffer OEn comes from the supply's power-good, **not from the FPGA**. Bank direction = DIP switch (closed = OUT), wired-AND with a PCF8574A on the EEM I²C. | DIO-MCX p. 2 |
| V10 | Kasli PUDC_B pulled high (R42 fitted, R43 DNP): FPGA I/O **float** (no pull-ups) before and during configuration | Kasli p. 2 |
| V11 | ARTIQ enables **DIFF_TERM = TRUE** on every DIO input it receives on (`InOut_8X`) | ARTIQ source |
| V12 | Post-route: herald → ISERDESE2.O → **BUFGCTRL (inserted by Yosys `clkbufmap`)** → global clock → **11 flops, all FDCE** (bitstream: no FFSYNC, no LATCH, no CLKINV, clear-to-0, CE/SR used) | `scripts/analyze_herald_path.py`, FASM |
| V13 | Each Path A output = **1 herald flop → 1 LUT → OBUFDS**. The only other LUT inputs are static clk_sys flops (`on`, `imm`, `pol`). Nothing clocked by clk_sys sits between herald and pad. Together with sim T11 (clock stopped), Path A does not depend on the 125 MHz clock. | same |
| V14 | Power-up state from bitstream INIT values: `on = 0`, `pol = 0`, `kill = 0`, `arm = 0`, OSERDES `INIT_OQ = SRVAL_OQ = 0`. **All outputs low (beams/source "off", triggers low) from GTS release on**, before MMCM lock or reset. A herald before arming has no effect (CE = 0). | FASM ZINI / ZINIT_OQ |
| V15 | LVDS_25 output encoding (`LVDS_25.OUT` + `DRIVE.I_FIXED` on the master half, no `OUT_DIFF`) matches the Vivado reference bitstream the openXC7 developers compared against | nextpnr `fasm.cc` + vc707-hp-diffio notes |
| V16 | Bitstream round trip: decoded FASM re-encodes to **identical frames**; intended-but-undecoded features carry **0 bits**; IDCODE 0x03631093 (XC7A100T); start-up sequence present | `make bitstream-check` |
| V17 | Bitstream generation is deterministic: two builds differ only in the header timestamp | payload comparison |

## 3. Unresolved risks (ordered by severity)

### 3.1 Missing DIFF_TERM: a real out-of-spec condition (open flow only)

The link is designed as a doubly-terminated M-LVDS link: 100 Ω on the DIO plus
100 Ω inside the FPGA (V4, V5, V11). SN65MLVD040 drives **480–650 mV into ≈50 Ω**.
- Without the FPGA termination, the load is 100 Ω and the swing is roughly
  **0.96–1.3 V**.
- DS181 limit: LVDS_25 V_IDIFF max is **600 mV** (V_ICM 0.3–1.5 V).
- Even ARTIQ's configuration is at or slightly above 600 mV in the worst case.

The receiver will very probably still switch, but it operates outside its
specified conditions, so its delay and jitter are uncharacterised. The open flow
**cannot** fix this: there is no DIFF_TERM feature in either prjxray-db.
- Affects: the herald input, plus any future input.
- Not affected: outputs. The FPGA drives into the DIO's 100 Ω, which is correct.
- Mitigation: produce bitstreams with Vivado for any use beyond bench bring-up.
  For bring-up, measure herald thresholds and latency with the open-flow and
  Vivado bitstreams side by side (§5 M6).

### 3.2 Undefined DIO-MCX outputs while the FPGA is unconfigured (both flows)

Banks set to OUT by DIP switch drive their MCX outputs as soon as the DIO supply
is good (V9). The FPGA side of each pair floats (V10), the M-LVDS receivers are
Type-1 (V6), and the 100 Ω across the pair gives about 0 V differential. **The MCX
output level is then undefined; it may sit high, low, or toggle.** This happens:
- at every power-up until configuration completes;
- during every JTAG reload;
- after a failed configuration.

Configuration time is longer for the open-flow bitstream. It carries no
CONFIGRATE/SPI-width settings (`[current_design]` is ignored), so flash boot
runs at the default CCLK. Using UG470's nominal default of about 3 MHz on SPI ×1,
that is ≈ 10 s for a 3.8 MB image, versus ≈ 0.5 s for Vivado's 33 MHz ×2. This is
an estimate and must be measured.

During this window a pulse generator, EOM or Pockels-cell driver could be
triggered.

Mitigations, in order of robustness:
1. **Direction under gateware control:** DIP switches open, the PCF8574A powers
   up with pins high = all banks IN, and the gateware sets banks to OUT over I²C
   only after outputs are defined. Needs a small I²C master plus Kasli's EEM I²C
   mux in the gateware.
2. Procedure: connect equipment only after configuration (DONE LED, ID register
   read over UART), and never reprogram with equipment connected.
3. Equipment-side interlocks: trigger enable on the PPG and Pockels-cell driver.

Before connecting anything, measure M2.

### 3.3 Path A channels can disagree in the arm race (both flows, design issue)

`arm` reaches the four herald flops with **0.19–0.35 ns skew** in the routed
netlists; it is unconstrained and differs per build. A herald edge in that window
can set some kill flops and not others. Rough rate: arm edges (≈1.5×10⁵/s) ×
herald rate (≈1.5×10⁵/s) × 0.35 ns ≈ **8 events/s** at the paper's rates.
Simulation cannot show this, because its skew is zero.

Consequences:
- a trial with one beam still on (a noisy trial);
- or a kill set without `fired`: that channel stays off while ARMED until the
  next accepted cycle clears it. This is safe but wrong.

Proposed fix, same architecture (asynchronous edge-triggered capture, no clock in
the path): one master herald flop (`fired`) for all channels. Each output becomes
`pol ⊕ (on ∧ ¬(fired ∧ imm ∧ ¬restored_i))`, with `restored_i` a clk_sys flag set
at T_REST_i, so the outputs are consistent with Path B's truth by construction.
Not implemented yet (open design decision).

### 3.4 Herald input threshold

The DIO-MCX input is a 74LVT162245 with V_IH = 2.0 V (V8). The SPCM-AQRH-1x
delivers **2.2 V typical, 1.5 V minimum** into 50 Ω. That leaves 0.2 V typical
margin and negative worst-case margin. This risk was flagged in docs/01 and is
now confirmed by the actual part.

Options:
- measure the SPAD (M4);
- use a 4.4 V SPAD variant (-4x);
- or add a comparator/level translator in front of the DIO.

### 3.5 No configuration CRC in the open-flow bitstream

RCRC is issued but no CRC word is written (`xc7frames2bit` has no option for it),
so the FPGA cannot detect corrupted configuration data. Mitigations:
- flash with read-back verify;
- check the ID register and status over UART after every load;
- use a Vivado bitstream for experiments.

### 3.6 Lower-severity items

- **Clock:** the Si549 is a custom-ordered part (549BACB001937ABG). 125 MHz at
  power-up is assumed, as for ARTIQ's default bootstrap; ARTIQ also supports 100
  MHz. With 100 MHz every ns-timing scales by 1.25 and the UART runs at 800 kbaud.
  A failing UART exposes this immediately; check it (M1).
- **Board revision:** Kasli v2.1 adds an EEM power enable (U21) that this XDC does
  not drive. Confirm the delivered revision.
- **Path A placement is unconstrained in the open flow:** the herald flops landed
  30–40 rows from their pads, and LUT→OBUF routing is 2.2–3.7 ns. The FPGA part
  of Path A is estimated at **8.8–9.3 ns**, close to the 10 ns intended bound,
  and varies between builds. Add LOC/pblock constraints in both flows.
- **IBUF_LOW_PWR="FALSE" is ignored on HR banks by nextpnr** (no
  `DIFF.ZIBUF_LOW_PWR`). Input delay differs between flows, so calibrations don't
  transfer.
- **OVERTEMPPOWERDOWN** and the other `[current_design]` options are absent in
  open-flow bitstreams.
- **74LVT162245 supply:** the onsemi datasheet copy is marked discontinued.
  Check DIO-MCX availability.

## 4. Toolchain limitations (nextpnr / prjxray, verified in source or output)

| Limitation | Consequence | Evidence |
|---|---|---|
| XDC: only pins, IOSTANDARD, `create_clock`, `set_multicycle_path`. Generic SDC: `create_clock`; `set_false_path` "does not do anything (yet)". | No `set_max_delay`, clock groups, output delay or bus skew | `xdc.cc`, `common/kernel/sdc.cc` |
| **Nets driven by herald flops are not timed at all** | herald→clk synchronizer inputs and FF→LUT→pad of Path A are unanalysed | `--detailed-timing-report`: 0 entries |
| No delay model for IOB, BUFGCTRL, ISERDES (empty SDF cells) | Path A cannot be estimated by nextpnr alone | `qm_top.sdf` |
| No DIFF_TERM, no CRC, no `[current_design]` options | §3.1, §3.5, §3.2 | prjxray-db, `xc7frames2bit` |
| Yosys `xilinx_srl` ignores ASYNC_REG | **Synchronizers had been packed into SRL16E** | netlist; **fixed** |
| Yosys `clkbufmap` inserts a BUFG on the herald net implicitly | Herald clock buffer type decided by the tool, not the design | netlist |

**Fixed in this review:** the 8 three-stage synchronizer flops (`u_sync_state`,
`u_sync_raw`) were SRL16E in the open-flow netlist, with their first stage in
LUT-RAM storage, which is unsuitable for metastability resolution.
- `synth_xilinx -nosrl` added in `openxc7_build.sh` and `yosys_synth.ys`.
- `SHREG_EXTRACT = "NO"` added in `qm_sync.sv`, for Vivado explicitness.
- New rule [5] in `analyze_herald_path.py` catches regressions.
- Re-verified at the time: sim 761 checks / 0 errors; nextpnr timing PASS (clk 133 MHz est.).
  Later timing fixes and the 12-seed results are in docs/04 §3.3.

## 5. Required measurements at bring-up (in this order)

| # | Measurement | Setup | Pass criterion |
|---|---|---|---|
| M1 | Clock / basic life | Kasli + DIO-MCX, **no equipment**. LED heartbeat ≈ 1.07 s, `qmctl status`. | ID = QMC1, UART works at 1 Mbaud |
| M2 | **Output behaviour while unconfigured** | 4-ch scope on MCX ch4–7 and ch8–11 (1 MΩ and 50 Ω), single-shot on any edge; power-cycle Kasli, JTAG reload, failed load | outputs stay low, or the behaviour is documented and the mitigation of §3.2 is chosen |
| M3 | Output levels | each output into 50 Ω and into high-Z | ≈1.5 V / ≈3.3 V; edges clean |
| M4 | Herald amplitude and threshold | SPAD pulse at the MCX (50 Ω term on); DG645 amplitude sweep 1.2–3.3 V | firing threshold known with margin over the SPAD minimum |
| M5 | Polarity of every pair | toggle each output via `run`/`stop`/CHCFG | matches docs/01 channel map |
| M6 | Path A latency/jitter, **open-flow vs Vivado bitstream** | docs/03 §3.3 | ≤ 25 ns MCX→MCX; difference between flows quantifies the DIFF_TERM effect |
| M7 | Arm-race consistency | herald at 10⁵–10⁶/s; scope pump vs repump, or a kill-vs-fired mismatch counter (needs §3.3 fix or a counter) | no inconsistent channel state, or the rate is measured |
| M8 | Configuration time / CRC substitute | measure DONE after power-up for both bitstreams; read ID after every load | known window length for §3.2 |

## 6. What stands between the bitstream and a safe first bring-up

**For a bench bring-up with no equipment connected (M1–M5): nothing blocking.**
Set the DIP switches to bank 0 IN (50 Ω on ch0), banks 1–2 OUT, bank 3 IN; then
flash or JTAG-load and run M1–M5.

**Before connecting laboratory equipment:**
1. Results of M2, and a chosen mitigation for undefined outputs during
   configuration (§3.2). Gateware-controlled direction is recommended.
2. A Vivado-built bitstream (DIFF_TERM, CRC, config rate, timing sign-off of the
   CDC and Path A constraints), *or* a documented, measured acceptance of the
   open-flow deviations (M6).
3. A decision on the herald front-end, based on M4 (§3.4).
4. The interface definition of every connected device (polarity, input
   impedance, trigger edge/level), then M3/M5 against it.
5. Recommended before the experiment: the §3.3 consistency fix, plus placement
   constraints for Path A.
