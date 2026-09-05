# ===----------------------------------------------------------------------=== #
# Sprint G2 — the shader pane and the direct pane.
#
# The two layers with no drawing API of their own, so they are the smallest
# statement of the pattern: compile MSL, build a pipeline, encode into the
# frame's command buffer, draw three vertices.
#
# Every check here goes through a real drawable and comes back as pixels,
# which is the only way to tell "the pipeline built" from "the pipeline
# draws what it was asked to". The Rust's own tests come with it:
# `stride_is_the_width_rounded_up_to_the_devices_alignment` and
# `the_backbuffer_pointer_is_writable_memory`, plus G0's two shader tests
# now running against the real ShaderPane rather than a spike.
#
# Run: ./tools/gp.sh gamepane/tests/test_panes.mojo
# ===----------------------------------------------------------------------=== #

from std.objc import load_framework, ObjCObject, send, nsenum, autoreleasepool
from std.memory import Pointer

from gamepane.api import (
    ShaderParams, Palette, PALETTE_SIZE, stride_for, buffer_len_for,
)
from gamepane.metal import GamePane, ShaderPane, DirectPane, NUM_BUFFERS


comptime W = 64
comptime H = 48


def main() raises:
    if not load_framework["Metal"]():
        raise Error("could not load Metal")

    var failures = 0

    # ── the neutral tier, which needs no device at all ───────────────────
    # The stride rule, from the Rust: the width rounded UP to the alignment,
    # never less, and the NEXT multiple rather than any further one. 321 is
    # deliberately awkward -- it is the width a demo assuming `y*width + x`
    # gets wrong.
    for align in [1, 16, 64]:
        for width in [1, 64, 320, 321]:
            let s = stride_for(width, align)
            if s < width or s % align != 0 or s >= width + align:
                print("FAIL  stride_for(", width, ",", align, ") =", s)
                failures += 1
    if buffer_len_for(stride_for(321, 16), 8) != 336 * 8:
        print("FAIL  buffer_len_for disagrees with the stride")
        failures += 1
    print("ok    the stride is the width rounded up, and no further")

    var sp = ShaderParams()
    sp.set_param(0, 0.5)
    sp.set_param(7, 1.5)
    sp.set_param(8, 99.0)       # out of range: ignored, not a crash
    sp.set_param(-1, 99.0)
    if sp.param(0) != 0.5 or sp.param(7) != 1.5 or sp.param(8) != 0.0:
        print("FAIL  set_param did not bound-check")
        failures += 1
    if sp.byte_length() != 40:
        print("FAIL  Uniforms is", sp.byte_length(), "bytes, want 40")
        failures += 1
    print("ok    Uniforms is 40 bytes and set_param is bounds-checked")

    var pal = Palette()
    pal.set_rgb(3, 10, 20, 30)
    pal.set_rgb(PALETTE_SIZE, 1, 2, 3)   # out of range: ignored
    let got = pal.rgb(3)
    if got[0] != 10 or got[1] != 20 or got[2] != 30:
        print("FAIL  palette round trip:", got[0], got[1], got[2])
        failures += 1
    print("ok    the palette round-trips a colour")

    # ── the backend ──────────────────────────────────────────────────────
    var pane = GamePane(String("gamepane G2"), W, H)

    with autoreleasepool():
        # A shader that returns exactly what it is told, so a rendered pixel
        # is a statement about u.p reaching the GPU and nothing else.
        var shader = ShaderPane(
            pane.device,
            String(
                "fragment float4 fmain(VOut in [[stage_in]],"
                " constant Uniforms& u [[buffer(0)]]) {"
                " return float4(u.p[0], u.p[1], u.p[2], 1.0); }"
            ),
        )
        shader.set_param(0, 1.0)     # R
        shader.set_param(1, 0.0)     # G
        shader.set_param(2, 0.5)     # B
        shader.set_aspect(pane.aspect())
        print("ok    a trivial fmain compiled against the supplied header")

        # The negative, from the Rust: a source with no fmain must fail, and
        # the failure must say so rather than crashing later.
        var missing_said_so = False
        try:
            var _bad = ShaderPane(pane.device, String("// no fmain here"))
        except e:
            missing_said_so = String(e).find("fmain") >= 0
        if not missing_said_so:
            print("FAIL  a source without fmain did not name fmain")
            failures += 1
        else:
            print("ok    a source without fmain fails and names it")

        var direct = DirectPane(pane.device, W, H)
        if direct.buffer_count() != NUM_BUFFERS:
            print("FAIL  buffer_count is not", NUM_BUFFERS)
            failures += 1
        if direct.stride_bytes() < W:
            print("FAIL  stride is narrower than the pane")
            failures += 1

        # The backbuffer is writable memory, and a fresh pane is zeroed so a
        # demo's first frame is a colour rather than whatever was there.
        let fresh = direct.backbuffer_ptr()
        var nonzero = 0
        for i in range(direct.buffer_len()):
            if fresh[unsafe_offset=i] != 0:
                nonzero += 1
        if nonzero != 0:
            print("FAIL ", nonzero, "bytes of a fresh pane were not zero")
            failures += 1
        for i in range(direct.buffer_len()):
            fresh[unsafe_offset=i] = UInt8(i % 251)
        var bad = 0
        for i in range(direct.buffer_len()):
            if fresh[unsafe_offset=i] != UInt8(i % 251):
                bad += 1
        if bad != 0:
            print("FAIL ", bad, "bytes did not read back")
            failures += 1
        else:
            print("ok    the backbuffer is zeroed, writable memory")

        # Every buffer is a distinct allocation -- the rotation is real.
        let ptrs = direct.buffer_ptrs()
        if len(ptrs) != NUM_BUFFERS or ptrs[0] == ptrs[1] or ptrs[1] == ptrs[2]:
            print("FAIL  buffer_ptrs did not give distinct buffers")
            failures += 1
        else:
            print("ok    the rotation is", NUM_BUFFERS, "distinct buffers")

        # ── layer 0, drawn and read back ─────────────────────────────────
        var frame = pane.begin_frame()
        shader.render(frame)
        pane.end_frame(frame)
        var px = pane.read_frame(frame)
        if len(px) == 0:
            print("SKIP  no drawable; the shader pixel check needs one")
        else:
            # BGRA, so p[2]=0.5 -> B=128, p[1]=0 -> G=0, p[0]=1 -> R=255.
            if (
                abs(Int(px[0]) - 128) <= 1
                and Int(px[1]) == 0
                and Int(px[2]) == 255
            ):
                print("ok    u.p reached the shader: BGRA", px[0], px[1], px[2])
            else:
                print("FAIL  shader pixel is", px[0], px[1], px[2])
                failures += 1

        # ── the direct pane, drawn and read back ─────────────────────────
        # Palette entry 200 is a colour nothing else could be; fill the
        # whole plane with that index and every pixel must come back as it.
        direct.set_rgb(200, 12, 200, 60)
        let fb = direct.backbuffer_ptr()
        for i in range(direct.buffer_len()):
            fb[unsafe_offset=i] = 200
        frame = pane.begin_frame()
        direct.render(frame)
        pane.end_frame(frame)
        px = pane.read_frame(frame)
        if len(px) == 0:
            print("SKIP  no drawable; the direct pixel check needs one")
        elif (
            abs(Int(px[0]) - 60) <= 2
            and abs(Int(px[1]) - 200) <= 2
            and abs(Int(px[2]) - 12) <= 2
        ):
            print("ok    a host byte became a palette colour on screen")
        else:
            print("FAIL  direct pixel is", px[0], px[1], px[2])
            failures += 1

        # The rotation advanced, so the buffer the host writes next is not
        # the one just drawn.
        if direct.write == 0:
            print("FAIL  render did not advance the write buffer")
            failures += 1
        else:
            print("ok    render advanced the rotation to", direct.write)

    pane.close()

    print()
    if failures == 0:
        print("G2 shader pane / direct pane: PASS")
    else:
        print("G2 shader pane / direct pane: FAILED", failures, "check(s)")
        raise Error("G2 failed")
