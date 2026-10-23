#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Source the Vivado environment if it is installed in the volume.
set -e
if [ "${QM_UDEV_STUB:-0}" = 1 ]; then
  export LD_PRELOAD=/usr/local/lib/libudev_stub.so${LD_PRELOAD:+:$LD_PRELOAD}
fi
VIVADO_VERSION=${VIVADO_VERSION:-2024.2}
for s in /opt/Xilinx/Vivado/$VIVADO_VERSION/settings64.sh \
         /opt/Xilinx/$VIVADO_VERSION/Vivado/settings64.sh; do
  # shellcheck disable=SC1090
  [ -f "$s" ] && . "$s" && break
done
exec "$@"
