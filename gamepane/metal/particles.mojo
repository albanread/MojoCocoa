"""The particle field: two Mojo GPU kernels and the plane they scatter into.

This is the first thing in the package that gives the kernels real work. The
blitter moves rectangles, which a CPU loop would manage; this integrates
thousands of independent particles every frame, which is what one thread per
element is actually for.

Per frame: clear the plane, then step every particle -- advance it under
gravity, age it, decide by a hash whether this is a frame it is drawn on,
and scatter it into the plane. One kernel does the whole of the second half,
so a particle's state and its pixel are written by the same thread and
nothing has to be read back.

The plane is an ordinary 8-bit index plane with a linear texture view, like
every other plane here, and the fragment shader is the same shape as the
direct pane's: sample the index, discard on 0, look the colour up. So the
debris composites over the game for free.
"""

from std.gpu import global_idx
from std.memory import Pointer
from std.objc import Cls, ObjCObject, send, nsenum, nsstring
from max.gpu.host import DeviceContext, DeviceBuffer

from gamepane.api import (
    P, stride_for, particle_colour, burst_velocity,
    PARTICLE_COLOURS_PER_DEF,
)
from .window import Frame
from .device import (
    metal_buffer, metal_offset, host_ptr, linear_alignment, index_plane_view,
)
from .blitter import blit_fill_kernel, blit_grid, BLOCK


comptime PARTICLE_PALETTE = 256


# The shader: the direct pane's, plus a discard. Index 0 is transparent
# everywhere in this package, and a plane of debris is almost entirely
# index 0 -- so without the discard the field would paint a black rectangle
# over the game.
comptime PARTICLE_SHADER = String(
    """
#include <metal_stdlib>
using namespace metal;
struct VOut { float4 pos [[position]]; float2 uv; };
struct U { float w; float h; };
vertex VOut vmain(uint vid [[vertex_id]]) {
    float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
    VOut o;
    o.pos = float4(p[vid], 0, 1);
    o.uv = float2((p[vid].x + 1) * 0.5, 1.0 - (p[vid].y + 1) * 0.5);
    return o;
}
fragment float4 fmain(VOut in [[stage_in]],
                      constant U& u [[buffer(0)]],
                      texture2d<uint> idx [[texture(0)]],
                      constant float4* pal [[buffer(1)]]) {
    uint x = uint(in.uv.x * u.w), y = uint(in.uv.y * u.h);
    if (x >= uint(u.w)) x = uint(u.w) - 1;
    if (y >= uint(u.h)) y = uint(u.h) - 1;
    uint ci = idx.read(uint2(x, y)).r;
    if (ci == 0u) { discard_fragment(); }
    return pal[ci];
}
"""
)


@fieldwise_init
struct ParticleUniforms(Copyable, Movable):
    var w: Float32
    var h: Float32


# ── the kernel ──────────────────────────────────────────────────────────────


def particles_step_kernel(
    px: Pointer[Float32, MutAnyOrigin],
    py: Pointer[Float32, MutAnyOrigin],
    pvx: Pointer[Float32, MutAnyOrigin],
    pvy: Pointer[Float32, MutAnyOrigin],
    life: Pointer[Float32, MutAnyOrigin],
    colour: Pointer[UInt8, MutAnyOrigin],
    plane: Pointer[UInt8, MutAnyOrigin],
    stride: Int32,
    width: Int32,
    height: Int32,
    dt: Float32,
    gravity: Float32,
    fade: Float32,
    count: Int32,
    frame: Int32,
):
    """One thread, one particle: integrate, age, thin, scatter.

    All of it in one kernel because a particle's state and its pixel belong
    to the same thread -- splitting them would mean writing the position out
    and reading it back in a second pass for no gain.
    """
    var i = Int(global_idx.x)
    if i >= Int(count):
        return
    var l = life[unsafe_offset=i]
    if l <= 0.0:
        return

    var vy = pvy[unsafe_offset=i] + gravity * dt
    var x = px[unsafe_offset=i] + pvx[unsafe_offset=i] * dt
    var y = py[unsafe_offset=i] + vy * dt
    var nl = l - fade * dt
    px[unsafe_offset=i] = x
    py[unsafe_offset=i] = y
    pvy[unsafe_offset=i] = vy
    life[unsafe_offset=i] = nl
    if nl <= 0.0:
        return

    # THINNING. A hash of the particle and the frame gives each one its own
    # deterministic coin; a particle at life 0.3 comes up heads three times
    # in ten and is drawn on those frames only. Hashing the index as well as
    # the frame is what stops the whole cloud blinking in unison.
    var h = (i * 2654435761 + Int(frame) * 40503) & 0x7FFFFFFF
    h = (h ^ (h >> 13)) & 0x7FFFFFFF
    h = (h * 1274126177) & 0x7FFFFFFF
    var coin = Float32((h >> 7) & 0xFFFF) / 65536.0
    if coin > nl:
        return

    var xi = Int(x)
    var yi = Int(y)
    if xi < 0 or yi < 0 or xi >= Int(width) or yi >= Int(height):
        return
    plane[unsafe_offset = yi * Int(stride) + xi] = colour[unsafe_offset=i]


# ── the field ───────────────────────────────────────────────────────────────


struct ParticleField(Movable):
    """A fixed pool of particles and the plane they scatter into.

    A ROLLING cursor rather than a free list: a new burst overwrites the
    oldest particles still alive. At a few thousand slots that never shows,
    and it means spawning is a write with no search -- which matters when a
    wave-clear spawns everything at once.
    """

    var capacity: Int
    var cursor: Int
    var width: Int
    var height: Int
    var stride: Int
    var frame: Int

    var px: DeviceBuffer[DType.float32]
    var py: DeviceBuffer[DType.float32]
    var pvx: DeviceBuffer[DType.float32]
    var pvy: DeviceBuffer[DType.float32]
    var life: DeviceBuffer[DType.float32]
    var colour: DeviceBuffer[DType.uint8]
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
        capacity: Int = 8192,
    ) raises:
        self.capacity = capacity
        self.cursor = 0
        self.width = width
        self.height = height
        self.frame = 0
        self.stride = stride_for(
            width, linear_alignment(device, nsenum["MTLPixelFormatR8Uint"]())
        )

        self.px = ctx.enqueue_create_buffer[DType.float32](capacity)
        self.py = ctx.enqueue_create_buffer[DType.float32](capacity)
        self.pvx = ctx.enqueue_create_buffer[DType.float32](capacity)
        self.pvy = ctx.enqueue_create_buffer[DType.float32](capacity)
        self.life = ctx.enqueue_create_buffer[DType.float32](capacity)
        self.colour = ctx.enqueue_create_buffer[DType.uint8](capacity)
        let lp = host_ptr(self.life)
        for i in range(capacity * 4):
            lp[unsafe_offset=i] = 0            # every slot starts dead

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
        for i in range(PARTICLE_PALETTE):
            self.palette[i * 4 + 3] = 1.0
        let pal = send[ObjCObject, "newBufferWithLength:options:"](
            ObjCObject(device),
            Int(PARTICLE_PALETTE * 16),
            nsenum["MTLResourceStorageModeShared"](),
        )
        if pal.addr() == 0:
            raise Error("particles: no palette buffer")
        self.palette_buffer = pal.addr()
        self.palette_dirty = True
        self.pipeline = _particle_pipeline(device)

    def set_colour(mut self, slot: Int, r: Float32, g: Float32, b: Float32):
        """One entry of the shared table. `particle_colour` says which."""
        if slot <= 0 or slot >= PARTICLE_PALETTE:
            return
        self.palette[slot * 4 + 0] = r
        self.palette[slot * 4 + 1] = g
        self.palette[slot * 4 + 2] = b
        self.palette[slot * 4 + 3] = 1.0
        self.palette_dirty = True

    def spawn(
        mut self,
        rows: Span[UInt8, _],
        src_w: Int,
        src_h: Int,
        src_stride: Int,
        definition: Int,
        cx: Float64,
        cy: Float64,
        scale: Float64,
        speed: Float64,
        seed: Int,
    ) raises -> Int:
        """Turn a sprite frame into debris. Returns how many particles.

        `rows` is the frame's index bytes -- the sprite's OWN pixels, which
        is the whole point: the colours are not chosen, they are whatever
        that alien was made of.
        """
        let xs = host_ptr(self.px)
        let ys = host_ptr(self.py)
        let vxs = host_ptr(self.pvx)
        let vys = host_ptr(self.pvy)
        let ls = host_ptr(self.life)
        let cs = host_ptr(self.colour)
        var fx = xs.unsafe_bitcast[Float32]()
        var fy = ys.unsafe_bitcast[Float32]()
        var fvx = vxs.unsafe_bitcast[Float32]()
        var fvy = vys.unsafe_bitcast[Float32]()
        var fl = ls.unsafe_bitcast[Float32]()

        var made = 0
        var rng = seed | 1
        let half_w = Float64(src_w) / 2.0
        let half_h = Float64(src_h) / 2.0
        for y in range(src_h):
            for x in range(src_w):
                let at = y * src_stride + x
                if at >= len(rows):
                    continue
                let idx = Int(rows[at])
                if idx == 0:
                    continue
                # A cheap xorshift, so a burst is ragged without a call.
                rng = (rng ^ (rng << 13)) & 0x7FFFFFFF
                rng = rng ^ (rng >> 17)
                rng = (rng ^ (rng << 5)) & 0x7FFFFFFF
                let jitter = Float64(rng & 0xFFFF) / 65536.0 * 0.8 - 0.2

                let dx = Float64(x) - half_w
                let dy = Float64(y) - half_h
                let v = burst_velocity(dx, dy, speed, jitter)

                let s = self.cursor
                fx[unsafe_offset=s] = Float32(cx + dx * scale)
                fy[unsafe_offset=s] = Float32(cy + dy * scale)
                fvx[unsafe_offset=s] = Float32(v[0])
                fvy[unsafe_offset=s] = Float32(v[1] - speed * 0.35)
                fl[unsafe_offset=s] = Float32(0.75 + jitter * 0.3)
                cs[unsafe_offset=s] = UInt8(particle_colour(definition, idx))
                self.cursor = (s + 1) % self.capacity
                made += 1
        return made

    def step(
        mut self, mut ctx: DeviceContext, dt: Float64,
        gravity: Float64 = 260.0, fade: Float64 = 0.85,
    ) raises:
        """Clear the plane and advance every particle -- two kernels, and
        the only per-frame GPU compute in the package."""
        self.frame += 1
        var clear = ctx.compile_function[blit_fill_kernel]()
        ctx.enqueue_function(
            clear, self.plane, Int32(self.stride),
            Int32(0), Int32(0), Int32(self.width), Int32(self.height),
            UInt8(0),
            grid_dim=(blit_grid(self.width), blit_grid(self.height)),
            block_dim=(BLOCK, BLOCK),
        )
        var step = ctx.compile_function[particles_step_kernel]()
        ctx.enqueue_function(
            step,
            self.px, self.py, self.pvx, self.pvy, self.life, self.colour,
            self.plane,
            Int32(self.stride), Int32(self.width), Int32(self.height),
            Float32(dt), Float32(gravity), Float32(fade),
            Int32(self.capacity), Int32(self.frame),
            grid_dim=((self.capacity + 255) // 256,),
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


def _particle_pipeline(device: Int) raises -> Int:
    let dev = ObjCObject(device)
    var err = ObjCObject(0)
    let lib = send[ObjCObject, "newLibraryWithSource:options:error:"](
        dev, nsstring(PARTICLE_SHADER).ptr(), ObjCObject(0).ptr(),
        Pointer(to=err).unsafe_bitcast[ObjCObject]()[],
    )
    if lib.addr() == 0:
        raise Error("particle shader did not compile")
    let vfn = send[ObjCObject, "newFunctionWithName:"](
        lib, nsstring(String("vmain")).ptr()
    )
    let ffn = send[ObjCObject, "newFunctionWithName:"](
        lib, nsstring(String("fmain")).ptr()
    )
    let desc = send[ObjCObject, "init"](
        ObjCObject(Cls["MTLRenderPipelineDescriptor"]().alloc().id)
    )
    _ = send[ObjCObject, "setVertexFunction:"](desc, vfn.ptr())
    _ = send[ObjCObject, "setFragmentFunction:"](desc, ffn.ptr())
    let att = send[ObjCObject, "objectAtIndexedSubscript:"](
        send[ObjCObject, "colorAttachments"](desc), Int(0)
    )
    _ = send[ObjCObject, "setPixelFormat:"](
        att, nsenum["MTLPixelFormatBGRA8Unorm"]()
    )
    var perr = ObjCObject(0)
    let pipeline = send[
        ObjCObject, "newRenderPipelineStateWithDescriptor:error:"
    ](dev, desc.ptr(), Pointer(to=perr).unsafe_bitcast[ObjCObject]()[])
    if pipeline.addr() == 0:
        raise Error("particle pipeline failed to build")
    return pipeline.addr()
