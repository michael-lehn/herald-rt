#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# vivado_docker.sh - run the Vivado batch flow inside the qm-vivado container.
#
#   scripts/vivado_docker.sh            # = make vivado inside the container
#
# On Apple Silicon this runs x86-64 Vivado through Rosetta (EXPERIMENTAL,
# not supported by AMD; see docs/04). On x86-64 Linux it runs natively.
# Programming the board is done from the host (scripts/program_kasli.sh),
# not from the container.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=${IMAGE:-qm-vivado:22.04}
VIVADO_VERSION=${VIVADO_VERSION:-2024.2}
STUB=0; case "$(uname -m)" in arm64|aarch64) STUB=1 ;; esac

docker image inspect "$IMAGE" >/dev/null 2>&1 || \
  docker build --platform linux/amd64 -t "$IMAGE" "$ROOT/docker/vivado"

exec docker run --rm --platform linux/amd64 \
  -e QM_UDEV_STUB=$STUB -e VIVADO_VERSION="$VIVADO_VERSION" \
  -v xilinx:/opt/Xilinx -v "$ROOT":/work -w /work \
  "$IMAGE" make vivado
