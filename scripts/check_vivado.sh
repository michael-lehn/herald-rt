#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# check_vivado.sh <build/vivado> - minimal implementation test for the Vivado flow.
# Parses the reports written by scripts/vivado_build.tcl. UNTESTED: written
# against the documented Vivado report formats, never run against real output.
set -u
D=${1:-build/vivado}
fail=0
ok()  { echo "  PASS  $*"; }
bad() { echo "  FAIL  $*"; fail=1; }

echo "Vivado implementation check ($D)"
[ -s "$D/qm_top.bit" ] && ok "bitstream written" || bad "no bitstream"

T="$D/timing_summary.rpt"
if [ -f "$T" ]; then
  grep -q "All user specified timing constraints are met" "$T" \
    && ok "all user timing constraints met" || bad "timing constraints NOT met (see $T)"
  # Design Timing Summary table: WNS TNS ... WHS THS ...
  awk '/Design Timing Summary/{f=1} f&&/^ *-?[0-9]+\.[0-9]+/{print "          WNS=" $1 " ns  WHS=" $5 " ns  WPWS=" $9 " ns"; exit}' "$T"
else
  bad "no timing_summary.rpt"
fi

[ -f "$D/drc.rpt" ] && { grep -Eq "Violations found: *0|No violations found" "$D/drc.rpt" \
  && ok "DRC clean" || echo "  WARN  DRC findings - review $D/drc.rpt"; }

if [ -f "$D/path_a.rpt" ]; then
  echo "  INFO  Path A (herald pad -> output pads), STA data path delays:"
  grep -E "^Slack|Data Path Delay|^ *Source:|^ *Destination:|Path Type" "$D/path_a.rpt" \
    | sed 's/^/          /' | head -40
else
  bad "no path_a.rpt"
fi
grep -q "CRITICAL WARNING" "$D/vivado.log" 2>/dev/null \
  && echo "  WARN  $(grep -c 'CRITICAL WARNING' "$D/vivado.log") critical warnings in vivado.log"
exit $fail
