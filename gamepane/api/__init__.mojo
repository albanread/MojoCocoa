"""The platform-neutral surface. Nothing here may import a backend."""

from .input import (
    KEY_LEFT, KEY_RIGHT, KEY_DOWN, KEY_UP, KEY_SPACE, KEY_ESCAPE,
    KEY_A, KEY_S, KEY_D, KEY_W, KEY_Z, KEY_X, KEY_RETURN,
    MAX_KEY_CODE, MouseState, GamepadState,
)

from .shader import ShaderParams, SHADER_PARAM_COUNT
from .direct import Palette, PALETTE_SIZE, stride_for, buffer_len_for

from .indexed import (
    Plane, NUM_BUFFERS, FRONT, BACK, TRANSPARENT, GLOBAL_COLORS, LINE_COLORS,
    palette_entries, palette_global_base, palette_line_entry,
    palette_global_entry, hsv_to_rgb, clamp_scroll,
)

from .blit import BlitRect, clip_blit, OP_AND, OP_OR, OP_XOR

from .sprites import (
    SpriteBitmap, SpriteInstance, parse_sprite_rows, sprites_overlap,
    quad_vertices, SPRITE_COLORS,
)

from .text import (
    RgbaCanvas, glyph_for, text_cols, text_rows,
    GLYPH_W, GLYPH_H, GLYPH_ADVANCE, CELL_W, CELL_H, CELL_BYTES,
    FLAG_TRANSPARENT_BG,
)
