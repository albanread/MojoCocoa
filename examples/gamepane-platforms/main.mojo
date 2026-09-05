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
# Headless:
#   GAMEPANE_FRAMES=30 GAMEPANE_DUMP=/tmp/platforms.bgra \
#       cocoamojo run examples/gamepane-platforms/main.mojo
# ===----------------------------------------------------------------------=== #

from std.objc import load_framework, autoreleasepool
from gamepane.api import KEY_ESCAPE, KEY_LEFT, KEY_RIGHT, FRONT
from gamepane.metal import GamePane, ShaderPane, IndexedPane, key_held


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

    var scroll_x = Float64(WORLD_W - VIEW_W) / 2.0
    let scroll_y = (WORLD_H - VIEW_H) // 2

    while pane.pump():
        if key_held(KEY_ESCAPE):
            break
        # A slow drift, and the arrow keys on top of it. Neither redraws
        # anything -- they move where the composite reads from.
        scroll_x += 0.3
        if key_held(KEY_LEFT):
            scroll_x -= 4.0
        if key_held(KEY_RIGHT):
            scroll_x += 4.0
        world.set_scroll(Int(scroll_x), scroll_y)

        with autoreleasepool():
            let frame = pane.begin_frame()
            sky.render(frame)          # layer 0: Clear
            world.render(frame)        # layer 1: Load, index 0 discards
            pane.end_frame(frame)

    pane.close()
    print("presented", pane.frame_count(), "frames")
