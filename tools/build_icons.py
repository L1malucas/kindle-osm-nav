#!/usr/bin/env python3
"""High-contrast maneuver icons (96x96 PNG) for the Kindle navigation panel.

Names match router.lua `mod`: straight, slight_left/right, left/right,
sharp_left/right, uturn, roundabout, arrive. Output: kindle-map/icons/.
"""

import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parents[1] / "kindle-map" / "icons"
S = 4  # supersampling
SIZE = 96
W = 13  # stroke width at 1x


def canvas():
    img = Image.new("L", (SIZE * S, SIZE * S), 255)
    return img, ImageDraw.Draw(img)


def p(x, y):
    return (x * S, y * S)


def head(d, tip, angle_deg, size=26):
    a = math.radians(angle_deg)
    # angle 0 = up, positive = clockwise
    dx, dy = math.sin(a), -math.cos(a)
    nx, ny = -dy, dx
    base = (tip[0] - dx * size, tip[1] - dy * size)
    pts = [tip, (base[0] + nx * size * 0.62, base[1] + ny * size * 0.62),
           (base[0] - nx * size * 0.62, base[1] - ny * size * 0.62)]
    d.polygon([p(*q) for q in pts], fill=0)
    return base


def line(d, pts):
    d.line([p(*q) for q in pts], fill=0, width=W * S, joint="curve")
    for q in (pts[0],):
        r = W / 2
        d.ellipse([p(q[0] - r, q[1] - r), p(q[0] + r, q[1] + r)], fill=0)


def turn(angle):
    img, d = canvas()
    a = math.radians(angle)
    length = 40
    if abs(angle) > 100:
        length = 58
    sharp = abs(angle) > 100
    corner = (48 - math.sin(a) * (34 if sharp else 18), 34 if sharp else 54)
    tip = (corner[0] + math.sin(a) * length, corner[1] - math.cos(a) * length)
    base = head(d, tip, angle, size=24)
    line(d, [(corner[0], 92), corner, base])
    return img


def straight():
    img, d = canvas()
    base = head(d, (48, 8), 0)
    line(d, [(48, 90), base])
    return img


def uturn(left=True):
    img, d = canvas()
    sx = 62 if left else 34
    ex = 30 if left else 66
    d.arc([p(min(sx, ex) - 2, 18), p(max(sx, ex) + 2, 18 + (abs(sx - ex) + 4))], 180, 360, fill=0, width=W * S)
    line(d, [(sx, 90), (sx, 18 + (abs(sx - ex) + 4) / 2)])
    base = head(d, (ex, 84), 180)
    line(d, [(ex, 18 + (abs(sx - ex) + 4) / 2), base])
    return img


def roundabout():
    img, d = canvas()
    r = 20
    d.ellipse([p(48 - r, 40 - r), p(48 + r, 40 + r)], outline=0, width=9 * S)
    line(d, [(48, 92), (48, 62)])
    base = head(d, (84, 12), 45)
    line(d, [(62, 26), base])
    return img


def arrive():
    img, d = canvas()
    d.ellipse([p(18, 18), p(78, 78)], outline=0, width=10 * S)
    d.ellipse([p(37, 37), p(59, 59)], fill=0)
    return img


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    icons = {
        "straight": straight(),
        "slight_right": turn(40), "slight_left": turn(-40),
        "right": turn(90), "left": turn(-90),
        "sharp_right": turn(140), "sharp_left": turn(-140),
        "uturn": uturn(True),
        "roundabout": roundabout(),
        "arrive": arrive(),
    }
    for name, img in icons.items():
        img.resize((SIZE, SIZE), Image.LANCZOS).point(lambda v: 0 if v < 128 else 255).save(str(OUT / (name + ".png")), optimize=True)
    print("icons:", ", ".join(sorted(icons)), "->", OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
