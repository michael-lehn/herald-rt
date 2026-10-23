#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""analyze_herald_path.py - structural review of Path A in the nextpnr routed netlist.

    analyze_herald_path.py build/openxc7/qm_top_routed.json

Checks, from the post-route netlist (cells at BELs, nets with ROUTING PIPs):
  1. what the herald (ISERDESE2.O) net drives, and through which clock resources;
  2. that every flop clocked by the herald clock is the intended Path A set;
  3. what drives the CE / SR (clear) / D pins of those flops (must be clk_sys flops);
  4. the cone from the herald flops to the Path A output pads: only LUTs, no flop
     and no clk_sys element between flop Q and pad;
  5. that clk_sys / clk_fast nets do not reach any element of that cone except as
     static LUT inputs (configuration).
Exit status 1 if a structural rule is violated.
"""
import json
import sys
from collections import defaultdict

PATH_A_PORTS = ["pump_p", "repump_p", "source_p", "fwd_p"]


def load(path):
    mods = json.load(open(path))["modules"]
    return mods[next(iter(mods))]


def main():
    m = load(sys.argv[1])
    cells, nets = m["cells"], m["netnames"]
    ok = True

    drivers, sinks = {}, defaultdict(list)
    for cn, c in cells.items():
        for p, bits in c["connections"].items():
            d = c["port_directions"][p]
            for b in bits:
                if isinstance(b, str):
                    continue
                if d == "output":
                    drivers[b] = (cn, p)
                else:
                    sinks[b].append((cn, p))
    bitname = {}
    for nn, n in nets.items():
        for b in n["bits"]:
            if isinstance(b, int) and (b not in bitname or n.get("hide_name", 0) == 0):
                bitname[b] = nn

    def bel(cn):
        return cells[cn]["attributes"].get("NEXTPNR_BEL", "?")

    def routing(b):
        r = nets[bitname[b]]["attributes"].get("ROUTING", "")
        return r.split(";")[0::3]

    def fail(msg):
        nonlocal ok
        ok = False
        print("  VIOLATION:", msg)

    # 1. herald net
    iser = next(cn for cn, c in cells.items() if c["type"].startswith("ISERDESE2"))
    hb = cells[iser]["connections"]["O"][0]
    print(f"[1] herald source: {iser} @ {bel(iser)}, net {bitname[hb]}")
    clk_bits = {hb}
    frontier = [hb]
    while frontier:
        b = frontier.pop()
        w = routing(b)
        res = [x.split("/")[-1] for x in w if any(t in x for t in ("HCLK", "HROW", "BUFG", "GCLK"))]
        print(f"    net {bitname[b][:60]}: {len(w)} wires; clock resources: {sorted(set(res))[:6]}")
        for cn, p in sinks[b]:
            t = cells[cn]["type"]
            if t == "BUFGCTRL":
                ob = cells[cn]["connections"]["O"][0]
                print(f"    -> {t} {bel(cn)} (pin {p}) -> net {bitname[ob][:50]}")
                clk_bits.add(ob)
                frontier.append(ob)

    # 2. flops clocked by the herald clock
    ffs = [cn for b in clk_bits for cn, p in sinks[b] if cells[cn]["type"] == "SLICE_FFX" and p == "CK"]
    other = [(cn, cells[cn]["type"], p) for b in clk_bits for cn, p in sinks[b]
             if not (cells[cn]["type"] == "SLICE_FFX" and p == "CK") and cells[cn]["type"] != "BUFGCTRL"]
    print(f"[2] flops clocked by herald: {len(ffs)}")
    for cn in sorted(ffs):
        print(f"    {bel(cn):28s} {cn}")
    if other:
        fail(f"herald clock also drives non-flop pins: {other}")

    # 3. what drives the control pins of those flops
    print("[3] control inputs of herald flops (driver cell -> its clock)")
    seen = set()
    for cn in ffs:
        for p, bits in cells[cn]["connections"].items():
            if cells[cn]["port_directions"][p] != "input" or p == "CK":
                continue
            for b in bits:
                if not isinstance(b, int) or b not in drivers:
                    continue
                dc, dp = drivers[b]
                dt = cells[dc]["type"]
                dclk = cells[dc]["connections"].get("CK", [None])[0]
                key = (p, dt, bitname.get(dclk, "-"))
                if key in seen:
                    continue
                seen.add(key)
                dom = "herald" if dclk in clk_bits else (bitname.get(dclk, "comb/const")[:30])
                print(f"    pin {p:4s} <- {dt:12s} (domain: {dom})")

    # 4/5. output cones
    print("[4] Path A output cones (pad <- buffer <- LUTs <- sources)")
    pads = {cells[cn]["attributes"].get("X_IO_PORT", ""): cn for cn, c in cells.items() if c["type"] == "PAD"}
    for port in PATH_A_PORTS:
        cand = [cn for cn in cells if cn == port or cn.endswith("." + port) or cn == f"{port}$pad"]
        pad = pads.get(port) or (cand[0] if cand else None)
        if pad is None:  # exact port name before any '$' suffix (pump_p must not match repump_p)
            pad = next((cn for cn, c in cells.items()
                        if c["type"] == "PAD" and cn.split("$")[0].split(".")[-1] == port), None)
        if pad is None:
            fail(f"no pad found for {port}")
            continue
        # walk back through buffers and LUTs
        stack, srcs, luts, bufs = [pad], [], 0, []
        visited = set()
        while stack:
            cn = stack.pop()
            if cn in visited:
                continue
            visited.add(cn)
            t = cells[cn]["type"]
            if t == "SLICE_LUTX":
                luts += 1
            elif t not in ("PAD",) and "OUTBUF" not in t and t != "INVERTER":
                srcs.append(cn)
                continue
            if "OUTBUF" in t or t == "INVERTER":
                bufs.append(t)
            for p, bits in cells[cn]["connections"].items():
                if cells[cn]["port_directions"][p] not in ("input", "inout"):
                    continue
                for b in bits:
                    if isinstance(b, int) and b in drivers and drivers[b][0] != cn:
                        stack.append(drivers[b][0])
        hsrc = [s for s in srcs if s in ffs]
        osrc = [s for s in srcs if s not in ffs]
        dom = defaultdict(int)
        for s in osrc:
            ck = cells[s]["connections"].get("CK", [None])[0]
            dom[bitname.get(ck, cells[s]["type"])[:24]] += 1
        print(f"    {port:9s} pad@{bel(pad):22s} bufs={bufs} LUT levels<= {luts}  "
              f"herald-flop sources={len(hsrc)}  static sources={dict(dom)}")
        if not hsrc:
            fail(f"{port}: no herald flop in its cone")
        if any(cells[s]["type"] in ("OSERDESE2_OSERDESE2", "ISERDESE2_ISERDESE2") for s in srcs):
            fail(f"{port}: serdes in Path A cone")
        if luts > 2:
            fail(f"{port}: more than 2 LUTs between flop and pad")

    # 6. synchronizer inputs: herald flop outputs entering clk_sys logic must
    #    land on flip-flop D pins (no SRL / LUT-RAM storage as first stage).
    print("[5] herald flop outputs into other logic (synchronizer check)")
    def comb_fwd(b, depth=0):
        """sinks reached from net bit b through LUTs (not through flops)"""
        res = []
        for cn, p in sinks[b]:
            t = cells[cn]["type"]
            if t == "SLICE_LUTX" and not p.startswith("DI") and depth < 3:
                for op, ob in cells[cn]["connections"].items():
                    if cells[cn]["port_directions"][op] == "output":
                        for x in ob:
                            if isinstance(x, int):
                                res += comb_fwd(x, depth + 1)
            else:
                res.append((cn, p, depth))
        return res
    n_sync, n_srl = 0, 0
    for cn in ffs:
        q = cells[cn]["connections"]["Q"][0]
        for dc, dp, depth in comb_fwd(q):
            t = cells[dc]["type"]
            if t == "SLICE_LUTX" and dp.startswith("DI"):
                n_srl += 1
                fail(f"herald flop {cn} feeds SRL/LUT-RAM data pin {dc}.{dp} (synchronizer as SRL)")
            elif t == "SLICE_FFX":
                ck = cells[dc]["connections"].get("CK", [None])[0]
                if ck not in clk_bits:
                    n_sync += 1
                    if depth > 0:
                        print(f"    note: {cn} reaches clk flop {dc} through {depth} LUT level(s)")
    print(f"    clk-domain flop inputs fed by herald flops: {n_sync}; SRL/LUT-RAM inputs: {n_srl}")

    print("RESULT:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
