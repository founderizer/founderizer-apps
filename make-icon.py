"""The Founderizer app icon, from the brand mark.

The mark is `founderizer-landing/public/brand/founderizer-mark.svg`, which is also the website's
`icon.svg`: a violet plate and two white chevrons. This script reproduces it — the same plate and
radius, the same chevrons — and writes what macOS and iOS ask for:

    python3 make-icon.py .

It redraws rather than rasterises because this Mac has no SVG renderer. If the mark ever changes,
change the numbers here from that file and run it again.

It writes the iPhone's icon too, the same 1024 square, so the two apps carry one brand: the phone kept
the old blue art with an "F" for weeks after the Mac took this one.

**The icon's chevrons are 1.1 times the mark's**, about the plate's centre, strokes and all: they span
60 % of the tile's width and 64 % of its height, so 18 % of the tile stays clear above and below them and
20 % at each side. At 1.3 (the owner's yes of 28 October 2026, D-8, as Grok Bot's head fills its icon)
only 12 % stayed clear above and below, and he saw them crowd the edges on both apps (3 November 2026:
"they are too close to the edges, too little padding"). The mark in the app and on the website keeps its
size.

The art is **full bleed**: the plate fills the square and the icon draws no margin of its own.
macOS 26 frames an icon it does not recognise as the new format rather than masking it, so art
with Apple's old margin is drawn as a small tile inside a white container.
"""
import os
import subprocess
import sys

from PIL import Image, ImageDraw

S = 1024                      # the canvas; the mark's own viewBox is 512, so every number doubles
SCALE = S / 512
VIOLET = (0x63, 0x5B, 0xFF, 255)
WHITE = (0xFF, 0xFF, 0xFF, 255)
RADIUS = 116 * SCALE          # rx="116" on the plate

CHEVRONS = (                  # (points, stroke width), exactly the mark's two polylines
    (((172, 217), (256, 133), (340, 217)), 50),
    (((148, 373), (256, 265), (364, 373)), 62),
)
GROW = 1.1                    # the icon's chevrons against the mark's, about the plate's centre (256, 256)


def chevron(d, points, width, scale):
    """One polyline with round caps and round joins, as `stroke-linecap` and `stroke-linejoin` ask, GROW times
    the mark's about the plate's centre, on a canvas `scale` times the icon's."""
    pts = [((256 + (x - 256) * GROW) * SCALE * scale, (256 + (y - 256) * GROW) * SCALE * scale) for x, y in points]
    w = width * GROW * SCALE * scale
    d.line(pts, fill=WHITE, width=int(round(w)), joint="curve")
    for x, y in pts:                                    # the round caps, and a clean apex
        d.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=WHITE)


def icon():
    # Plate and chevrons are drawn at 4x and then made smaller, so their edges are smooth: Pillow draws no edge
    # smoothing of its own, and the chevrons drawn at 1x had a stepped edge and a notch where each cap meets its stroke.
    big = Image.new("RGBA", (S * 4, S * 4), (0, 0, 0, 0))
    d = ImageDraw.Draw(big)
    d.rounded_rectangle([0, 0, S * 4 - 1, S * 4 - 1], radius=RADIUS * 4, fill=VIOLET)
    for points, width in CHEVRONS:
        chevron(d, points, width, 4)
    return big.resize((S, S), Image.LANCZOS)


ICONSET = ((16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
           (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"),
           (512, "icon_256x256@2x"), (512, "icon_512x512"), (1024, "icon_512x512@2x"))


def main(out="."):
    art = icon()

    flat = Image.new("RGB", (S, S), VIOLET[:3])          # iOS takes a square with no transparency
    flat.paste(art, (0, 0), art)
    flat.save(f"{out}/AppIcon-1024.png")
    phone = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ios/Assets.xcassets/AppIcon.appiconset")
    flat.save(f"{phone}/AppIcon-1024.png")                 # the iPhone's, full bleed: iOS draws its corners

    folder = f"{out}/AppIcon.iconset"
    subprocess.run(["mkdir", "-p", folder], check=True)
    for size, name in ICONSET:
        art.resize((size, size), Image.LANCZOS).save(f"{folder}/{name}.png")
    subprocess.run(["iconutil", "-c", "icns", folder, "-o", f"{out}/AppIcon.icns"], check=True)
    subprocess.run(["rm", "-rf", folder], check=True)
    print(f"wrote {out}/AppIcon.icns, {out}/AppIcon-1024.png and {phone}/AppIcon-1024.png")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".")
