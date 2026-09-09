#!/usr/bin/env python3
"""Draw Mission Planner's icon: the Moon, and the course to it.

    ./tools/make-planner-icon.py

The Moon alone would be a weather app. What makes it this application is the
second thing in the frame: a translunar arc rising from the Earth's limb at
the bottom-left to a point just short of the Moon, with the spacecraft on it.
That is the picture the whole program draws, reduced until it survives at
sixteen pixels.

Sizes are what the design is FOR. At 1024 the craters, the terminator and the
spacecraft all read; at 32 the arc is a hairline and the Moon is the icon; at
16 only the lit disc against a dark ground survives, which is why the disc is
large and the ground is nearly black. An icon designed at 1024 and checked
only at 1024 is an icon that disappears in the Dock.

Drawn here rather than pasted in as a binary, for the reason tools/make-icon.py
gives for Roast's: an .icns nobody can regenerate is a file that rots. There is
no image library in this environment, so this is arithmetic into a pixel
buffer, 4x supersampled and box-filtered down, with a small pure-Python PNG
writer at the end.
"""

import math
import os
import shutil
import struct
import subprocess
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

SS = 4
MASTER = 1024
SIZES = [16, 32, 64, 128, 256, 512, 1024]

INSET = 0.085
CORNER = 0.225


def srgb(c):
    return max(0, min(255, int(round(c * 255))))


def lerp(a, b, t):
    t = max(0.0, min(1.0, t))
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def superellipse_inside(x, y, cx, cy, half, n):
    dx = abs(x - cx) / half
    dy = abs(y - cy) / half
    return (dx ** n + dy ** n) <= 1.0


def smoothstep(e0, e1, x):
    t = max(0.0, min(1.0, (x - e0) / (e1 - e0)))
    return t * t * (3.0 - 2.0 * t)


# Colour. A near-black ground, because the one thing that must survive at
# sixteen pixels is a bright disc against dark.
SKY_HI = (0.086, 0.098, 0.161)   # top left, a touch of indigo
SKY_LO = (0.020, 0.024, 0.043)   # bottom right, nearly black
MOON_LIT = (0.925, 0.918, 0.882)
MOON_MID = (0.541, 0.537, 0.522)
MOON_DARK = (0.114, 0.118, 0.145)
MARE = (0.435, 0.435, 0.435)
ARC = (0.435, 0.714, 1.0)
CRAFT = (1.0, 0.898, 0.541)
EARTH_LIT = (0.157, 0.435, 0.760)
EARTH_RIM = (0.412, 0.686, 0.949)

# Geometry, in fractions of the canvas. y runs down.
MOON = (0.630, 0.335, 0.258)      # centre x, centre y, radius
EARTH = (0.020, 1.080, 0.340)     # mostly off the bottom-left corner: a limb
# The course, as an ellipse arc: an implicit curve rather than a stroked
# polyline, because a per-pixel distance to a polyline is the one thing this
# renderer cannot afford.
#
# It stops WELL SHORT of the Moon, and that is the composition. Drawn all the
# way to it the curve passes behind the disc and the last two thirds of it --
# including the spacecraft, the one warm thing in the frame -- are simply not
# in the picture. A course that ends in open space also reads as a course
# still being flown, which is what the application is for.
ARC_C = (0.520, 0.980)
ARC_R = (0.440, 0.500)
ARC_W = 0.052                     # half-width, in the ellipse's own units
ARC_FROM = -0.48                  # show the sweep while u is left of this

# Craters: x, y (relative to the Moon's centre, in radii), radius, depth.
CRATERS = [
    (-0.34, -0.30, 0.20, 0.85),
    (0.28, -0.44, 0.13, 0.70),
    (0.42, 0.22, 0.17, 0.75),
    (-0.12, 0.46, 0.11, 0.65),
    (-0.58, 0.24, 0.09, 0.55),
    (0.06, 0.02, 0.07, 0.45),
]
# Maria: the big dark plains, which are what make a moon read as the Moon.
MARIA = [
    (-0.30, 0.30, 0.40),
    (0.18, 0.44, 0.30),
    (-0.44, -0.10, 0.26),
]

# The light, from the upper left, normalised.
_L = (-0.52, -0.46, 0.72)
_LN = math.sqrt(sum(c * c for c in _L))
LIGHT = tuple(c / _LN for c in _L)


def render(size):
    n = size * SS
    px = bytearray(n * n * 4)
    half = n * (0.5 - INSET)
    cx = cy = n * 0.5
    corner_n = 2.0 / CORNER * 0.55 + 2.0

    mx, my, mr = MOON[0] * n, MOON[1] * n, MOON[2] * n
    ex, ey, er = EARTH[0] * n, EARTH[1] * n, EARTH[2] * n
    acx, acy = ARC_C[0] * n, ARC_C[1] * n
    arx, ary = ARC_R[0] * n, ARC_R[1] * n

    # The spacecraft, at the leading end of the visible arc.
    ct = math.radians(180.0 + 56.0)
    craft_x = acx + arx * math.cos(ct)
    craft_y = acy + ary * math.sin(ct)
    craft_r = n * 0.028

    for y in range(n):
        row = y * n * 4
        for x in range(n):
            i = row + x * 4
            if not superellipse_inside(x, y, cx, cy, half, corner_n):
                continue

            t = ((x / n) + (y / n)) * 0.5
            r, g, b = lerp(SKY_HI, SKY_LO, t * 1.15)

            # A few stars, from a hash rather than a table so they are stable
            # across sizes without being a list of coordinates.
            if size >= 128:
                h = (x * 73856093) ^ (y * 19349663)
                if (h % 9973) < 3:
                    r, g, b = lerp((r, g, b), (0.85, 0.88, 0.95), 0.55)

            # ── the Earth's limb, bottom left ────────────────────────────
            de = math.hypot(x - ex, y - ey)
            if de < er:
                u = (x - ex) / er
                v = (y - ey) / er
                nz2 = 1.0 - u * u - v * v
                nz = math.sqrt(max(0.0, nz2))
                lit = max(0.0, u * LIGHT[0] + v * LIGHT[1] + nz * LIGHT[2])
                r, g, b = lerp((0.02, 0.05, 0.11), EARTH_LIT, lit ** 0.75)
                rim = smoothstep(0.86, 1.0, de / er)
                r, g, b = lerp((r, g, b), EARTH_RIM, rim * 0.65 * (0.35 + lit))

            # ── the course ───────────────────────────────────────────────
            au = (x - acx) / arx
            av = (y - acy) / ary
            if au <= ARC_FROM and av <= 0.05:
                d = abs(math.hypot(au, av) - 1.0)
                if d < ARC_W:
                    k = 1.0 - smoothstep(ARC_W * 0.35, ARC_W, d)
                    # Brightest at the leading end and fading back toward the
                    # Earth, so the curve reads as a direction and not a wire.
                    along = smoothstep(-0.98, -0.10, av) * 0.60 + 0.40
                    # And faded out at the very end rather than cut off square.
                    tip = 1.0 - smoothstep(ARC_FROM - 0.10, ARC_FROM, au)
                    r, g, b = lerp((r, g, b), ARC, k * 0.95 * along * (0.35 + 0.65 * tip))

            # ── the spacecraft ───────────────────────────────────────────
            dc = math.hypot(x - craft_x, y - craft_y)
            if dc < craft_r * 2.2:
                glow = 1.0 - smoothstep(craft_r * 0.7, craft_r * 2.2, dc)
                r, g, b = lerp((r, g, b), CRAFT, glow * 0.55)
                if dc < craft_r * 0.72:
                    r, g, b = CRAFT

            # ── the Moon ─────────────────────────────────────────────────
            dm = math.hypot(x - mx, y - my)
            if dm < mr:
                u = (x - mx) / mr
                v = (y - my) / mr
                nz = math.sqrt(max(0.0, 1.0 - u * u - v * v))
                lit = u * LIGHT[0] + v * LIGHT[1] + nz * LIGHT[2]
                # A soft terminator: the Moon has no atmosphere, so the edge is
                # sharp in life, and a razor edge here reads as a bug.
                shade = smoothstep(-0.06, 0.42, lit)
                base = lerp(MOON_DARK, MOON_MID, shade)
                base = lerp(base, MOON_LIT, shade ** 2.1)

                for cxr, cyr, crr in MARIA:
                    dd = math.hypot(u - cxr, v - cyr)
                    if dd < crr:
                        k = (1.0 - smoothstep(crr * 0.35, crr, dd)) * 0.32
                        base = lerp(base, MARE, k * shade)

                for cxr, cyr, crr, depth in CRATERS:
                    dd = math.hypot(u - cxr, v - cyr)
                    if dd < crr * 1.35:
                        # A bowl: dark on the light side of its floor, with a
                        # bright rim on the far side. That asymmetry is what
                        # makes a crater a hole rather than a spot.
                        inner = 1.0 - smoothstep(crr * 0.55, crr, dd)
                        base = lerp(base, MOON_DARK, inner * 0.42 * depth * shade)
                        ring = (1.0 - smoothstep(0.0, crr * 0.30, abs(dd - crr))) * depth
                        side = (u - cxr) * LIGHT[0] + (v - cyr) * LIGHT[1]
                        if side > 0:
                            base = lerp(base, MOON_LIT, ring * 0.45 * shade)
                        else:
                            base = lerp(base, MOON_DARK, ring * 0.30 * shade)

                # Limb darkening, so the disc is a sphere and not a coin.
                base = lerp(base, MOON_DARK, smoothstep(0.90, 1.0, dm / mr) * 0.35)
                r, g, b = base

            px[i] = srgb(r)
            px[i + 1] = srgb(g)
            px[i + 2] = srgb(b)
            px[i + 3] = 255

    return downsample(px, n, size)


def downsample(px, n, size):
    out = bytearray(size * size * 4)
    for y in range(size):
        for x in range(size):
            r = g = b = a = 0
            for dy in range(SS):
                base = ((y * SS + dy) * n + x * SS) * 4
                for dx in range(SS):
                    i = base + dx * 4
                    al = px[i + 3]
                    r += px[i] * al
                    g += px[i + 1] * al
                    b += px[i + 2] * al
                    a += al
            o = (y * size + x) * 4
            if a:
                out[o] = min(255, r // a)
                out[o + 1] = min(255, g // a)
                out[o + 2] = min(255, b // a)
            out[o + 3] = a // (SS * SS)
    return out


def write_png(path, size, rgba):
    raw = bytearray()
    for y in range(size):
        raw.append(0)
        raw += rgba[y * size * 4:(y + 1) * size * 4]

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def main():
    out = os.path.join(ROOT, "tools", "mission-planner.iconset")
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)

    # The iconset names macOS wants: each size, and its @2x twin drawn at
    # double resolution rather than scaled, which is the whole point of @2x.
    want = [
        (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
    ]
    cache = {}
    for size, name in want:
        if size not in cache:
            print(f"   {size}px", flush=True)
            cache[size] = render(size)
        write_png(os.path.join(out, name), size, cache[size])

    icns = os.path.join(ROOT, "tools", "mission-planner.icns")
    subprocess.run(["iconutil", "-c", "icns", out, "-o", icns], check=True)
    shutil.rmtree(out, ignore_errors=True)
    print(f"   {icns} ({os.path.getsize(icns) // 1024} KB)")


if __name__ == "__main__":
    main()
