# ===----------------------------------------------------------------------=== #
# Sprint G5 — sprites, composited by the GPU.
#
# This layer draws QUADS. Nothing here writes into the indexed pane's planes
# and the blitter is not involved: each visible instance is a textured quad
# in the sprite layer's own render pass, blended source-alpha over whatever
# the layers below already put on the drawable. That is what makes scale,
# rotation and alpha per-instance and free, and why a moving sprite never
# has to repair the background it covered.
#
# All six of the Rust's sprite tests, plus four checks it has no equivalent
# of -- the composite read back through a real drawable, where a sprite's
# own palette resolves, index 0 discards to the layer below, alpha actually
# blends rather than switches, and the world-space position tracks the
# scroll.
#
# Run: GAMEPANE_FRAMES=3 ./tools/gp.sh gamepane/tests/test_sprites.mojo
# ===----------------------------------------------------------------------=== #

from std.objc import load_framework, autoreleasepool

from gamepane.api import (
    parse_sprite_rows, sprites_overlap, quad_vertices, SpriteInstance,
)
from gamepane.metal import GamePane, IndexedPane, Sprites


comptime VIEW_W = 64
comptime VIEW_H = 64

# A 4x3 sprite: a solid block of index 1 with a transparent notch.
comptime BLOCK = String("1111/1..1/1111")
comptime BLOCK_B = String("2222/2..2/2222")


def main() raises:
    if not load_framework["Metal"]():
        raise Error("could not load Metal")

    var failures = 0

    # ── the row format ───────────────────────────────────────────────────
    let bmp = parse_sprite_rows(String(".0ff/A.9./1234"))
    if bmp.width != 4 or bmp.height != 3:
        print("FAIL  parsed", bmp.width, "x", bmp.height, "want 4 x 3")
        failures += 1
    # '.' and '0' are both transparent; hex is case-insensitive.
    if (
        bmp.pixels[0] != 0 or bmp.pixels[1] != 0
        or bmp.pixels[2] != 15 or bmp.pixels[3] != 15
        or bmp.pixels[4] != 10 or bmp.pixels[5] != 0
        or bmp.pixels[6] != 9 or bmp.pixels[11] != 4
    ):
        print("FAIL  hex digits and '.' did not parse as expected")
        failures += 1
    else:
        print("ok    hex digits parse, '.' and '0' are both transparent")

    var rejected = 0
    for bad in [String("111/11"), String(""), String("11/"), String("1g1")]:
        try:
            _ = parse_sprite_rows(bad)
        except:
            rejected += 1
    if rejected != 4:
        print("FAIL  ragged/empty/non-hex accepted:", 4 - rejected, "of 4")
        failures += 1
    else:
        print("ok    ragged, empty and non-hex rows are rejected")

    # ── the quad transform, which is arithmetic ──────────────────────────
    # A 4x2 sprite at the centre of a 64x64 viewport, unrotated, unscrolled:
    # its corners are +/-2 and +/-1 pixels about the centre, so in NDC the
    # left edge is at -2/32 and the top at +1/32.
    var probe = SpriteInstance(0, 32.0, 32.0)
    var v = quad_vertices(probe, 4, 2, 0.0, 0.0, 64.0, 64.0)
    if (
        abs(Float64(v[0]) + 0.0625) > 1e-5      # top-left x  = -2/32
        or abs(Float64(v[1]) - 0.03125) > 1e-5  # top-left y  = +1/32
        or abs(Float64(v[2])) > 1e-6            # u
        or abs(Float64(v[3])) > 1e-6            # v
        or abs(Float64(v[12]) - 0.0625) > 1e-5  # bottom-right x
    ):
        print("FAIL  quad corners:", v[0], v[1], v[12], v[13])
        failures += 1
    else:
        print("ok    the quad is centre-anchored and maps to NDC")

    # Rotated a quarter turn, the same sprite's half-extents swap.
    probe.rotation_degrees = 90.0
    v = quad_vertices(probe, 4, 2, 0.0, 0.0, 64.0, 64.0)
    if abs(Float64(v[0]) - 0.03125) > 1e-5:
        print("FAIL  a 90-degree rotation did not swap the extents:", v[0])
        failures += 1
    else:
        print("ok    rotation happens about the sprite's own centre")

    # Scrolling moves the sprite on screen without moving it in the world.
    probe.rotation_degrees = 0.0
    v = quad_vertices(probe, 4, 2, 16.0, 0.0, 64.0, 64.0)
    if abs(Float64(v[0]) - (-0.0625 - 0.5)) > 1e-5:
        print("FAIL  the scroll was not subtracted:", v[0])
        failures += 1
    else:
        print("ok    world coordinates track the scroll")

    # ── the AABB ─────────────────────────────────────────────────────────
    if not sprites_overlap(0.0, 0.0, 4.0, 4.0, 3.0, 0.0, 4.0, 4.0):
        print("FAIL  overlapping boxes did not register")
        failures += 1
    if sprites_overlap(0.0, 0.0, 4.0, 4.0, 5.0, 0.0, 4.0, 4.0):
        print("FAIL  separate boxes registered as a hit")
        failures += 1
    # Edge-to-edge is not a hit: a sprite resting exactly on another must
    # not read as a collision every frame.
    if sprites_overlap(0.0, 0.0, 4.0, 4.0, 4.0, 0.0, 4.0, 4.0):
        print("FAIL  boxes sharing only an edge registered as a hit")
        failures += 1
    else:
        print("ok    the AABB is strict about touching edges")

    # ── definitions, instances and animation ─────────────────────────────
    var pane = GamePane(String("gamepane G5"), VIEW_W, VIEW_H)
    var sp = Sprites(pane.device)

    let sid = sp.define_sprite(pane.ctx, BLOCK)
    if sid != 0 or sp.frame_count(sid) != 1:
        print("FAIL  define_sprite returned", sid, "with",
              sp.frame_count(sid), "frames")
        failures += 1
    if not sp.add_frame(pane.ctx, sid, BLOCK_B):
        print("FAIL  a same-size frame was rejected")
        failures += 1
    if sp.add_frame(pane.ctx, sid, String("11/11")):
        print("FAIL  a mismatched-size frame was accepted")
        failures += 1
    if sp.frame_count(sid) != 2:
        print("FAIL  frame count is", sp.frame_count(sid), "want 2")
        failures += 1
    else:
        print("ok    define/add_frame, and a size mismatch is refused")

    let a = sp.place(sid, 20.0, 20.0)
    let b = sp.place(sid, 21.0, 20.0)
    if sp.sprite_x(a) != 20.0 or sp.sprite_y(b) != 20.0:
        print("FAIL  place did not record the position")
        failures += 1
    if not sp.hit(a, b):
        print("FAIL  two overlapping instances did not hit")
        failures += 1
    sp.move_to(b, 60.0, 60.0)
    if sp.hit(a, b):
        print("FAIL  separated instances still hit")
        failures += 1
    else:
        print("ok    place/move_to, and hit follows them")

    # animate: 4 fps means a frame every 250 ms, and a long dt advances
    # more than one frame rather than dropping the extra.
    sp.animate(a, 4.0)
    sp.tick(0.1)
    if sp.sprite_frame(a) != 0:
        print("FAIL  animation advanced early")
        failures += 1
    sp.tick(0.2)                 # 0.3 s total -> one frame
    if sp.sprite_frame(a) != 1:
        print("FAIL  animation did not advance at the period")
        failures += 1
    sp.tick(0.5)                 # two more periods -> wraps twice
    if sp.sprite_frame(a) != 1:
        print("FAIL  a long dt did not advance twice; frame is",
              sp.sprite_frame(a))
        failures += 1
    else:
        print("ok    animate cycles frames, and a slow frame catches up")
    sp.animate(a, 0.0)
    sp.set_frame(a, 0)

    # alpha is clamped rather than trusted.
    sp.set_alpha(a, 5.0)
    sp.set_alpha(b, -1.0)
    if sp.instances[a].alpha != 1.0 or sp.instances[b].alpha != 0.0:
        print("FAIL  alpha was not clamped")
        failures += 1
    else:
        print("ok    alpha is clamped to 0..1")
    sp.set_alpha(a, 1.0)

    # ── composited, through a real drawable ──────────────────────────────
    with autoreleasepool():
        var ip = IndexedPane(
            pane.ctx, pane.device, VIEW_W, VIEW_H, VIEW_W, VIEW_H
        )
        # Index 20, not 9: 1..15 are the per-line half and set_rgb refuses
        # them, which the indexed pane's own test already covers.
        ip.active_plane().cls(20)         # a background to composite over
        ip.set_rgb(20, 0, 0, 200)         # blue
        ip.set_scroll(0, 0)

        sp.sprite_rgb(sid, 1, 250, 10, 20)
        sp.hide(b)
        sp.set_frame(a, 0)
        sp.move_to(a, 32.0, 32.0)
        sp.set_scale(a, 8.0)              # 32x24 on screen, centred

        var frame = pane.begin_frame()
        ip.render(frame, clear=True)
        sp.render(frame, 0.0, 0.0, Float64(VIEW_W), Float64(VIEW_H))
        pane.end_frame(frame)
        var px = pane.read_frame(frame)

        if len(px) == 0:
            print("SKIP  no drawable; the composite checks need one")
        else:
            # Centre of the sprite is its transparent notch -> the indexed
            # pane's blue shows through. A point inside the solid border is
            # the sprite's own palette entry 1.
            let centre = (32 * VIEW_W + 32) * 4
            let border = (22 * VIEW_W + 32) * 4     # above the notch
            if not (Int(px[centre + 0]) == 200 and Int(px[centre + 2]) == 0):
                print("FAIL  the sprite's index 0 did not discard: BGRA",
                      px[centre], px[centre + 1], px[centre + 2])
                failures += 1
            elif not (
                Int(px[border + 2]) == 250 and Int(px[border + 1]) == 10
            ):
                print("FAIL  the sprite's own palette did not resolve: BGRA",
                      px[border], px[border + 1], px[border + 2])
                failures += 1
            else:
                print("ok    the sprite composited over the layer below,")
                print("      with its own palette and a transparent notch")

            # Half alpha over a blue background: the red must come back
            # about halfway, which is blending rather than switching.
            sp.set_alpha(a, 0.5)
            frame = pane.begin_frame()
            ip.render(frame, clear=True)
            sp.render(frame, 0.0, 0.0, Float64(VIEW_W), Float64(VIEW_H))
            pane.end_frame(frame)
            px = pane.read_frame(frame)
            let r = Int(px[border + 2])
            let bl = Int(px[border + 0])
            if r > 100 and r < 160 and bl > 70 and bl < 130:
                print("ok    alpha blends against the layer below: BGRA",
                      px[border], px[border + 1], px[border + 2])
            else:
                print("FAIL  alpha did not blend: BGRA",
                      px[border], px[border + 1], px[border + 2])
                failures += 1

            # A hidden sprite draws nothing at all.
            sp.set_alpha(a, 1.0)
            sp.hide(a)
            frame = pane.begin_frame()
            ip.render(frame, clear=True)
            sp.render(frame, 0.0, 0.0, Float64(VIEW_W), Float64(VIEW_H))
            pane.end_frame(frame)
            px = pane.read_frame(frame)
            if Int(px[border + 0]) == 200 and Int(px[border + 2]) == 0:
                print("ok    a hidden instance draws nothing")
            else:
                print("FAIL  a hidden instance still drew: BGRA",
                      px[border], px[border + 1], px[border + 2])
                failures += 1

    pane.close()

    print()
    if failures == 0:
        print("G5 sprites: PASS")
    else:
        print("G5 sprites: FAILED", failures, "check(s)")
        raise Error("G5 failed")
