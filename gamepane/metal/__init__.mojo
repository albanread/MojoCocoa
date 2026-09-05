"""The Cocoa + Metal backend -- the only tier that touches a platform."""

from .window import (
    GamePane, GameView, key_held, mouse_state, clear_input, gamepad_state,
    CLEAR_R, CLEAR_G, CLEAR_B,
)
