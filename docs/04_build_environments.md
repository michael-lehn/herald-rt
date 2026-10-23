# Build environments: Vivado on Apple Silicon, open-source flow, remote x86-64

The hardware target is unchanged: Kasli 2.0, XC7A100T-3FGG484, DIO-MCX.
Everything in this document concerns how the bitstream is produced.

## 0. Development machine (measured 2026-10-23)

| Item | Value |
|---|---|
| Model | MacBook Air (Apple M5) |
| CPU | **Apple M5, arm64**, 10 cores (4 performance + 6 efficiency) |
| RAM | 32 GB |
| OS | macOS 26.6 |
| Rosetta 2 | **not installed** (`arch -x86_64` fails) |
| Pre-installed | Homebrew, Verilator 5.052, Yosys 0.70, Python 3.12/3.15 |

## 1. Summary

| | A1: x86-64 VM, full emulation (UTM/QEMU) | A2: arm64 Linux VM + Rosetta (Colima/UTM/OrbStack), x86-64 container | B: openXC7 (Yosys + nextpnr-xilinx + Project X-Ray), native | C: x86-64 Linux over SSH |
|---|---|---|---|---|
| Runs Vivado | yes, in principle | experimental (community reports) | – (no Vivado) | **yes, AMD-supported OS** |
| AMD support | OS supported, emulation not | **unsupported** | n/a | **supported** |
| Speed | **measured ~67× slower** (qemu-user, CPU-bound test) | expected close to native (Rosetta); **not measured** | **≈ 23–39 s** measured for the complete scripted flow on the M5 (incl. routed netlist + SDF for the review checks) | native |
| Full flow incl. bitstream | untested | untested | **verified** (P&R, bitstream file) | untested (no host available) |
| Honors our XDC (CDC, Path A, false paths) | yes (Vivado) | yes (Vivado) | **no**: only pins, IOSTANDARD, clocks | yes |
| Timing sign-off | yes | yes, if Vivado runs correctly | **no** | **yes** |
| Long-term risk | low | Apple's Rosetta beyond macOS 27 is unannounced for Linux VMs | project maturity | cost / access |
| Recommended role | not recommended | optional local Vivado, after validation | **daily local iteration** | **primary sign-off** |

**Recommendation**
- **Primary workflow:** simulate and run the open flow locally for every change
  (`make sim openxc7`, under 30 s). Run Vivado sign-off on an x86-64 Linux host over
  SSH (`make vivado-remote`) before any bitstream goes to the lab.
- **Fallback:** if no x86-64 host is available, use Vivado inside the x86-64 container
  on the Mac with Rosetta (`make vivado-docker`). Its timing reports should be
  cross-checked once against a native run before they are trusted.
- **Not recommended:** full x86-64 emulation (A1), because of the measured slowdown.

## 2. Task A: Vivado on the MacBook Air

### 2.1 Facts

- AMD ships Vivado for **x86-64 Linux and Windows only**: no macOS build, no arm64
  build. An arm64 Linux VM therefore **cannot run Vivado directly**. Vivado needs
  an x86-64 userspace, provided either by full emulation (A1) or by binary
  translation through Rosetta for Linux (A2).
- **Rosetta for Linux** is the Apple Virtualization framework's binfmt translator for
  x86-64 binaries inside arm64 Linux guests. UTM (Apple Virtualization backend),
  Colima/Lima (`vz` + `--vz-rosetta`), OrbStack and Docker Desktop expose it.
- Community reports that run Vivado this way:
  - [vivado-on-silicon-mac](https://github.com/ichi4096/vivado-on-silicon-mac):
    Vivado 2021.1–2024.1 in a Rosetta container. It notes that most macOS 14
    versions misbehave.
  - [vivado-docker](https://github.com/filmil/vivado-docker): Vivado 2025.2. It needs
    an LD_PRELOAD stub, because the licence/WebTalk code calls
    `udev_enumerate_scan_devices()`, which crashes under Rosetta. It also warns that
    `launch_runs` may crash because its child processes hit the same problem.
- **Mitigating factor for this project:** `scripts/vivado_build.tcl` is a
  *non-project* flow (`synth_design`, `place_design`, … in one process). It never
  calls `launch_runs`, which is the step reported to crash.
- **Risk:** Apple has said Rosetta remains generally available through macOS 27 and
  only a subset afterwards. It has not said what happens to Rosetta for Linux VMs
  ([Apple developer forum](https://developer.apple.com/forums/thread/787530),
  [Eclectic Light](https://eclecticlight.co/2026/03/14/how-to-survive-the-loss-of-rosetta/)).
  Do not make A2 the only path to a bitstream.
- JTAG from inside the VM is not needed: program from macOS with openFPGALoader
  (`scripts/program_kasli.sh`).

### 2.2 What was verified here

| Step | Result |
|---|---|
| `brew install colima docker`; `colima start --profile qm --vm-type vz` | **works** |
| x86-64 container (`--platform linux/amd64`) on that VM, without Rosetta | **works**, via qemu-user binfmt (`uname -m` = x86_64) |
| `docker build` of `docker/vivado/Dockerfile` (Ubuntu 22.04 amd64 + Vivado runtime libraries + udev stub) | **works** (86 s) |
| Entrypoint: stub preloaded when `QM_UDEV_STUB=1`, make present | **works** |
| Speed of qemu-user x86-64 vs arm64, same Python CPU loop | **21.4 s vs 0.32 s (~67×)**. Interpreter code is the worst case, but A1 is clearly impractical. |
| Rosetta-backed container | **not tested**. Needs `softwareupdate --install-rosetta` (accepting Apple's licence), which was deliberately not done. |
| Vivado install and run in the container | **not tested**. Needs an AMD account and the installer. |

### 2.3 Setup (A2, experimental)

```sh
# 1. Rosetta (accepts Apple's licence)
softwareupdate --install-rosetta --agree-to-license
# 2. Linux VM with Rosetta translation for x86-64 containers
brew install colima docker
colima start --profile qm --vm-type vz --vz-rosetta --cpu 8 --memory 24 --disk 200
# 3. Vivado into the docker volume "xilinx" (asks for AMD credentials once;
#    download the Linux "Unified Web Installer" .bin from AMD first)
VIVADO_VERSION=2024.2 docker/vivado/install.sh ~/Downloads/FPGAs_AdaptiveSoCs_Unified_2024.2_*_Lin64.bin
# 4. Build
make vivado-docker              # runs `make vivado` in the container, then check_vivado.sh
```

Checklist for the first run. Each item must be confirmed before A2 counts as working:
1. `vivado -version` in the container.
2. `make vivado-docker` completes, including `write_bitstream`.
3. `timing_summary.rpt`, `path_a.rpt` and `cdc.rpt` are identical in content to a
   run of the same commit on native x86-64 (§4). Timing numbers must match exactly:
   STA is deterministic for identical inputs, version and seed-free placement
   directives.

## 3. Task B: open-source flow (openXC7)

### 3.1 Tool landscape

| Tool | Role | Status for XC7A100T |
|---|---|---|
| **Yosys** `synth_xilinx` | Synthesis | Mature. Already used. |
| **Project X-Ray** (+ openXC7 prjxray-db fork) | Bitstream documentation, FASM→bit | Database contains **`xc7a100tfgg484-3`** (and -1/-2/-2L) |
| **nextpnr-xilinx** (gatecat / openXC7) | P&R | **Archived**; development moved to [openXC7/nextpnr](https://github.com/openXC7/nextpnr) (`himbaechel`, `xilinx` uarch). That is what was used here. |
| **F4PGA** (VPR-based) | Alternative P&R flow | Not tested here. openXC7 is the actively developed xc7 path. |

### 3.2 Verified feature coverage for *this* design

These come from actually running the flow at the pinned revisions (§3.4), plus
inspection of prjxray-db and the nextpnr XDC parser.

| Requirement | Status | Evidence |
|---|---|---|
| Exact device + package `xc7a100tfgg484-3` | **supported** | chip database built; P&R placed all pads on the Kasli pins |
| Clocking: IBUFDS_GTE2 refclk → BUFG → MMCME2 (1000 MHz VCO) → BUFG | **works** | log: MMCM placed via dedicated routing, VCO derived 1000 MHz; 5 BUFGCTRL |
| Async-clear flops (FDCE) | **works** | 11 FDCE, all clocked by the herald net (`check_openxc7.sh`) |
| Herald as a clock domain through `ISERDESE2.O` → fabric → FDCE.C | **routes** | timed as its own clock via `create_clock` on net `herald_async` |
| ISERDESE2 NETWORKING DDR 8:1, OSERDESE2 DDR 8:1 | **placed, in FASM** | prjxray-db has `ISERDES.NETWORKING.DDR.W8`, OSERDES features |
| Constant ties on ILOGIC clock-inverter pins (OCLKB, CLKDIVP) | **unsupported** | router error `Failed to route … OCLKBINV_OUT`. Workaround applied in the vendor wrapper: unused pins left open (valid for Vivado too). |
| LVDS_25 in / out (HR banks) | **works** | FASM: `LVDS_25_SSTL135_SSTL15.IN_DIFF`, 8 × `LVDS_25.OUT` |
| **DIFF_TERM (100 Ω internal LVDS termination)** | **missing** | no such feature in prjxray-db (only single-ended `IN_TERM`). The open-flow bitstream has **unterminated LVDS inputs**. docs/05 §3.1 confirms from the schematics that this is a real out-of-spec condition (≈1 V vs 600 mV V_IDIFF max). |
| Configuration CRC | **missing** | `xc7frames2bit` writes RCRC but no CRC word (docs/05 §3.5) |
| Synchronizers kept as flip-flops | **needed `-nosrl`** | Yosys packed the 3-stage synchronizers into SRL16E despite ASYNC_REG. Fixed (docs/05 §4). |
| Timing constraints | **partial** | supported: pins, IOSTANDARD, `create_clock`, `set_multicycle_path`. **Ignored:** `set_clock_groups`, `set_max_delay -datapath_only`, `set_false_path`, `set_output_delay`, `set_bus_skew`. |
| CDC analysis, Path A pad-to-pad bound | **not available** | follows from the previous row |
| Bitstream config options (SPIx2, CONFIGRATE, compression, CFGBVS) | **ignored** | `[current_design] isn't supported`. The bitstream uses defaults; JTAG load should be fine, SPI boot is untested. |
| Bitstream generation | **works** | `qm_top.bit`, 3.8 MB, header names `xc7a100tfgg484` |
| Runs natively on macOS arm64 | **yes** | built from source with Homebrew clang; setup ≈ 1.5–2 min |
| Runs on arm64 Linux | expected (same sources), **not tested** | |
| Bitstream works on hardware | **untested** | no board |

### 3.3 It found real problems

The first open-flow runs failed nextpnr timing at 125 MHz:
- 99–112 MHz on the first runs;
- 108 MHz after the first fix;
- 102 MHz after the second.

nextpnr's timing model is not sign-off quality, but each critical path it reported
was a genuine design weakness. Each fix is RTL-only, behavior-preserving, and
re-verified (sim: 761 checks, 0 errors at the time):

1. `now_cyc` → 64-bit add → 8 × (subtract + compare) in `qm_pulse_unit`. Fixed
   with a registered ns base counter plus a two-stage pulse unit, compensated by
   `SCHED_LAT = OUT_LAT_CYC + 1`.
2. Combinational `cfg_err` (33-bit sums over the live registers) feeding the arm
   decision. Fixed with the registered `qm_cfg_check`, now applied to the frozen
   snapshot in S_REL. The new testbench case T17 shows an invalid configuration
   never arms.
3. Event times `t_h + T_x` added and compared in the same cycle, plus the late
   check. Fixed by computing absolute times once at accept, from a registered
   candidate. Acceptance is now one cycle later, about 8 ns of the 270 ns budget.

After the fixes, nextpnr estimated clk at 128–151 MHz over seeds 1–5, all passing
125 MHz.

**After the synchronizer fix of docs/05 §4 (2026-10-23):** the extra 24
synchronizer flip-flops cost margin. Seeds 1–5 gave 133.4, 124.2, 139.4, 117.9 and
127.9 MHz, so only 3 of 5 seeds passed. The two failures were on quasi-static paths:
- **seed 2, host read path:** UART bridge address → a single ~30-way, 32-bit
  register read mux in `qm_regs`. About 6 LUT levels, 7.95 ns.
- **seed 4, configuration check:** a 33-bit sum `d_readin + t_store + w_ctrl`
  followed by a 33-bit compare with `t_end` in one cycle (`qm_cfg_check`). Two
  carry chains, 8.38 ns.

**Fixes (minimal, behaviour-preserving):**
- **Read path.** Two registered levels.
  - Stage 1 runs in the same cycle as before. It captures the addressed value in
    one of four groups of eight registers (`addr[6:5]` / `addr[4:2]`); all side
    effects (HI-shadow latch, FIFO pop) stay on this cycle.
  - Stage 2 selects the group or `0xDEADBEEF`.
  - The UART bridge takes its first reply byte straight from `rdata` instead of
    copying it into `txbuf` first, which absorbs the extra cycle.
  - Measured in simulation: **the reply still starts 8 ns after the address byte,
    as before.**
- **Configuration check.** Two stages: the sum and the per-channel compares in
  parallel, then the final compare and OR. The snapshot check is consumed at the
  end of `S_REL`, exactly two cycles after the snapshot, so **arming latency is
  unchanged** (T_PREP + 4 cycles, now asserted by the testbench).
  - A mutant with one more cycle of latency fails T17: an invalid configuration
    would be armed.
- **New regression tests:** exact arming latency, register-map read-back
  including unmapped addresses, LAST_TS read-back, exact UART reply latency.
  Simulation: **800 checks, 0 errors.**

**Result, 12 placement seeds (nextpnr estimates, clk target 125 MHz):**

| seed | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| clk (MHz) | 138.8 | 137.4 | 138.9 | 132.1 | 138.1 | 131.5 | 126.1 | 137.7 | **124.5** | 133.1 | 147.7 | 143.7 |
| herald (MHz) | 540 | 463 | 541 | 541 | 448 | 453 | 365 | 452 | 503 | 540 | 417 | 463 |

- **11 of 12 seeds pass.** Worst: seed 9, 124.5 MHz (0.4 % short); best 147.7 MHz;
  the default seed 1 gives 138.8 MHz.
- Neither targeted path limits any seed any more.
- Seed 9 is limited by a different path: the sequencer's 32-bit `timer`
  comparison (`timer >= T_PREP`), 8.03 ns of which 6.1 ns is routing. Fixing it
  cleanly would change when a mid-preparation write to T_PREP takes effect, a
  register-semantics change, so it was deliberately left as is.
- These are open-flow estimates; Vivado sign-off is still required.

### 3.4 Setup and use (verified on this Mac)

```sh
make openxc7-setup      # = scripts/setup_openxc7.sh; installs into ~/opt/openxc7 (~1.5 GB)
make openxc7            # synth + P&R + bitstream in build/openxc7, then check_openxc7.sh
```

Pinned revisions:
- openXC7/nextpnr `96809c1a`
- openXC7/prjxray `317fdc13`
- openXC7/prjxray-db `a90f27c1`
- Yosys 0.70

Minimal implementation test output (`scripts/check_openxc7.sh`):

```text
  PASS  bitstream written for xc7a100tfgg484
  PASS  nextpnr timing clk: ... 'clk': 138.81 MHz (PASS at 125.00 MHz)
  PASS  nextpnr timing herald_async: ... 353.61 MHz (PASS at 50.00 MHz)
  PASS  placed ISERDESE2 / OSERDESE2 / MMCME2_ADV / IBUFDS_GTE2
  PASS  LVDS_25 differential input configured
  PASS  8 LVDS_25 differential outputs configured
  PASS  11 FDCE cells clocked directly by the herald net
  NOTE  constraints in constr/kasli_v2_0.xdc that this flow does NOT apply:
        set_bus_skew, set_clock_groups, set_false_path x3, set_max_delay x2, set_output_delay x2
        DIFF_TERM requested but absent from the bitstream: LVDS inputs are UNTERMINATED
```

**What the open flow is good for here:**
- fast routability and placement feedback;
- rough timing feedback;
- checking that vendor primitives are instantiated legally.

**What it cannot do:**
- sign off the asynchronous Path A and the CDC constraints;
- terminate the LVDS inputs.

Do not deploy an openXC7 bitstream on the experiment without understanding the
missing DIFF_TERM. Check whether the DIO-MCX→Kasli lines are terminated on the
board; if they are not, signal integrity is compromised.

## 4. Task C: x86-64 Linux build host over SSH

Any AMD-supported distribution works, e.g. Ubuntu 22.04/24.04 LTS or RHEL 8/9.
Sizing for this design (XC7A100T, about 4 % utilisation):
- 4–8 cores,
- 16–32 GB RAM,
- about 100 GB disk (a Vivado ML Standard install with only 7-series devices is
  roughly 30 GB).

It can be a lab workstation or a cloud VM, stopped when idle.

```sh
# on the build host (once)
sudo apt install make rsync git
# install Vivado ML Standard (free, covers XC7A100T) to /tools/Xilinx
# - or use the container: docker/vivado/install.sh on that host

# on the Mac (every build)
REMOTE=me@buildhost VIVADO_SETTINGS=/tools/Xilinx/Vivado/2024.2/settings64.sh make vivado-remote
#   rsync sources -> make vivado remotely -> rsync reports + .bit back -> check_vivado.sh
scripts/program_kasli.sh sram build/vivado/qm_top.bit
```

`REMOTE_CMD="scripts/vivado_docker.sh" make vivado-remote` runs the same container
image natively on the host. That gives identical tool environments for A2 and C.

Status: scripts written and syntax-checked (`sh -n`). **Not run**, because no x86-64
host or Vivado installation was available.

## 5. An additional platform for a smoother workflow (not a replacement)

Lattice ECP5 has the most mature fully open flow:
- nextpnr-ecp5 with proper timing analysis;
- native arm64 builds;
- openFPGALoader programming.

A bench board such as the ECP5 Versa would allow rapid hardware experiments with the
herald latch without any Vivado. It cannot run the Kasli/DIO-MCX target, and Sinara
has no ECP5 carrier, so it is only useful as a side test bed. It has not been evaluated
in depth.

## 6. Verified vs. assumed

| Verified (run here) | Assumed / untested |
|---|---|
| Host: M5 arm64, 32 GB, macOS 26.6, no Rosetta | Vivado runs under Rosetta in the container |
| openXC7 toolchain builds natively on macOS arm64 (`setup_openxc7.sh`, pinned) | openXC7 builds on arm64 Linux |
| Full open flow on `qm_top`: synth, P&R, FASM, `.bit` for xc7a100tfgg484-3 | That `.bit` configures a real Kasli correctly |
| nextpnr timing PASS at 125 MHz (5 seeds), after 3 RTL timing fixes | That Vivado STA also passes (expected, since its model is less pessimistic; not shown) |
| DIFF_TERM absent from prjxray-db and from the bitstream | DIO-MCX/Kasli board termination (needs the schematic) |
| nextpnr ignores the CDC / Path A / false-path constraints | – |
| Colima vz VM runs x86-64 containers via qemu-user; image builds; ~67× slowdown measured | Rosetta-backed speed; Vivado install via `install.sh` and `install_config.txt` |
| Simulation 800 checks / 0 errors after the RTL changes; lint clean | `check_vivado.sh` parsing (written against documented report formats) |
| | `vivado_remote.sh` against a real host |
