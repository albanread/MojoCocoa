# ===----------------------------------------------------------------------=== #
# Galaxigans — a Galaga in Mojo, on the game pane.
#
# Ported from the BASIC original (fbzig-basic-arm64/demos/galaxigans.bas,
# 1,447 lines). The BASIC's model maps onto this package almost one for one:
# SPRITE DEF/PALETTE is `define_sprite`/`sprite_rgb`, SPRITE id,frame,x,y is
# `place`/`move_to`/`set_frame`, DRAWTEXT is the text overlay, GKEYDOWN is
# `key_held`, and MUSIC PLAY is an effect on chip B.
#
# The game imports `gamepane.api` for everything it can and `gamepane.metal`
# only to open a window. It never touches Metal, a kernel or an audio unit.
#
# Headless:
#   GAMEPANE_FRAMES=120 GAMEPANE_DUMP=/tmp/g.bgra \
#       cocoamojo run examples/galaxigans/main.mojo
# ===----------------------------------------------------------------------=== #

from std.objc import load_framework, autoreleasepool

from gamepane.api import (
    KEY_ESCAPE, KEY_LEFT, KEY_RIGHT, KEY_SPACE, STARFIELD,
)
from gamepane.metal import GamePane, ShaderPane, Sprites, TextOverlay, key_held

from art import (
    define_all,
    PLAYER_SLOT, BEE_SLOT, BOSS_SLOT, BULLET_SLOT, BOMB_SLOT, STAR_SLOT,
    EXPLOSION_SLOT, SAUCER_SLOT, BEE_FLAP_SLOT, BOSS_FLAP_SLOT, DIVER_SLOT,
    BANNER_SLOT,
)


comptime VIEW_W = 640
comptime VIEW_H = 480


def main() raises:
    if not load_framework["Metal"]():
        raise Error("could not load Metal")

    var pane = GamePane(String("Galaxigans"), VIEW_W, VIEW_H)
    var sky = ShaderPane(pane.device, STARFIELD)
    sky.set_aspect(pane.aspect())
    var sprites = Sprites(pane.device)
    let ids = define_all(pane.ctx, sprites)
    print("defined", len(ids), "sprite definitions")

    # A first look at every definition: one of each, laid out in a row, so
    # the art can be checked before a single line of game logic exists.
    var x = 40.0
    for s in range(len(ids)):
        let inst = sprites.place(ids[s], x, 240.0)
        sprites.set_scale(inst, 2.0)
        if sprites.frame_count(ids[s]) > 1:
            sprites.animate(inst, 6.0)
        x += 48.0

    var hud = TextOverlay(pane.device, VIEW_W, VIEW_H)
    hud.draw_text(10, 10, String("GALAXIGANS"), 255, 241, 232, 2)
    hud.draw_text(10, 40, String("SPRITE ART CHECK"), 41, 173, 255, 1)

    while pane.pump():
        if key_held(KEY_ESCAPE):
            break
        sprites.tick(pane.dt())
        with autoreleasepool():
            let frame = pane.begin_frame()
            sky.render(frame)
            sprites.render(
                frame, 0.0, 0.0, Float64(VIEW_W), Float64(VIEW_H)
            )
            hud.render(frame)
            pane.end_frame(frame)

    pane.close()
    print("presented", pane.frame_count(), "frames")
