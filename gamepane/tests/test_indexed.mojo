# ===----------------------------------------------------------------------=== #
# Sprint G3 — the indexed pane.
#
# Layer 1 entire: eight slots, the per-line/global palette split, overscan
# scrolling, and every drawing primitive -- with no CPU mirror. Each slot is
# one DeviceBuffer with a linear R8Uint texture view over it, so a `pset`
# stores into the exact bytes the fragment shader samples: no dirty flag, no
# upload(), and nothing that can copy a stale mirror over a game's work.
#
# All nine of the Rust's `indexed_pane.rs` tests are here, plus a composite
# read back through a real drawable, because "the palette arithmetic is
# right" and "the right colour reached the screen" are different claims.
#
# Run: GAMEPANE_FRAMES=3 ./tools/gp.sh gamepane/tests/test_indexed.mojo
# ===----------------------------------------------------------------------=== #

from std.objc import load_framework, autoreleasepool

from gamepane.api import (
    Plane, NUM_BUFFERS, FRONT, BACK, TRANSPARENT,
    palette_entries, palette_global_base, palette_line_entry,
    hsv_to_rgb, clamp_scroll,
)
from gamepane.metal import GamePane, IndexedPane


comptime WORLD_W = 640
comptime WORLD_H = 480
comptime VIEW_W = 320
comptime VIEW_H = 240


def main() raises:
    if not load_framework["Metal"]():
        raise Error("could not load Metal")

    var failures = 0
    var pane = GamePane(String("gamepane G3"), VIEW_W, VIEW_H)
    var ip = IndexedPane(
        pane.ctx, pane.device, WORLD_W, WORLD_H, VIEW_W, VIEW_H
    )
    print(
        "world", WORLD_W, "x", WORLD_H, " viewport", VIEW_W, "x", VIEW_H,
        " stride", ip.stride,
    )

    # ── pset/pget round-trips within the active buffer ───────────────────
    var p = ip.active_plane()
    p.pset(3, 4, 9)
    p.pset(WORLD_W - 1, WORLD_H - 1, 200)
    if p.pget(3, 4) != 9 or p.pget(WORLD_W - 1, WORLD_H - 1) != 200:
        print("FAIL  pset/pget did not round-trip")
        failures += 1
    else:
        print("ok    pset/pget round-trips within the active buffer")

    # ── out-of-bounds pset is a no-op, not a trap ────────────────────────
    p.pset(-1, 0, 7)
    p.pset(0, -1, 7)
    p.pset(WORLD_W, 0, 7)
    p.pset(0, WORLD_H, 7)
    p.pset(1 << 30, 1 << 30, 7)
    if p.pget(-1, -1) != TRANSPARENT or p.pget(WORLD_W, WORLD_H) != TRANSPARENT:
        print("FAIL  out-of-bounds pget was not transparent")
        failures += 1
    else:
        print("ok    out-of-bounds pset is a no-op and pget is transparent")

    # ── cls fills the whole active buffer ────────────────────────────────
    p.cls(42)
    var wrong = 0
    for y in range(0, WORLD_H, 37):
        for x in range(0, WORLD_W, 41):
            if p.pget(x, y) != 42:
                wrong += 1
    if wrong != 0 or p.pget(0, 0) != 42 or p.pget(WORLD_W - 1, WORLD_H - 1) != 42:
        print("FAIL  cls left", wrong, "cells unfilled")
        failures += 1
    else:
        print("ok    cls fills the whole active buffer")

    # ── fill_rect covers exactly its rectangle ───────────────────────────
    p.cls(0)
    p.fill_rect(10, 20, 5, 3, 77)
    var bad = 0
    for y in range(18, 26):
        for x in range(8, 18):
            let want = UInt8(77) if (
                x >= 10 and x < 15 and y >= 20 and y < 23
            ) else UInt8(0)
            if p.pget(x, y) != want:
                bad += 1
    if bad != 0:
        print("FAIL  fill_rect is wrong at", bad, "cells")
        failures += 1
    else:
        print("ok    fill_rect covers exactly its rectangle")

    # ── blit is bulk and length-safe in both directions ──────────────────
    p.cls(0)
    var short = List[UInt8](length=5, fill=3)
    p.blit(Span(short))
    if p.pget(0, 0) != 3 or p.pget(4, 0) != 3 or p.pget(5, 0) != 0:
        print("FAIL  a short blit did not fill only the prefix")
        failures += 1
    var over = List[UInt8](length=WORLD_W * WORLD_H + 1000, fill=8)
    p.blit(Span(over))
    if p.pget(0, 0) != 8 or p.pget(WORLD_W - 1, WORLD_H - 1) != 8:
        print("FAIL  an oversized blit did not fill the plane")
        failures += 1
    else:
        print("ok    blit is bulk and length-safe in both directions")

    # blit is width-packed while the plane is stride-packed, so the row after
    # a full blit must start with the source's row-1 byte, not its stride-th.
    var ramp = List[UInt8](length=WORLD_W * 2, fill=0)
    for i in range(WORLD_W * 2):
        ramp[i] = UInt8(i % 251)
    p.cls(0)
    p.blit(Span(ramp))
    if p.pget(0, 1) != UInt8(WORLD_W % 251):
        print("FAIL  blit did not repack width rows into stride rows")
        failures += 1
    else:
        print("ok    blit repacks width-major source into stride-major rows")

    # ── the primitives that draw shapes ──────────────────────────────────
    p.cls(0)
    p.line(0, 0, 10, 10, 5)
    var diag = 0
    for i in range(11):
        if p.pget(i, i) == 5:
            diag += 1
    p.line(2, 30, 20, 30, 6)
    var horiz = 0
    for x in range(2, 21):
        if p.pget(x, 30) == 6:
            horiz += 1
    if diag != 11 or horiz != 19:
        print("FAIL  line: diagonal", diag, "of 11, horizontal", horiz, "of 19")
        failures += 1
    else:
        print("ok    Bresenham draws both a diagonal and an axis-aligned run")

    p.cls(0)
    p.circle(50, 50, 10, 4)
    # The outline touches the four cardinal points and leaves the middle bare.
    if (
        p.pget(60, 50) != 4
        or p.pget(40, 50) != 4
        or p.pget(50, 60) != 4
        or p.pget(50, 40) != 4
        or p.pget(50, 50) != 0
    ):
        print("FAIL  circle is not a hollow outline through its cardinals")
        failures += 1
    else:
        print("ok    circle is a hollow midpoint outline")

    p.cls(0)
    p.disc(50, 50, 10, 4)
    if p.pget(50, 50) != 4 or p.pget(60, 50) != 4 or p.pget(50, 62) != 0:
        print("FAIL  disc is not filled, or leaked outside its radius")
        failures += 1
    else:
        print("ok    disc fills the circle and stops at the radius")

    # ── swap_buffers exchanges FRONT and BACK content ────────────────────
    ip.set_active(FRONT)
    ip.active_plane().cls(1)
    ip.set_active(BACK)
    ip.active_plane().cls(2)
    ip.set_active(FRONT)
    ip.swap_buffers()
    # active followed its content: it was FRONT, so it is BACK now.
    if ip.active != BACK:
        print("FAIL  swap_buffers did not follow the active slot")
        failures += 1
    if ip.plane(FRONT).pget(0, 0) != 2 or ip.plane(BACK).pget(0, 0) != 1:
        print("FAIL  swap_buffers did not exchange front and back")
        failures += 1
    else:
        print("ok    swap_buffers exchanges FRONT and BACK")
    ip.set_active(FRONT)

    # ── scroll is clamped to the overscan margin ─────────────────────────
    ip.set_scroll(-100, -100)
    var s = ip.scroll()
    if s[0] != 0 or s[1] != 0:
        print("FAIL  negative scroll was not clamped to 0")
        failures += 1
    ip.set_scroll(10000, 10000)
    s = ip.scroll()
    if s[0] != WORLD_W - VIEW_W or s[1] != WORLD_H - VIEW_H:
        print("FAIL  scroll clamped to", s[0], s[1])
        failures += 1
    else:
        print("ok    scroll is clamped to the overscan margin")
    ip.set_scroll(0, 0)

    # ── the palette's per-line / global split ────────────────────────────
    let pal = ip.palette_ptr()
    ip.set_line_rgb(5, 3, 10, 20, 30)
    var k = palette_line_entry(5, 3)
    if (
        pal[unsafe_offset = k * 4 + 0] != 10
        or pal[unsafe_offset = k * 4 + 1] != 20
        or pal[unsafe_offset = k * 4 + 2] != 30
        or pal[unsafe_offset = k * 4 + 3] != 255
    ):
        print("FAIL  set_line_rgb wrote the wrong entry")
        failures += 1
    ip.set_rgb(200, 40, 50, 60)
    k = ip.palette_global_start() + (200 - 16)
    if (
        pal[unsafe_offset = k * 4 + 0] != 40
        or pal[unsafe_offset = k * 4 + 1] != 50
        or pal[unsafe_offset = k * 4 + 2] != 60
    ):
        print("FAIL  set_rgb wrote the wrong entry")
        failures += 1
    if ip.palette_global_start() != VIEW_H * 16:
        print("FAIL  the globals do not begin after every line's sixteen")
        failures += 1
    if ip.palette_entry_count() != VIEW_H * 16 + 240:
        print("FAIL  palette_entry_count is", ip.palette_entry_count())
        failures += 1
    else:
        print("ok    the palette splits per-line from global at index 16")

    # ── set_line_rgb rejects index 0 and the global range ────────────────
    var rejected = 0
    try:
        ip.set_line_rgb(0, 0, 1, 2, 3)
    except:
        rejected += 1
    try:
        ip.set_line_rgb(0, 16, 1, 2, 3)
    except:
        rejected += 1
    try:
        ip.set_line_rgb(VIEW_H, 1, 1, 2, 3)
    except:
        rejected += 1
    try:
        ip.set_rgb(15, 1, 2, 3)
    except:
        rejected += 1
    if rejected != 4:
        print("FAIL  the palette accepted", 4 - rejected, "bad calls")
        failures += 1
    else:
        print("ok    index 0 and the wrong half are rejected, not silent")

    # ── a world whose width the alignment does NOT divide ────────────────
    # 640 is a multiple of 16, so everything above ran with stride == width
    # and proved nothing about the stride. 641 is the case a demo assuming
    # `y * width + x` gets wrong, so it is the one worth testing.
    var awk = IndexedPane(pane.ctx, pane.device, 641, 64, 320, 32)
    if awk.stride <= 641 or awk.stride % 16 != 0:
        print("FAIL  awkward stride is", awk.stride)
        failures += 1
    var ap = awk.active_plane()
    ap.cls(0)
    ap.pset(640, 0, 11)          # the last visible column of row 0
    ap.pset(0, 1, 22)            # the first column of row 1
    if ap.pget(640, 0) != 11 or ap.pget(0, 1) != 22:
        print("FAIL  the awkward-width plane did not round-trip")
        failures += 1
    # Row 1 starts a full STRIDE in, not a width in: reading at the width
    # offset must land in the padding, which cls left at 0.
    let araw = awk.plane(awk.active)
    if araw.base[unsafe_offset=641] != 0:
        print("FAIL  row 1 began at the width, not the stride")
        failures += 1
    elif araw.base[unsafe_offset = awk.stride] != 22:
        print("FAIL  row 1 is not a stride in")
        failures += 1
    else:
        print("ok    a 641-wide world has a", awk.stride, "byte row")

    # ── the composite, through a real drawable ───────────────────────────
    with autoreleasepool():
        # Index 0 must discard so the layer below shows through; index 200
        # must resolve through the GLOBAL half of the palette; and a per-line
        # index must resolve differently on different lines, which is the
        # whole point of the split.
        ip.set_active(FRONT)
        var fp = ip.active_plane()
        fp.cls(0)
        fp.fill_rect(0, 0, VIEW_W, 1, 200)          # top line: global colour
        fp.fill_rect(0, 1, VIEW_W, 1, 3)            # line 1: per-line index 3
        fp.fill_rect(0, 2, VIEW_W, 1, 3)            # line 2: the same index
        ip.set_rgb(200, 40, 50, 60)
        ip.set_line_rgb(1, 3, 90, 0, 0)
        ip.set_line_rgb(2, 3, 0, 90, 0)

        let frame = pane.begin_frame()
        pane.clear(frame)           # a ground for index 0 to reveal
        ip.render(frame)            # Load, so the clear shows through
        pane.end_frame(frame)
        let px = pane.read_frame(frame)
        if len(px) == 0:
            print("SKIP  no drawable; the composite check needs one")
        else:
            # BGRA rows of VIEW_W pixels.
            let row0 = 0
            let row1 = VIEW_W * 4
            let row2 = VIEW_W * 8
            let row9 = VIEW_W * 4 * 9
            var ok = True
            if not (
                Int(px[row0 + 0]) == 60
                and Int(px[row0 + 1]) == 50
                and Int(px[row0 + 2]) == 40
            ):
                print("FAIL  global index 200 is BGRA",
                      px[row0], px[row0 + 1], px[row0 + 2])
                ok = False
            if not (Int(px[row1 + 2]) == 90 and Int(px[row1 + 1]) == 0):
                print("FAIL  line 1 index 3 is BGRA",
                      px[row1], px[row1 + 1], px[row1 + 2])
                ok = False
            if not (Int(px[row2 + 1]) == 90 and Int(px[row2 + 2]) == 0):
                print("FAIL  line 2 index 3 is BGRA",
                      px[row2], px[row2 + 1], px[row2 + 2])
                ok = False
            # Index 0 discarded: row 9 is untouched, so the pane's ground.
            if not (Int(px[row9 + 0]) == 23 and Int(px[row9 + 2]) == 13):
                print("FAIL  index 0 did not discard; row 9 is BGRA",
                      px[row9], px[row9 + 1], px[row9 + 2])
                ok = False
            if ok:
                print("ok    the same index is two colours on two lines,")
                print("      a global index resolves in the other half,")
                print("      and index 0 discarded to the layer below")
            else:
                failures += 1

        # Scrolling moves what the viewport reads with nothing redrawn: put a
        # marker deeper into the world than the viewport can see, then scroll
        # to it.
        # A marker at world row 300 -- past the viewport's first 240 rows, so
        # invisible until the pane scrolls. Scrolling the full overscan
        # margin (480 - 240 = 240) puts it at SCREEN row 60, and nothing is
        # redrawn to get it there: only the uniform changed.
        comptime MARKER_ROW = 300
        let margin = WORLD_H - VIEW_H
        let screen_row = MARKER_ROW - margin
        fp.cls(0)
        fp.fill_rect(0, MARKER_ROW, VIEW_W, 1, 200)
        var f2 = pane.begin_frame()
        pane.clear(f2)
        ip.render(f2)
        pane.end_frame(f2)
        var before = pane.read_frame(f2)

        ip.set_scroll(0, 10000)          # asks for far more than exists
        let sc = ip.scroll()
        if sc[1] != margin:
            print("FAIL  scroll clamped to", sc[1], "want", margin)
            failures += 1
        f2 = pane.begin_frame()
        pane.clear(f2)
        ip.render(f2)
        pane.end_frame(f2)
        let after = pane.read_frame(f2)

        let at = screen_row * VIEW_W * 4
        if len(before) == 0 or len(after) == 0:
            print("SKIP  no drawable; the scroll check needs one")
        elif Int(before[at]) == 23 and Int(after[at]) == 60:
            print(
                "ok    world row", MARKER_ROW, "arrived at screen row",
                screen_row, "with nothing redrawn",
            )
        else:
            print("FAIL  scroll: screen row", screen_row, "BGRA before",
                  before[at], " after", after[at])
            failures += 1

    pane.close()

    print()
    if failures == 0:
        print("G3 indexed pane: PASS")
    else:
        print("G3 indexed pane: FAILED", failures, "check(s)")
        raise Error("G3 failed")
