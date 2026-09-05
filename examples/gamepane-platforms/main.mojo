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
    KEY_ESCAPE, KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN, FRONT,
)
from gamepane.api import FLAG_TRANSPARENT_BG
from gamepane.metal import (
    GamePane, ShaderPane, IndexedPane, Sprites, TextOverlay, TextPlane,
    key_held,
)


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

    var scroll_x = Float64(WORLD_W - VIEW_W) / 2.0
    let scroll_y = (WORLD_H - VIEW_H) // 2

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

    pane.close()
    print("presented", pane.frame_count(), "frames")
