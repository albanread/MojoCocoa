# ===----------------------------------------------------------------------=== #
# Sprint G6 — the text overlay and the text plane.
#
# Layer 3 both ways, from one font table. The overlay rasterises glyphs into
# an RGBA buffer when you call it -- retained, right for a title, quietly
# expensive for a HUD. The plane is a grid of four-byte cells a game writes
# with byte stores -- no call to make too often, and a whole screen is one
# copy.
#
# All eight of the Rust's text_overlay tests and all three of text_plane's,
# plus four the Rust cannot ask: the overlay and the plane composited over a
# real drawable, an untouched plane proved invisible, and a transparent
# background proved to leave the picture alone.
#
# Run: GAMEPANE_FRAMES=3 ./tools/gp.sh gamepane/tests/test_text.mojo
# ===----------------------------------------------------------------------=== #

from std.objc import load_framework, autoreleasepool

from gamepane.api import (
    RgbaCanvas, glyph_for, text_cols, text_rows,
    GLYPH_W, GLYPH_H, GLYPH_ADVANCE, CELL_W, CELL_H, CELL_BYTES,
    FLAG_TRANSPARENT_BG,
)
from gamepane.metal import GamePane, IndexedPane, TextOverlay, TextPlane


comptime VIEW_W = 128
comptime VIEW_H = 64


def lit(canvas: RgbaCanvas, x: Int, y: Int) -> Bool:
    """Is this pixel opaque? Alpha is the only channel a blank cannot set."""
    if x < 0 or y < 0 or x >= canvas.width or y >= canvas.height:
        return False
    return canvas.base[unsafe_offset = (y * canvas.width + x) * 4 + 3] != 0


def main() raises:
    if not load_framework["Metal"]():
        raise Error("could not load Metal")

    var failures = 0
    var pane = GamePane(String("gamepane G6"), VIEW_W, VIEW_H)
    var ov = TextOverlay(pane.device, VIEW_W, VIEW_H)
    var c = ov.canvas()

    # ── clear zeroes the whole buffer ────────────────────────────────────
    ov.draw_text(0, 0, String("FILL"), 255, 255, 255, 1)
    ov.clear()
    var nonzero = 0
    for i in range(VIEW_W * VIEW_H * 4):
        if c.base[unsafe_offset=i] != 0:
            nonzero += 1
    if nonzero != 0:
        print("FAIL  clear left", nonzero, "non-zero bytes")
        failures += 1
    else:
        print("ok    clear zeroes the whole buffer")

    # ── letter A lights the expected pixels ──────────────────────────────
    # 0x0E is .###. -- so the top row of A is lit at x=1,2,3 and dark at 0,4.
    ov.clear()
    ov.draw_text(0, 0, String("A"), 200, 100, 50, 1)
    if (
        lit(c, 0, 0) or not lit(c, 1, 0) or not lit(c, 2, 0)
        or not lit(c, 3, 0) or lit(c, 4, 0)
    ):
        print("FAIL  A's top row is not .###.")
        failures += 1
    # Row 3 is 0x1F, the crossbar: all five lit.
    elif not (lit(c, 0, 3) and lit(c, 4, 3)):
        print("FAIL  A's crossbar is not solid")
        failures += 1
    else:
        print("ok    letter A lights the expected pixels")
    # And the colour is the one asked for.
    if c.base[unsafe_offset = (0 * VIEW_W + 1) * 4 + 0] != 200:
        print("FAIL  the glyph is not the colour requested")
        failures += 1

    # ── digit 0 is a ring with a hollow interior ─────────────────────────
    ov.clear()
    ov.draw_text(0, 0, String("0"), 255, 255, 255, 1)
    # 0x0E,0x11,... -- the sides are lit and (1,1) is not.
    if not (lit(c, 0, 1) and lit(c, 4, 1)) or lit(c, 1, 1):
        print("FAIL  digit 0 is not a hollow ring")
        failures += 1
    else:
        print("ok    digit 0 is a ring with a hollow interior")

    # ── space leaves its cell untouched ──────────────────────────────────
    ov.clear()
    ov.draw_text(0, 0, String(" "), 255, 255, 255, 1)
    var any = 0
    for y in range(GLYPH_H):
        for x in range(GLYPH_W):
            if lit(c, x, y):
                any += 1
    if any != 0:
        print("FAIL  space lit", any, "pixels")
        failures += 1
    else:
        print("ok    space leaves its cell untouched")

    # ── characters advance by GLYPH_ADVANCE at scale 1 ───────────────────
    ov.clear()
    ov.draw_text(0, 0, String("AA"), 255, 255, 255, 1)
    # The second A's top row starts at x = 6 + 1 = 7, and x = 5, 6 are the
    # spacing columns between them.
    if lit(c, 5, 0) or lit(c, 6, 0) or not lit(c, 7, 0):
        print("FAIL  the advance is not", GLYPH_ADVANCE, "pixels")
        failures += 1
    else:
        print("ok    characters advance by", GLYPH_ADVANCE, "pixels")

    # ── scale blocks each font pixel into a square ───────────────────────
    ov.clear()
    ov.draw_text(0, 0, String("A"), 255, 255, 255, 3)
    # A's top row .###. at scale 3: x 0..2 dark, 3..11 lit, and three rows
    # deep.
    if (
        lit(c, 0, 0) or lit(c, 2, 2)
        or not lit(c, 3, 0) or not lit(c, 11, 2)
        or lit(c, 12, 0)
    ):
        print("FAIL  scale 3 did not block each font pixel into a square")
        failures += 1
    else:
        print("ok    scale blocks each font pixel into a square")

    # ── an unknown character is the hollow placeholder ───────────────────
    ov.clear()
    ov.draw_text(0, 0, String("%"), 255, 255, 255, 1)
    # 0x1F top and bottom, 0x11 between: a box.
    if not (
        lit(c, 0, 0) and lit(c, 4, 0) and lit(c, 2, 0)
        and lit(c, 0, 3) and lit(c, 4, 3) and not lit(c, 2, 3)
        and lit(c, 2, 6)
    ):
        print("FAIL  an unknown character is not a hollow box")
        failures += 1
    else:
        print("ok    an unknown character renders the hollow placeholder")

    # ── lowercase folds to the uppercase glyph ───────────────────────────
    let upper = glyph_for(ord("A"))
    let lower = glyph_for(ord("a"))
    var same = True
    for i in range(GLYPH_H):
        if upper[i] != lower[i]:
            same = False
    if not same:
        print("FAIL  lowercase did not fold to uppercase")
        failures += 1
    else:
        print("ok    lowercase folds to the uppercase glyph")

    # ── the plane's geometry ─────────────────────────────────────────────
    # 6x8 cells: the glyph plus one column and one row of leading. A
    # 320x240 viewport is therefore 53x30, which is the check -- comparing
    # the constants to themselves is something the compiler folds away and
    # warns about.
    if text_cols(320) != 53 or text_rows(240) != 30:
        print("FAIL  320x240 is", text_cols(320), "x", text_rows(240),
              "cells, want 53 x 30")
        failures += 1
    # Never zero, however small the viewport.
    if text_cols(1) != 1 or text_rows(0) != 1:
        print("FAIL  a tiny viewport gave a zero-sized grid")
        failures += 1
    else:
        print("ok    the viewport divides into 6x8 cells, never zero of them")

    var tp = TextPlane(pane.device, VIEW_W, VIEW_H)
    if tp.cols != text_cols(VIEW_W) or tp.rows != text_rows(VIEW_H):
        print("FAIL  the plane's grid disagrees with the geometry")
        failures += 1

    # ── a fresh plane is entirely unused cells ───────────────────────────
    let cp = tp.cells_ptr()
    var used = 0
    for i in range(tp.cells_len()):
        if cp[unsafe_offset=i] != 0:
            used += 1
    if used != 0:
        print("FAIL  a fresh plane had", used, "non-zero bytes")
        failures += 1
    else:
        print("ok    a fresh plane is entirely unused cells")

    # ── cells are writable, and clear blanks them ────────────────────────
    tp.write(2, 1, String("HI"), 23, 16, 0)
    let at = (1 * tp.cols + 2) * CELL_BYTES
    if (
        cp[unsafe_offset = at + 0] != UInt8(ord("H"))
        or cp[unsafe_offset = at + 1] != 23
        or cp[unsafe_offset = at + CELL_BYTES] != UInt8(ord("I"))
    ):
        print("FAIL  a written cell did not read back")
        failures += 1
    tp.put(-1, 0, ord("X"))
    tp.put(0, tp.rows, ord("X"))
    tp.clear()
    used = 0
    for i in range(tp.cells_len()):
        if cp[unsafe_offset=i] != 0:
            used += 1
    if used != 0:
        print("FAIL  clear left", used, "non-zero bytes")
        failures += 1
    else:
        print("ok    cells are writable, out of range is safe, clear blanks")

    # ── composited, through a real drawable ──────────────────────────────
    with autoreleasepool():
        var ip = IndexedPane(
            pane.ctx, pane.device, VIEW_W, VIEW_H, VIEW_W, VIEW_H
        )
        ip.active_plane().cls(20)
        ip.set_rgb(20, 0, 0, 200)          # a blue picture underneath
        ip.set_scroll(0, 0)

        # An untouched plane must be invisible, and the overlay's blank
        # pixels must be too: both are the reason layer 3 can always be on.
        ov.clear()
        var frame = pane.begin_frame()
        ip.render(frame, clear=True)
        ov.render(frame)
        tp.render(frame)
        pane.end_frame(frame)
        var px = pane.read_frame(frame)
        if len(px) == 0:
            print("SKIP  no drawable; the composite checks need one")
        else:
            if Int(px[0]) == 200 and Int(px[2]) == 0:
                print("ok    an empty overlay and an untouched plane are")
                print("      invisible over the picture")
            else:
                print("FAIL  layer 3 painted over an empty frame: BGRA",
                      px[0], px[1], px[2])
                failures += 1

            # The overlay: a red 'A' at 4,4 must reach the drawable.
            ov.clear()
            ov.draw_text(4, 4, String("A"), 250, 20, 30, 1)
            frame = pane.begin_frame()
            ip.render(frame, clear=True)
            ov.render(frame)
            pane.end_frame(frame)
            px = pane.read_frame(frame)
            let a_lit = ((4 + 0) * VIEW_W + (4 + 1)) * 4     # A's top row
            let a_gap = ((4 + 0) * VIEW_W + (4 + 0)) * 4     # dark column
            if (
                Int(px[a_lit + 2]) == 250 and Int(px[a_lit + 1]) == 20
                and Int(px[a_gap + 0]) == 200
            ):
                print("ok    the overlay composited over the picture")
            else:
                print("FAIL  the overlay: lit BGRA", px[a_lit],
                      px[a_lit + 1], px[a_lit + 2], " gap", px[a_gap])
                failures += 1

            # The plane, with a transparent background: the glyph paints and
            # the cell around it does not.
            ov.clear()
            tp.clear()
            tp.write(1, 1, String("X"), 23, 16, FLAG_TRANSPARENT_BG)
            frame = pane.begin_frame()
            ip.render(frame, clear=True)
            tp.render(frame)
            pane.end_frame(frame)
            px = pane.read_frame(frame)
            # Cell (1,1) covers pixels x 6..11, y 8..15. X's top row is
            # 0x11 -- lit at the first and last columns.
            let x_lit = (8 * VIEW_W + 6) * 4
            let x_bg = (15 * VIEW_W + 11) * 4      # the leading, never lit
            if Int(px[x_lit + 0]) != 232 or Int(px[x_bg + 0]) != 200:
                print("FAIL  transparent-bg cell: glyph BGRA", px[x_lit],
                      px[x_lit + 1], px[x_lit + 2],
                      " leading", px[x_bg])
                failures += 1
            else:
                print("ok    a transparent background leaves the picture,")
                print("      and the glyph paints in its palette colour")

            # And an opaque background paints the whole cell.
            tp.clear()
            tp.write(1, 1, String(" "), 23, 24, 0)   # space, bg = red
            frame = pane.begin_frame()
            ip.render(frame, clear=True)
            tp.render(frame)
            pane.end_frame(frame)
            px = pane.read_frame(frame)
            if Int(px[x_bg + 2]) == 255 and Int(px[x_bg + 1]) == 0:
                print("ok    an opaque background paints the whole cell")
            else:
                print("FAIL  an opaque background did not paint: BGRA",
                      px[x_bg], px[x_bg + 1], px[x_bg + 2])
                failures += 1

    pane.close()

    print()
    if failures == 0:
        print("G6 text overlay / text plane: PASS")
    else:
        print("G6 text overlay / text plane: FAILED", failures, "check(s)")
        raise Error("G6 failed")
