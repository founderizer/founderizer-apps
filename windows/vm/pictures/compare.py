#!/usr/bin/env python3
"""Compares a picture of the Windows app with an approved picture of the same size (README.md, "Pictures").

    python3 -I compare.py <approved.png> <built.png> <side-by-side.png> [x0 y0 x1 y1 ...]

It writes the two crops side by side (approved left, built right) and prints, for each region, the mean difference
of the colour channels (0 to 255) and the share of pixels that differ by more than 24 in a channel. A region is four
numbers in the pictures' own pixels; the default regions are the frame of the approved pictures at scale 2: the title
bar, the pane, and the content area's corner. Python's standard library only.
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
        for y in range(y0, y1):
            ra, rb = a[y], b[y]
            for x in range(x0 * 3, x1 * 3, 3):
                d = max(abs(ra[x] - rb[x]), abs(ra[x + 1] - rb[x + 1]), abs(ra[x + 2] - rb[x + 2]))
                total += abs(ra[x] - rb[x]) + abs(ra[x + 1] - rb[x + 1]) + abs(ra[x + 2] - rb[x + 2])
                far += d > 24
                count += 1
        print(f"{name}: mean difference {total / (3 * count):.2f} of 255, pixels far apart {100 * far / count:.2f}%")
    # Side by side: the left 1000 pixels of each picture, the approved one on the left.
    crop, gap = min(1000, w1), 16
    rows = [a[y][:crop * 3] + b"\x80\x80\x80" * gap + b[y][:crop * 3] for y in range(h1)]
    save(out, 2 * crop + gap, h1, rows)
    print(out)


if __name__ == "__main__":
    main()
