"""Input, as a game sees it: polled state, not an event queue.

The codes are macOS virtual key codes because that is what the one backend
reports, and inventing a private enumeration would mean a translation table
in every backend for no gain -- a second platform maps its own codes to
these. `IndexedPane.mod` and the Rust engine both use exactly these numbers.

Mouse position is NORMALISED (0..1 across the view) and measured from the
TOP, which is the pane's own convention. A window can be resized while the
world it shows keeps its fixed size, so a coordinate in points would quietly
mean a different cell after a resize; a fraction never does. The flip happens
once, at the source, rather than in every game that reads it.
"""

comptime MAX_KEY_CODE = 128

comptime KEY_LEFT = 123
comptime KEY_RIGHT = 124
comptime KEY_DOWN = 125
comptime KEY_UP = 126
comptime KEY_SPACE = 49
comptime KEY_ESCAPE = 53
# The number row, for a demo that wants a key per effect. Apple's codes are
# not in numeric order past 3, which is why these are written out.
comptime KEY_1 = 18
comptime KEY_2 = 19
comptime KEY_3 = 20
comptime KEY_4 = 21
comptime KEY_5 = 23
comptime KEY_6 = 22

comptime KEY_RETURN = 36
comptime KEY_A = 0
comptime KEY_S = 1
comptime KEY_D = 2
comptime KEY_W = 13
comptime KEY_Z = 6
comptime KEY_X = 7


@fieldwise_init
struct MouseState(Copyable, Movable):
    """Where the mouse is and what is held, as of the last event."""

    var x: Float64
    """0..1 across the view, left to right."""
    var y: Float64
    """0..1 down the view, TOP to bottom."""
    var left: Bool
    var right: Bool


@fieldwise_init
struct GamepadState(Copyable, Movable):
    """The first connected extended gamepad, or all-clear when there is none.
    """

    var connected: Bool
    var button_a: Bool
    var button_b: Bool
    var stick_x: Float64
    """-1..1, left to right."""
    var stick_y: Float64
    """-1..1, down to up (the controller's own sign)."""


# ── letters ─────────────────────────────────────────────────────────────────
#
# Apple's key codes are laid out by POSITION on the original keyboard, not
# alphabetically -- A is 0, S is 1, D is 2, and Q is 12 because it sits where
# it does. So a letter needs a table, and this is it: the only thing standing
# between a game and an arcade initials screen.

comptime LETTER_KEY_COUNT = 26


def letter_key(index: Int) -> Int:
    """The key code for letter `index`, 0 = A .. 25 = Z."""
    var t: List[Int] = [
        0,   11,  8,   2,   14,  3,   5,   4,   34,  38,   # A B C D E F G H I J
        40,  37,  46,  45,  31,  35,  12,  15,  1,   17,   # K L M N O P Q R S T
        32,  9,   13,  7,   16,  6,                        # U V W X Y Z
    ]
    if index < 0 or index >= LETTER_KEY_COUNT:
        return -1
    return t[index]
