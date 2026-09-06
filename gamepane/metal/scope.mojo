# The oscilloscope — CT5's first instrument.
#
# A strip of index plane, a buffer of column heights, and one kernel: each
# thread owns a column, reads its sample and its neighbour's, and draws the
# vertical run between them so the trace connects. Left and right are two
# traces, phosphor green over cyan, because a stereo chip deserves a stereo
# scope. The fragment shader, the palette layout and the pipeline are the
# particle field's own, imported rather than copied -- an index plane with
# a discard at zero is an index plane with a discard at zero.
#
# The data path is the house model, one memory and its readers: the trio's
# ring is copied into a Shared DeviceBuffer on the UI thread (the copy IS
# the downsample), the kernel reads it, the fragment shader samples the
# plane the kernel wrote. No readback anywhere.

from std.gpu import global_idx
from std.memory import Pointer, MutAnyOrigin, MutUntrackedOrigin
from std.objc import Cls, ObjCObject, send, nsenum
from max.gpu.host import DeviceContext, DeviceBuffer

from gamepane.api import P, stride_for
from gamepane.abc import trio_scope_read, SCOPE_FRAMES
from .window import Frame
from .device import (
    metal_buffer, metal_offset, host_ptr, linear_alignment, index_plane_view,
)
from .blitter import blit_fill_kernel, blit_grid, BLOCK
from .particles import _particle_pipeline, PARTICLE_PALETTE, ParticleUniforms


comptime IX_SCOPE_GRID = 1
comptime IX_SCOPE_LEFT = 2
comptime IX_SCOPE_RIGHT = 3


def scope_plot_kernel(
    samples: Pointer[Float32, MutAnyOrigin],   # width L columns, then width R
    plane: Pointer[UInt8, MutAnyOrigin],
    stride: Int32,
    width: Int32,
    height: Int32,
    gain: Float32,
):
    """One thread, one column, two traces.

    The run drawn is from the NEIGHBOUR's level to this column's, so a
    steep edge is a vertical line rather than dots -- the whole difference
    between an oscilloscope and confetti.
    """
    let x = Int(global_idx.x)
    let w = Int(width)
    if x >= w:
        return
    let h = Int(height)
    let mid = h // 2
    let half = Float32(h) * 0.5

    # The midline first, so the traces draw over it.
    if (x & 3) == 0:
        plane[unsafe_offset = mid * Int(stride) + x] = UInt8(IX_SCOPE_GRID)

    for tr in range(2):
        let base = tr * w
        var a = samples[unsafe_offset = base + (x - 1 if x > 0 else 0)]
        var b = samples[unsafe_offset = base + x]
        var ya = mid - Int(a * gain * half)
        var yb = mid - Int(b * gain * half)
        if ya > yb:
            let t = ya
            ya = yb
            yb = t
        if ya < 0:
            ya = 0
        if yb > h - 1:
            yb = h - 1
        let ink = UInt8(IX_SCOPE_LEFT if tr == 0 else IX_SCOPE_RIGHT)
        for y in range(ya, yb + 1):
            plane[unsafe_offset = y * Int(stride) + x] = ink


struct ScopeField(Movable):
    """The mix, drawn: feed it the trio, step it, render it over the rest."""

    var width: Int
    var height: Int
    var stride: Int
    var gain: Float32
    var samples: DeviceBuffer[DType.float32]
    var staging: List[Float32]
    var plane: DeviceBuffer[DType.uint8]
    var view: Int
    var palette: List[Float32]
    var palette_buffer: Int
    var palette_dirty: Bool
    var pipeline: Int

    def __init__(
        out self,
        mut ctx: DeviceContext,
        device: Int,
        width: Int,
        height: Int,
    ) raises:
        self.width = width
        self.height = height
        self.gain = 0.92
        self.stride = stride_for(
            width, linear_alignment(device, nsenum["MTLPixelFormatR8Uint"]())
        )
        self.samples = ctx.enqueue_create_buffer[DType.float32](width * 2)
        let sp = host_ptr(self.samples).unsafe_bitcast[Float32]()
        for i in range(width * 2):
            sp[unsafe_offset=i] = 0.0
        self.staging = List[Float32](length=SCOPE_FRAMES * 2, fill=0.0)

        self.plane = ctx.enqueue_create_buffer[DType.uint8](
            self.stride * height
        )
        let pp = host_ptr(self.plane)
        for i in range(self.stride * height):
            pp[unsafe_offset=i] = 0
        self.view = index_plane_view(
            metal_buffer(self.plane), metal_offset(self.plane),
            width, height, self.stride,
        )

        self.palette = List[Float32](length=PARTICLE_PALETTE * 4, fill=0.0)
        let pal = send[ObjCObject, "newBufferWithLength:options:"](
            ObjCObject(device),
            Int(PARTICLE_PALETTE * 16),
            nsenum["MTLResourceStorageModeShared"](),
        )
        if pal.addr() == 0:
            raise Error("scope: no palette buffer")
        self.palette_buffer = pal.addr()
        self.palette_dirty = True
        self.pipeline = _particle_pipeline(device)
        # Inline rather than through set_colour: a method cannot run on a
        # half-built self, and these three ARE the initialisation.
        var ink: List[Float32] = [
            0.10, 0.30, 0.16,        # grid: dim green
            0.35, 1.00, 0.55,        # left trace: phosphor
            0.40, 0.85, 1.00,        # right trace: cyan
        ]
        for k in range(3):
            let slot = IX_SCOPE_GRID + k
            self.palette[slot * 4 + 0] = ink[k * 3 + 0]
            self.palette[slot * 4 + 1] = ink[k * 3 + 1]
            self.palette[slot * 4 + 2] = ink[k * 3 + 2]
            self.palette[slot * 4 + 3] = 1.0

    def set_colour(mut self, slot: Int, r: Float32, g: Float32, b: Float32):
        if slot <= 0 or slot >= PARTICLE_PALETTE:
            return
        self.palette[slot * 4 + 0] = r
        self.palette[slot * 4 + 1] = g
        self.palette[slot * 4 + 2] = b
        self.palette[slot * 4 + 3] = 1.0
        self.palette_dirty = True

    def feed(mut self, t: P) raises:
        """Pull the newest mix from the trio's ring and fold it to columns.

        The fold averages the frames each column covers -- a box filter,
        which for a scope is right: peaks survive, single-sample spikes do
        not lie about the waveform.
        """
        let got = trio_scope_read(
            t,
            Pointer[Float32, MutUntrackedOrigin](
                unsafe_from_address=Int(self.staging.unsafe_ptr())
            ),
            SCOPE_FRAMES,
        )
        if got == 0:
            return
        let per = got // self.width if got >= self.width else 1
        let sp = host_ptr(self.samples).unsafe_bitcast[Float32]()
        for x in range(self.width):
            var l = Float32(0.0)
            var r = Float32(0.0)
            let start = x * got // self.width
            for k in range(per):
                let f = start + k
                if f < got:
                    l += self.staging[f * 2]
                    r += self.staging[f * 2 + 1]
            sp[unsafe_offset=x] = l / Float32(per)
            sp[unsafe_offset = self.width + x] = r / Float32(per)

    def step(mut self, mut ctx: DeviceContext) raises:
        """Clear the strip and draw both traces: two kernels a frame."""
        var clear = ctx.compile_function[blit_fill_kernel]()
        ctx.enqueue_function(
            clear, self.plane, Int32(self.stride),
            Int32(0), Int32(0), Int32(self.width), Int32(self.height),
            UInt8(0),
            grid_dim=(blit_grid(self.width), blit_grid(self.height)),
            block_dim=(BLOCK, BLOCK),
        )
        var plot = ctx.compile_function[scope_plot_kernel]()
        ctx.enqueue_function(
            plot, self.samples, self.plane,
            Int32(self.stride), Int32(self.width), Int32(self.height),
            self.gain,
            grid_dim=((self.width + 255) // 256,),
            block_dim=(256,),
        )

    def render(mut self, frame: Frame) raises:
        if not frame.valid:
            return
        if self.palette_dirty:
            let pp = Pointer[Float32, MutUntrackedOrigin](
                unsafe_from_address=Int(
                    send[ObjCObject, "contents"](
                        ObjCObject(self.palette_buffer)
                    ).addr()
                )
            )
            for i in range(PARTICLE_PALETTE * 4):
                pp[unsafe_offset=i] = self.palette[i]
            self.palette_dirty = False
        var uni = ParticleUniforms(Float32(self.width), Float32(self.height))
        let pass_desc = ObjCObject(
            Cls["MTLRenderPassDescriptor"]().renderPassDescriptor().id
        )
        let c0 = send[ObjCObject, "objectAtIndexedSubscript:"](
            send[ObjCObject, "colorAttachments"](pass_desc), Int(0)
        )
        _ = send[ObjCObject, "setTexture:"](c0, ObjCObject(frame.target).ptr())
        _ = send[ObjCObject, "setLoadAction:"](c0, nsenum["MTLLoadActionLoad"]())
        _ = send[ObjCObject, "setStoreAction:"](
            c0, nsenum["MTLStoreActionStore"]()
        )
        let enc = send[ObjCObject, "renderCommandEncoderWithDescriptor:"](
            ObjCObject(frame.cb), pass_desc.ptr()
        )
        _ = send[ObjCObject, "setRenderPipelineState:"](
            enc, ObjCObject(self.pipeline).ptr()
        )
        _ = send[ObjCObject, "setFragmentBytes:length:atIndex:"](
            enc, Pointer(to=uni).unsafe_bitcast[NoneType]()[], Int(8), Int(0)
        )
        _ = send[ObjCObject, "setFragmentTexture:atIndex:"](
            enc, ObjCObject(self.view).ptr(), Int(0)
        )
        _ = send[ObjCObject, "setFragmentBuffer:offset:atIndex:"](
            enc, ObjCObject(self.palette_buffer).ptr(), Int(0), Int(1)
        )
        _ = send[ObjCObject, "drawPrimitives:vertexStart:vertexCount:"](
            enc, nsenum["MTLPrimitiveTypeTriangle"](), Int(0), Int(3)
        )
        _ = send[ObjCObject, "endEncoding"](enc)
