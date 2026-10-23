#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# setup_openxc7.sh - build the open-source Artix-7 flow (openXC7) from source.
#
# Verified on: MacBook Air M5 (arm64), macOS 26.6, Homebrew clang, 2026-10-23.
# Should also work on arm64/x86-64 Linux (apt: cmake ninja-build libboost-all-dev
# libeigen3-dev python3-venv).
#
#   scripts/setup_openxc7.sh            # installs into $OPENXC7 (default ~/opt/openxc7)
#
# Components (pinned):
#   nextpnr (himbaechel/xilinx)  github.com/openXC7/nextpnr      96809c1a
#   prjxray tools + python       github.com/openXC7/prjxray      317fdc13
#   prjxray-db                   github.com/openXC7/prjxray-db   a90f27c1
#   yosys                        Homebrew / distro (>= 0.40; tested 0.70)
# Disk: ~1.5 GB (the database is ~850 MB). Build time on M5: ~2 min.
set -eu

OPENXC7=${OPENXC7:-$HOME/opt/openxc7}
NEXTPNR_REV=96809c1ac49841b2def520aa3a44307cdbe15c5f
PRJXRAY_REV=317fdc1319a225f57b6a0e6993a37d1a4ae75e5a
DB_REV=a90f27c1caefee5276f47440f4c730b50519a86f
DEVICES=${DEVICES:-xc7a100t}
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN)}

if [ "$(uname)" = Darwin ]; then
  brew install cmake ninja boost eigen python@3.12 yosys
  PY=$(brew --prefix python@3.12)/bin/python3.12
else
  PY=${PY:-python3}
fi

mkdir -p "$OPENXC7/src"
cd "$OPENXC7/src"

fetch() {  # fetch <url> <dir> <rev>
  [ -d "$2/.git" ] || git clone "$1" "$2"
  git -C "$2" fetch --depth 1 origin "$3"
  git -C "$2" checkout -q "$3"
}

fetch https://github.com/openXC7/prjxray-db.git prjxray-db  "$DB_REV"
fetch https://github.com/openXC7/nextpnr.git    nextpnr     "$NEXTPNR_REV"
fetch https://github.com/openXC7/prjxray.git    prjxray     "$PRJXRAY_REV"

# nextpnr-himbaechel with the xc7a100t chip database
git -C nextpnr submodule update --init --depth 1 himbaechel/uarch/xilinx/meta
cmake -S nextpnr -B nextpnr/build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DARCH=himbaechel -DHIMBAECHEL_UARCH=xilinx -DHIMBAECHEL_XILINX_DEVICES="$DEVICES" \
  -DHIMBAECHEL_PRJXRAY_DB="$OPENXC7/src/prjxray-db" -DBUILD_GUI=OFF -DBUILD_PYTHON=OFF
cmake --build nextpnr/build -j "$JOBS"

# prjxray: only xc7frames2bit is needed (C++), plus fasm2frames.py (python)
git -C prjxray submodule update --init --depth 1 \
  third_party/abseil-cpp third_party/gflags third_party/googletest \
  third_party/yaml-cpp third_party/cctz third_party/sanitizers-cmake third_party/fasm
cmake -S prjxray -B prjxray/build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DPRJXRAY_BUILD_TESTING=OFF
cmake --build prjxray/build -j "$JOBS" --target xc7frames2bit

"$PY" -m venv "$OPENXC7/venv"
"$OPENXC7/venv/bin/pip" install -q --upgrade pip
"$OPENXC7/venv/bin/pip" install -q -e prjxray ./prjxray/third_party/fasm \
  intervaltree numpy pyyaml simplejson progressbar2 pyjson5

cat > "$OPENXC7/env.sh" <<EOF
export OPENXC7=$OPENXC7
export NEXTPNR_XILINX=$OPENXC7/src/nextpnr/build/nextpnr-himbaechel
export PRJXRAY=$OPENXC7/src/prjxray
export PRJXRAY_DB=$OPENXC7/src/prjxray-db
export PRJXRAY_PYTHON=$OPENXC7/venv/bin/python
EOF
echo "done. 'source $OPENXC7/env.sh' or pass OPENXC7=$OPENXC7 to make."
