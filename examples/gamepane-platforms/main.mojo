# ===----------------------------------------------------------------------=== #
# Two layers composited: the shader pane's starfield, and an indexed pane of
# platforms drawn over it.
#
# Three things are on display, and each is one line of game code:
#
#   * INDEX 0 IS TRANSPARENT. The world is cleared to 0 and only a dozen
#     rectangles are drawn, so the starfield shows through everywhere else --
#     the fragment shader discards on index 0 and the layer below survives.
#
#   * INDICES 1..15 ARE PER SCANLINE. Index 1 is a different colour on every
#     line of the viewport, so the gradient band runs top to bottom without
#     a single pixel being redrawn to make it.
#
#   * THE WORLD IS BIGGER THAN THE SCREEN. Everything is drawn ONCE into a
#     960x640 world; the camera then moves `set_scroll` a third of a pixel a
#     frame. Nothing is redrawn to scroll, ever -- the composite reads a
#     different window of the same bytes.
#
#   * THE SOUND IS TWO CHIPS. Chip A runs a bass line on its own 50 Hz
#     player hook -- inside the audio callback, on the beat, where a raster
#     interrupt would have been. Chip B plays effects. The game thread never
#     touches either: it pushes an effect number onto a lock-free ring and
#     the callback drains it at the top of the next buffer.
#
#   * LAYER 3 IS TEXT, TWICE. The overlay rasterises a title and a HUD line
#     into an RGBA buffer -- retained, right for something that changes when
#     the game says so. The text plane is a grid of four-byte cells with a
#     transparent background, so a menu sits over the picture without a box
#     around it and without a draw call per line.
#
#   * SPRITES ARE COMPOSITED, NOT BLITTED. The coins are quads drawn in
#     their own pass with source-alpha blending, so they move over the
#     platforms without disturbing a single index byte -- nothing has to be
#     erased and repainted behind them, and scale, rotation and alpha are
#     per instance and free. They are placed in WORLD coordinates, so they
#     scroll with the background without being told to.
#
# Headless:
#   GAMEPANE_FRAMES=30 GAMEPANE_DUMP=/tmp/platforms.bgra \
#       cocoamojo run examples/gamepane-platforms/main.mojo
# ===----------------------------------------------------------------------=== #

from std.objc import load_framework, autoreleasepool
from gamepane.api import (
    KEY_ESCAPE, KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN, KEY_SPACE, KEY_1,
    FRONT,
)
from gamepane.api import (
    FLAG_TRANSPARENT_BG, P, SFX_COIN, SFX_JUMP, SFX_ZAP, SFX_EXPLODE,
    SFX_POWERUP, SFX_BLIP, WAVE_PULSE, WAVE_TRI,
    set_freq_hz, set_pulse_width, set_wave, set_adsr, gate_on, gate_off,
    set_volume, get, put, PLAYER_BASE,
)
from gamepane.metal import (
    GamePane, ShaderPane, IndexedPane, Sprites, TextOverlay, TextPlane,
    key_held, deck_new, deck_free, music_chip, set_music_tick, sfx_play,
    start_audio, stop_audio,
)


# ── the bass line, as a 50 Hz player routine ────────────────────────────────
#
# This runs on CHIP A's own player hook, inside the audio callback, on the
# beat -- exactly where a raster interrupt would have put it. It is a `fn`
# because that is what the chip's hook takes: no allocation, no raising, and
# nothing that could block the audio thread.

comptime M_STEP = 0        # which note of the pattern
comptime M_COUNT = 1       # frames left on this note
comptime M_FRAMES = 10     # 10 frames at 50 Hz -- a note every fifth of a second


fn music_tick(st: P):
    var left = get(st, PLAYER_BASE + M_COUNT)
    if left > 0:
        put(st, PLAYER_BASE + M_COUNT, left - 1)
        return
    var step = get(st, PLAYER_BASE + M_STEP)
    # A minor pentatonic walk: A, C, D, E, G, E, D, C.
    var hz = 110.0
    if step == 1: hz = 130.81
    elif step == 2: hz = 146.83
    elif step == 3: hz = 164.81
    elif step == 4: hz = 196.0
    elif step == 5: hz = 164.81
    elif step == 6: hz = 146.83
    elif step == 7: hz = 130.81
    gate_off(st, 0)
    set_freq_hz(st, 0, hz)
    gate_on(st, 0)
    put(st, PLAYER_BASE + M_STEP, (step + 1) % 8)
    put(st, PLAYER_BASE + M_COUNT, M_FRAMES)


# An 8x8 coin in two frames. The digits are palette indices into the
# sprite's OWN sixteen colours, `.` is transparent, and the only difference
# between the frames is where the highlight sits -- which is the whole
# animation.
comptime COIN_A = String(
    "..2222../.222222./22233222/22333222/22333222/22233222/.222222./..2222.."
)
comptime COIN_B = String(
    "..2222../.223222./22332222/23332222/22322222/22222222/.222222./..2222.."
)


comptime VIEW_W = 480
comptime VIEW_H = 320
comptime WORLD_W = 960   # twice the viewport each way -> a real overscan margin
comptime WORLD_H = 640


comptime STARFIELD = String(
    """
fragment float4 fmain(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 uv = in.uv * float2(u.aspect, 1.0);
    float3 col = float3(0.02, 0.02, 0.06);
    for (int i = 0; i < 3; i++) {
        float layer = float(i);
        float scale = 18.0 + layer * 14.0;
        float2 grid = uv * scale + layer * 11.0;
        float2 cellId = floor(grid);
        float2 cellUv = fract(grid) - 0.5;
        float h = fract(sin(dot(cellId, float2(12.9898, 78.233)) + layer * 3.7) * 43758.5453);
        float star = smoothstep(0.06, 0.0, length(cellUv)) * step(0.97, h);
        float twinkle = 0.5 + 0.5 * sin(u.time * (2.0 + h * 4.0) + h * 12.0);
        col += float3(star * twinkle);
    }
    return float4(col, 1.0);
}
"""
)


def build_world(mut pane: IndexedPane) raises:
    """Draw the world once. Nothing here runs again."""
    # Six widely spaced brick colours. The default palette's global range is
    # one smooth 240-step hue wheel, so six CONSECUTIVE indices would span
    # about nine degrees of hue and be indistinguishable from each other.
    let bricks = [
        (180, 60, 60), (200, 130, 40), (170, 170, 60),
        (60, 160, 90), (60, 120, 190), (140, 70, 170),
    ]
    for i in range(len(bricks)):
        pane.set_rgb(17 + i, bricks[i][0], bricks[i][1], bricks[i][2])

    # Sparse platforms, not a tiled wall: most of the frame stays index 0 so
    # the starfield shows through generously rather than through mortar
    # seams. That is what makes this a composite and not a wallpaper.
    let platforms = [
        (80, 100, 120, 20), (300, 180, 150, 20), (600, 120, 100, 20),
        (820, 220, 110, 20), (150, 300, 100, 24), (400, 340, 140, 24),
        (700, 380, 120, 24), (50, 450, 130, 20), (350, 480, 100, 20),
        (600, 500, 150, 24), (850, 460, 90, 20), (200, 550, 120, 20),
    ]
    pane.set_active(FRONT)
    var world = pane.active_plane()
    world.cls(0)
    for i in range(len(platforms)):
        let r = platforms[i]
        world.fill_rect(r[0], r[1], r[2], r[3], UInt8(17 + i % 6))

    # Stripes of index 1, and index 1 given a different colour on every
    # LINE of the viewport: a handful of rectangles, 320 palette entries,
    # and a vertical gradient that no pixel was ever drawn to make. As the
    # camera pans, the stripes slide past while the gradient stays put --
    # the colours belong to the SCREEN line, not to the world.
    for bx in range(0, WORLD_W, 240):
        world.fill_rect(bx, 0, 24, WORLD_H, 1)
    for line in range(VIEW_H):
        let t = Float32(line) / Float32(VIEW_H)
        pane.set_line_rgb(
            line, 1, Int(t * 40.0), Int(t * 10.0), Int(60.0 + t * 80.0)
        )


def main() raises:
    if not load_framework["Metal"]():
        raise Error("could not load Metal")

    var pane = GamePane(String("Platforms"), VIEW_W, VIEW_H)
    var sky = ShaderPane(pane.device, STARFIELD)
    sky.set_aspect(pane.aspect())
    var world = IndexedPane(
        pane.ctx, pane.device, WORLD_W, WORLD_H, VIEW_W, VIEW_H
    )
    build_world(world)

    # Layer 2. One definition, two frames, seven instances.
    var sprites = Sprites(pane.device)
    let coin = sprites.define_sprite(pane.ctx, COIN_A)
    _ = sprites.add_frame(pane.ctx, coin, COIN_B)
    sprites.sprite_rgb(coin, 2, 220, 170, 40)      # gold
    sprites.sprite_rgb(coin, 3, 255, 245, 190)     # the glint

    # Five decorative coins across the world, glinting at 4 fps and half a
    # beat out of step with each other.
    let spots = [
        (140, 90), (360, 170), (660, 110), (880, 210), (460, 330),
    ]
    for i in range(len(spots)):
        let c = sprites.place(coin, Float64(spots[i][0]), Float64(spots[i][1]))
        sprites.set_scale(c, 2.0)
        sprites.animate(c, 4.0)
        sprites.set_alpha(c, 0.85)
        sprites.tick(Float64(i) * 0.06)

    # And one the player drives.
    var player = sprites.place(
        coin, Float64(WORLD_W) / 2.0, Float64(WORLD_H) / 2.0
    )
    sprites.set_scale(player, 4.0)
    sprites.animate(player, 6.0)

    # Layer 3a: the retained overlay. Drawn once here -- it does not change,
    # so it costs nothing per frame beyond the composite.
    var hud = TextOverlay(pane.device, VIEW_W, VIEW_H)
    hud.draw_text(6, 6, String("0-9 :- DEMO %"), 255, 241, 232, 1)
    hud.draw_text(6, 20, String("GAMEPANE"), 255, 163, 0, 3)

    # Layer 3b: the cell grid, transparent-backed, so the menu sits over the
    # picture rather than in a box. Writing it is byte stores, not calls.
    var menu = TextPlane(pane.device, VIEW_W, VIEW_H)
    let items = [
        String("ARROWS  MOVE"),
        String("ESC     QUIT"),
    ]
    for i in range(len(items)):
        menu.write(2, menu.rows - 3 + i, items[i], 26, 16, FLAG_TRANSPARENT_BG)

    # Two chips on one audio unit. Chip A plays; chip B waits for triggers.
    var deck = deck_new()
    let music = music_chip(deck)
    set_volume(music, 12)
    set_wave(music, 0, WAVE_PULSE)
    set_pulse_width(music, 0, 0x300)
    set_adsr(music, 0, 0, 7, 6, 5)
    set_music_tick(deck, music_tick)
    let unit = start_audio(deck)

    var scroll_x = Float64(WORLD_W - VIEW_W) / 2.0
    let scroll_y = (WORLD_H - VIEW_H) // 2
    var held_space = False
    var held_num = List[Bool](length=6, fill=False)
    let effects = [SFX_COIN, SFX_JUMP, SFX_EXPLODE, SFX_POWERUP, SFX_BLIP, SFX_ZAP]

    while pane.pump():
        if key_held(KEY_ESCAPE):
            break
        # A slow drift. Nothing is redrawn to scroll -- it moves where the
        # composite reads from.
        scroll_x += 0.3
        if scroll_x > Float64(WORLD_W - VIEW_W):
            scroll_x = 0.0
        world.set_scroll(Int(scroll_x), scroll_y)

        # The arrow keys drive the player sprite, in WORLD coordinates, so
        # it stays where it was put as the camera drifts past.
        let speed = 140.0 * pane.dt()
        var px = sprites.sprite_x(player)
        var py = sprites.sprite_y(player)
        if key_held(KEY_LEFT):
            px -= speed
        if key_held(KEY_RIGHT):
            px += speed
        if key_held(KEY_UP):
            py -= speed
        if key_held(KEY_DOWN):
            py += speed
        # Space fires a zap; the number keys try the others. sfx_play only
        # writes a ring slot and bumps a counter -- it never blocks, so it
        # is safe to call from the frame loop.
        if key_held(KEY_SPACE) and not held_space:
            _ = sfx_play(deck, SFX_ZAP)
        held_space = key_held(KEY_SPACE)
        for k in range(6):
            let code = KEY_1 + k
            if key_held(code) and not held_num[k]:
                _ = sfx_play(deck, effects[k])
            held_num[k] = key_held(code)

        sprites.move_to(player, px, py)
        sprites.set_rotation(player, sprites.instances[player].rotation_degrees + 60.0 * pane.dt())
        sprites.tick(pane.dt())

        with autoreleasepool():
            let frame = pane.begin_frame()
            sky.render(frame)          # layer 0: Clear
            world.render(frame)        # layer 1: Load, index 0 discards
            sprites.render(            # layer 2: quads, alpha-blended
                frame, Float64(Int(scroll_x)), Float64(scroll_y),
                Float64(VIEW_W), Float64(VIEW_H),
            )
            hud.render(frame)          # layer 3a: the retained overlay
            menu.render(frame)         # layer 3b: the cell grid
            pane.end_frame(frame)

    # ALWAYS, before main returns: an audio unit outliving the state its
    # callback reads is a crash on the way out.
    stop_audio(unit)
    deck_free(deck)
    pane.close()
    print("presented", pane.frame_count(), "frames")
