# SPDX-License-Identifier: Apache-2.0
# x86-64 Ubuntu 22.04 userspace for headless Vivado.
#
# Two uses:
#   * on an x86-64 Linux host (native, AMD-supported OS)        -> docs/04 Task C
#   * on Apple Silicon via Docker/Colima/OrbStack + Rosetta      -> docs/04 Task A (EXPERIMENTAL)
#
# Vivado itself is NOT baked into the image (licence, ~30-100 GB). It is
# installed once into the named volume `xilinx` by docker/vivado/install.sh.
FROM --platform=linux/amd64 ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates locales make git python3 gcc libc6-dev \
      libtinfo5 libncurses5 libx11-6 libxext6 libxrender1 libxtst6 libxi6 \
      libfreetype6 fontconfig libglib2.0-0 libsm6 libgtk-3-0 \
      && rm -rf /var/lib/apt/lists/* \
 && locale-gen en_US.UTF-8

# Rosetta workaround: Vivado's licence manager / WebTalk call
# udev_enumerate_scan_devices(), which crashes under Rosetta with
# "realloc(): invalid pointer" (reported by github.com/filmil/vivado-docker).
# The stub is only preloaded when QM_UDEV_STUB=1 (set by scripts/vivado_docker.sh
# on arm64 hosts); native x86-64 hosts run unmodified.
COPY udev_stub.c /tmp/udev_stub.c
RUN gcc -shared -fPIC -O2 -o /usr/local/lib/libudev_stub.so /tmp/udev_stub.c

ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
COPY entrypoint.sh /usr/local/bin/qm-entrypoint
ENTRYPOINT ["/usr/local/bin/qm-entrypoint"]
CMD ["bash"]
