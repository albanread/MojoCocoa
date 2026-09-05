"""The blitter: four Mojo GPU kernels over the index bytes.

A bitblt between any two of the indexed pane's eight slots -- copy,
colour-keyed copy, a bitwise combine, a rectangular fill -- dispatched
through this fork's own GPU backend rather than through hand-written Metal
compute shaders. The kernels below are ordinary Mojo `def`s; the compiler
turns them into AIR and the runtime launches them.

**They write the same bytes the fragment shader samples.** That is the whole
difference from the Rust, whose blitter has to apply every operation twice
-- once on the GPU texture and once on a CPU mirror -- because its
`upload()` would otherwise push stale mirror bytes over the blit's result.
There is no mirror here (see `layers.mojo`), so there is one application and
nothing to keep in step.

**Kernel arguments must be fixed width.** `Int` and `UInt` do not conform to
`DevicePassable` and the diagnostic says so; every parameter here is
`Int32`, `UInt8` or a pointer.

**The ordering rule.** A blit is enqueued on the runtime's stream and the
frame is encoded on the layer's command queue -- two different submission
paths to the same device. `IndexedPane.render` does not synchronise, so a
game that blits and then presents in the same frame must call
`Blitter.finish(ctx)` between the two. `GamePane.begin_frame` does it for
you; the rule is written here because this is where it can be broken.
"""

from std.gpu import global_idx
from std.memory import Pointer
from max.gpu.host import DeviceContext, DeviceBuffer

from gamepane.api import BlitRect, clip_blit, OP_AND, OP_OR, OP_XOR


# ── the kernels ─────────────────────────────────────────────────────────────
#
# One thread per destination pixel, a (w, h) grid. The rectangle has already
# been clipped against both planes before launch, so the only bounds check
# left is the grid's own rounding -- a grid is whole threadgroups, and the
# last one runs off the end of a rectangle whose size is not a multiple of
# the block.


def blit_copy_kernel(
    src: Pointer[UInt8, MutAnyOrigin],
    dst: Pointer[UInt8, MutAnyOrigin],
    src_stride: Int32,
    dst_stride: Int32,
    src_x: Int32,
    src_y: Int32,
    dst_x: Int32,
    dst_y: Int32,
    w: Int32,
    h: Int32,
):
    var gx = Int(global_idx.x)
    var gy = Int(global_idx.y)
    if gx >= Int(w) or gy >= Int(h):
        return
    var v = src[
        unsafe_offset = (Int(src_y) + gy) * Int(src_stride) + Int(src_x) + gx
    ]
    dst[
        unsafe_offset = (Int(dst_y) + gy) * Int(dst_stride) + Int(dst_x) + gx
    ] = v


def blit_transparent_kernel(
    src: Pointer[UInt8, MutAnyOrigin],
    dst: Pointer[UInt8, MutAnyOrigin],
    src_stride: Int32,
    dst_stride: Int32,
    src_x: Int32,
    src_y: Int32,
    dst_x: Int32,
    dst_y: Int32,
    w: Int32,
    h: Int32,
):
    """Copy, except that source index 0 leaves the destination alone -- the
    ordinary sprite blit, and the same meaning index 0 has everywhere else
    in the pane."""
    var gx = Int(global_idx.x)
    var gy = Int(global_idx.y)
    if gx >= Int(w) or gy >= Int(h):
        return
    var v = src[
        unsafe_offset = (Int(src_y) + gy) * Int(src_stride) + Int(src_x) + gx
    ]
    if v == 0:
        return
    dst[
        unsafe_offset = (Int(dst_y) + gy) * Int(dst_stride) + Int(dst_x) + gx
    ] = v


def blit_minterm_kernel(
    src: Pointer[UInt8, MutAnyOrigin],
    dst: Pointer[UInt8, MutAnyOrigin],
    src_stride: Int32,
    dst_stride: Int32,
    src_x: Int32,
    src_y: Int32,
    dst_x: Int32,
    dst_y: Int32,
    w: Int32,
    h: Int32,
    op: Int32,
):
    var gx = Int(global_idx.x)
    var gy = Int(global_idx.y)
    if gx >= Int(w) or gy >= Int(h):
        return
    var s = src[
        unsafe_offset = (Int(src_y) + gy) * Int(src_stride) + Int(src_x) + gx
    ]
    var di = (Int(dst_y) + gy) * Int(dst_stride) + Int(dst_x) + gx
    var d = dst[unsafe_offset=di]
    var r = s
    if Int(op) == 0:
        r = s & d
    elif Int(op) == 1:
        r = s | d
    elif Int(op) == 2:
        r = s ^ d
    dst[unsafe_offset=di] = r


def blit_fill_kernel(
    dst: Pointer[UInt8, MutAnyOrigin],
    dst_stride: Int32,
    dst_x: Int32,
    dst_y: Int32,
    w: Int32,
    h: Int32,
    value: UInt8,
):
    var gx = Int(global_idx.x)
    var gy = Int(global_idx.y)
    if gx >= Int(w) or gy >= Int(h):
        return
    dst[
        unsafe_offset = (Int(dst_y) + gy) * Int(dst_stride) + Int(dst_x) + gx
    ] = value


# ── launch geometry ─────────────────────────────────────────────────────────


comptime BLOCK = 16
"""Threadgroup edge. A (w, h) rectangle launches ceil(w/16) x ceil(h/16)
groups, so the last one overhangs and every kernel checks the grid bound."""


def blit_grid(n: Int) -> Int:
    """Threadgroups needed to cover `n` threads."""
    return (n + BLOCK - 1) // BLOCK


def warm_up_blitter(mut ctx: DeviceContext) raises:
    """Compile all four kernels now rather than during a frame.

    `compile_function` is cached: the FIRST call for a kernel costs about
    140 ms, and every later one is roughly 28 microseconds -- measured, not
    assumed. So the operations below call it per blit without apology, and
    this exists only so a game pays the 140 ms at startup instead of at the
    first sprite.
    """
    _ = ctx.compile_function[blit_copy_kernel]()
    _ = ctx.compile_function[blit_transparent_kernel]()
    _ = ctx.compile_function[blit_minterm_kernel]()
    _ = ctx.compile_function[blit_fill_kernel]()
