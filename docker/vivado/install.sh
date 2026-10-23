#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# install.sh - install Vivado (batch mode) into the docker volume `xilinx`.
#
#   docker/vivado/install.sh /path/to/FPGAs_AdaptiveSoCs_Unified_<ver>_Lin64.bin
#
# Uses AMD's web installer in batch mode. You need an AMD account; the
# auth-token step asks for your credentials interactively (they are not
# stored in this repository). Only Vivado ML Standard with 7-series devices
# is installed, which keeps the installation at roughly 30 GB.
# Status: UNTESTED (no installer / AMD credentials were available).
set -eu
INSTALLER=${1:?path to AMD unified web installer (.bin)}
VIVADO_VERSION=${VIVADO_VERSION:-2024.2}
IMAGE=${IMAGE:-qm-vivado:22.04}
HERE=$(cd "$(dirname "$0")" && pwd)
STUB=0; [ "$(uname -m)" = arm64 ] || [ "$(uname -m)" = aarch64 ] && STUB=1

docker build --platform linux/amd64 -t "$IMAGE" "$HERE"
docker volume create xilinx >/dev/null

INST_DIR=$(cd "$(dirname "$INSTALLER")" && pwd)
INST_BIN=$(basename "$INSTALLER")

docker run --rm -it --platform linux/amd64 \
  -e QM_UDEV_STUB=$STUB -e VIVADO_VERSION="$VIVADO_VERSION" \
  -v xilinx:/opt/Xilinx -v "$INST_DIR":/installer:ro -v "$HERE":/cfg:ro \
  "$IMAGE" sh -c "
    set -e
    cp /installer/$INST_BIN /tmp/inst.bin && chmod +x /tmp/inst.bin
    /tmp/inst.bin --keep --noexec --target /tmp/inst
    /tmp/inst/xsetup -b AuthTokenGen
    /tmp/inst/xsetup -b Install -a XilinxEULA,3rdPartyEULA -c /cfg/install_config.txt
  "
