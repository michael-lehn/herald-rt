#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# program_kasli.sh - load or flash the bitstream on Kasli 2.0 via its FT4232H JTAG.
#
#   scripts/program_kasli.sh sram  build/vivado/qm_top.bit   # volatile, for development
#   scripts/program_kasli.sh flash build/vivado/qm_top.bit   # persistent (SPI flash)
#
# Uses openFPGALoader (https://github.com/trabucayre/openFPGALoader).
# VERIFY on first use: which FT4232H interface carries JTAG on your Kasli
# (ARTIQ's artiq_flash drives the same FTDI part with OpenOCD). If the
# default does not detect the XC7A100T, try --ftdi-channel 1..3.
set -eu
mode=${1:?sram|flash}
bit=${2:?bitstream}
case "$mode" in
  sram)  openFPGALoader --cable ft4232 --ftdi-channel 0 --freq 10M "$bit" ;;
  flash) openFPGALoader --cable ft4232 --ftdi-channel 0 --freq 10M --fpga-part xc7a100tfgg484 -f "$bit" ;;
  *)     echo "usage: $0 sram|flash file.bit" >&2; exit 2 ;;
esac
