"""Turn Galaxigans' sprite definitions into the game pane's text-row format.

The BASIC draws several sprites with ELLIPSE / TRIANGLE / CIRCLEF / RECT
into the definition's pixel buffer. `define_sprite` takes text rows, so the
drawing is done ONCE, here, and the Mojo source carries the result as art a
person can read and edit -- which is what the hand-written ones already are.

Signatures taken from graphics_runtime.zig, not guessed: the last argument
of RECT / ELLIPSE / TRIANGLE / CIRCLE is `filled`, not an outline colour,
and gfx_rect's x,y,w,h becomes rect(x, y, x+w, y+h).
"""
import re, sys

src = open(sys.argv[1]).read()
body = src[src.index("SUB InitArt()"):]
body = body[:body.index("\nEND SUB")]

defs = {}          # id -> [w, h, grid]
frames = {}        # id -> (frame_w, frame_h, count)
palettes = {}      # id -> {index: (r,g,b)}
order = []
frame_origin = 0   # x offset of the frame currently being drawn into

def blank(w, h):
    return [[0] * w for _ in range(h)]

def pset(g, w, h, x, y, c):
    x += frame_origin
    if 0 <= x < w and 0 <= y < h:
        g[y][x] = c

def line(g, w, h, x0, y0, x1, y1, c):
    dx, dy = abs(x1 - x0), -abs(y1 - y0)
    sx = 1 if x0 < x1 else -1
    sy = 1 if y0 < y1 else -1
    err = dx + dy
    while True:
        pset(g, w, h, x0, y0, c)
        if x0 == x1 and y0 == y1:
            break
        e2 = 2 * err
        if e2 >= dy:
            err += dy; x0 += sx
        if e2 <= dx:
            err += dx; y0 += sy

def rect(g, w, h, x, y, rw, rh, c, filled):
    x1, y1 = x + rw, y + rh
    if filled:
        for yy in range(min(y, y1), max(y, y1) + 1):
            for xx in range(min(x, x1), max(x, x1) + 1):
                pset(g, w, h, xx, yy, c)
    else:
        line(g, w, h, x, y, x1, y, c); line(g, w, h, x, y1, x1, y1, c)
        line(g, w, h, x, y, x, y1, c); line(g, w, h, x1, y, x1, y1, c)

def ellipse(g, w, h, cx, cy, rx, ry, c, filled):
    if rx <= 0 or ry <= 0:
        return
    for yy in range(cy - ry, cy + ry + 1):
        for xx in range(cx - rx, cx + rx + 1):
            dx, dy = (xx - cx) / rx, (yy - cy) / ry
            d = dx * dx + dy * dy
            if filled:
                if d <= 1.0:
                    pset(g, w, h, xx, yy, c)
            elif 0.55 <= d <= 1.0:
                pset(g, w, h, xx, yy, c)

def triangle(g, w, h, x1, y1, x2, y2, x3, y3, c, filled):
    if filled:
        def area(ax, ay, bx, by, cx2, cy2):
            return (bx - ax) * (cy2 - ay) - (cx2 - ax) * (by - ay)
        lo_x, hi_x = min(x1, x2, x3), max(x1, x2, x3)
        lo_y, hi_y = min(y1, y2, y3), max(y1, y2, y3)
        for yy in range(lo_y, hi_y + 1):
            for xx in range(lo_x, hi_x + 1):
                a = area(x1, y1, x2, y2, xx, yy)
                b = area(x2, y2, x3, y3, xx, yy)
                cc = area(x3, y3, x1, y1, xx, yy)
                if (a >= 0 and b >= 0 and cc >= 0) or (a <= 0 and b <= 0 and cc <= 0):
                    pset(g, w, h, xx, yy, c)
    else:
        line(g, w, h, x1, y1, x2, y2, c)
        line(g, w, h, x2, y2, x3, y3, c)
        line(g, w, h, x3, y3, x1, y1, c)

cur = None
NUM = r'\s*(-?\d+)\s*'
for raw in body.splitlines():
    s = raw.split("'")[0].strip()
    if not s:
        continue
    for stmt in s.split(" : "):
        stmt = stmt.strip()
        m = re.match(r'SPRITE DEF' + NUM + ',' + NUM + ',' + NUM + '$', stmt)
        if m:
            i, w, h = (int(x) for x in m.groups())
            defs[i] = [w, h, blank(w, h)]
            palettes.setdefault(i, {})
            order.append(i)
            continue
        m = re.match(r'SPRITE PALETTE' + NUM + ',' + NUM + ',' + NUM + ',' + NUM + ',' + NUM + '$', stmt)
        if m:
            i, idx, r, g_, b = (int(x) for x in m.groups())
            palettes.setdefault(i, {})[idx] = (r, g_, b)
            continue
        m = re.match(r'SPRITE FRAMES' + NUM + ',' + NUM + ',' + NUM + ',' + NUM + '$', stmt)
        if m:
            i, fw, fh, n = (int(x) for x in m.groups())
            frames[i] = (fw, fh, n)
            continue
        m = re.match(r'SPRITE BEGIN' + NUM + '$', stmt)
        if m:
            cur = int(m.group(1)); frame_origin = 0; continue
        if stmt == "SPRITE END":
            cur = None; continue
        if cur is None:
            continue
        w, h, g = defs[cur]
        m = re.match(r'SPRITE FRAME' + NUM + '$', stmt)
        if m:
            # Frames are a horizontal strip and drawing is frame-LOCAL, so
            # everything after this shifts by the frame's own origin.
            frame_origin = int(m.group(1)) * frames[cur][0]
            continue
        m = re.match(r'SPRITE ROW' + NUM + r',\s*"([0-9a-fA-F]*)"$', stmt)
        if m:
            row, data = int(m.group(1)), m.group(2)
            # Frame-LOCAL, like every other drawing command. Getting this
            # wrong is invisible in a single-frame definition (the origin is
            # 0) and silently destroys a multi-frame one: the scorpion's two
            # frames both wrote rows 0..13, so frame 1 landed on top of
            # frame 0 and frame 1's own half of the strip stayed empty --
            # which showed up in the game as an alien flashing on and off.
            for x, ch in enumerate(data):
                xx = x + frame_origin
                if 0 <= xx < w and 0 <= row < h:
                    g[row][xx] = int(ch, 16)
            continue
        m = re.match(r'GCLS' + NUM + '$', stmt)
        if m:
            c = int(m.group(1))
            fw = frames[cur][0] if cur in frames else w
            fh = frames[cur][1] if cur in frames else h
            for yy in range(min(fh, h)):
                for xx in range(fw):
                    if frame_origin + xx < w:
                        g[yy][frame_origin + xx] = c
            continue
        m = re.match(r'PSET' + NUM + ',' + NUM + ',' + NUM + '$', stmt)
        if m:
            pset(g, w, h, *(int(x) for x in m.groups())); continue
        m = re.match(r'GLINE' + NUM + ',' + NUM + ',' + NUM + ',' + NUM + ',' + NUM + '$', stmt)
        if m:
            line(g, w, h, *(int(x) for x in m.groups())); continue
        m = re.match(r'RECT' + NUM + ',' + NUM + ',' + NUM + ',' + NUM + ',' + NUM + ',' + NUM + '$', stmt)
        if m:
            rect(g, w, h, *(int(x) for x in m.groups())); continue
        m = re.match(r'ELLIPSE' + NUM + ',' + NUM + ',' + NUM + ',' + NUM + ',' + NUM + ',' + NUM + '$', stmt)
        if m:
            ellipse(g, w, h, *(int(x) for x in m.groups())); continue
        m = re.match(r'CIRCLEF?' + NUM + ',' + NUM + ',' + NUM + ',' + NUM + '$', stmt)
        if m:
            cx, cy, r, c = (int(x) for x in m.groups())
            ellipse(g, w, h, cx, cy, r, r, c, 1); continue
        m = re.match(r'TRIANGLE' + NUM + (',' + NUM) * 7 + '$', stmt)
        if m:
            vals = [int(x) for x in re.findall(r'-?\d+', stmt)]
            triangle(g, w, h, *vals); continue
        print("  UNPARSED: %s" % stmt, file=sys.stderr)

NAMES = {0: "PLAYER", 1: "BEE", 2: "BOSS", 3: "BULLET", 4: "BOMB",
         5: "STAR", 6: "EXPLOSION", 7: "BUTTERFLY", 8: "SCORPION",
         9: "BLUE_BEE", 10: "MOTH", 11: "SAUCER"}

def art_rows(i):
    w, h, g = defs[i]
    fw, fh, n = frames.get(i, (w, h, 1))
    return fw, fh, n, [
        "/".join(
            "".join(("%x" % c) if c else "." for c in row[f * fw:(f + 1) * fw])
            for row in g[:fh]
        )
        for f in range(n)
    ]


if len(sys.argv) > 2 and sys.argv[2] == "--mojo":
    import textwrap
    out = ['''"""Galaxigans' sprite art, converted from the BASIC original.

GENERATED. Regenerate with:

    python3 tools/galaxigans-art.py <the .bas> --mojo > examples/galaxigans/art.mojo

The conversion runs once and the result is committed, because it is art a
person can read and edit -- and because half of it was DRAWN in the original
with ellipses, triangles and filled circles into the definition's pixel
buffer, which `define_sprite` cannot take.

A digit is an index into the sprite's OWN sixteen colours and `.` is
transparent, exactly as the BASIC's own `SPRITE ROW` art was written.
"""

from gamepane.metal import Sprites
from max.gpu.host import DeviceContext

''']
    for i in order:
        fw, fh, n, rs = art_rows(i)
        name = NAMES.get(i, "DEF%d" % i)
        for f, r in enumerate(rs):
            suffix = "" if n == 1 else "_F%d" % f
            wrapped = "\n".join('    "%s"' % c for c in textwrap.wrap(
                r, 68, break_long_words=True, drop_whitespace=False))
            out.append('comptime %s%s = String(\n%s\n)\n' % (name, suffix, wrapped))
    out.append('''

def define_all(mut ctx: DeviceContext, mut sprites: Sprites) raises -> List[Int]:
    """Every definition and its palette, in the BASIC's own order. The
    returned handles are indexed by the *_SLOT constants below."""
    var ids = List[Int]()
''')
    for i in order:
        fw, fh, n, rs = art_rows(i)
        name = NAMES.get(i, "DEF%d" % i)
        low = name.lower()
        first = name if n == 1 else name + "_F0"
        out.append("\n    # %s -- %dx%d, %d frame%s\n"
                   % (name, fw, fh, n, "" if n == 1 else "s"))
        out.append("    let %s_ID = sprites.define_sprite(ctx, %s)\n" % (low, first))
        for f in range(1, n):
            out.append("    _ = sprites.add_frame(ctx, %s_ID, %s_F%d)\n" % (low, name, f))
        for idx in sorted(palettes.get(i, {})):
            r, gg, b = palettes[i][idx]
            out.append("    sprites.sprite_rgb(%s_ID, %d, %d, %d, %d)\n"
                       % (low, idx, r, gg, b))
        out.append("    ids.append(%s_ID)\n" % low)
    out.append("    return ids^\n\n")
    out.append("\n# Where each definition sits in the list `define_all` returns.\n")
    for n_, i in enumerate(order):
        out.append("comptime %s_SLOT = %d\n" % (NAMES.get(i, "DEF%d" % i), n_))
    out.append("\n# Frame sizes, for collision boxes and placement.\n")
    for i in order:
        fw, fh, n, rs = art_rows(i)
        name = NAMES.get(i, "DEF%d" % i)
        out.append("comptime %s_W = %d\ncomptime %s_H = %d\n" % (name, fw, name, fh))
    sys.stdout.write("".join(out))
    sys.exit(0)

for i in order:
    fw, fh, n, rs = art_rows(i)
    print("DEF %d %dx%d frames=%d %s" % (i, fw, fh, n, NAMES.get(i, "DEF%d" % i)))
    for f, r in enumerate(rs):
        print("ROWS %d %s" % (f, r))
    for idx in sorted(palettes.get(i, {})):
        r, gg, b = palettes[i][idx]
        print("PAL %d %d %d %d %d" % (i, idx, r, gg, b))
