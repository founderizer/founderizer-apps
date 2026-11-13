#!/usr/bin/env python3
"""Reads the frames of frames.ps1 of any part of the screen and says in how many frames that part changed from the
frame before (a pixel that moved by more than 8 in a colour), and how many pixels changed at most (README.md,
"Pictures"): the proof that a part moves, or that nothing in it moves at rest. With x0 y0 x1 y1 (in the frames' own
pixels) it reads that box of the frames only.

    python3 -I changes.py <frames folder> [x0 y0 x1 y1]
"""
import importlib.util
import pathlib
import sys

spec = importlib.util.spec_from_file_location("compare", pathlib.Path(__file__).with_name("compare.py"))
compare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compare)

folder = pathlib.Path(sys.argv[1])
frames = [compare.load(str(p)) for p in sorted(folder.glob("frame-*.png"))]
if len(frames) < 2:
    raise SystemExit("fewer than two frames")
width, height = frames[0][0], frames[0][1]
x0, y0, x1, y1 = [int(v) for v in sys.argv[2:6]] if len(sys.argv) >= 6 else (0, 0, width, height)


def changed(one, two):
    return sum(1 for y in range(y0, y1) for a, b in zip(one[y][x0 * 3:x1 * 3], two[y][x0 * 3:x1 * 3]) if abs(a - b) > 8)


counts = [changed(frames[i - 1][2], frames[i][2]) for i in range(1, len(frames))]
moved = sum(1 for n in counts if n > 0)
print(f"{x0},{y0}-{x1},{y1}: changed in {moved} of {len(counts)} frames, at most {max(counts)} values of a pixel's colours")
