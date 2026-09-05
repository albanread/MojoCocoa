"""The Cocoa + Metal backend -- the only tier that touches a platform."""

from .window import (
    GamePane, GameView, Frame, key_held, mouse_state, clear_input,
    gamepad_state, CLEAR_R, CLEAR_G, CLEAR_B,
)

from .layers import (
    ShaderPane, DirectPane, IndexedPane,
    SHADER_HEADER, DIRECT_SHADER, INDEXED_SHADER, DIRECT_BUFFERS,
)
from .device import (
    metal_device, metal_buffer, metal_offset, host_ptr, linear_alignment,
    index_plane_view,
)

from .blitter import (
    blit_copy_kernel, blit_transparent_kernel, blit_minterm_kernel,
    blit_fill_kernel, blit_grid, BLOCK, warm_up_blitter,
)

from .sprites import Sprites, SpriteDef, SPRITE_SHADER
