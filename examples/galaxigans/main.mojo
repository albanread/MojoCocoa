# ===----------------------------------------------------------------------=== #
# Galaxigans — a Galaga in Mojo, on the game pane.
#
# Ported from the BASIC original (fbzig-basic-arm64/demos/galaxigans.bas,
# 1,447 lines). The model maps onto this package almost one for one:
#
#   SPRITE DEF / PALETTE      define_sprite / sprite_rgb
#   SPRITE id, def, x, y      place
#   SPRITE POS / ROT / SCALE  move_to / set_rotation / set_scale
#   SPRITE SHOW / HIDE        show / hide
#   SPRITE ANIMATE            animate
#   SPRITEHIT                 hit
#   GKEYDOWN                  key_held        (the same macOS key codes)
#   DRAWTEXT                  TextOverlay.draw_text
#   MUSIC PLAY n              sfx_play, on chip B
#
# TWO DIFFERENCES worth knowing, because both would be silent bugs.
#
# The BASIC's sprites are anchored TOP-LEFT and ours are anchored at their
# CENTRE -- a natural pivot for rotation, which this game uses for the
# player's lean and the divers' tumble. So every placement adds half the
# sprite, and `place_tl` below is the only place that arithmetic lives.
#
# The BASIC has no delta time: it runs at VSYNC and counts frames. This does
# too -- `pane.dt()` is used only for animation -- because the dive curves
# and the fire cooldown are written in frames, and reinterpreting them as
# seconds would change the game rather than port it.
#
# The game imports `gamepane.api` for everything it can and `gamepane.metal`
# only to open a window and make sound. It never touches Metal, a kernel or
# an audio unit.
#
# Headless:
#   GAMEPANE_FRAMES=300 GAMEPANE_DUMP=/tmp/g.bgra \
#       ./galaxigans          (built; the JIT cannot resolve AudioToolbox)
# ===----------------------------------------------------------------------=== #

from std.math import sin, cos, atan2, sqrt
from std.objc import load_framework, autoreleasepool
from std.os import getenv
from std.time import perf_counter_ns

from gamepane.api import (
    P,
    KEY_ESCAPE, KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_SPACE,
    SFX_SHOOT, SFX_EXPLODE, SFX_BANG, SFX_SAUCER, SFX_POWERUP, SFX_HURT,
    SFX_COIN, SFX_BLIP,
)
from gamepane.metal import (
    GamePane, Sprites, TextOverlay, key_held,
    deck_new, deck_free, sfx_play, start_audio, stop_audio,
)

from art import (
    define_all,
    PLAYER_SLOT, BEE_SLOT, BOSS_SLOT, BULLET_SLOT, BOMB_SLOT, STAR_SLOT,
    EXPLOSION_SLOT, SAUCER_SLOT, BUTTERFLY_SLOT, SCORPION_SLOT,
    BLUE_BEE_SLOT, MOTH_SLOT,
    PLAYER_W, PLAYER_H, BOSS_W, BOSS_H, BEE_W, BEE_H,
    BULLET_W, BULLET_H, BOMB_W, BOMB_H, STAR_W, STAR_H,
    EXPLOSION_W, EXPLOSION_H, SAUCER_W, SAUCER_H,
)


comptime VIEW_W = 640
comptime VIEW_H = 480

comptime ENEMIES = 60
comptime BULLETS = 3
comptime BOMBS = 10
comptime EXPLOSIONS = 5
comptime STARS = 20
comptime HUD_ICONS = 5

comptime STATE_INTRO = 0
comptime STATE_PLAYING = 1
comptime STATE_GAMEOVER = 2
comptime STATE_WIN = 3

def row_defs() -> List[Int]:
    """The rows, as the BASIC lays them out: ten of each, forty apart.

    A runtime `List`, not a `comptime` array: a comptime array cannot be
    indexed by a loop variable without an explicit `materialize`.
    """
    return [BOSS_SLOT, BUTTERFLY_SLOT, BEE_SLOT, SCORPION_SLOT,
            BLUE_BEE_SLOT, MOTH_SLOT]


struct Game(Movable):
    """Every array the BASIC declared, and the sprite handle beside it.

    The BASIC addresses sprites by a hand-assigned instance number -- 0 for
    the player, 1..60 for enemies, 61..63 for bullets. Here `place` hands
    back a handle, so the handles are kept in lists in the same order and
    the game indexes those instead. Same shape, no magic numbers.
    """

    var ids: List[Int]              # the twelve definitions
    var player: Int
    var enemy: List[Int]
    var bullet: List[Int]
    var bomb: List[Int]
    var boom: List[Int]
    var star: List[Int]
    var hud_icon: List[Int]
    var saucer: Int

    var enemy_alive: List[Int]
    var enemy_dive: List[Float64]
    var enemy_return: List[Float64]
    var enemy_join_row: List[Int]
    var enemy_target_col: List[Int]

    var bullet_active: List[Int]
    var bullet_x: List[Float64]
    var bullet_y: List[Float64]
    var bullet_dx: List[Float64]

    var bomb_active: List[Int]
    var bomb_x: List[Float64]
    var bomb_y: List[Float64]
    var bomb_dy: List[Float64]

    var boom_timer: List[Int]

    var px: Float64
    var p_alive: Int
    var p_respawn: Int
    var p_death_timer: Int
    var ships: Int
    var score: Int
    var fire_cooldown: Int
    var shoot_held: Int
    var shoot_release: Int

    var formation_x: Float64
    var formation_y: Float64
    var formation_dir: Int

    var saucer_active: Int
    var saucer_spawn: Int
    var saucer_x: Float64
    var saucer_y: Float64
    var saucer_dx: Float64
    var saucer_exploding: Int

    var rng: Int

    def __init__(out self, mut sprites: Sprites, ids: List[Int]) raises:
        self.ids = ids.copy()
        self.player = sprites.place(ids[PLAYER_SLOT], 320.0, 448.0)
        self.enemy = List[Int]()
        let rows = row_defs()
        for i in range(ENEMIES):
            let row = i // 10
            self.enemy.append(sprites.place(ids[rows[row]], -100.0, -100.0))
            if row != 0:
                # The BASIC animates every row but the bosses.
                sprites.animate(self.enemy[i], 3.0 + Float64(row))
        self.bullet = List[Int]()
        for _ in range(BULLETS):
            self.bullet.append(sprites.place(ids[BULLET_SLOT], -100.0, -100.0))
        self.bomb = List[Int]()
        for _ in range(BOMBS):
            self.bomb.append(sprites.place(ids[BOMB_SLOT], -100.0, -100.0))
        self.boom = List[Int]()
        for _ in range(EXPLOSIONS):
            self.boom.append(sprites.place(ids[EXPLOSION_SLOT], -100.0, -100.0))
        self.star = List[Int]()
        for _ in range(STARS):
            self.star.append(sprites.place(ids[STAR_SLOT], -100.0, -100.0))
        self.hud_icon = List[Int]()
        for _ in range(HUD_ICONS):
            self.hud_icon.append(sprites.place(ids[PLAYER_SLOT], -100.0, -100.0))
        self.saucer = sprites.place(ids[SAUCER_SLOT], -100.0, -100.0)

        self.enemy_alive = List[Int](length=ENEMIES, fill=1)
        self.enemy_dive = List[Float64](length=ENEMIES, fill=0.0)
        self.enemy_return = List[Float64](length=ENEMIES, fill=0.0)
        self.enemy_join_row = List[Int](length=ENEMIES, fill=0)
        self.enemy_target_col = List[Int](length=ENEMIES, fill=0)
        self.bullet_active = List[Int](length=BULLETS, fill=0)
        self.bullet_x = List[Float64](length=BULLETS, fill=0.0)
        self.bullet_y = List[Float64](length=BULLETS, fill=0.0)
        self.bullet_dx = List[Float64](length=BULLETS, fill=0.0)
        self.bomb_active = List[Int](length=BOMBS, fill=0)
        self.bomb_x = List[Float64](length=BOMBS, fill=0.0)
        self.bomb_y = List[Float64](length=BOMBS, fill=0.0)
        self.bomb_dy = List[Float64](length=BOMBS, fill=0.0)
        self.boom_timer = List[Int](length=EXPLOSIONS, fill=20)

        self.px = 308.0
        self.p_alive = 1
        self.p_respawn = 0
        self.p_death_timer = 0
        self.ships = 3
        self.score = 0
        self.fire_cooldown = 0
        self.shoot_held = 0
        self.shoot_release = 0
        self.formation_x = 0.0
        self.formation_y = 0.0
        self.formation_dir = 1
        self.saucer_active = 0
        self.saucer_spawn = 240
        self.saucer_x = 0.0
        self.saucer_y = 40.0
        self.saucer_dx = 0.0
        self.saucer_exploding = 0
        self.rng = 0x2545F4914F6CDD1D

    # ── the little things ────────────────────────────────────────────────

    def rnd(mut self) -> Float64:
        """xorshift64*, seeded fixed. Deterministic on purpose: a headless
        run has to produce the same attract mode every time, or the frame
        check in the harness is a coin toss."""
        var x = self.rng
        x ^= (x >> 12) & 0xFFFFFFFFFFFFF
        x ^= (x << 25) & 0xFFFFFFFFFFFFFFFF
        x ^= (x >> 27) & 0x1FFFFFFFFFFFFFFF
        self.rng = x & 0xFFFFFFFFFFFFFFFF
        return Float64((self.rng >> 11) & 0x1FFFFFFFFFFFFF) / 9007199254740992.0

    def place_tl(
        self, mut sprites: Sprites, inst: Int, x: Float64, y: Float64,
        w: Int, h: Int,
    ):
        """The BASIC's top-left placement, in our centre-anchored world."""
        sprites.move_to(inst, x + Float64(w) / 2.0, y + Float64(h) / 2.0)

    def spawn_boom(
        mut self, mut sprites: Sprites, x: Float64, y: Float64, fps: Float64
    ) -> Bool:
        """The first free explosion slot, or none. The BASIC's five slots
        are a hard cap and staying under it is what keeps a chain of deaths
        from spawning a hundred sprites."""
        for k in range(EXPLOSIONS):
            if self.boom_timer[k] >= 15:
                self.boom_timer[k] = 0
                self.place_tl(sprites, self.boom[k], x, y,
                              EXPLOSION_W, EXPLOSION_H)
                sprites.show(self.boom[k])
                sprites.set_frame(self.boom[k], 0)
                sprites.animate(self.boom[k], fps)
                return True
        return False

    # ── where an enemy belongs ───────────────────────────────────────────

    def formation_slot(self, i: Int) -> Tuple[Float64, Float64]:
        """The enemy's place in the formation, before any dive.

        A returnee holds the row ABOVE the bosses until the boss in its
        column dies, and then fills that gap -- which is why this asks about
        `enemy_alive` rather than just doing arithmetic on the index.
        """
        if self.enemy_join_row[i] > 0:
            let col = (self.enemy_join_row[i] - 1) % 10
            let ex = 88.0 + Float64(col) * 50.0 + self.formation_x
            if self.enemy_alive[col] == 0:
                return (ex, 100.0 + self.formation_y)
            return (ex, 60.0 + self.formation_y)
        let row = i // 10
        if row == 0:
            return (80.0 + Float64(i) * 50.0 + self.formation_x,
                    100.0 + self.formation_y)
        let col = i % 10
        return (88.0 + Float64(col) * 50.0 + self.formation_x,
                Float64(140 + (row - 1) * 40) + self.formation_y)

    def front_row(self) -> Tuple[Int, Int]:
        """The lowest row with a living original in it. Divers come from the
        front line, so a formation that has lost its bottom rows starts
        sending its bosses."""
        var start = 0
        var end = 9
        for row in range(1, 6):
            var any = False
            for i in range(row * 10, row * 10 + 10):
                if self.enemy_alive[i] == 1 and self.enemy_join_row[i] == 0:
                    any = True
            if any:
                start = row * 10
                end = row * 10 + 9
        return (start, end)

    def free_column(self, i: Int) -> Int:
        """A column for a returnee to come back into, avoiding one another.

        Without this two divers rejoin the same column and sit on top of
        each other for the rest of the game.
        """
        var tc = (i % 10) + 1
        for attempt in range(11):
            var taken = False
            for j in range(ENEMIES):
                if j == i or self.enemy_alive[j] != 1:
                    continue
                if self.enemy_target_col[j] == tc and self.enemy_return[j] > 0.0:
                    taken = True
                if (
                    self.enemy_join_row[j] == tc
                    and self.enemy_dive[j] == 0.0
                    and self.enemy_return[j] == 0.0
                ):
                    taken = True
            if not taken:
                return tc
            tc = attempt + 1
        return (i % 10) + 1

    # ── the update passes, in the BASIC's own order ──────────────────────

    def reset(mut self, mut sprites: Sprites) raises:
        for i in range(ENEMIES):
            self.enemy_alive[i] = 1
            self.enemy_dive[i] = 0.0
            self.enemy_return[i] = 0.0
            self.enemy_join_row[i] = 0
            self.enemy_target_col[i] = 0
            sprites.show(self.enemy[i])
            sprites.set_rotation(self.enemy[i], 0.0)
        for k in range(EXPLOSIONS):
            self.boom_timer[k] = 20
            sprites.hide(self.boom[k])
        for b in range(BULLETS):
            self.bullet_active[b] = 0
            self.bullet_dx[b] = 0.0
            sprites.hide(self.bullet[b])
        for b in range(BOMBS):
            self.bomb_active[b] = 0
            sprites.hide(self.bomb[b])
        self.px = 308.0
        self.p_alive = 1
        self.p_respawn = 0
        self.p_death_timer = 0
        self.ships = 3
        self.score = 0
        self.fire_cooldown = 0
        self.shoot_held = 0
        self.shoot_release = 0
        self.saucer_active = 0
        self.saucer_exploding = 0
        self.saucer_spawn = 240
        self.formation_x = 0.0
        self.formation_y = 0.0
        self.formation_dir = 1
        sprites.hide(self.saucer)
        sprites.show(self.player)
        for s in range(STARS):
            # The randoms FIRST: `rnd` mutates self, and passing it in the
            # same call as `self.star[s]` keeps an interior reference alive
            # across the mutation. The compiler says so -- "use of
            # invalidated interior reference" -- which is a better outcome
            # than the aliasing bug it would otherwise be.
            var sx = self.rnd() * 640.0
            var sy = self.rnd() * 480.0
            self.place_tl(sprites, self.star[s], sx, sy, STAR_W, STAR_H)
            sprites.show(self.star[s])

    def update_stars(mut self, mut sprites: Sprites):
        for s in range(STARS):
            var y = sprites.sprite_y(self.star[s]) + 1.5
            if y > 480.0:
                y = -4.0
            sprites.move_to(self.star[s], sprites.sprite_x(self.star[s]), y)

    def draw_hud_ships(mut self, mut sprites: Sprites):
        for i in range(HUD_ICONS):
            if i < self.ships:
                self.place_tl(sprites, self.hud_icon[i],
                              560.0 + Float64(i) * 16.0, 12.0,
                              PLAYER_W, PLAYER_H)
                sprites.set_scale(self.hud_icon[i], 0.6)
                sprites.show(self.hud_icon[i])
            else:
                sprites.hide(self.hud_icon[i])

    def update_player(
        mut self, mut sprites: Sprites, deck: P, attract: Bool, frame: Int
    ) raises:
        if self.p_alive == 0:
            if self.p_death_timer > 0:
                self.p_death_timer -= 1
                if self.p_death_timer % 18 == 0:
                    var bx = self.rnd() * 28.0 - 14.0
                    var by = self.rnd() * 14.0 - 7.0
                    _ = self.spawn_boom(
                        sprites, self.px + bx, 440.0 + by, 3.0
                    )
                return
            self.p_respawn += 1
            if self.p_respawn > 100 and self.ships > 0:
                self.p_alive = 1
                self.p_respawn = 0
                self.px = 308.0
                self.place_tl(sprites, self.player, self.px, 440.0,
                              PLAYER_W, PLAYER_H)
                sprites.show(self.player)
            return

        # ATTRACT MODE. A headless run must not read the keyboard: the
        # window is an unfocused Accessory, but it still receives keys typed
        # elsewhere, so the harness result would depend on what someone was
        # doing at the time. Measured, not assumed -- a check run picked up
        # two stray shots. So when GAMEPANE_FRAMES is set the game plays
        # ITSELF, from the frame counter, and the same run produces the same
        # frame every time.
        var want_left = key_held(KEY_LEFT)
        var want_right = key_held(KEY_RIGHT)
        var want_fire = key_held(KEY_SPACE)
        if attract:
            let sweep = (frame // 3) % 200
            want_left = sweep >= 100
            want_right = sweep < 100
            want_fire = (frame % 20) < 8

        var angle = 0.0
        var aim_dx = 0.0
        if want_left:
            self.px -= 4.0
            angle = -12.0
            aim_dx = -2.0
        if want_right:
            self.px += 4.0
            angle = 12.0
            aim_dx = 2.0
        if not attract and key_held(KEY_UP):
            angle = 0.0
            aim_dx = 0.0
        if self.px < 10.0:
            self.px = 10.0
        elif self.px > 614.0:
            self.px = 614.0

        self.place_tl(sprites, self.player, self.px, 440.0, PLAYER_W, PLAYER_H)
        sprites.set_rotation(self.player, angle)
        sprites.show(self.player)

        if self.fire_cooldown > 0:
            self.fire_cooldown -= 1

        # Edge-triggered fire, with the BASIC's three-frame release debounce:
        # a key that flickers for one frame must not read as two shots.
        if not want_fire:
            self.shoot_release += 1
            if self.shoot_release >= 3:
                self.shoot_held = 0
                self.shoot_release = 3
        else:
            self.shoot_release = 0
            if self.shoot_held == 0:
                self.shoot_held = 1
                if self.fire_cooldown == 0:
                    for b in range(BULLETS):
                        if self.bullet_active[b] == 0:
                            self.bullet_active[b] = 1
                            self.bullet_x[b] = self.px + 6.0 + aim_dx * 2.0
                            self.bullet_y[b] = 430.0
                            self.bullet_dx[b] = aim_dx
                            self.place_tl(sprites, self.bullet[b],
                                          self.bullet_x[b], self.bullet_y[b],
                                          BULLET_W, BULLET_H)
                            sprites.show(self.bullet[b])
                            self.fire_cooldown = 15
                            _ = sfx_play(deck, SFX_SHOOT)
                            break

    def update_enemies(
        mut self, mut sprites: Sprites, deck: P, frame: Int
    ) raises:
        self.formation_x += 1.5 * Float64(self.formation_dir)
        if self.formation_x > 100.0:
            self.formation_dir = -1
            self.formation_y += 10.0
        elif self.formation_x < -70.0:
            self.formation_dir = 1
            self.formation_y += 10.0

        # Who is left decides how the wave behaves.
        var originals = False
        var total = 0
        for i in range(ENEMIES):
            if self.enemy_alive[i] == 1:
                total += 1
                if (
                    self.enemy_join_row[i] == 0
                    and self.enemy_return[i] == 0.0
                    and self.enemy_dive[i] == 0.0
                ):
                    originals = True

        if not originals or total < 5:
            # FRENZY: the last few come at you all at once.
            if frame % 8 == 0:
                for i in range(ENEMIES):
                    if (
                        self.enemy_alive[i] == 1
                        and self.enemy_dive[i] == 0.0
                        and self.enemy_return[i] == 0.0
                    ):
                        self.enemy_dive[i] = 0.001
        elif frame % 45 == 0:
            let fr = self.front_row()
            let ri = fr[0] + Int(self.rnd() * Float64(fr[1] - fr[0] + 1))
            if (
                ri < ENEMIES
                and self.enemy_alive[ri] == 1
                and self.enemy_dive[ri] == 0.0
                and self.enemy_return[ri] == 0.0
                and self.enemy_join_row[ri] == 0
            ):
                self.enemy_dive[ri] = 0.001

        # Bombs.
        let bomb_rate = 10 if (not originals or total < 5) else 25
        if frame % bomb_rate == 0:
            let ri = Int(self.rnd() * Float64(ENEMIES - 1))
            if self.enemy_alive[ri] == 1:
                for b in range(BOMBS):
                    if self.bomb_active[b] == 0:
                        self.bomb_active[b] = 1
                        self.bomb_x[b] = sprites.sprite_x(self.enemy[ri])
                        self.bomb_y[b] = sprites.sprite_y(self.enemy[ri]) + 12.0
                        self.bomb_dy[b] = 4.0
                        self.place_tl(sprites, self.bomb[b],
                                      self.bomb_x[b], self.bomb_y[b],
                                      BOMB_W, BOMB_H)
                        sprites.show(self.bomb[b])
                        break

        for b in range(BOMBS):
            if self.bomb_active[b] != 1:
                continue
            self.bomb_y[b] += self.bomb_dy[b]
            self.place_tl(sprites, self.bomb[b], self.bomb_x[b],
                          self.bomb_y[b], BOMB_W, BOMB_H)
            if self.bomb_y[b] > 480.0:
                self.bomb_active[b] = 0
                sprites.hide(self.bomb[b])
                continue
            if self.p_alive == 1 and sprites.hit(self.bomb[b], self.player):
                self.p_alive = 0
                self.p_respawn = 0
                self.p_death_timer = 150
                self.ships -= 1
                self.bomb_active[b] = 0
                sprites.hide(self.bomb[b])
                sprites.hide(self.player)
                if self.spawn_boom(sprites, self.px, 440.0, 4.0):
                    _ = sfx_play(deck, SFX_BANG)

        # Every enemy's position: formation, dive, or return.
        for i in range(ENEMIES):
            if self.enemy_alive[i] != 1:
                continue
            let home = self.formation_slot(i)
            var ex = home[0]
            var ey = home[1]

            # A formation that has walked down far enough dives on its own.
            if (
                self.enemy_dive[i] == 0.0
                and self.enemy_return[i] == 0.0
                and ey >= 450.0
            ):
                self.enemy_dive[i] = 0.001

            if self.enemy_dive[i] > 0.0:
                self.enemy_dive[i] += 0.004
                let t = self.enemy_dive[i]
                let dx = sin(t * 2.5) * 180.0
                let dy = t * 450.0
                sprites.set_rotation(
                    self.enemy[i],
                    atan2(450.0 * cos(t * 2.5), -450.0) * 57.295 + 180.0,
                )
                ex += dx
                ey += dy
                if ey > 550.0:
                    # Off the bottom: come back in at the top, in a column
                    # nobody else has claimed.
                    self.enemy_target_col[i] = self.free_column(i)
                    self.enemy_dive[i] = 0.0
                    self.enemy_return[i] = 0.001
                    ex -= dx
                    ey = -30.0
                    sprites.set_rotation(self.enemy[i], 180.0)
            elif self.enemy_return[i] > 0.0:
                self.enemy_return[i] += 0.004
                let t = self.enemy_return[i]
                let target = 60.0 + self.formation_y
                ex = (
                    88.0 + Float64(self.enemy_target_col[i] - 1) * 50.0
                    + self.formation_x
                )
                # The flourish is zero at both ends, so the entry and the
                # arrival are both straight and only the middle swings.
                ex += sin(t * 3.14159) * 80.0
                ey = -30.0 + t * (target + 30.0)
                sprites.set_rotation(self.enemy[i], 180.0 * (1.0 - t))
                if self.enemy_return[i] >= 1.0:
                    self.enemy_return[i] = 0.0
                    self.enemy_join_row[i] = self.enemy_target_col[i]
                    sprites.set_rotation(self.enemy[i], 0.0)

            let w = BOSS_W if i < 10 else BEE_W
            let h = BOSS_H if i < 10 else BEE_H
            self.place_tl(sprites, self.enemy[i], ex, ey, w, h)

            # A diver that reaches the player takes them with it.
            if (
                self.p_alive == 1
                and self.enemy_dive[i] > 0.0
                and sprites.hit(self.enemy[i], self.player)
            ):
                self.p_alive = 0
                self.p_respawn = 0
                self.p_death_timer = 150
                self.ships -= 1
                sprites.hide(self.player)
                if self.spawn_boom(sprites, self.px, 440.0, 4.0):
                    _ = sfx_play(deck, SFX_BANG)

    def update_saucer(mut self, mut sprites: Sprites, deck: P) raises:
        if self.saucer_exploding > 0:
            self.saucer_exploding -= 1
            if self.saucer_exploding % 8 == 0:
                var ox = self.rnd() * 32.0 - 8.0
                var oy = self.rnd() * 14.0 - 4.0
                _ = self.spawn_boom(
                    sprites, self.saucer_x + ox, self.saucer_y + oy, 3.5
                )
            return

        if self.saucer_active == 0:
            self.saucer_spawn -= 1
            if self.saucer_spawn <= 0:
                _ = sfx_play(deck, SFX_SAUCER)
                self.saucer_active = 1
                self.saucer_y = 40.0
                if self.rnd() < 0.5:
                    self.saucer_x = -40.0
                    self.saucer_dx = 2.8
                else:
                    self.saucer_x = 680.0
                    self.saucer_dx = -2.8
                self.place_tl(sprites, self.saucer, self.saucer_x,
                              self.saucer_y, SAUCER_W, SAUCER_H)
                sprites.set_scale(self.saucer, 1.1)
                sprites.show(self.saucer)
            return

        self.saucer_x += self.saucer_dx
        self.place_tl(sprites, self.saucer, self.saucer_x, self.saucer_y,
                      SAUCER_W, SAUCER_H)
        if self.saucer_x < -80.0 or self.saucer_x > 720.0:
            self.saucer_active = 0
            self.saucer_spawn = 240 + Int(self.rnd() * 360.0)
            sprites.hide(self.saucer)

    def update_bullets(mut self, mut sprites: Sprites, deck: P) raises:
        for b in range(BULLETS):
            if self.bullet_active[b] != 1:
                continue
            self.bullet_y[b] -= 6.0
            self.bullet_x[b] += self.bullet_dx[b]
            self.place_tl(sprites, self.bullet[b], self.bullet_x[b],
                          self.bullet_y[b], BULLET_W, BULLET_H)

            if (
                self.bullet_y[b] < -10.0
                or self.bullet_x[b] < -20.0
                or self.bullet_x[b] > 660.0
            ):
                self.bullet_active[b] = 0
                sprites.hide(self.bullet[b])
                continue

            for j in range(ENEMIES):
                if self.enemy_alive[j] != 1 or self.bullet_active[b] != 1:
                    continue
                if sprites.hit(self.bullet[b], self.enemy[j]):
                    self.enemy_alive[j] = 0
                    self.bullet_active[b] = 0
                    self.score += 10
                    sprites.hide(self.enemy[j])
                    sprites.hide(self.bullet[b])
                    if self.spawn_boom(
                        sprites,
                        sprites.sprite_x(self.enemy[j]),
                        sprites.sprite_y(self.enemy[j]),
                        4.0,
                    ):
                        _ = sfx_play(deck, SFX_EXPLODE)

            if (
                self.saucer_active == 1
                and self.bullet_active[b] == 1
                and sprites.hit(self.bullet[b], self.saucer)
            ):
                self.bullet_active[b] = 0
                sprites.hide(self.bullet[b])
                self.saucer_active = 0
                sprites.hide(self.saucer)
                self.saucer_spawn = 300 + Int(self.rnd() * 360.0)
                self.score += 100
                self.saucer_exploding = 64
                _ = sfx_play(deck, SFX_EXPLODE)
                # Three at once for the initial burst, then the sustain
                # above scatters more across the wreckage.
                _ = self.spawn_boom(sprites, self.saucer_x, self.saucer_y, 4.0)
                _ = self.spawn_boom(sprites, self.saucer_x + 14.0,
                                    self.saucer_y - 5.0, 4.0)
                _ = self.spawn_boom(sprites, self.saucer_x + 25.0,
                                    self.saucer_y + 3.0, 4.0)

        for k in range(EXPLOSIONS):
            if self.boom_timer[k] < 15:
                self.boom_timer[k] += 1
                if self.boom_timer[k] >= 15:
                    sprites.hide(self.boom[k])

    def all_dead(self) -> Bool:
        for i in range(ENEMIES):
            if self.enemy_alive[i] == 1:
                return False
        return True


def pad6(n: Int) -> String:
    """`SCORE: 000123` — the BASIC's RIGHT$("000000" & STR$(score), 6)."""
    var s = String(n)
    while s.byte_length() < 6:
        s = String("0") + s
    return s


def main() raises:
    if not load_framework["Metal"]():
        raise Error("could not load Metal")

    var pane = GamePane(String("Galaxigans"), VIEW_W, VIEW_H)
    var sprites = Sprites(pane.device)
    let ids = define_all(pane.ctx, sprites)
    var game = Game(sprites, ids)
    var hud = TextOverlay(pane.device, VIEW_W, VIEW_H)

    # Headless means attract mode: see update_player.
    let attract = getenv("GAMEPANE_FRAMES").byte_length() > 0

    var deck = deck_new()
    let unit = start_audio(deck)

    game.reset(sprites)

    var state = STATE_INTRO
    var frame = 0
    var intro_timer = 0
    var flash_timer = 0
    var last_score = -1
    var last_ships = -1
    var last_state = -1
    var last_flash = -1

    while pane.pump():
        if key_held(KEY_ESCAPE):
            break

        # The overlay is RETAINED, so it is redrawn only when what it says
        # changes -- which for a score and three words is almost never. The
        # BASIC redraws its text every frame because it has to.
        let flash = (flash_timer // 10) % 6
        if (
            game.score != last_score
            or game.ships != last_ships
            or state != last_state
            or flash != last_flash
        ):
            hud.clear()
            hud.draw_text(10, 10, String("SCORE: ") + pad6(game.score),
                          255, 241, 232, 1)
            hud.draw_text(280, 20, String("STAGE 1"), 255, 241, 232, 1)
            var flash_r: List[Int] = [255, 255, 255, 0, 41, 131]
            var flash_g: List[Int] = [0, 163, 236, 228, 173, 118]
            var flash_b: List[Int] = [77, 0, 39, 54, 255, 156]
            if state == STATE_INTRO:
                hud.draw_text(230, 200, String("PLAYER 1 READY"),
                              flash_r[flash], flash_g[flash], flash_b[flash], 1)
            elif state == STATE_GAMEOVER:
                hud.draw_text(266, 200, String("GAME OVER"),
                              flash_r[flash], flash_g[flash], flash_b[flash], 1)
            elif state == STATE_WIN:
                hud.draw_text(242, 200, String("PLAYER WINS!"),
                              flash_r[flash], flash_g[flash], flash_b[flash], 1)
            last_score = game.score
            last_ships = game.ships
            last_state = state
            last_flash = flash

        game.draw_hud_ships(sprites)
        game.update_stars(sprites)

        if state == STATE_INTRO:
            if intro_timer == 0:
                _ = sfx_play(deck, SFX_COIN)
            intro_timer += 1
            if (not attract and key_held(KEY_SPACE)) or intro_timer > 60:
                state = STATE_PLAYING
                frame = 0
            flash_timer = intro_timer

        elif state == STATE_PLAYING:
            game.update_player(sprites, deck, attract, frame)
            game.update_enemies(sprites, deck, frame)
            game.update_saucer(sprites, deck)
            game.update_bullets(sprites, deck)
            if game.ships <= 0 and game.p_death_timer <= 0:
                state = STATE_GAMEOVER
                flash_timer = 0
                _ = sfx_play(deck, SFX_HURT)
            elif game.all_dead():
                state = STATE_WIN
                flash_timer = 0
                _ = sfx_play(deck, SFX_POWERUP)
            frame += 1

        elif state == STATE_GAMEOVER:
            flash_timer += 1
            if flash_timer > 600:
                game.reset(sprites)
                state = STATE_INTRO
                intro_timer = 0

        else:                                   # STATE_WIN
            game.update_player(sprites, deck, attract, frame)
            game.update_enemies(sprites, deck, frame)
            game.update_saucer(sprites, deck)
            game.update_bullets(sprites, deck)
            frame += 1
            flash_timer += 1
            if flash_timer > 180:
                game.reset(sprites)
                state = STATE_INTRO
                intro_timer = 0

        sprites.tick(pane.dt())

        with autoreleasepool():
            let f = pane.begin_frame()
            pane.clear(f)                       # layer 0: the empty sky
            sprites.render(f, 0.0, 0.0, Float64(VIEW_W), Float64(VIEW_H))
            hud.render(f)
            pane.end_frame(f)

    stop_audio(unit)
    deck_free(deck)
    pane.close()
    print("presented", pane.frame_count(), "frames; score", game.score,
          "ships", game.ships)
