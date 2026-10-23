#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""path_a_estimate.py <qm_top.sdf> <qm_top_routed.json> - Path A latency ESTIMATE.

nextpnr ignores the Path A pad-to-pad and CDC constraints, and its timing model
has no delays for IOBs, BUFGCTRL or ISERDES (their SDF cells are empty).
This script combines
  * nextpnr's routed interconnect delays from the SDF (its own model), and
  * AMD DS181 v1.27 Artix-7 -3 cell delays for the unmodelled elements,
into a bottom-up estimate of the FPGA-internal herald pad -> output pad delay,
and reports the clk_sys -> herald-latch control skew (arm on CE).

This is NOT static timing sign-off (no corners, no clock-tree insertion model
for the BUFG distribution beyond nextpnr's interconnect value). Use Vivado
(path_a.rpt) for the bound and the oscilloscope for the truth (docs/03 §3.3).
"""
import json
import re
import sys

# DS181 v1.27, speed grade -3 (max values), ns
DS181 = {
    "TIOPI_LVDS_25": 0.73,   # LVDS_25 pad -> I (input buffer)
    "TBCCKO_O": 0.08,        # BUFGCTRL I0 -> O
    "TCKO": 0.40,            # CLB flop clock -> Q
    "TILO": 0.10,            # LUT address -> output
    "TIOOP_LVDS_25": 1.29,   # O -> pad (LVDS_25 output buffer)
}
UNMODELLED = "ISERDESE2 D->O bypass (no DS181 figure; assumed small)"


def main():
    sdf = open(sys.argv[1]).read()
    m = json.load(open(sys.argv[2]))["modules"]
    m = m[next(iter(m))]
    cells = m["cells"]

    def esc(n):
        return re.sub(r"([^A-Za-z0-9_.])", r"\\\1", n)

    ic = {}
    for mm in re.finditer(r"\(INTERCONNECT (\S+) (\S+) \((\d+):(\d+):(\d+)\)", sdf):
        ic[(mm.group(1), mm.group(2))] = int(mm.group(5)) / 1000.0

    def arc(sc, sp, dc, dpn):
        return ic.get((esc(sc) + "/" + sp, esc(dc) + "/" + dpn))

    drv, sinks = {}, {}
    for n, c in cells.items():
        for p, bits in c["connections"].items():
            for b in bits:
                if not isinstance(b, int):
                    continue
                if c["port_directions"][p] == "output":
                    drv[b] = (n, p)
                else:
                    sinks.setdefault(b, []).append((n, p))

    iser = next(n for n, c in cells.items() if c["type"].startswith("ISERDESE2"))
    bufg = next(n for n, c in cells.items() if c["type"] == "BUFGCTRL"
                and drv.get(c["connections"]["I0"][0], ("",))[0] == iser)
    hff = {n for n, c in cells.items() if c["type"] == "SLICE_FFX"
           and drv.get(c["connections"]["CK"][0], ("",))[0] == bufg}
    r_in = arc(iser, "O", bufg, "I0")

    print("FPGA-internal Path A estimate (herald pad -> output pad), ns")
    print(f"  fixed part: IBUF {DS181['TIOPI_LVDS_25']} + route ISERDES.O->BUFG {r_in:.3f}"
          f" + BUFG {DS181['TBCCKO_O']}   [{UNMODELLED}]")
    worst = 0.0
    for port in ("pump_p", "repump_p", "source_p", "fwd_p"):
        pad = next(n for n, c in cells.items() if c["type"] == "PAD"
                   and n.split("$")[0].split(".")[-1] == port)
        ob, _ = drv[cells[pad]["connections"]["PAD"][0]]
        lut, lp = drv[cells[ob]["connections"]["IN"][0]]
        ff, fpin = next((drv[b[0]][0], p) for p, b in cells[lut]["connections"].items()
                        if cells[lut]["port_directions"][p] == "input" and b and b[0] in drv
                        and drv[b[0]][0] in hff)
        r_ck, r_q, r_o = arc(bufg, "O", ff, "CK"), arc(ff, "Q", lut, fpin), arc(lut, lp, ob, "IN")
        tot = (DS181["TIOPI_LVDS_25"] + r_in + DS181["TBCCKO_O"] + r_ck + DS181["TCKO"]
               + r_q + DS181["TILO"] + r_o + DS181["TIOOP_LVDS_25"])
        worst = max(worst, tot)
        print(f"  {port:9s} BUFG->FF {r_ck:.3f}  FF.Q->LUT {r_q:.3f}  LUT->OBUF {r_o:.3f}"
              f"  => total {tot:.2f}")
    print(f"  worst: {worst:.2f} ns (XDC requirement for the Vivado flow: <= 10 ns)")

    print("clk_sys -> herald latch controls (CE = arm, SR = clears), routed ns")
    for sig, pin in (("arm", "CE"), ("clr", "SR")):
        vals = []
        for f in sorted(hff):
            b = cells[f]["connections"].get(pin, [None])[0]
            if b in drv:
                d, dp = drv[b]
                v = arc(d, dp, f, pin)
                if v is not None and cells[d]["type"] == "SLICE_FFX":
                    vals.append(v)
        if vals:
            print(f"  {pin} ({sig}): {min(vals):.3f} .. {max(vals):.3f}  (skew {max(vals) - min(vals):.3f})")


if __name__ == "__main__":
    main()
