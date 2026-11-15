"""The picture behind the two icons of the app's disk image: one gray arrow from Founderizer to Applications.

    python3 make-background.py .

It writes `background.png` (640 x 400) and `background@2x.png` (1280 x 800). `release.sh` gives the first to
`dmgbuild`, which finds the second beside it and joins both into one picture for normal and Retina screens.

**The picture is white, in dark mode too** (measured on 14 November 2026 in Finder on macOS 27 in dark mode): Finder
draws the names under the icons in black on a disk image's picture, whatever the Mac's appearance. On a dark picture
"Applications" could not be read, and a clear picture is drawn on white anyway.

**The arrow stands where the icons are**: `settings.py` puts their centres at (160, 190) and (480, 190) of the
window's content, and the picture starts at the top of that content too, under the title bar. Change both together.

The owner's yes of 14 November 2026 is to an arrow and no words: no line of text goes on this picture.
"""
import os
import sys

from PIL import Image, ImageDraw

WIDTH, HEIGHT = 640, 400
CENTRE_Y = 190
FROM_X, TO_X = 262, 378         # the gap between the two 128-point icons, at 224 and 416, with room on each side
STROKE = 5
HEAD = 16
GRAY = (142, 142, 147, 255)     # macOS's system gray, the same in both appearances
WHITE = (255, 255, 255, 255)


def picture(scale):
    image = Image.new("RGBA", (WIDTH * scale, HEIGHT * scale), WHITE)
    draw = ImageDraw.Draw(image)
    y = CENTRE_Y * scale
    x0, x1 = FROM_X * scale, TO_X * scale
    width, head = STROKE * scale, HEAD * scale
    draw.line([(x0, y), (x1, y)], fill=GRAY, width=width)
    draw.line([(x1 - head, y - head), (x1, y), (x1 - head, y + head)], fill=GRAY, width=width, joint="curve")
    # Round ends, as the brand's chevrons have.
    radius = width / 2
    for x, at in [(x0, y), (x1 - head, y - head), (x1 - head, y + head)]:
        draw.ellipse([x - radius, at - radius, x + radius, at + radius], fill=GRAY)
    return image.convert("RGB")


def main(out="."):
    picture(1).save(os.path.join(out, "background.png"), optimize=True)
    picture(2).save(os.path.join(out, "background@2x.png"), optimize=True)


if __name__ == "__main__":
    main(*sys.argv[1:])
