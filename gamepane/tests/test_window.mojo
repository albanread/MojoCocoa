# Sprint G1 — the window, the loop, and input.
#
# Headless by default: GAMEPANE_FRAMES makes the pane an unfocused Accessory
# that renders N frames and stops, and GAMEPANE_DUMP writes the last one as
# raw BGRA -- so this proves a real window and a real presented frame with no
# screen and nobody's focus stolen.

from std.os import getenv
from gamepane.api import KEY_SPACE, KEY_LEFT, MAX_KEY_CODE
from gamepane.metal import (
    GamePane, key_held, mouse_state, clear_input, gamepad_state,
    CLEAR_R, CLEAR_G, CLEAR_B,
)


def main() raises:
    var failures = 0

    # Polled state before any event: everything clear, out of range safe.
    clear_input()
    if key_held(KEY_SPACE) or key_held(KEY_LEFT):
        print("FAIL  a key read as held before any event")
        failures += 1
    if key_held(-1) or key_held(9999) or key_held(MAX_KEY_CODE):
        print("FAIL  an out-of-range key code was not safe")
        failures += 1
    let m = mouse_state()
    if m.left or m.right:
        print("FAIL  a mouse button read as held before any event")
        failures += 1
    print("ok    input starts clear and is out-of-range safe")

    # The gamepad bridge must not crash when nothing is plugged in.
    let g = gamepad_state()
    print("ok    gamepad bridge answered (connected =", g.connected, ")")

    comptime W = 480
    comptime H = 320
    var pane = GamePane(String("gamepane G1"), W, H)
    print("ok    window, layer and view created")

    var n = 0
    while pane.pump():
        n += 1
        pane.present()
    print("presented", pane.frame_count(), "frames; dt =", pane.dt())
    if pane.frame_count() == 0:
        print("FAIL  no frame was presented")
        failures += 1
    else:
        print("ok    frames presented through a real CAMetalLayer drawable")
    pane.close()

    # The dump is the only part of this a human cannot see happening, so it
    # is the part worth checking hardest: the right number of bytes, and
    # every one of them the ground colour that went in. Byte-for-byte
    # equality with round(c * 255) also says the drawable is BGRA8Unorm and
    # not its sRGB twin, which would encode these to 63 and 83 instead.
    let dump = getenv("GAMEPANE_DUMP")
    if dump.byte_length() > 0:
        let want_b = UInt8(Int(Float64(CLEAR_B) * 255.0 + 0.5))
        let want_g = UInt8(Int(Float64(CLEAR_G) * 255.0 + 0.5))
        let want_r = UInt8(Int(Float64(CLEAR_R) * 255.0 + 0.5))
        var px: List[UInt8]
        with open(dump, "r") as f:
            px = f.read_bytes()
        if len(px) != W * H * 4:
            print("FAIL  dump is", len(px), "bytes, want", W * H * 4)
            failures += 1
        else:
            var bad = 0
            for i in range(0, len(px), 4):
                if (
                    px[i] != want_b
                    or px[i + 1] != want_g
                    or px[i + 2] != want_r
                    or px[i + 3] != 255
                ):
                    bad += 1
            if bad != 0:
                print("FAIL ", bad, "of", W * H, "pixels are not the ground")
                print("      first BGRA =", px[0], px[1], px[2], px[3])
                failures += 1
            else:
                print(
                    "ok   ",
                    W,
                    "x",
                    H,
                    "dump, every pixel BGRA",
                    want_b,
                    want_g,
                    want_r,
                    255,
                )

    print()
    if failures == 0:
        print("G1 window/loop/input: PASS")
    else:
        print("G1 window/loop/input: FAILED", failures, "check(s)")
        raise Error("G1 failed")
