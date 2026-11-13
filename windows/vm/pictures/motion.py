#!/usr/bin/env python3
"""Reads the frames of frames.ps1 (the pane's agents at scale 2) and says, for each sample agent, how many frames
changed its glyph and its line from the frame before; then writes a sheet of the glyphs, one column for each frame.

    python3 -I motion.py <frames folder> <sheet.png>
"""
import importlib.util
import pathlib
import sys

spec = importlib.util.spec_from_file_location("compare", pathlib.Path(__file__).with_name("compare.py"))
compare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compare)

AGENTS = ["Fleet Manager", "Customer Support", "Developer", "DevOps", "Marketing"]
folder = pathlib.Path(sys.argv[1])
frames = [compare.load(str(p))[2] for p in sorted(folder.glob("frame-*.png"))]
scale = 2


def region(rows, x0, y0, w, h):
    return [rows[y][x0 * 3:(x0 + w) * 3] for y in range(y0, y0 + h)]


def changed(one, two):
    return sum(1 for ra, rb in zip(one, two) for i in range(len(ra)) if abs(ra[i] - rb[i]) > 8)


sheet = []
for i, name in enumerate(AGENTS):
    # In the frames, y 0 is the screen's 96: the pane's row i is at 92 + 54 i in effective pixels from the pane's top.
    top = (92 + 54 * i) * scale
    glyph = [region(f, 10 * scale, top + 12 * scale, 28 * scale, 28 * scale) for f in frames]
    line = [region(f, 48 * scale + 4 * scale, top + 27 * scale, 250 * scale, 16 * scale) for f in frames]
    g = sum(1 for k in range(1, len(frames)) if changed(glyph[k - 1], glyph[k]) > 0)
    w = sum(1 for k in range(1, len(frames)) if changed(line[k - 1], line[k]) > 0)
    print(f"{name}: glyph changed in {g} of {len(frames) - 1} frames, line changed in {w} of {len(frames) - 1}")
    for y in range(28 * scale):
        sheet.append(b"".join(glyph[k][y] + b"\x80\x80\x80" * 4 for k in range(len(frames))))
    sheet.extend([b"\x80\x80\x80" * ((28 * scale + 4) * len(frames))] * 4)
compare.save(sys.argv[2], (28 * scale + 4) * len(frames), len(sheet), sheet)
print(sys.argv[2])
