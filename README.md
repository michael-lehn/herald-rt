# HeraldRT

**Event-Driven FPGA Control for Quantum Experiments**

HeraldRT is a SystemVerilog controller that reacts to a single external
event — the detection of a *herald* photon — in dedicated hardware.

A single herald trigger drives two separate hardware paths:
- **Path A** switches laser and photon-source signals off without any processor,
  software or system-clock edge in the path.
- **Path B**, a synchronous path, time-stamps the same event, sequences the rest
  of the experiment and reports to a host.

The design targets a [Sinara Kasli 2.0](https://github.com/sinara-hw/Kasli/wiki)
(AMD Artix-7 XC7A100T) with a DIO-MCX digital I/O card. It is designed around the
control requirements of a published quantum-memory experiment.

> **Status in one line:** the design is simulated (800 self-checks pass),
> synthesised, placed and routed with the open-source openXC7 flow, and a
> bitstream is generated. **It has not yet run on hardware.** No latency or
> jitter has been measured, and Vivado timing sign-off is still open. See
> [Verification status](#7-verification-status).

---

## 1. The experiment

The reference is Buser *et al.*,
[*Single-Photon Storage in a Ground-State Vapor Cell Quantum Memory*](https://arxiv.org/abs/2204.12389)
(2022). It stores single photons in a warm rubidium vapour cell and retrieves them
later.

![Experiment schematic](docs/figures/experiment.svg)
*Figure 1 – Simplified schematic of the reference experiment (original drawing based on the paper's description).*

- **Photon pairs.** A violet pump laser (404 nm) drives a nonlinear crystal in an
  optical cavity (spontaneous parametric down-conversion). Occasionally it emits
  a *pair* of photons at the same instant: a **signal** photon at 795 nm, which
  is the one to be stored, and an **idler** photon at 822 nm.
- **Herald.** The idler goes to a single-photon detector. A detector click
  *heralds* that a signal photon now exists and is on its way. The click is a
  random, asynchronous electrical pulse. It is the event this project is about.
- **Optical delay.** The signal photon travels through about 60 m of fibre and
  reaches the memory **≈ 270 ns** after the herald. Within these 270 ns the
  electronics must switch the preparation beams off and trigger the first
  control pulse.
- **Memory.** Before a photon can be stored, pump and repump lasers prepare the
  atoms in one quantum state for **at least 2 µs**. After a herald, these beams
  are switched off until the photon has been retrieved; the paper prioritises
  this switching to minimise noise.
  - A strong optical **control pulse (3.77 ns FWHM)** maps the arriving photon
    into the atoms.
  - A second control pulse after the **storage time** (160 ns in the paper's main
    example) retrieves it.
- **Source switching.** A Pockels cell also switches the photon source off
  during retrieval, to suppress unrelated background photons.

The paper performs this cycle about 1.5 × 10⁵ times per second. A herald
triggers a commercial digital delay generator (Highland T564, 21 ns insertion
delay, < 35 ps RMS jitter), which switches off pump, repump and source. A second
delay generator triggers the control-pulse generation. The paper reports that
the alignment of control pulse and photon is limited mainly by the > 350 ps
jitter of the idler detector. It estimates that this reduces the efficiency by a
factor of < 0.90(5), and measures the remaining control-pulse jitter, excluding
the idler detection, as 126(3) ps.

## 2. The timing challenge

The experiment needs two very different kinds of timing:

| Requirement | What matters | What the paper gives |
|---|---|---|
| **Shut off** pump, repump and source after a herald, and keep them off until retrieval | A short, *reliable* latency and a persistent state after a ~10 ns pulse | A DDG with 21 ns insertion delay. The source is off ≈ 140 ns after the herald (text); pump and repump are off ≈ 60–115 ns after it (read from Fig. 4). The optical switches dominate. |
| **Align** the control pulses with the photon | Low jitter of the pulse relative to the herald | No numerical requirement. Idler detector > 350 ps (dominant), rest of the chain 126(3) ps. |

This distinction drives the whole design:
- **Not every operation needs picosecond precision.** The shutdown only has to be
  fast and guaranteed.
- **The alignment is the precision problem.** An FPGA that counts clock cycles
  from an asynchronous event adds a uniform quantisation error of one clock
  period: 2.3 ns RMS at 8 ns, 289 ps RMS at 1 ns.
- **Electrical edges are not optical edges.** SOAs, Pockels cells and EOMs add
  their own latencies. Each output must therefore be calibrated against the
  light it controls.

**What is and is not established about the alignment requirement.**
- HeraldRT uses a target of **≤ 100 ps RMS added controller jitter**
  ([docs/01](docs/01_requirements_and_hardware.md), row 28). This is an
  *engineering assumption*: added in quadrature to the 350 ps detector jitter it
  increases the total by less than 4 % (√(350² + 100²) ≈ 364 ps). The paper
  states no such threshold.
- Whether the ≈ 289 ps RMS quantisation of Tier 1 (below) would measurably
  reduce the storage efficiency is **not established**. The question needs a
  measurement on the experiment, for example the efficiency as a function of a
  known added control-pulse jitter.

The [timing diagram](#figure-4) shows one complete cycle.

## 3. Background: ARTIQ and Sinara

[ARTIQ](https://m-labs.hk/experiment-control/artiq/) is the standard open-source
control system for atomic-physics experiments. On a Kasli board the FPGA contains:
- the RTIO core, which executes *time-stamped* input and output events with
  nanosecond resolution;
- a soft CPU (VexRiscv) that runs compiled experiment kernels.

Outputs scheduled *in advance* are timed precisely by gateware.

![ARTIQ feedback loop](docs/figures/artiq-feedback.svg)
*Figure 2 – A representative CPU-mediated feedback scenario. The numbered markers identify latency contributions; none were measured in this project.*

Reacting to an *unpredictable* external event is different: the input event is
time-stamped, a kernel reads it, decides, and writes a new output event, which
must carry a future time stamp (*slack*). The reaction then includes kernel time,
clock-grid quantisation, FIFO and EEM-link transfers, and the output electronics
(an Urukul DDS, for example, needs an SPI transfer before its output changes).

This is an **architectural concern from our earlier investigation, not a measured
deficiency of ARTIQ.** That investigation proposed moving the critical path into
dedicated FPGA logic, possibly with a custom I/O board and programmable delay
lines. HeraldRT implements the dedicated logic on stock Sinara hardware; the custom
board and delay lines remain proposals.

## 4. Our approach: one trigger, two paths

![HeraldRT architecture](docs/figures/herald-architecture.svg)
*Figure 3 – HeraldRT as implemented in `rtl/`. Dashed grey blocks are proposals.*

**Path A — direct reaction** ([`qm_herald_latch.sv`](rtl/qm_herald_latch.sv),
output logic in [`qm_core.sv`](rtl/qm_core.sv)):
- **The herald is the clock of a few flip-flops (FDCE).** Its rising edge sets the
  *kill* flops for pump, repump and source and a *fired* flag; the state persists
  after the pulse ends. One LUT per output applies polarity and masking,
  `out = pol ⊕ (on ∧ ¬(kill ∧ imm))`. The route is herald input → global clock
  buffer → flop → LUT → output buffer, with no CPU and no system-clock edge.
  Estimated latency, not measured: ≈ 8–9 ns inside the FPGA (from routed delays),
  ≈ 15–25 ns connector to connector including the DIO-MCX buffers (Figure 4).
- **Arm, trigger, re-arm.** The flops are armed through their clock enable (`arm`)
  and cleared through their asynchronous clear, both driven by synchronous logic.
  Clears change only while `arm` is low, so a herald at a clear release is
  harmless.
- **The arming race is only partly resolved.** Path A consists of four independent
  herald-clocked flip-flops (three kill flops and `fired`), each sampling `arm`.
  A herald edge inside `arm`'s setup/hold window, widened by the routed skew of
  `arm` between these flops, can set some of them but not others.
  - *Synchronous state:* consistent. The sequencer decides acceptance only from
    the synchronised `fired` flag, so counters, time stamps and the scheduled
    pulses agree with one decision.
  - *Physical Path A outputs:* **not guaranteed consistent.** A beam can stay on
    during an accepted attempt, or switch off without one and stay off until a
    later cycle clears it. The gateware does not detect this; simulation cannot
    show it (zero skew). This is an open hardware issue
    ([docs/05 §3.3](docs/05_hardware_readiness.md)). The proposed fix, deriving
    all outputs from one master flip-flop, is not implemented.
- **Risks of an asynchronous clock:** metastability at the arming edge, a minimum
  pulse width, clock-enable skew between flops, and limited open-source timing
  analysis. All are analysed in [docs/05](docs/05_hardware_readiness.md).

**Path B — acquisition and control** (synchronous, 125 MHz system clock):
- An input serdes samples the herald at 1 GS/s, giving **1 ns time stamps**.
  [`qm_edge_capture.sv`](rtl/qm_edge_capture.sv)
- A Gray-coded counter, itself clocked by the herald, counts herald edges in
  every state, including edges the serdes may miss (within the flip-flops'
  minimum pulse width). It is a diagnostic and does not influence any control
  decision. In simulation the counters reconcile:
  `edges = accepted + rejected + race`, and `raw = edges + unseen`. On hardware
  the second identity holds only if every edge missed by the serdes arrives
  while armed.
- The **sequencer** ([`qm_sequencer.sv`](rtl/qm_sequencer.sv)):
  - enforces a programmable minimum preparation time (default 2 µs, the
    paper's value) and rejects heralds while not armed;
  - pairs the accepted herald with its time stamp;
  - schedules the read-in / read-out triggers on a 1 ns output grid
    ([`qm_pulse_unit.sv`](rtl/qm_pulse_unit.sv));
  - restores the beams at programmable times;
  - re-arms.
- **Host link.** Counters, a 64-entry time-stamp FIFO and a register file are
  reachable through a 1 Mbaud UART ([`qm_regs.sv`](rtl/qm_regs.sv),
  [`qm_uart.sv`](rtl/qm_uart.sv)), using [`tools/qmctl.py`](tools/qmctl.py).

**Separation of responsibilities.** Once armed, the shutdown happens in hardware
whether or not any software ever reads the event. The host only configures and
observes.

**Timing tiers for the control pulses:**

| Tier | Mechanism | Status |
|---|---|---|
| 0 | Forward the gated herald (`HERALD_FWD`) to an external delay generator, as in the paper | Output implemented and simulated; external DDG required. Jitter of the forwarding path not measured. |
| 1 | FPGA-generated triggers on a 1 ns serdes grid | **Implemented and simulated.** ≈ 289 ps RMS quantisation (T/√12), a property of the architecture, not a measurement. Adequacy for photon alignment not established (§2). |
| 2 | Herald phase measurement (TDC) plus a fine output delay: an external programmable delay line on Kasli (e.g. MC100EP195B, 10 ps steps), or an FPGA with runtime-programmable output delays | **Proposal only.** Nothing implemented. |

### Fine timing on the current hardware: findings so far

These findings come from datasheets and toolchain sources, not from
measurements.
- **The Kasli outputs are limited to the serdes grid.** The Artix-7 has only
  HR I/O banks, which have no output delay element (ODELAYE2; AMD UG953). An
  output edge can only be placed by OSERDESE2, at most 1250 Mb/s at speed
  grade -3 (DS181). That is an 800 ps grid, ≈ 231 ps RMS, against 1 ns now.
- **A TDC alone does not remove output quantisation.** A carry-chain TDC can
  measure the herald phase, but the pulse still lands on the output grid. Tier 2
  needs both the phase measurement and a fine output delay.
- **Board buffers need calibration.** The DIO-MCX output path has propagation
  delays of several ns with part-to-part spread: the SN65MLVD040 receiver is
  specified at 2.5–6 ns, the 74LVT162245 at 1–4 ns. Its added jitter is
  unmeasured.
- **Alternative under consideration.** Some FPGA families have runtime-loadable
  output delays that compensate for voltage and temperature. An example is
  ODELAYE3 in TIME mode in the HP banks of the AMD UltraScale+ families (UG861).
  The AMD SCU35 evaluation kit (Spartan UltraScale+ XCSU35P) brings an HP bank
  out to its expansion connector (UG1713).
  - It is a **candidate for a bench evaluation only**: not selected, not
    purchased, and no RTL has been ported.
  - It would still need a herald TDC, an analogue front end for the SPAD input
    and the 50 Ω outputs, and Vivado. openXC7 does not support UltraScale+.
  - Its achievable end-to-end precision is unknown.

<a id="figure-4"></a>
![Timing diagram](docs/figures/timing.svg)
*Figure 4 – One storage-and-retrieval cycle, reconstructed from the paper and the HeraldRT register defaults. Tags: P published, D derived from the paper, C configurable, A assumption. Not a measurement.*

## 5. Hardware platform

> [!WARNING]
> **The current bitstream is not approved for use with connected laboratory
> equipment.** Two board-level issues must be resolved first:
> - **Missing LVDS input termination:** the open-source bitstream cannot enable
>   the FPGA's internal LVDS termination (DIFF_TERM), so the herald input operates
>   outside the receiver's specified conditions.
> - **Undefined outputs during configuration:** while the FPGA is unconfigured,
>   being configured or reloaded, the DIO-MCX outputs can be undefined and might
>   trigger connected equipment.
>
> Full analysis and bring-up procedure: [docs/05](docs/05_hardware_readiness.md).

| Item | Selection |
|---|---|
| FPGA carrier | Sinara Kasli 2.0: AMD Artix-7 **XC7A100T-3FGG484**, Si549 reference (125 MHz assumed, to be confirmed at bring-up), FT4232H USB (JTAG + UART) |
| Digital I/O | Sinara **DIO-MCX (2238)**: 16 MCX channels, 50 Ω-capable, connected over EEM LVDS |
| Lab equipment | herald SPAD; SOA drivers, Pockels-cell driver, pulse generator / EOM (as in the paper) |

**Why this platform:**
- a mature FPGA architecture and free tools;
- laboratory-grade digital I/O without a custom PCB;
- the same hardware ecosystem as ARTIQ, which gives a path to later integration.

**Limitation:** the Artix-7 has no output delay element, so FPGA-generated
control pulses on the DIO-MCX outputs are limited to the serdes grid (§4).

HeraldRT runs as a **dedicated bitstream**; its critical path does not depend on
the ARTIQ runtime. Pin assignments were checked against the Kasli v2.0.2
schematic ([constraints](constr/kasli_v2_0.xdc)).

**Open hardware questions** (from schematics and datasheets, see
[docs/05](docs/05_hardware_readiness.md)):
- **Input threshold:** the SPAD's 2.2 V typical / 1.5 V minimum output against the
  DIO-MCX buffer's 2.0 V threshold.
- **LVDS termination:** the receiver termination (DIFF_TERM) is missing in
  open-flow bitstreams.
- **Undefined outputs during configuration:** DIO-MCX outputs are undefined while
  the FPGA is not yet configured.
- **Unverified on real boards:** signal polarity on every channel, the board
  revision, and all propagation delays.

**No hardware has been purchased, programmed or measured for this project yet.**

## 6. Implementation

| Module | Responsibility |
|---|---|
| [`qm_herald_latch`](rtl/qm_herald_latch.sv) | Path A flops (herald-clocked), Gray edge counter |
| [`qm_edge_capture`](rtl/qm_edge_capture.sv) | 1 ns edge detection and time stamps from the serdes |
| [`qm_sequencer`](rtl/qm_sequencer.sv) | arm / clear protocol, accept / reject, scheduling, restore, preparation |
| [`qm_pulse_unit`](rtl/qm_pulse_unit.sv) | wrap-safe 1 ns pulse generation (two pipeline stages) |
| [`qm_cfg_check`](rtl/qm_cfg_check.sv) | registered consistency check; an invalid cycle is never armed |
| [`qm_regs`](rtl/qm_regs.sv), [`qm_fifo`](rtl/qm_fifo.sv) | configuration, status, counters, time-stamp FIFO |
| [`qm_uart`](rtl/qm_uart.sv) | host register access |
| [`qm_sync`](rtl/qm_sync.sv) | clock-domain synchronisers |
| [`qm_xilinx7_io`](rtl/vendor/xilinx7/qm_xilinx7_io.sv) | **all** AMD primitives: MMCM, ISERDESE2, OSERDESE2, LVDS buffers |
| [`qm_top`](rtl/qm_top.sv) | Kasli 2.0 / DIO-MCX pin-level top |

Module names use the prefix `qm_` (quantum memory).

**Decisions worth noting:**
- **Vendor isolation.** Every vendor primitive is confined to one wrapper, which
  has behavioural models of the same name for simulation.
- **Refinement driven by place-and-route.** The open-source flow exposed real
  125 MHz critical paths, each fixed in RTL: the pulse comparison was split into
  two pipeline stages with a registered nanosecond base counter; configuration
  validation was registered and applied to the frozen snapshot; absolute event
  times are precomputed when a herald is accepted. The scheduler compensates the
  added latency, so simulated timing stays exact to the nanosecond.
  The host read mux and the configuration check were split into two registered
  levels; regression tests pin the arming latency (T_PREP + 4 cycles) and the
  UART reply timing, both unchanged.
- **A tool-induced defect was caught by netlist review.** Yosys had packed the
  three-stage clock-domain synchronisers into SRL16E shift registers, despite
  `ASYNC_REG`. They are now forced to be flip-flops (`-nosrl`, `SHREG_EXTRACT`),
  and a script checks this on every build.

## 7. Verification status

| Item | Result | Evidence |
|---|---|---|
| Functional simulation (Verilator) | **800 checks, 0 errors**; mutation tests show the bench detects broken Path A logic and one-cycle latency errors | [`tb/tb_qm_top.sv`](tb/tb_qm_top.sv), [docs/03](docs/03_verification_and_validation.md) |
| Lint (Verilator `-Wall`) | clean | `make lint` |
| Synthesis (Yosys, XC7) | maps; 11 herald-clocked FDCE, no SRL in synchronisers | `make yosys` |
| Place & route (openXC7, xc7a100tfgg484-3) | routes. Default seed: **138.8 MHz estimated** vs 125 MHz target. 12 seeds: 124.5–147.7 MHz, **11 of 12 pass**; worst seed 0.4 % short. | `make openxc7`, [docs/04](docs/04_build_environments.md) |
| Bitstream | generated (3.8 MB). Independent decode reproduces identical frames. **No configuration CRC.** | `make bitstream-check` |
| Path A structure (post-route) | herald → BUFG → FDCE → LUT → OBUFDS, no system-clock element in the path | `scripts/analyze_herald_path.py` |
| Build host | runs natively on an Apple M5 MacBook Air; full scripted flow ≈ 23–39 s | – |
| Vivado timing sign-off | **not done** | – |
| Hardware test, latency, jitter, electrical compatibility | **not done** | plan in [docs/03](docs/03_verification_and_validation.md) §3 |

The timing figures above are nextpnr *estimates*. nextpnr does not honour the
design's clock-domain-crossing and pad-to-pad constraints, and it does not time
the herald-driven nets at all. Only Vivado static timing analysis and measurements
on the board can establish those numbers.

## 8. Quick start

Prerequisites:
- Verilator ≥ 5 (with `--timing`) and Yosys, for simulation and synthesis;
- the openXC7 toolchain for place and route, built by `make openxc7-setup`;
- LuaLaTeX and Poppler, for the figures only.

```bash
make sim            # self-checking testbench (≈ 1 s)
make openxc7-setup  # one-time: build nextpnr-xilinx + Project X-Ray (~2 min)
make openxc7        # synthesis, P&R, bitstream, Path A review
make figures        # rebuild documentation figures (LuaLaTeX + TikZ -> SVG)
```

The generated bitstream is for bench bring-up only, not for operation with
connected equipment (see the [warning in §5](#5-hardware-platform)).

Vivado (x86-64 Linux, local or over SSH) and programming are covered in
[docs/04](docs/04_build_environments.md) and [docs/03](docs/03_verification_and_validation.md).

## 9. Limitations and next steps

1. Gain margin on the remaining near-critical sequencer paths: 1 of 12 seeds
   misses 125 MHz by 0.4 % on the `timer` compare
   ([docs/04 §3.3](docs/04_build_environments.md)).
2. Run Vivado for timing sign-off, CDC analysis, DIFF_TERM and a configuration CRC.
3. Make outputs safe during FPGA configuration. Recommended: gateware-controlled
   DIO-MCX direction.
4. Derive all Path A outputs from one herald flip-flop, to remove the
   inter-channel arming race.
5. Bench bring-up, then latency and jitter measurement with a ps-class time tagger
   ([docs/05](docs/05_hardware_readiness.md) §5).
6. Establish the alignment requirement experimentally: the sensitivity of the
   storage efficiency to added control-pulse jitter (§2). Until then Tier 0
   remains the precision option.
7. Only if that measurement requires it, evaluate Tier 2:
   - an external delay line on Kasli;
   - or an FPGA with runtime output delays, starting with a bench test of
     ODELAYE3 and a carry-chain TDC on the SCU35.

## 10. Future work: a DSL for event-driven hardware

The long-term goal is for a scientist to describe an experiment like this:

```text
on rising(herald) {
    immediate { pump = low; repump = low; }
    at storage_delay                { pulse control for pulse_width; }
    at storage_delay + storage_time { pulse control for pulse_width; }
}
```

A compiler would then generate experiment-specific FPGA logic from it. The
compiler must preserve not only the logical behaviour of an experiment, but also
its physical timing requirements. Each construct already corresponds to a hardware
mechanism in HeraldRT, with its own timing class:

| Construct | Mechanism | Timing class |
|---|---|---|
| `on rising(herald)` | herald-clocked capture plus arming | asynchronous |
| `immediate` | Path A flip-flops | asynchronous |
| `at T` | sequencer events | 8 ns grid |
| `pulse` | serdes pulse units | 1 ns grid |

A compiler must reason about exactly these classes, for example by rejecting a
50 ps requirement without Tier 2 hardware.

**The DSL and the compiler do not exist yet.** This controller is the first step
towards understanding which abstractions and timing constraints they need
([docs/02 §7](docs/02_architecture.md)).

## 11. Documentation

| Document | Content |
|---|---|
| [01 Requirements and hardware](docs/01_requirements_and_hardware.md) | experiment analysis, classified timing parameters, platform comparison, BOM |
| [02 Architecture](docs/02_architecture.md) | asynchronous design rules, timing concepts, tiers, ARTIQ integration, DSL mapping |
| [03 Verification and validation](docs/03_verification_and_validation.md) | testbench, synthesis, measurement plan |
| [04 Build environments](docs/04_build_environments.md) | openXC7 (native macOS), Vivado via container / SSH |
| [05 Hardware readiness](docs/05_hardware_readiness.md) | schematic review, netlist and bitstream review, bring-up checklist |
| [Figures](docs/figures/) | LuaLaTeX/TikZ sources; `make figures`, `make figures-check` |

## Use of AI-assisted development

HeraldRT builds on earlier investigations and manually developed prototypes from the German Aerospace Center (DLR) collaboration on real-time control of quantum-memory experiments.

The project explores how experiment-specific control requirements can be implemented directly in FPGA logic, separating latency-critical asynchronous reactions from synchronous experiment sequencing.

Claude has been used as a development assistant for investigating design alternatives, implementing and refining SystemVerilog modules, developing simulation tests, and improving technical documentation.

The underlying experimental requirements and earlier prototypes were developed independently of AI assistance. I direct the engineering work, review the architecture and implementation, and evaluate the results against the experiment's requirements.

The distinction between simulation results, synthesis and place-and-route results, and physical hardware validation is documented explicitly. HeraldRT has not yet been validated on physical hardware.

## Licence

| Part | Licence |
|---|---|
| RTL (`rtl/`, `sim/`, `tb/`), constraints, scripts, tools, container and build files | [Apache License 2.0](LICENSE) |
| Documentation (`README.md`, `docs/*.md`) and the original figures (`docs/figures/*.tex`, `*.svg`) | [CC BY 4.0](LICENSE-DOCS) |

Source files and generated figures carry an `SPDX-License-Identifier`; the
complete mapping, including the documentation files, and the third-party notes
are in [NOTICE](NOTICE).

## References

- G. Buser, R. Mottola, B. Cotting, J. Wolters, P. Treutlein, *Single-Photon
  Storage in a Ground-State Vapor Cell Quantum Memory*, arXiv:2204.12389 (2022).
  <https://arxiv.org/abs/2204.12389>
- ARTIQ: <https://m-labs.hk/experiment-control/artiq/> ·
  Sinara hardware: <https://github.com/sinara-hw>
- openXC7 toolchain: <https://github.com/openXC7> ·
  Project X-Ray: <https://github.com/f4pga/prjxray>
- AMD DS181, *Artix-7 FPGAs Data Sheet: DC and AC Switching Characteristics*.
- AMD UG953, *Vivado Design Suite 7 Series FPGA and Zynq 7000 SoC Libraries
  Guide* (ODELAYE2 availability). AMD UG861, *UltraScale Architecture SelectIO
  Resources* (ODELAYE3). AMD UG1713, *SCU35 Evaluation Board User Guide*.

---

HeraldRT is an independent project. It is not affiliated with or endorsed by the
authors of the reference paper, their institutions, M-Labs, the Sinara project or
any other organisation mentioned here.
