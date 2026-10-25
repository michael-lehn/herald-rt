# Milestone 1 – Requirements and hardware selection

Reference: G. Buser, R. Mottola, B. Cotting, J. Wolters, P. Treutlein,
*Single-Photon Storage in a Ground-State Vapor Cell Quantum Memory*,
arXiv:2204.12389v1 (2022). All section and figure numbers below refer to that preprint.

> **Sources for ARTIQ/Sinara:** an earlier internal architecture study is not
> part of this repository and was not used for this document. All ARTIQ/Sinara
> statements below come from public sources: the migen/ARTIQ source trees,
> Sinara wikis, schematics and datasheets.

---

## 1. What the experiment actually does (control view)

The control-relevant content of Sections III, IV and V and Figs. 2 and 4:

| Element (Fig. 2) | Device | Control input | Role in a cycle |
|---|---|---|---|
| Herald detector | SPAD for 822 nm idler (model not stated for the idler; the signal SPADs are Excelitas SPCM-AQRH-16) | – (source of the trigger) | Idler detection = herald |
| Optical pumping, D1 | ECDL → fiber SOA | SOA current ("fast switching via the SOA current in response to a herald trigger") | Prepares \|F=2,m=2⟩; must be **off** while the photon is stored |
| Repumping, D2 | ECDL → fiber SOA | SOA current | Same |
| SPDC source | 404 nm pump through a **Pockels cell** | PC driver trigger | Rotating the pump polarization switches the source off to suppress uncorrelated background photons during retrieval; takes "about 140 ns upon the detection of an idler photon" |
| Control pulses | ECDL → **Jenoptik AM785** fiber EOM → TA → filters | EOM driven by **PicoQuant PPG512** pulse generator | Gaussian, 3.77(4) ns FWHM; read-in at photon arrival, read-out after the storage time |
| Critical DDG | **Highland Technology T564** (21 ns insertion delay, < 35 ps RMS jitter) | herald | Switches off pump, repump and source "until after the photon is retrieved" |
| Second DDG | not named | herald, relayed | "less time critical tasks, including triggering the generation of control pulses and time stamping the idler photon detection" |
| TDC | **qutools quTAU**, 81 ps bins | herald, signal SPADs | Time stamps for the histograms in Figs. 3 and 4 |

The sequence stated in Section V:

1. **Initialize.** Pump and repump are on for at least 2 µs. *"During this pumping
   stage the detection of idler photons is rejected on a hardware level."*
2. **Herald.** After that minimum, an idler detection triggers DDG 1, which switches
   off pump, repump and source pumping until the photon has been retrieved. The
   switching is prioritized to minimize noise, "as the extinction ratio of the
   switches improves over time". Cables are kept short.
3. **Store.** The signal photon reaches the cell about 270 ns after the herald (60 m
   fiber delay). The read-in control pulse must overlap it.
4. **Retrieve.** The read-out control pulse follows after the storage time τs. The
   representative value is 160 ns. τs is scanned up to about 1 µs in Fig. 3b.
5. **Recover.** Pump and repump are switched back on (Fig. 4, feature E) and later
   the source (feature F). The memory "remains ready to accept a photon at any time
   after initialization".

Rate: about 1.5 × 10⁵ attempts per second, set by the heralding rate. 159,752,941
heralds in 20 min is about 1.33 × 10⁵ /s.

### 1.1 Timing parameters and their classification

Classes: **[P]** explicitly specified in the paper · **[D]** derived from stated
relationships or read from a figure · **[C]** configurable because the paper does not
fix it · **[A]** engineering assumption for this prototype.

All times are relative to the herald edge at the controller input (t = 0).

| # | Parameter | Value | Class | Notes |
|---|---|---|---|---|
| 1 | Herald → signal photon at memory | ≈ 270 ns | P | "about"; fixed by the 60 m fiber. Our D_READIN default. |
| 2 | Minimum state-preparation time | 2 µs | P | Our T_PREP = 250 cycles |
| 3 | Herald rejection during preparation | hardware level | P | Implemented by the latch `arm` gate |
| 4 | DDG 1 insertion delay / jitter | 21 ns / < 35 ps RMS | P | Property of the T564, **not** a requirement on us. It is the benchmark the paper's setup met. |
| 5 | Control pulse FWHM | 3.77(4) ns | P | Shaped by PPG512 + EOM. Our design only triggers it. |
| 6 | Storage time (representative) | 160 ns | P | Scanned 0 – ~1 µs in Fig. 3b. Configurable T_STORE. |
| 7 | Retrieval time-bin | 6.48 ns (80 × 81 ps) | P | Analysis window, not a control output |
| 8 | Source switch-off time | ≈ 140 ns after herald | P | Pockels-cell chain latency, measured optically |
| 9 | Remaining control-pulse jitter (excl. idler detection) | 126(3) ps | P | Whole electronic + optical chain |
| 10 | Idler SPAD jitter | > 350 ps | P | Dominates timing alignment; efficiency factor < 0.90(5) |
| 11 | Pump effectively off | ≈ +60 ns | D | Fig. 4 bar starts at τp ≈ −210 ns; τp = t_mem − t_h − 270 ns. **Read from a log plot, ±10 ns.** Includes DDG, driver and SOA latency. |
| 12 | Repump effectively off | ≈ +115 ns | D | Fig. 4, τp ≈ −155 ns. Why repump lags pump by about 55 ns is not stated. |
| 13 | Source effectively off | ≈ +125 – 140 ns | D | Fig. 4 bar start (τp ≈ 125) vs. text ("about 140 ns") |
| 14 | Pump/repump back on | ≈ +570 ns | D | Fig. 4 feature E at τp ≈ 300 ns. About 140 ns after read-out. |
| 15 | Source back on | ≈ +525 ns | D | Fig. 4 feature F at τp ≈ 525 ns (source photons travel the same fiber, so τp = t_switch − t_h) |
| 16 | Read-out time | ≈ +430 ns | D | 270 + 160 |
| 17 | Minimum cycle period | ≈ 0.6 µs + 2 µs | D | Restore + preparation |
| 18 | Electrical trigger → optical control pulse latency (PPG512 + EOM + TA + fibers) | unknown | C | D_READIN must be set to 270 ns minus this latency. **Calibrate.** |
| 19 | SOA driver latency and polarity | unknown | C | Paper gives no driver model. Polarity is per channel in CHCFG. |
| 20 | Pockels-cell driver trigger polarity, width, latency | unknown | C | Only the optical result (~140 ns) is given |
| 21 | Whether the PPG512 is triggered once (pattern contains both pulses) or twice | unknown | C | Both are supported: CTRL_A alone, or CTRL_A + CTRL_B / merged |
| 22 | Read-in vs. read-out amplitude | equal in the paper | C | Not a timing parameter. Separate CTRL_B allows separate PPG channels. |
| 23 | Ordering of pump vs. repump switch-off | pump first (Fig. 4) | C | Per-channel immediate / delayed mode |
| 24 | Herald pulse width at the controller | 10 ns (SPCM-AQRH -1x option) | A | Datasheet. It depends on the actual idler SPAD model. |
| 25 | Herald amplitude | 2.2 V typ., **1.5 V min.** into 50 Ω (AQRH -1x) | A | Datasheet. **Input-threshold risk**, see §4.3. |
| 26 | Minimum herald spacing | ≥ 22 ns (SPAD dead time) | A | Sets the 20 ns herald clock constraint |
| 27 | Trigger width to PPG512 | 10 ns | A | W_CTRL. Check against the PPG512 trigger-input spec. |
| 28 | Added RMS jitter budget for the control trigger | ≤ 100 ps | A | Derived target: √(350² + 100²) = 364 ps, so less than 4 % degradation over the SPAD alone. The paper chain achieved 126 ps total. |
| 29 | Path A latency budget (herald → SOA/PC trigger, electrical) | ≤ 25 ns | A | Matches the T564's 21 ns insertion delay. Optical effect followed 40 – 120 ns later in the paper. |

### 1.2 Representative cycle (timing diagram)

```text
 t (ns, from herald edge at controller input)
        -2000      0   ~20   60   115  140      270       430        525  570       ~2600
          |        |    |    |     |    |        |         |          |    |           |
 HERALD   ________/‾\___________________________________________________________________
                   10 ns
 ARMED    ‾‾‾‾‾‾‾‾‾\__________________________________________________________ ... ____/‾‾
          (≥2 µs PREP before)                                                   (≥2 µs)
 PUMP_EN  ‾‾‾‾‾‾‾‾‾‾\_______________________________________________________/‾‾‾‾‾‾‾‾‾‾‾‾
                     ^ Path A (electrical, ~10–20 ns est.)                    ^ T_REST0 (sync)
 pump light ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\.........(off from ~+60 ns, Fig. 4)........../‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
 REPUMP_EN ‾‾‾‾‾‾‾‾‾\_______________________________________________________/‾‾‾‾‾‾‾‾‾‾‾‾
             (immediate, or delayed by T_OFF1 if the channel is not immediate)
 SOURCE_EN ‾‾‾‾‾‾‾‾‾\__________________________________________________/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
 source light ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\.......(off ~+140 ns PC latency)...../‾‾‾‾‾‾‾‾‾‾‾‾
 HERALD_FWD ______/‾‾‾‾\________________________________________________________________
                    FWD_W (to external DDG/PPG if used)
 CTRL_A   _____________________________________/‾\__________________________________
                                       D_READIN (1 ns grid)
 CTRL_B   ______________________________________________/‾\_________________________
                                                 D_READIN + T_STORE
 photon at memory                             ^270      ^430 (retrieved)
 state    ARMED |ACTIVE.................................................... |PREP ...|ARMED
```

Electrical-to-optical latencies (rows "pump light", "source light") belong to the
connected devices. The controller only sets the electrical edges, so each delay
register has to be calibrated against the optical response (docs/03 §4).

## 2. The hard timing constraints

1. **Persistent shutdown with bounded latency (Path A).** A 10 ns herald must
   switch pump, repump and source off and keep them off for about 0.5 µs, with no
   CPU and no clock in the path. The latency requirement is only tens of
   nanoseconds: the optical switches take 40 – 120 ns anyway, and the photon arrives
   at 270 ns. Jitter at the 100 ps level does not matter here. What matters is that
   the reaction is guaranteed, persistent, and not quantized to a clock period that
   could add 8 ns of random delay.
2. **Control-pulse alignment (the precision problem).** The 3.77 ns control pulse
   must hit a photon of about 1 ns duration at a fixed offset from the herald.
   The paper gives no numerical jitter requirement. It reports that the alignment
   is limited mainly by the > 350 ps SPAD jitter, with 126(3) ps from the rest of
   the chain. HeraldRT therefore uses an **engineering target** of ≤ 100 ps RMS
   added jitter (row 28). The physical need for this target is not established.
   An FPGA timer that counts clock cycles from an asynchronous event adds a
   uniform quantization error of one period, with RMS = T/√12:
   - 8 ns system clock: 2.3 ns RMS. Far outside the target.
   - 1 ns serdes grid (this prototype, Tier 1): 289 ps RMS. Exceeds the target.
     Adequate for bring-up. Whether it measurably reduces the storage efficiency
     has not been determined; that needs a measurement on the experiment.
   - Reaching ≤ 100 ps needs either the herald phase to be measured (TDC) and the
     output corrected with a fine delay line (Tier 2), or the herald forwarded to a
     dedicated DDG, as in the paper (Tier 0). See docs/02 §4.
3. **Arming race.** The re-arm moment and a random herald edge can coincide
   (~1.5 × 10⁵ arm events/s × 1.5 × 10⁵ heralds/s × window). The two paths must
   always agree on whether that herald started an attempt.
4. **Reliable capture of an eligible herald.** A herald that arrives while the
   controller is armed must start the attempt, and that accepted herald must be
   timestamped for scheduling. A pulse too short for the 1 ns sampling grid must
   not go unnoticed; HeraldRT flags it as no-edge and aborts the cycle.
   Counting *all* raw herald edges, including those while not armed, is a
   separate diagnostic goal of HeraldRT (docs/02 §3). It has not been
   established that the experiment requires lossless counting of every event.

## 3. Candidate platforms

All parts below existed and were sold well before 23 Oct 2025. The Artix-7 and
Kintex-7 families date from 2010–2011, the AC701 and KC705 kits from 2012–2013, the
ECP5 Versa from about 2015, Kasli 2.0 from about 2021, and the DIO-MCX 2238 datasheet
from 2022. Verify current stock with the distributor before ordering.

| Criterion | **A: Sinara Kasli 2.0 + DIO-MCX (2238)** | B: AMD AC701 (Artix-7 XC7A200T-2) | C: AMD KC705 (Kintex-7 XC7K325T-2) | D: Lattice ECP5-5G Versa (LFE5UM5G-45F) |
|---|---|---|---|---|
| FPGA | XC7A100T-3FGG484 (speed grade -3 per migen platform file) | XC7A200T-2FBG676C | XC7K325T-2FFG900C | LFE5UM5G-45F |
| Lab I/O | 16 × MCX, 50 Ω-capable, 3.3 V, per-channel 50 Ω termination by DIP switch, direction per bank of 4 | 1 SMA GPIO pair + FMC. Needs a custom FMC front-end | SMA GPIO pairs + 2 FMC. Needs a front-end | Headers. Needs a front-end |
| Direct trigger→output | Yes: LVDS in → fabric FDCE → LVDS out, plus the DIO buffers | Yes | Yes | Yes |
| Async elements | FDCE/FDPE with async CLR/PRE, any net as clock | same | same | Async set/reset FFs |
| Delay primitives | IDELAYE2 only (HR banks; no ODELAY on Artix-7). 32 taps × 78 ps at 200 MHz refclk | same (HR only) | IDELAYE2 **and ODELAYE2** in HP banks | DELAYF/DELAYG on I/O (tap size to verify, Lattice TN1265) |
| Serdes for 1 ns grid | ISERDESE2/OSERDESE2 8:1 DDR at 1 Gb/s, used by ARTIQ's own TTL PHYs on this board | yes (-2: up to 1250 Mb/s HR) | yes | IDDRX4/ODDRX4 gearing |
| Clocking | 125 MHz Si549 DCXO + SMA clock input; ARTIQ-compatible clock tree | 200 MHz oscillator + SMA | 200 MHz + SMA | 100 MHz osc. |
| Tools | Vivado ML Standard (free for XC7A100T) | Vivado free | **Device-locked licence** (included with kit) | Diamond or open-source Yosys/nextpnr |
| SystemVerilog | Vivado: good | good | good | Diamond: limited; Yosys: partial |
| Timing analysis of async paths | Vivado STA: clock-to-out on herald-clocked FFs, datapath-only CDC constraints | same | same | weaker documentation for async constraints |
| ARTIQ integration | **Native**: same board, same EEM cards; the core can later become an ARTIQ PHY (docs/02 §6) | none | none | none |
| Complexity | Low: no custom PCB for Tier 1 | Medium: custom FMC I/O board | Medium–high | High |
| Meets Path A? | Yes (est. ≤ 25 ns incl. buffers, to be measured) | Yes | Yes | Likely |
| Meets the ≤ 100 ps target (assumption, row 28)? | Only with Tier 0 (external DDG) or Tier 2 (TDC + external fine delay EEM) | same | Partly: ODELAY gives ~78 ps output taps, but range 2.5 ns plus calibration | same as A |

**Option E – FPGA plus commercial DDG (the paper's architecture).** The FPGA does
arming, rejection, sequencing and diagnostics. A T564 or SRS DG645 does the
precision delays. This is always available as Tier 0 in our design through
HERALD_FWD.

### 3.1 Selection

**Sinara Kasli 2.0 (XC7A100T-3FGG484) with one DIO-MCX (2238) card on EEM0 + EEM1,
running a custom standalone bitstream (not ARTIQ gateware).**

Reasons:
- **Lab-grade I/O without a custom PCB.** The DIO-MCX gives 50 Ω-capable MCX I/O.
  Its datasheet explicitly recommends it over the isolated DIO-BNC/SMA cards
  (2118/2128) for low-jitter use. The isolated cards are explicitly unsuitable
  because of their isolation components.
- **Proven 1 GS/s serdes I/O.** ISERDES/OSERDES at 1 Gb/s on these EEM LVDS lines is
  exactly what ARTIQ's TTL PHYs use on Kasli, so Tier 1 is known to work
  electrically on this hardware.
- **Same hardware ecosystem the group already evaluated.** The later ARTIQ
  integration path is direct (docs/02 §6).
- **Fully supported tools.** The device is in Vivado's free edition with full
  static timing analysis, including the asynchronous constructs used here.
- **Clear Tier 2 path.** The fine-delay front-end becomes one custom EEM board
  (docs/02 §4), plugged into the same Kasli. This matches the "custom board
  integrating input and output electronics" direction.

What it does **not** solve on its own: control-pulse alignment within the
≤ 100 ps engineering target.
That needs Tier 0 (existing T564/PPG chain driven by HERALD_FWD) or Tier 2.

Fallback: AC701 with a custom FMC I/O board, if Kasli hardware cannot be obtained.

## 4. Required interface circuitry

### 4.1 Input (herald)

SPAD BNC output → 50 Ω coax → BNC–MCX adapter → DIO-MCX ch0 with 50 Ω termination
DIP set ON. The DIO-MCX converts to LVDS on EEM0 d0, which is a clock-capable pair.

### 4.2 Outputs

DIO-MCX ch4–7 and ch8–11 drive 3.3 V into 50 Ω. Each driven device (SOA current
driver modulation inputs, Pockels-cell driver trigger, PPG512 trigger) must be
checked for:
- input impedance (terminate at the far end if it is 50 Ω, otherwise short cables),
- logic threshold,
- polarity, which can be inverted per channel in CHCFG,
- minimum trigger width (FWD_W, W_CTRL).

### 4.3 Open risk: herald amplitude vs. input threshold

The SPCM-AQRH -1x specifies V_OH = 2.2 V typical, **1.5 V minimum**, into 50 Ω. The
DIO-MCX input buffer and its threshold are not in the public wiki. If it is an
LVTTL-type input (V_IH = 2.0 V), the margin is poor, and a weak pulse could be
missed or shortened by an amount that depends on its amplitude. That is an
amplitude-dependent latency, i.e. jitter.

Before use:
1. Read the DIO-MCX schematic (sinara-hw/DIO_MCX releases).
2. Measure the actual SPAD pulse at the DIO input with the scope (docs/03 §3).

If the margin is insufficient, insert a comparator with adjustable threshold. For a
bench solution, use a fast comparator evaluation board or a NIM/TTL level
translator. In Tier 2 this sits on the custom EEM board (ADCMP600-class comparator,
threshold DAC).

## 5. Bill of materials

Part identifiers are given as published by the vendors. Prices and lead times are
not included and must be quoted.

| # | Item | Identifier | Qty | Purpose | Source / link |
|---|---|---|---|---|---|
| 1 | FPGA carrier | Sinara **Kasli 2.0** (XC7A100T-3FGG484, 12 EEM, FT4232H USB JTAG/UART, Si549 DCXO) | 1 | Controller | https://github.com/sinara-hw/Kasli/wiki · vendors: M-Labs (https://m-labs.hk/experiment-control/sinara-core/), Creotech, Technosystem |
| 2 | Digital I/O | Sinara **2238 DIO-MCX** (16 ch, non-isolated, 50 Ω-capable) | 1 | Herald in, all outputs | https://github.com/sinara-hw/DIO_MCX/wiki |
| 3 | EEM ribbon cables | Sinara EEM IDC cable (usually supplied with the card) | 2 | Kasli EEM0/EEM1 ↔ DIO-MCX | with item 2 |
| 4 | Crate or bench mount + 12 V supply | per Kasli 2.0 power-input spec | 1 | Power | Kasli wiki – **verify connector and rating** |
| 5 | Coax | MCX plug ↔ SMA or BNC, 50 Ω, RG316, ≤ 0.5 m | 12 | Lab wiring | e.g. Amphenol RF / Mini-Circuits pre-made assemblies |
| 6 | USB cable | micro-USB (Kasli FT4232H) | 1 | JTAG + UART | – |
| 7 | Programming software | Vivado ML Standard 2023.2+ (free); openFPGALoader | – | Build / program | https://www.xilinx.com/support/download.html · https://github.com/trabucayre/openFPGALoader |
| 8 | Test-pulse source | Stanford Research Systems **DG645** (spec. < 25 ps RMS trigger→output jitter), or the lab's Highland **T564** | 1 | Synthetic herald with known timing | https://www.thinksrs.com/products/dg645.html |
| 9 | Oscilloscope | ≥ 2.5 GHz, ≥ 10 GS/s, 4 ch, low intrinsic jitter (< 1 ps), e.g. Tektronix MSO64B (2.5 GHz option) or Keysight MXR254A | 1 | Latency, edges, levels | vendor sites |
| 10 | Time tagger | Swabian Instruments **Time Tagger X** (≈ 2 ps RMS) or Time Tagger Ultra (Performance edition); the lab's quTAU (81 ps bins) is **not** sufficient for ps-level jitter | 1 | Jitter / drift statistics | https://www.swabianinstruments.com |
| 11 | Fast photodiode | Thorlabs **DET025A** (2 GHz, Si) | 2 | Optical response of SOAs / EOM | https://www.thorlabs.com |
| 12 | Temperature logging | thermocouple logger at Kasli and DIO-MCX | 1 | Drift vs. temperature | – |
| 13 | **Tier 2 only** – custom EEM fine-timing board | onsemi **MC100EP195B** (programmable delay, 10 ps steps, 10-bit parallel), Analog Devices **ADCMP600** class comparator, threshold DAC | – | ≤ 100 ps alignment target (assumption, row 28) | https://www.onsemi.com/products/clocks-timing/clock-generation/programmable-delay-lines |

## 6. Minimal hardware architecture

```text
 SPAD (idler) ─► MCX ch0 ─► DIO-MCX input buffer ─► LVDS EEM0 d0 ─► IBUFDS
                                                                      │
                     ┌────────────────── ISERDESE2.O (bypass) ────────┤
                     │                                                │ ISERDESE2.Q (1 GS/s)
     PATH A (no clock)                                       PATH B (clk_sys 125 MHz)
     FDCE ×3 (C=herald, CE=arm, CLR=clr) ─► LUT ─► OBUFDS    edge detect + timestamp (1 ns)
     FDCE fired ─────────────────────────► LUT ─► OBUFDS    sync(fired) = truth ─► sequencer
       │ pump / repump / source / HERALD_FWD                 │        │            │
       ▼ MCX ch4..7 ─► SOA drivers, PC driver, ext. DDG      │   counters, FIFO   pulse units
                                                             │   UART regs        │ OSERDESE2
                       arm, clr_* ◄──────────────────────────┘                    ▼ MCX ch8,9
                                                                            CTRL_A/B ─► PPG512
```

Which part of the design uses which timing technique:

| Function | Technique | Why |
|---|---|---|
| Kill pump/repump/source on herald, hold until restore | **Asynchronous state element** (herald-clocked FDCE) | Persistent state without waiting for a clock edge |
| Gated herald copy (HERALD_FWD) | Asynchronous state element | Same edge, deterministic latency, rejects heralds when not armed |
| Polarity, masking | **Combinational** (one LUT after the flop) | No state needed |
| Arming, clearing, restore times, preparation timer | **Synchronous FSM** (8 ns) | Tolerates clock quantization (optical response is 40–120 ns) |
| Herald timestamp, counters | Synchronous + **serdes oversampling** (1 ns) | Diagnostics, scheduling |
| Control-pulse triggers | Serdes **1 ns grid** (Tier 1), external DDG (Tier 0) or TDC + external fine delay (Tier 2) | The only path to which the ≤ 100 ps target (assumption) applies |
