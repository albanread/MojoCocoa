# ===----------------------------------------------------------------------=== #
# The shader pane: a background that is one fragment function.
#
# Everything on screen here comes from thirteen lines of MSL. There is no
# vertex buffer, no texture, no per-frame upload and no CPU work at all --
# the pane hands the GPU a full-screen triangle and forty bytes of uniforms,
# and the shader decides what every pixel is.
#
# The shader is quoted verbatim from MacGamePane's Rust starfield demo, and
# `u.time` is the only thing that changes between frames, which is what makes
# the stars twinkle.
#
# Headless:
#   GAMEPANE_FRAMES=30 GAMEPANE_DUMP=/tmp/starfield.bgra \
#       cocoamojo run examples/gamepane-starfield/main.mojo
# ===----------------------------------------------------------------------=== #

from std.objc import load_framework, autoreleasepool
from gamepane.api import KEY_ESCAPE
from gamepane.metal import GamePane, ShaderPane, key_held


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


def main() raises:
    if not load_framework["Metal"]():
        raise Error("could not load Metal")

    var pane = GamePane(String("Starfield"), 640, 400)
    var sky = ShaderPane(pane.device, STARFIELD)
    sky.set_aspect(pane.aspect())

    while pane.pump():
        if key_held(KEY_ESCAPE):
            break
        with autoreleasepool():
            let frame = pane.begin_frame()
            sky.render(frame)
            pane.end_frame(frame)

    pane.close()
    print("presented", pane.frame_count(), "frames")
