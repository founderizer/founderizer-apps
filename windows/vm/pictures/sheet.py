#!/usr/bin/env python3
"""A sheet of pictures of the Windows app side by side: the title bar and the pane of each (the left 640 by 1200 of
the screen's own pixels at scale 2), at half size, in the order given (README.md, "Pictures").

    python3 -I sheet.py <sheet.png> <picture.png> ...
"""
import importlib.util
import pathlib
import sys

spec = importlib.util.spec_from_file_location("compare", pathlib.Path(__file__).with_name("compare.py"))
compare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compare)

width, height, gap = 640, 1200, 12
crops = []
for path in sys.argv[2:]:
    _, _, rows = compare.load(path)
    half = []
    for y in range(0, height, 2):
        a, b = rows[y], rows[y + 1]
        line = bytearray()
        for x in range(0, width, 2):
            for c in range(3):
                i, j = x * 3 + c, (x + 1) * 3 + c
                line.append((a[i] + a[j] + b[i] + b[j]) // 4)
        half.append(bytes(line))
    crops.append(half)
grey = b"\x80\x80\x80" * gap
sheet = [grey.join(crop[y] for crop in crops) for y in range(height // 2)]
compare.save(sys.argv[1], len(crops) * (width // 2) + (len(crops) - 1) * gap, height // 2, sheet)
print(sys.argv[1])
