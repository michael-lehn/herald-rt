#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# bitstream_roundtrip.sh <build/openxc7> - independent decode of the bitstream.
#
#   1. bit -> FASM with Project X-Ray's own reader (bitread + bit2fasm.py)
#   2. features nextpnr intended but the decoder did not report must encode to
#      zero set bits (pseudo-PIPs, defaults) - otherwise information was lost
#   3. decoded FASM -> frames must equal the frames the bitstream was built from
#   4. configuration packets: IDCODE, sync, start-up sequence, CRC
# This validates bitstream generation against the prjxray database. It cannot
# validate the database itself, nor replace a hardware test.
set -eu
D=${1:-build/openxc7}
OPENXC7=${OPENXC7:-$HOME/opt/openxc7}
P=$OPENXC7/src/prjxray
DB=$OPENXC7/src/prjxray-db/artix7
PY=$OPENXC7/venv/bin/python
PART=xc7a100tfgg484-3
ROOT=$(cd "$(dirname "$0")/.." && pwd)
H="$ROOT/scripts/bitstream_tools.py"
cd "$D"

[ -x "$P/build/tools/bitread" ] || cmake --build "$P/build" --target bitread >/dev/null
"$PY" "$P/utils/bit2fasm.py" --db-root "$DB" --part "$PART" --bitread "$P/build/tools/bitread" \
  --canonical qm_top.bit 2>/dev/null | grep -v '^#' | sort -u > rt_decoded.fasm
"$PY" "$H" canon qm_top.fasm 2>/dev/null | sort -u > rt_intended.fasm
comm -23 rt_intended.fasm rt_decoded.fasm > rt_only_intended.fasm
"$PY" "$P/utils/fasm2frames.py" --part "$PART" --db-root "$DB" rt_only_intended.fasm rt_only_intended.frames 2>/dev/null
"$PY" "$P/utils/fasm2frames.py" --part "$PART" --db-root "$DB" rt_decoded.fasm rt_decoded.frames 2>/dev/null

echo "bitstream round trip ($D)"
echo "  intended features $(wc -l < rt_intended.fasm | tr -d ' '), decoded $(wc -l < rt_decoded.fasm | tr -d ' ')," \
     "intended-but-not-decoded $(wc -l < rt_only_intended.fasm | tr -d ' ')"
"$PY" "$H" setbits rt_only_intended.frames "intended-but-not-decoded features"
"$PY" "$H" cmpframes qm_top.frames rt_decoded.frames
"$PY" "$ROOT/scripts/bitstream_packets.py" qm_top.bit 0x3631093 | grep -E "PASS|FAIL"
