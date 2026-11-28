#!/usr/bin/env python3
"""Regenerate the icons the web page installs with (serve/web/manifest.webmanifest).

The shape is the Monitor's Context fill gauge (serve/web/index.html): a 270 degree ring, round caps, the gap
at the bottom. Same geometry as the page, so the installed app and the page agree.

Run from the repository root, with the interpreter that has Pillow - the plain "python3" on this machine
does not, and the repository's own venv does:

    .venv/bin/python tools/make_web_icons.py

Needs Pillow, which the Monitor already uses (requirements-monitor.txt).
"""
from math import cos, radians, sin
from pathlib import Path

from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parent.parent / "serve" / "web"

ACCENT_LIGHT = (16, 185, 129)   # --st-accent, light theme
ACCENT_DARK = (52, 211, 153)    # --st-accent, dark theme
BG_DARK = (14, 17, 19)          # --st-bg, dark theme

# The gauge as index.html draws it, in its own viewBox units: a circle of r 50 in a 120 box, 10 wide, drawn
# 235.6 of its 314.2 circumference (75%, 270 degrees) and turned 135 degrees so the gap sits at the bottom.
BOX = 120.0
RADIUS = 50.0
STROKE = 10.0
START_DEG = 135.0               # screen degrees: 0 is right, increasing clockwise
SWEEP_DEG = 270.0

SS = 8                          # draw 8 times bigger than asked for, then shrink: the curve comes out smooth


def ring(size, color, scale=1.0):
    """The gauge ring, `scale` of the square, centred, on a transparent square of `size` pixels."""
    side = size * SS
    img = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    k = side / BOX * scale
    cx = cy = side / 2.0
    r = RADIUS * k
    width = max(1, round(STROKE * k))
    # A polyline with round joints, one point every half degree: the round caps and the smooth curve come
    # from that, without depending on the arc helper's angle convention.
    steps = int(SWEEP_DEG * 2)
    at = lambda i: (cx + r * cos(radians(START_DEG + SWEEP_DEG * i / steps)),  # noqa: E731
                    cy + r * sin(radians(START_DEG + SWEEP_DEG * i / steps)))
    points = [at(i) for i in range(steps + 1)]
    draw.line(points, fill=color + (255,), width=width, joint="curve")
    for i in (0, steps):        # the two ends, so the caps are round like stroke-linecap="round"
        x, y = points[i]
        draw.ellipse([x - width / 2, y - width / 2, x + width / 2, y + width / 2], fill=color + (255,))
    return img.resize((size, size), Image.LANCZOS)


def on_background(size, color, scale):
    """The same ring on a solid square, for the two places a transparent icon would go black."""
    out = Image.new("RGBA", (size, size), BG_DARK + (255,))
    out.alpha_composite(ring(size, color, scale))
    return out


ICONS = {
    # "any": the ring alone, so it sits on whatever the launcher or the store shows it on.
    "icon-192.png": ring(192, ACCENT_LIGHT),
    "icon-512.png": ring(512, ACCENT_LIGHT),
    # A maskable icon keeps its art inside the middle of the square, because a launcher cuts away what falls
    # outside its own circle or rounded square. 0.70 leaves the ring well clear of that cut.
    "icon-maskable-512.png": on_background(512, ACCENT_DARK, 0.70),
    # iOS paints a transparent icon on black, so this one carries its own background.
    "apple-touch-icon-180.png": on_background(180, ACCENT_DARK, 0.84),
}

if __name__ == "__main__":
    for name, image in ICONS.items():
        image.save(OUT / name)
        print(f"wrote {name} {image.size}")
