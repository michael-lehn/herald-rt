#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# openxc7_build.sh - open-source implementation of qm_top for Kasli 2.0:
#   Yosys synth_xilinx -> nextpnr-himbaechel (xilinx) -> FASM -> prjxray bitstream
#
# This is an EXPERIMENTAL second flow next to Vivado (docs/04). It produces a
# placed and routed design and a bitstream, but it does NOT honour the CDC,
# Path A pad-to-pad, false-path or DIFF_TERM constraints of constr/kasli_v2_0.xdc
# (nextpnr ignores those commands; see the generated XDC below).
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/build/openxc7}
OPENXC7=${OPENXC7:-$HOME/opt/openxc7}
NEXTPNR_XILINX=${NEXTPNR_XILINX:-$OPENXC7/src/nextpnr/build/nextpnr-himbaechel}
PRJXRAY=${PRJXRAY:-$OPENXC7/src/prjxray}
PRJXRAY_DB=${PRJXRAY_DB:-$OPENXC7/src/prjxray-db}
PRJXRAY_PYTHON=${PRJXRAY_PYTHON:-$OPENXC7/venv/bin/python}
PART=xc7a100tfgg484-3
SEED=${SEED:-1}

mkdir -p "$OUT"
cd "$OUT"

# 1. Synthesis (same sources as the Vivado flow)
SRCS=""
for f in $(cat "$ROOT/scripts/rtl_files.f"); do SRCS="$SRCS $ROOT/$f"; done
SRCS="$SRCS $ROOT/rtl/vendor/xilinx7/qm_xilinx7_io.sv $ROOT/rtl/qm_top.sv"
yosys -q -l yosys.log -p "read_verilog -sv $SRCS; \
  synth_xilinx -flatten -abc9 -nosrl -arch xc7 -top qm_top; \
  tee -q -o yosys_stat.txt stat; write_json qm_top.json"

# 2. Constraints: keep pin/IO properties from the master XDC, restate clocks
#    on the nets nextpnr sees. Everything else is unsupported by nextpnr.
{
  echo "# generated from constr/kasli_v2_0.xdc by scripts/openxc7_build.sh - do not edit"
  grep -E '^set_property .*(PACKAGE_PIN|IOSTANDARD)' "$ROOT/constr/kasli_v2_0.xdc"
  echo "create_clock -period 8.000  [get_ports clk125_p]"
  echo "create_clock -period 20.000 [get_nets herald_async]"
} > qm_top_openxc7.xdc

# 3. Place and route
"$NEXTPNR_XILINX" --device "$PART" --json qm_top.json \
  -o xdc=qm_top_openxc7.xdc -o fasm=qm_top.fasm \
  --router router2 --seed "$SEED" --report report.json --log nextpnr.log \
  --write qm_top_routed.json --sdf qm_top.sdf >/dev/null

# 4. Bitstream
"$PRJXRAY_PYTHON" "$PRJXRAY/utils/fasm2frames.py" --part "$PART" \
  --db-root "$PRJXRAY_DB/artix7" qm_top.fasm qm_top.frames
"$PRJXRAY/build/tools/xc7frames2bit" --part_file "$PRJXRAY_DB/artix7/$PART/part.yaml" \
  --part_name "$PART" --frm_file qm_top.frames --output_file qm_top.bit

grep -E "Max frequency|Device utilisation" -A0 nextpnr.log || true
ls -l qm_top.bit
