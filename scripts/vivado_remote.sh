#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# vivado_remote.sh - run the Vivado batch flow on an x86-64 Linux host over SSH.
#
#   REMOTE=user@buildhost scripts/vivado_remote.sh
#
# Copies the sources (not build/), runs `make vivado` remotely, and copies
# build/vivado (bitstream + reports) back. Requirements on the remote host:
# an AMD-supported Linux (e.g. Ubuntu 22.04/24.04 LTS, RHEL 8/9), Vivado
# installed, GNU make, rsync. Optionally run it in the qm-vivado container
# there by setting REMOTE_CMD="scripts/vivado_docker.sh".
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
REMOTE=${REMOTE:?set REMOTE=user@host}
REMOTE_DIR=${REMOTE_DIR:-qm-controller}
VIVADO_SETTINGS=${VIVADO_SETTINGS:-/tools/Xilinx/Vivado/2024.2/settings64.sh}
REMOTE_CMD=${REMOTE_CMD:-". $VIVADO_SETTINGS && make vivado"}

rsync -az --delete --exclude build/ --exclude .git/ "$ROOT/" "$REMOTE:$REMOTE_DIR/"
ssh "$REMOTE" "cd $REMOTE_DIR && $REMOTE_CMD"
mkdir -p "$ROOT/build/vivado"
rsync -az "$REMOTE:$REMOTE_DIR/build/vivado/" "$ROOT/build/vivado/" \
  --include '*.rpt' --include '*.bit' --include '*.bin' --include '*.log' --exclude '*'
"$ROOT/scripts/check_vivado.sh" "$ROOT/build/vivado"
