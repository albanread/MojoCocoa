# ChipDeluxe — the chiptune player that is itself a demo.
#
# Three chips, nine voices, and the 1980s screen furniture drawn by the
# 2020s machinery: a plasma as the sky (fragment shader), copper VU bars
# whose gradients are the indexed pane's per-scanline palette, an
# oscilloscope plotted by a Mojo GPU kernel from the trio's own mix ring,
# and a sine scroller that is nothing but sprite instances riding a wave.
#
# The sync rule is the design's: no messages, no estimates. The audio
# callback renders the trio and publishes its playhead; this side reads
# the taps -- trio_voice_level for the bars, trio_scope_read (inside
# ScopeField.feed) for the trace -- and everything breathes with the
# music because everything IS the music, read back.
#
# Headless (GAMEPANE_FRAMES=n) opens no audio unit at all: the main loop
# renders the trio itself, a frame's worth per frame, into a buffer nobody
# hears. Same trio, same taps, deterministic pixels.
#
# Build it (AudioToolbox cannot be resolved by the JIT):
#   ./dist/CocoaMojo/bin/cocoamojo --build examples/chipdeluxe/main.mojo -o /tmp/chipdeluxe

from std.math import sin
from std.memory import Pointer, MutUntrackedOrigin
from std.objc import load_framework, autoreleasepool
from std.os import getenv

from gamepane.api import (
    KEY_ESCAPE, KEY_1, KEY_2, KEY_4, KEY_SPACE, SAMPLE_RATE, P,
)
from gamepane.metal import (
    GamePane, ShaderPane, IndexedPane, Sprites, TextOverlay, ScopeField,
    key_held, start_trio_audio, stop_audio,
)
from gamepane.abc import (
    Tune, parse_abc, resolve_ties, build_schedule, sort_steps, Step,
    trio_new, trio_free, flatten_trio, set_trio_loop, render_trio,
    trio_playhead, trio_voice_level,
)
from gamepane.api.text import glyph_for, GLYPH_W, GLYPH_H
from tunes import TUNE_SHOWCASE

comptime VIEW_W = 640
comptime VIEW_H = 400

comptime SCOPE_H = 110
comptime SCOPE_Y = 60                     # where the strip sits on screen

comptime VU_BASE = 384                    # bars grow up from here
comptime VU_MAX = 160
comptime IX_BAR = 1                       # the per-scanline copper index
comptime IX_BAR_DIM = 16                  # global: the unlit bar well
comptime IX_FRAME = 17

# The sky: four sines and a palette walk, dimmed to a backdrop. The same
# Uniforms every ShaderPane fragment gets -- time, aspect.
comptime PLASMA = String("""
fragment float4 fmain(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 uv = in.uv * float2(u.aspect, 1.0);
    float t = u.time * 0.55;
    float v = sin(uv.x * 6.0 + t)
            + sin(uv.y * 5.0 - t * 1.3)
            + sin((uv.x + uv.y) * 7.0 + t * 0.7)
            + sin(length(uv - float2(0.5 * u.aspect, 0.45)) * 11.0 - t * 1.9);
    v *= 0.25;
    float3 col = float3(0.5 + 0.5 * sin(3.14159 * v + t * 0.40),
                        0.5 + 0.5 * sin(3.14159 * v + 2.094 + t * 0.31),
                        0.5 + 0.5 * sin(3.14159 * v + 4.188));
    return float4(col * 0.20, 1.0);
}
""")

comptime SCROLL_TEXT = String(
    "CHIPDELUXE ... THREE CHIPS ... NINE VOICES ... ARPEGGIO VIBRATO "
    "SLIDE PWM TREMOLO SWEEP ... ONE PING-PONG ECHO ... ALL OF IT IS "
    "ABC ... GREETINGS TO THE TRADITION ...        ")


def glyph_rows(ch: Int) raises -> String:
    """One 5x7 font glyph as sprite rows, index 1 where the ink is."""
    let g = glyph_for(ch)
    var rows = String("")
    for y in range(GLYPH_H):
        for x in range(GLYPH_W):
            let on = (Int(g[y]) >> (GLYPH_W - 1 - x)) & 1
            rows += "1" if on == 1 else "."
        if y < GLYPH_H - 1:
            rows += "/"
    return rows


def main() raises:
    if not load_framework["Metal"]():
        raise Error("could not load Metal")
    var pane = GamePane(String("ChipDeluxe"), VIEW_W, VIEW_H)
    var sky = ShaderPane(pane.device, PLASMA)
    sky.set_aspect(pane.aspect())
    var field = IndexedPane(pane.ctx, pane.device, VIEW_W, VIEW_H,
                            VIEW_W, VIEW_H)
    var scope = ScopeField(pane.ctx, pane.device, VIEW_W, SCOPE_H)
    var sprites = Sprites(pane.device)
    var hud = TextOverlay(pane.device, VIEW_W, VIEW_H)

    # ── the copper: the bars' gradient lives in the palette, not the plane.
    # Green at the base through gold to red at reach; the bar itself is one
    # rectangle of index 1, and these 400 entries do the rest.
    for line in range(VIEW_H):
        let up = VU_BASE - line          # how far above the base this line is
        if up <= 0:
            field.set_line_rgb(line, IX_BAR, 40, 60, 40)
        else:
            var g = 255
            var r = up * 2
            if r > 255:
                r = 255
                g = 255 - (up - 128) * 2
                if g < 60:
                    g = 60
            field.set_line_rgb(line, IX_BAR, r, g, 70)
    field.set_rgb(IX_BAR_DIM, 24, 34, 30)
    field.set_rgb(IX_FRAME, 90, 220, 160)

    # ── the scroller: one sprite definition per distinct letter, one
    # instance per character of the message.
    var defs = List[Int](length=128, fill=-1)
    var text_inst = List[Int]()
    let msg = SCROLL_TEXT.as_bytes()
    for i in range(len(msg)):
        let ch = Int(msg[i])
        if ch == 32:
            text_inst.append(-1)
            continue
        if defs[ch] < 0:
            let d = sprites.define_sprite(pane.ctx, glyph_rows(ch))
            sprites.sprite_rgb(d, 1, 130, 255, 190)
            defs[ch] = d
        let inst = sprites.place(defs[ch], -100.0, -100.0)
        sprites.set_scale(inst, 3.0)
        text_inst.append(inst)

    # ── the music ────────────────────────────────────────────────────────
    var t = Tune()
    parse_abc(TUNE_SHOWCASE, t)
    resolve_ties(t)
    var steps = List[Step]()
    build_schedule(t, SAMPLE_RATE, steps)
    sort_steps(steps)
    var trio = trio_new()
    _ = flatten_trio(steps, trio)
    set_trio_loop(trio, True)

    let headless = getenv("GAMEPANE_FRAMES").byte_length() > 0
    var unit = 0
    var silent = List[Float32](length=1600 * 2, fill=0.0)
    if not headless:
        unit = start_trio_audio(trio)

    var frame_n = 0
    while pane.pump():
        if not headless:
            if key_held(KEY_ESCAPE):
                break
            if key_held(KEY_1):
                pane.set_zoom(1)
            elif key_held(KEY_2):
                pane.set_zoom(2)
            elif key_held(KEY_4):
                pane.set_zoom(4)
        else:
            # No unit is running: the loop is the renderer, one frame's
            # worth of samples a frame, deterministically.
            render_trio(trio, Pointer[Float32, MutUntrackedOrigin](
                unsafe_from_address=Int(silent.unsafe_ptr())), 800)
        frame_n += 1

        # ── read the taps, redraw the plane ─────────────────────────────
        scope.feed(trio)
        scope.step(pane.ctx)
        var plane = field.active_plane()
        plane.cls(0)
        for i in range(9):
            let level = trio_voice_level(trio, i // 3, i % 3)
            let x = 62 + i * 60
            plane.fill_rect(x, VU_BASE - VU_MAX, 44, VU_MAX, IX_BAR_DIM)
            var h = level * VU_MAX // 255
            if h > 0:
                plane.fill_rect(x, VU_BASE - h, 44, h, IX_BAR)
            if i % 3 == 0:
                plane.fill_rect(x - 10, VU_BASE - VU_MAX, 2, VU_MAX, IX_FRAME)
        plane.fill_rect(0, SCOPE_Y - 2, VIEW_W, 1, IX_FRAME)
        plane.fill_rect(0, SCOPE_Y + SCOPE_H + 1, VIEW_W, 1, IX_FRAME)

        # ── the scroller rides its wave ─────────────────────────────────
        let base_x = Float64(VIEW_W) - Float64(frame_n % 100000) * 2.0
        for i in range(len(text_inst)):
            let inst = text_inst[i]
            if inst < 0:
                continue
            var x = base_x + Float64(i) * 20.0
            let span = Float64(len(text_inst)) * 20.0
            while x < -30.0:
                x += span
            let y = 24.0 + 14.0 * sin(x * 0.02 + Float64(frame_n) * 0.05)
            sprites.move_to(inst, x, y)

        let ph = trio_playhead(trio)
        hud.clear()
        hud.draw_text(10, 8, String("CHIPDELUXE  TRIO SHOWCASE"),
                      140, 255, 200, 2)
        hud.draw_text(430, 8, String("1 2 4 ZOOM  ESC QUIT"),
                      120, 190, 160, 1)
        _ = ph

        with autoreleasepool():
            let frame = pane.begin_frame()
            sky.render(frame)
            field.render(frame)
            scope.render(frame)
            sprites.render(frame, 0.0, 0.0, Float64(VIEW_W), Float64(VIEW_H))
            hud.render(frame)
            pane.end_frame(frame)

    if unit != 0:
        stop_audio(unit)
    let final_ph = trio_playhead(trio)   # read BEFORE the free, obviously
    trio_free(trio)
    pane.close()
    print("ChipDeluxe: presented", pane.frame_count(), "frames, playhead",
          final_ph)
