#!/usr/bin/env python3
"""Compares a picture of the Windows app with an approved picture of the same size (README.md, "Pictures").

    python3 -I compare.py <approved.png> <built.png> <side-by-side.png> [x0 y0 x1 y1 ...]

It writes the two crops side by side (approved left, built right) and prints, for each region, the mean difference
of the colour channels (0 to 255) and the share of pixels that differ by more than 24 in a channel. A region is four
numbers in the pictures' own pixels; the default regions are the frame of the approved pictures at scale 2: the title
bar, the pane, and the content area's corner. Python's standard library only.

A mean hides a small element that is in one picture and not in the other (a pill of 30 pixels in a pane of a million
pixels moves the mean by 0.1). So each region also gets its largest solid patch of difference: the pixels that differ
by more than 16 in a channel (a grey pill on a grey row differs by about 20), of which only those stay whose eight neighbours differ too (text drawn a little
differently differs along its edges, one or two pixels wide, and goes), joined to their four neighbours. A missing
pill, button, dot or line of other words is a solid patch and stays; its size in pixels and its box are printed, and
each patch of 100 pixels or more is listed, so that a person looks at each.
"""
import struct
import sys
import zlib


def load(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{path}: not a PNG")
    i, idat, width, height, kind = 8, b"", 0, 0, 0
    while i < len(data):
        n = struct.unpack(">I", data[i:i + 4])[0]
        tag, body = data[i + 4:i + 8], data[i + 8:i + 8 + n]
        i += 12 + n
        if tag == b"IHDR":
            width, height, depth, kind = struct.unpack(">IIBB", body[:10])
            if depth != 8 or kind not in (2, 6):
                raise SystemExit(f"{path}: only 8-bit RGB or RGBA")
        elif tag == b"IDAT":
            idat += body
    raw, step = zlib.decompress(idat), (3 if kind == 2 else 4)
    stride, rows, prev, o = width * step, [], bytearray(width * step), 0
    for _ in range(height):
        kind_of_filter = raw[o]
        o += 1
        line = bytearray(raw[o:o + stride])
        o += stride
        if kind_of_filter == 1:
            for x in range(step, stride):
                line[x] = (line[x] + line[x - step]) & 255
        elif kind_of_filter == 2:
            for x in range(stride):
                line[x] = (line[x] + prev[x]) & 255
        elif kind_of_filter == 3:
            for x in range(stride):
                a = line[x - step] if x >= step else 0
                line[x] = (line[x] + ((a + prev[x]) >> 1)) & 255
        elif kind_of_filter == 4:
            for x in range(stride):
                a = line[x - step] if x >= step else 0
                b, c = prev[x], (prev[x - step] if x >= step else 0)
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(bytes(line) if step == 3 else bytes(v for x in range(0, stride, 4) for v in line[x:x + 3]))
        prev = line
    return width, height, rows


def save(path, width, height, rows):
    raw = b"".join(b"\x00" + row for row in rows)
    def chunk(tag, body):
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF)
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def solid_patches(marks, x0, y0):
    """The solid patches of a region's marks (one int of bits a row), largest first: (pixels, (x0, y0, x1, y1))."""
    height = len(marks)
    solid = []
    for y in range(height):
        row = marks[y]
        if y == 0 or y == height - 1 or not row:
            solid.append(0)
            continue
        across = [r & (r << 1) & (r >> 1) for r in (marks[y - 1], row, marks[y + 1])]
        solid.append(across[0] & across[1] & across[2])
    left = {(x, y) for y, row in enumerate(solid) if row for x in range(row.bit_length()) if row >> x & 1}
    patches = []
    while left:
        start = left.pop()
        stack, size = [start], 0
        xs, ys = [start[0], start[0]], [start[1], start[1]]
        while stack:
            x, y = stack.pop()
            size += 1
            xs[0], xs[1], ys[0], ys[1] = min(xs[0], x), max(xs[1], x), min(ys[0], y), max(ys[1], y)
            for n in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                if n in left:
                    left.remove(n)
                    stack.append(n)
        patches.append((size, (x0 + xs[0], y0 + ys[0], x0 + xs[1] + 1, y0 + ys[1] + 1)))
    patches.sort(reverse=True)
    return patches


def main():
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    approved, built, out = sys.argv[1:4]
    numbers = [int(v) for v in sys.argv[4:]]
    w1, h1, a = load(approved)
    w2, h2, b = load(built)
    if (w1, h1) != (w2, h2):
        raise SystemExit(f"the sizes differ: {w1}x{h1} and {w2}x{h2}")
    regions = [tuple(numbers[i:i + 4]) for i in range(0, len(numbers), 4)] or [
        (0, 0, 2880, 96, "title bar"), (0, 96, 640, 1800, "pane"), (640, 96, 1000, 400, "content corner")]
    for region in regions:
        x0, y0, x1, y1 = region[:4]
        name = region[4] if len(region) > 4 else f"{x0},{y0}-{x1},{y1}"
        total, far, count = 0, 0, 0
        marks = []
        for y in range(y0, y1):
            ra, rb = a[y], b[y]
            bits = 0
            for x in range(x0 * 3, x1 * 3, 3):
                d = max(abs(ra[x] - rb[x]), abs(ra[x + 1] - rb[x + 1]), abs(ra[x + 2] - rb[x + 2]))
                total += abs(ra[x] - rb[x]) + abs(ra[x + 1] - rb[x + 1]) + abs(ra[x + 2] - rb[x + 2])
                far += d > 24
                if d > 16:
                    bits |= 1 << (x // 3 - x0)
                count += 1
            marks.append(bits)
        print(f"{name}: mean difference {total / (3 * count):.2f} of 255, pixels far apart {100 * far / count:.2f}%")
        patches = solid_patches(marks, x0, y0)
        if patches:
            size, box = patches[0]
            listed = [p for p in patches if p[0] >= 100]
            print(f"  largest solid patch of difference: {size} pixels at {box[0]},{box[1]}-{box[2]},{box[3]}; "
                  f"{len(listed)} of 100 pixels or more" + "".join(f"\n    {p[0]} at {p[1][0]},{p[1][1]}-{p[1][2]},{p[1][3]}" for p in listed[:12]))
        else:
            print("  largest solid patch of difference: none")
    # Side by side: the left 1000 pixels of each picture, the approved one on the left.
    crop, gap = min(1000, w1), 16
    rows = [a[y][:crop * 3] + b"\x80\x80\x80" * gap + b[y][:crop * 3] for y in range(h1)]
    save(out, 2 * crop + gap, h1, rows)
    print(out)


if __name__ == "__main__":
    main()
