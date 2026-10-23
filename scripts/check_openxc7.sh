#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# check_openxc7.sh <build/openxc7> - minimal implementation test for the open flow.
# Exits non-zero if any check fails. Prints the constraints that the open flow
# did NOT honour, so a passing result is never mistaken for Vivado sign-off.
set -u
D=${1:-build/openxc7}
OPENXC7=${OPENXC7:-$HOME/opt/openxc7}
PY=$OPENXC7/venv/bin/python; [ -x "$PY" ] || PY=python3
fail=0
ok()  { echo "  PASS  $*"; }
bad() { echo "  FAIL  $*"; fail=1; }

echo "openXC7 implementation check ($D)"
[ -s "$D/qm_top.bit" ] && head -c 120 "$D/qm_top.bit" | grep -aq "xc7a100tfgg484" \
  && ok "bitstream written for xc7a100tfgg484" || bad "no bitstream for xc7a100tfgg484"

for c in clk herald_async; do
  l=$(grep "Max frequency for clock" "$D/nextpnr.log" | grep "'$c'" | tail -1)
  case "$l" in *PASS*) ok "nextpnr timing $c: ${l#*: }" ;; *) bad "nextpnr timing $c: ${l#*: }" ;; esac
done

for p in "ISERDESE2: *1/" "OSERDESE2: *2/" "MMCME2_ADV: *1/" "IBUFDS_GTE2: *1/"; do
  grep -Eq "$p" "$D/nextpnr.log" && ok "placed ${p%%:*}" || bad "missing ${p%%:*}"
done

grep -q "LVDS_25_SSTL135_SSTL15.IN_DIFF" "$D/qm_top.fasm" && ok "LVDS_25 differential input configured" \
  || bad "no LVDS_25 input in FASM"
n_out=$(grep -c 'LVDS_25.OUT' "$D/qm_top.fasm")
[ "$n_out" -eq 8 ] && ok "8 LVDS_25 differential outputs configured" \
  || bad "LVDS_25 outputs: $n_out (expected 8)"

# Path A structure: every herald-domain flop must be clocked by the herald net.
n=$("$PY" - "$D/qm_top.json" <<'EOF'
import json, sys
m = json.load(open(sys.argv[1]))["modules"]["qm_top"]
bits = set()
for name, n in m["netnames"].items():
    if name.endswith("herald_async"):
        bits.update(n["bits"])
print(sum(1 for c in m["cells"].values()
          if c["type"] == "FDCE" and c["connections"]["C"][0] in bits))
EOF
)
[ "${n:-0}" -ge 4 ] && ok "$n FDCE cells clocked directly by the herald net" \
  || bad "herald-clocked FDCE cells: ${n:-?}"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
echo "  NOTE  constraints in constr/kasli_v2_0.xdc that this flow does NOT apply:"
grep -oE '^set_[a-z_]+' "$ROOT/constr/kasli_v2_0.xdc" | grep -v '^set_property$' \
  | sort | uniq -c | sed 's/^/          /'
if grep -q "DIFF_TERM TRUE" "$ROOT/constr/kasli_v2_0.xdc" && ! grep -q "DIFF_TERM" "$D/qm_top.fasm"; then
  echo "          DIFF_TERM requested but absent from the bitstream (no prjxray-db feature):"
  echo "          LVDS inputs are UNTERMINATED in the openXC7 build"
fi
exit $fail
