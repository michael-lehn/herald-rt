#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""bitstream_packets.py <file.bit> - decode 7-series configuration packets (UG470 ch. 5).

Prints the register writes in order (frame data summarised), and checks
IDCODE, sync, CRC and start-up commands. Exit 1 if a check fails.
"""
import struct
import sys

REGS = {0: "CRC", 1: "FAR", 2: "FDRI", 3: "FDRO", 4: "CMD", 5: "CTL0", 6: "MASK", 7: "STAT",
        8: "LOUT", 9: "COR0", 10: "MFWR", 11: "CBC", 12: "IDCODE", 13: "AXSS", 14: "COR1",
        16: "WBSTAR", 17: "TIMER", 22: "BOOTSTS", 24: "CTL1", 31: "BSPI"}
CMDS = {0: "NULL", 1: "WCFG", 2: "MFW", 3: "LFRM", 4: "RCFG", 5: "START", 6: "RCAP", 7: "RCRC",
        8: "AGHIGH", 9: "SWITCH", 10: "GRESTORE", 11: "SHUTDOWN", 12: "GCAPTURE", 13: "DESYNC",
        15: "IPROG", 16: "CRCC", 17: "LTIMER"}


def main():
    path, expect_idcode = sys.argv[1], int(sys.argv[2], 0) if len(sys.argv) > 2 else 0x3631093
    b = open(path, "rb").read()
    i = b.find(bytes.fromhex("AA995566"))
    if i < 0:
        sys.exit("no sync word")
    words = struct.unpack(">%dI" % ((len(b) - i) // 4), b[i:i + ((len(b) - i) // 4) * 4])
    k, reg, ok, seen = 1, None, True, []
    cmds, idcode, crc_writes, fdri_words = [], None, 0, 0
    while k < len(words):
        w = words[k]; k += 1
        typ = w >> 29
        if typ == 1:
            op, reg, cnt = (w >> 27) & 3, (w >> 13) & 0x3FFF, w & 0x7FF
        elif typ == 2:
            op, cnt = (w >> 27) & 3, w & 0x7FFFFFF
        else:
            continue
        if op != 2 or cnt == 0:          # only writes with payload
            continue
        data = words[k:k + cnt]; k += cnt
        name = REGS.get(reg, f"R{reg}")
        if name == "FDRI":
            fdri_words += cnt
            seen.append(f"FDRI x{cnt} words")
        elif name == "CMD":
            for d in data:
                cmds.append(CMDS.get(d, hex(d)))
            seen.append("CMD " + ",".join(CMDS.get(d, hex(d)) for d in data))
        else:
            if name == "IDCODE":
                idcode = data[0]
            if name == "CRC":
                crc_writes += 1
            seen.append(f"{name} = " + ",".join(f"0x{d:08x}" for d in data[:3]))
    for s in seen:
        print("  ", s)
    def chk(c, msg):
        nonlocal ok
        print(("  PASS  " if c else "  FAIL  ") + msg)
        ok &= c
    chk(idcode is not None and (idcode & 0x0FFFFFFF) == (expect_idcode & 0x0FFFFFFF),
        f"IDCODE 0x{(idcode or 0):08x} matches 0x{expect_idcode:07x} (XC7A100T, revision nibble ignored)")
    chk("RCRC" in cmds, "CRC reset (RCRC) issued")
    chk(crc_writes > 0, f"CRC check word written ({crc_writes}x)")
    chk("WCFG" in cmds and fdri_words > 0, f"frame data written via FDRI ({fdri_words} words)")
    chk("START" in cmds and "DESYNC" in cmds, "start-up sequence (START ... DESYNC)")
    chk("GRESTORE" in cmds, "GRESTORE (initialise flops to INIT values)")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
