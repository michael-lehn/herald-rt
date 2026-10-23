#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""bitstream_tools.py - helpers for bitstream_roundtrip.sh.

  canon <file.fasm>                 canonical feature list (one bit per line)
  setbits <file.frames> <label>     PASS if the frames contain no set bit
  cmpframes <a.frames> <b.frames>   PASS if both describe identical frame data
"""
import sys


def load_frames(p):
    d = {}
    for line in open(p):
        a, w = line.split()
        v = [int(x, 16) for x in w.split(",")]
        if any(v):
            d[int(a, 16)] = v
    return d


def main():
    cmd = sys.argv[1]
    if cmd == "canon":
        import fasm
        out = set()
        for line in fasm.parse_fasm_filename(sys.argv[2]):
            if line.set_feature is not None:
                for f in fasm.canonical_features(line.set_feature):
                    out.add(fasm.set_feature_to_str(f))
        print("\n".join(sorted(out)))
    elif cmd == "setbits":
        d = load_frames(sys.argv[2])
        n = sum(bin(x).count("1") for v in d.values() for x in v)
        print(("  PASS  " if n == 0 else "  FAIL  ") + f"{sys.argv[3]} encode to {n} set bits")
        sys.exit(0 if n == 0 else 1)
    elif cmd == "cmpframes":
        a, b = load_frames(sys.argv[2]), load_frames(sys.argv[3])
        diff = [k for k in set(a) | set(b) if a.get(k) != b.get(k)]
        ok = not diff
        print(("  PASS  " if ok else "  FAIL  ") +
              f"decoded FASM re-encodes to identical frames ({len(a)} frames, {len(diff)} differ)")
        sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
