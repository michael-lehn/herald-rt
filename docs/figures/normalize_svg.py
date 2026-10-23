#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""normalize_svg.py <in.svg> <out.svg> - make pdftocairo output deterministic.

pdftocairo numbers its glyph/clip/surface ids per process; they are stable for
an identical PDF, but surface ids can depend on allocation order. This script
renumbers every id in order of first appearance (and the references to it),
strips trailing whitespace, adds an SPDX licence comment, and leaves all
drawing data untouched, so the SVG stays a pure vector file.
"""
import re
import sys


def main():
    src = open(sys.argv[1], encoding="utf-8").read()
    ids = []
    for m in re.finditer(r'\bid="([^"]+)"', src):
        if m.group(1) not in ids:
            ids.append(m.group(1))
    mapping = {}
    for i, old in enumerate(ids):
        prefix = re.sub(r"[-_]?\d+([-_]\d+)*$", "", old) or "id"
        mapping[old] = f"{prefix}-{i}"

    def ref(m):
        key = m.group(2)
        return m.group(1) + mapping.get(key, key) + m.group(3)

    out = re.sub(r'(\bid=")([^"]+)(")', ref, src)
    out = re.sub(r'(url\(#)([^)]+)(\))', ref, out)
    out = re.sub(r'((?:xlink:)?href="#)([^"]+)(")', ref, out)
    out = "\n".join(line.rstrip() for line in out.splitlines()) + "\n"
    # licence notice for the generated figure (see NOTICE in the repository root)
    # (no "--" inside the comment: it is not allowed in XML comments)
    notice = ("<!-- SPDX-License-Identifier: CC-BY-4.0. HeraldRT documentation figure, "
              "generated from its LuaLaTeX/TikZ source in docs/figures -->\n")
    if out.startswith("<?xml"):
        head, rest = out.split("\n", 1)
        out = head + "\n" + notice + rest
    else:
        out = notice + out
    # refuse to write a file that is not well-formed XML
    import xml.dom.minidom
    xml.dom.minidom.parseString(out.encode("utf-8"))
    open(sys.argv[2], "w", encoding="utf-8").write(out)


if __name__ == "__main__":
    main()
