#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""qmctl - host access to the herald controller over the Kasli UART.

Protocol (see rtl/qm_uart.sv): 'W' addr d3 d2 d1 d0 -> 'K';  'R' addr -> d3 d2 d1 d0.

  qmctl.py --port /dev/ttyUSB2 status
  qmctl.py --port /dev/ttyUSB2 set d_readin 270 t_store 160
  qmctl.py --port /dev/ttyUSB2 run | stop | abort | clear
  qmctl.py --port /dev/ttyUSB2 fifo

Requires pyserial. The FT4232H UART runs at 1 Mbaud (125 MHz / 125).
"""
import argparse
import struct
import sys

import serial  # pyserial

REGS = {
    "id": 0x00, "ctrl": 0x04, "status": 0x08, "chcfg": 0x0C,
    "t_prep": 0x10, "d_readin": 0x14, "t_store": 0x18, "w_ctrl": 0x1C,
    "t_off0": 0x20, "t_off1": 0x24, "t_off2": 0x28,
    "t_rest0": 0x2C, "t_rest1": 0x30, "t_rest2": 0x34,
    "t_end": 0x38, "fwd_w": 0x3C,
    "cnt_raw": 0x40, "cnt_edge": 0x44, "cnt_acc": 0x48, "cnt_rej": 0x4C,
    "cnt_race": 0x50, "cnt_abort": 0x54, "cnt_noedge": 0x58, "cnt_done": 0x5C,
    "cnt_late": 0x74,
}
STATES = ["IDLE", "PREP", "REL", "ARMED", "ACTIVE", "ABORT"]


class Controller:
    def __init__(self, port, baud=1_000_000):
        self.s = serial.Serial(port, baud, timeout=0.5)

    def read(self, addr):
        self.s.write(bytes([ord("R"), addr]))
        d = self.s.read(4)
        if len(d) != 4:
            raise IOError(f"read timeout at 0x{addr:02x}")
        return struct.unpack(">I", d)[0]

    def write(self, addr, value):
        self.s.write(bytes([ord("W"), addr]) + struct.pack(">I", value & 0xFFFFFFFF))
        if self.s.read(1) != b"K":
            raise IOError(f"write not acknowledged at 0x{addr:02x}")

    def read64(self, lo):
        a = self.read(lo)            # reading LO latches HI
        b = self.read(lo + 4)
        return (b << 32) | a


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", required=True)
    ap.add_argument("cmd", choices=["status", "set", "run", "stop", "abort", "clear", "fifo"])
    ap.add_argument("args", nargs="*")
    a = ap.parse_args()
    c = Controller(a.port)

    if c.read(REGS["id"]) != 0x514D4331:
        sys.exit("unexpected ID register - wrong port or bitstream?")

    if a.cmd == "status":
        st = c.read(REGS["status"])
        print(f"state={STATES[st & 0xF] if (st & 0xF) < len(STATES) else st & 0xF} "
              f"armed={st >> 4 & 1} cfg_err={st >> 5 & 1} kill={st >> 6 & 7:03b} "
              f"fired={st >> 9 & 1} run={st >> 11 & 1}")
        for k in sorted(REGS, key=REGS.get):
            if k not in ("id", "status"):
                print(f"  {k:10s} {c.read(REGS[k])}")
        print(f"  last_ts    {c.read64(0x60)} ns")
    elif a.cmd == "set":
        if len(a.args) % 2:
            sys.exit("set expects name value pairs")
        for name, val in zip(a.args[::2], a.args[1::2]):
            c.write(REGS[name], int(val, 0))
    elif a.cmd == "run":
        c.write(REGS["ctrl"], 1)
    elif a.cmd == "stop":
        c.write(REGS["ctrl"], 0)
    elif a.cmd == "abort":
        c.write(REGS["ctrl"], 3)
    elif a.cmd == "clear":
        run = c.read(REGS["ctrl"]) & 1
        c.write(REGS["ctrl"], run | 4)
    elif a.cmd == "fifo":
        stat = c.read(0x68)
        print(f"# level={stat & 0xFFFF} overflows={stat >> 16}")
        for _ in range(stat & 0xFFFF):
            print(c.read64(0x6C))


if __name__ == "__main__":
    main()
