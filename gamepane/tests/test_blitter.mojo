# ===----------------------------------------------------------------------=== #
# Sprint G4 — the blitter, as Mojo GPU kernels.
#
# copy, transparent copy, minterm (AND/OR/XOR) and fill, between any two of
# the indexed pane's eight slots, dispatched through this fork's own GPU
# backend. The kernels are ordinary Mojo `def`s -- no hand-written Metal
# compute shaders anywhere -- and they write the SAME bytes the fragment
# shader samples, so unlike the Rust there is no CPU mirror to apply every
# operation to a second time.
#
# The Rust's four blitter tests are here, reading the result straight back
# through the plane (there is nothing to map: the bytes are already ours),
# plus a fifth that blits, presents, and reads the composite -- which is the
# only thing that proves the ordering rule.
#
# Run: GAMEPANE_FRAMES=3 ./tools/gp.sh gamepane/tests/test_blitter.mojo
# ===----------------------------------------------------------------------=== #

from std.objc import load_framework, autoreleasepool

from gamepane.api import FRONT, BACK, OP_AND, OP_OR, OP_XOR, clip_blit
from gamepane.metal import GamePane, IndexedPane, warm_up_blitter


comptime W = 64
comptime H = 64
comptime VIEW_W = 32
comptime VIEW_H = 32


def main() raises:
    if not load_framework["Metal"]():
        raise Error("could not load Metal")

    var failures = 0
    var pane = GamePane(String("gamepane G4"), VIEW_W, VIEW_H)
    var ip = IndexedPane(pane.ctx, pane.device, W, H, VIEW_W, VIEW_H)
    warm_up_blitter(pane.ctx)
    print("blitter warmed; stride", ip.stride)

    # ── clipping, which happens before any thread launches ───────────────
    var r = clip_blit(0, 0, -2, -3, 10, 10, 64, 64, 64, 64)
    if r.src_x != 2 or r.src_y != 3 or r.dst_x != 0 or r.dst_y != 0 \
       or r.w != 8 or r.h != 7:
        print("FAIL  clipping a negative destination:", r.src_x, r.src_y,
              r.dst_x, r.dst_y, r.w, r.h)
        failures += 1
    r = clip_blit(60, 60, 0, 0, 10, 10, 64, 64, 64, 64)
    if r.w != 4 or r.h != 4:
        print("FAIL  clipping against the source's far edge:", r.w, r.h)
        failures += 1
    r = clip_blit(0, 0, 100, 100, 10, 10, 64, 64, 64, 64)
    if not r.empty():
        print("FAIL  a wholly off-plane blit was not empty")
        failures += 1
    else:
        print("ok    both origins move together, and off-plane clips to none")

    # ── copy moves pixels from one slot to another ───────────────────────
    var src = ip.plane(2)
    var dst = ip.plane(3)
    src.cls(0)
    dst.cls(0)
    src.pset(1, 1, 7)
    src.pset(2, 1, 8)
    src.pset(1, 2, 9)
    ip.blit_copy(pane.ctx, 2, 3, 1, 1, 10, 20, 2, 2)
    ip.finish(pane.ctx)
    if (
        dst.pget(10, 20) != 7
        or dst.pget(11, 20) != 8
        or dst.pget(10, 21) != 9
        or dst.pget(12, 20) != 0
    ):
        print("FAIL  copy:", dst.pget(10, 20), dst.pget(11, 20),
              dst.pget(10, 21), dst.pget(12, 20))
        failures += 1
    else:
        print("ok    copy moves a rectangle from one slot to another")

    # ── transparent copy skips index-0 source pixels ─────────────────────
    src.cls(0)
    dst.cls(5)
    src.pset(0, 0, 3)
    # (1, 0) stays 0, so the destination's 5 must survive there.
    src.pset(0, 1, 4)
    ip.blit_transparent(pane.ctx, 2, 3, 0, 0, 0, 0, 2, 2)
    ip.finish(pane.ctx)
    if (
        dst.pget(0, 0) != 3
        or dst.pget(1, 0) != 5
        or dst.pget(0, 1) != 4
        or dst.pget(1, 1) != 5
    ):
        print("FAIL  transparent copy:", dst.pget(0, 0), dst.pget(1, 0),
              dst.pget(0, 1), dst.pget(1, 1))
        failures += 1
    else:
        print("ok    transparent copy leaves index 0 alone")

    # ── minterm masks the destination by the source ──────────────────────
    # 0b1100 & 0b1010 = 0b1000, | = 0b1110, ^ = 0b0110.
    for op_and_want in [(OP_AND, 8), (OP_OR, 14), (OP_XOR, 6)]:
        src.cls(0)
        dst.cls(0)
        src.pset(0, 0, 12)
        dst.pset(0, 0, 10)
        ip.blit_minterm(pane.ctx, 2, 3, 0, 0, 0, 0, 1, 1, op_and_want[0])
        ip.finish(pane.ctx)
        if Int(dst.pget(0, 0)) != op_and_want[1]:
            print("FAIL  minterm op", op_and_want[0], "gave",
                  dst.pget(0, 0), "want", op_and_want[1])
            failures += 1
    print("ok    minterm combines source and destination bitwise")

    # ── fill covers exactly its rectangle ────────────────────────────────
    dst.cls(0)
    ip.blit_fill(pane.ctx, 3, 4, 5, 6, 7, 33)
    ip.finish(pane.ctx)
    var bad = 0
    for y in range(3, 14):
        for x in range(2, 12):
            let want = UInt8(33) if (
                x >= 4 and x < 10 and y >= 5 and y < 12
            ) else UInt8(0)
            if dst.pget(x, y) != want:
                bad += 1
    if bad != 0:
        print("FAIL  fill is wrong at", bad, "cells")
        failures += 1
    else:
        print("ok    fill covers exactly its rectangle")

    # A rectangle whose size is not a multiple of the 16-thread block: the
    # last threadgroup overhangs, and the grid check is what stops it
    # writing past the rectangle.
    dst.cls(0)
    ip.blit_fill(pane.ctx, 3, 0, 0, 17, 17, 44)
    ip.finish(pane.ctx)
    if dst.pget(16, 16) != 44 or dst.pget(17, 16) != 0 or dst.pget(16, 17) != 0:
        print("FAIL  an overhanging threadgroup wrote outside the rectangle")
        failures += 1
    else:
        print("ok    a 17x17 blit does not spill out of its last block")

    # An off-plane blit is a no-op, not a trap.
    dst.cls(1)
    ip.blit_copy(pane.ctx, 2, 3, 0, 0, 1000, 1000, 8, 8)
    ip.blit_fill(pane.ctx, 3, -100, -100, 4, 4, 99)
    ip.finish(pane.ctx)
    if dst.pget(0, 0) != 1:
        print("FAIL  an off-plane blit touched the plane")
        failures += 1
    else:
        print("ok    an off-plane blit is a no-op")

    # ── the ordering rule, through a real frame ──────────────────────────
    with autoreleasepool():
        # Blits go on the runtime's stream; the frame is encoded on the
        # layer's command queue. Nothing orders them but `finish`, so this
        # blits into FRONT, finishes, presents, and reads the composite: if
        # the ordering rule were wrong the frame would show the old bytes.
        ip.set_active(FRONT)
        ip.active_plane().cls(0)
        ip.set_rgb(200, 40, 50, 60)
        ip.set_scroll(0, 0)

        # NO explicit finish here, deliberately: begin_frame does it, and
        # this is the check that says so.
        #
        # The work has to be big enough to lose the race, or the check is
        # decorative. `enqueue_function` DOES commit -- it just does not
        # wait -- so a 32x4 fill finishes long before `nextDrawable`
        # returns and passes with the synchronize removed. Measured: a
        # single 2048x2048 fill is still unfinished the instant enqueue
        # returns. Here it is a queue of fills, every one of them writing
        # index 100 except the LAST, which writes 200. Any frame that
        # encodes before the queue drains reads 100, and 100 and 200 are
        # different colours.
        # It also has to be a big enough PLANE: 240 fills of a 64x64 world
        # is a million writes and still wins the race. A 1024x1024 world is
        # sixty million, and does not.
        comptime BIG = 1024
        comptime QUEUED = 60
        var big = IndexedPane(pane.ctx, pane.device, BIG, BIG, VIEW_W, VIEW_H)
        big.set_active(FRONT)
        big.set_scroll(0, 0)
        big.set_rgb(200, 40, 50, 60)
        big.set_rgb(100, 10, 220, 30)
        for i in range(QUEUED):
            let v = UInt8(200) if i == QUEUED - 1 else UInt8(100)
            big.blit_fill(pane.ctx, FRONT, 0, 0, BIG, BIG, v)

        let frame = pane.begin_frame()

        # The rule, checked where it can actually fail. Measured on this
        # machine: those sixty fills take 4.5 ms to drain and the plane's
        # last byte is still unwritten the instant enqueue returns -- but
        # `nextDrawable` itself blocks longer than 4.5 ms, so the composite
        # below passes even with the synchronize removed. It is masked, not
        # absent, and a faster drawable or a slower blit unmasks it. So ask
        # the plane directly: after begin_frame the queue must be drained.
        if big.plane(FRONT).pget(BIG - 1, BIG - 1) != 200:
            print("FAIL  begin_frame did not drain the blit queue:",
                  big.plane(FRONT).pget(BIG - 1, BIG - 1))
            failures += 1
        else:
            print("ok    begin_frame drained", QUEUED, "queued blits")

        pane.clear(frame)
        big.render(frame)
        pane.end_frame(frame)
        let px = pane.read_frame(frame)
        if len(px) == 0:
            print("SKIP  no drawable; the ordering check needs one")
        elif Int(px[0]) == 60 and Int(px[1]) == 50 and Int(px[2]) == 40:
            print("ok    the LAST of", QUEUED, "queued blits reached the")
            print("      frame that followed them")
        elif Int(px[1]) == 220:
            print("FAIL  the frame encoded before the blit queue drained")
            failures += 1
        else:
            print("FAIL  the blit did not reach the frame: BGRA",
                  px[0], px[1], px[2])
            failures += 1

    pane.close()

    print()
    if failures == 0:
        print("G4 blitter: PASS")
    else:
        print("G4 blitter: FAILED", failures, "check(s)")
        raise Error("G4 failed")
