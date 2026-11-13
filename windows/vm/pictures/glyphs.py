#!/usr/bin/env python3
"""Compares the agents' glyphs of the pane in a picture of the Windows app with the approved picture 1 (README.md,
"Pictures"): each 28-point glyph of the five sample agents at scale 2, its mean difference, and a strip of the pairs.

    python3 -I glyphs.py <approved.png> <built.png> <strip.png>
"""
import importlib.util
import pathlib
import sys

spec = importlib.util.spec_from_file_location("compare", pathlib.Path(__file__).with_name("compare.py"))
compare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compare)

AGENTS = ["Fleet Manager", "Customer Support", "Developer", "DevOps", "Marketing"]
_, _, a = compare.load(sys.argv[1])
_, _, b = compare.load(sys.argv[2])
scale, zoom, side = 2, 4, 28
rows_out = []
for i, name in enumerate(AGENTS):
    # The glyph's square: the pane's row at x 4 + 6, y 48 + 92 + 54 i + 12, in effective pixels.
    x0, y0 = (4 + 6) * scale, (48 + 92 + 54 * i + 12) * scale
    n = side * scale
    total = 0
    for y in range(y0, y0 + n):
        for x in range(x0 * 3, (x0 + n) * 3):
            total += abs(a[y][x] - b[y][x])
    print(f"{name}: mean difference {total / (n * n * 3):.2f} of 255")
    for y in range(y0, y0 + n):
        left = b"".join(a[y][x * 3:x * 3 + 3] * zoom for x in range(x0, x0 + n))
        right = b"".join(b[y][x * 3:x * 3 + 3] * zoom for x in range(x0, x0 + n))
        line = left + b"\x80\x80\x80" * 8 + right
        rows_out.extend([line] * zoom)
    rows_out.extend([b"\x80\x80\x80" * (2 * n * zoom + 8)] * 8)
compare.save(sys.argv[3], 2 * side * scale * zoom + 8, len(rows_out), rows_out)
print(sys.argv[3])
