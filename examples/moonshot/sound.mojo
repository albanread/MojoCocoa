# ===----------------------------------------------------------------------=== #
# Moonshot — the sound (sprint MC9).
#
# The chip and nothing more, as the design says: a Quindar-style tone
# bracketing each call from the trench (the real ones were 2 525 and
# 2 475 Hz for a quarter of a second; ours is the chip's nearest note, a
# D#7 at 2 489), a telemetry tick at 1×, the master alarm as the harsh
# alternating pair it was, and a four-bar figure at touchdown that is
# nobody's but ours. Everything is an ABC tune on the game pane's deck,
# so it is computed, not sampled, and it needs a built binary: the audio
# unit cannot be opened from a JIT run, and the headless checker does
# not ask for it.
# ===----------------------------------------------------------------------=== #

from std.memory import OpaquePointer
from gamepane.metal import deck_new, deck_free, sfx_play, start_audio, stop_audio, play_tune
from gamepane.api import SFX_BLIP

comptime P = OpaquePointer[MutUntrackedOrigin]

comptime QUINDAR = String("""X:1
M:4/4
L:1/16
Q:1/4=120
K:C
V:1
[I:chip v=0 wave=pulse pw=2048 a=0 d=1 s=9 r=1 vol=9]
^d''2 z2
""")

comptime ALARM = String("""X:1
M:4/4
L:1/8
Q:1/4=120
K:C
V:1
[I:chip v=0 wave=pulse pw=1024 a=0 d=2 s=8 r=1 vol=12]
g'2 c''2 g'2 c''2 g'2 c''2 g'2 c''2
""")

comptime TOUCHDOWN = String("""X:1
M:4/4
L:1/8
Q:1/4=112
K:C
V:1
[I:chip v=0 wave=pulse pw=1400 a=0 d=5 s=7 r=5 vol=11]
C2 E2 G2 c2 | G2 E2 C4 | E2 G2 c2 e2 | c8
V:2
[I:chip v=1 wave=tri a=0 d=6 s=6 r=6 vol=10]
C,4 G,,4 | C,4 G,,4 | C,4 G,,4 | C,8
""")


struct Sound(Movable):
    """The deck, or a silent stand-in when the run is headless."""

    var deck: P
    var unit: Int
    var on: Bool

    def __init__(out self, enabled: Bool) raises:
        # A deck is only memory; the audio unit is what a headless run
        # must not open. So the deck always exists, and pointers stay
        # non-null, which the stdlib insists on.
        self.deck = deck_new()
        self.unit = 0
        self.on = False
        if enabled:
            self.unit = start_audio(self.deck)
            self.on = True

    def quindar(mut self):
        if self.on:
            try:
                _ = play_tune(self.deck, QUINDAR)
            except:
                pass

    def alarm(mut self):
        if self.on:
            try:
                _ = play_tune(self.deck, ALARM)
            except:
                pass

    def touchdown(mut self):
        if self.on:
            try:
                _ = play_tune(self.deck, TOUCHDOWN)
            except:
                pass

    def tick(mut self):
        if self.on:
            _ = sfx_play(self.deck, SFX_BLIP)

    def close(mut self):
        if self.on:
            stop_audio(self.unit)
            self.on = False
        deck_free(self.deck)
