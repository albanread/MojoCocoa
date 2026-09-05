"""The render pipelines, and the MSL that defines what each layer means.

G2 brings the two layers that have no drawing API of their own, so they are
the smallest and the clearest statement of the pattern every later layer
follows: compile MSL at runtime, build one `MTLRenderPipelineState`, and
then per frame open a render pass on the frame's drawable, bind, draw three
vertices, end. The full-screen triangle comes from `vertex_id` alone, so
there is no vertex buffer anywhere in this file.

**The MSL is ported verbatim from the Rust.** Those strings are the
specification of each layer's behaviour -- the exact `uv` flip, the exact
clamp, the exact palette indexing -- and paraphrasing them would silently
change what a ported game looks like. They are quoted, not rewritten.

Objects made by a `new…` selector arrive owned. The panes hold them for the
life of the program and never release them, which is a leak of a fixed and
tiny number of objects and the honest trade for not tracking ownership of a
pipeline that exists until the window closes.
"""

from std.objc import (
    Cls,
    Obj,
    ObjCObject,
    send,
    nsenum,
    nsstring,
    ns_to_string,
    autoreleasepool,
)
from std.memory import Pointer
from std.time import perf_counter_ns

from max.gpu.host import DeviceContext, DeviceBuffer

from gamepane.api import (
    ShaderParams,
    Palette,
    PALETTE_SIZE,
    stride_for,
    buffer_len_for,
    Plane,
    NUM_BUFFERS,
    FRONT,
    BACK,
    GLOBAL_COLORS,
    palette_entries,
    palette_global_base,
    palette_line_entry,
    palette_global_entry,
    hsv_to_rgb,
    clamp_scroll,
)
from .window import Frame
from .device import (
    metal_buffer, metal_offset, host_ptr, linear_alignment, index_plane_view,
)


comptime DIRECT_BUFFERS = 3
"""Rotating write buffers for the direct pane.

Three is the number that lets the host write one while the GPU may still be
reading the one before it, with a frame of slack left over -- which is what
makes tearing a non-problem with no completion handler and no fence. One
would be the obvious upgrade if measurement ever showed a tear; it is not
needed to be correct.
"""


# The vertex half every layer shares: a triangle big enough to cover the
# screen, generated from vertex_id, with `uv` flipped so (0,0) is top-left.
# Quoted from the Rust `HEADER`.
comptime SHADER_HEADER = String(
    """
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; float2 uv; };
struct Uniforms { float time; float aspect; float p[8]; };

vertex VOut vmain(uint vid [[vertex_id]]) {
    float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    VOut out;
    float2 pos = positions[vid];
    out.pos = float4(pos, 0.0, 1.0);
    out.uv = float2((pos.x + 1.0) * 0.5, 1.0 - (pos.y + 1.0) * 0.5);
    return out;
}
"""
)


# The direct pane's whole shader, quoted from the Rust `SHADER`: sample the
# index plane as an unsigned texture, look the colour up in the palette
# buffer. No discard -- unlike the indexed pane, index 0 is a colour here.
comptime DIRECT_SHADER = String(
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
    return pal[idx.read(uint2(x, y)).r];
}
"""
)


@fieldwise_init
struct DirectUniforms(Copyable, Movable):
    """`struct U { float w; float h; }` -- eight bytes at buffer 0."""

    var w: Float32
    var h: Float32


def _error_text(err: ObjCObject) -> String:
    """An NSError's localizedDescription, or empty when there is none."""
    if err.addr() == 0:
        return String()
    return ns_to_string(
        ObjCObject(Obj["NSError"](err.addr()).localizedDescription().id)
    )


def _build_pipeline(device: Int, source: String, what: String) raises -> Int:
    """Compile `source`, take its `vmain`/`fmain`, and return a pipeline
    state that writes BGRA8Unorm. Raises with the compiler's own message,
    because a shader error a caller cannot read is not an error report."""
    let dev = ObjCObject(device)

    var err = ObjCObject(0)
    let lib = send[ObjCObject, "newLibraryWithSource:options:error:"](
        dev,
        nsstring(source).ptr(),
        ObjCObject(0).ptr(),
        Pointer(to=err).unsafe_bitcast[ObjCObject]()[],
    )
    if lib.addr() == 0:
        raise Error(String(what) + " did not compile: " + _error_text(err))

    let vfn = send[ObjCObject, "newFunctionWithName:"](
        lib, nsstring(String("vmain")).ptr()
    )
    let ffn = send[ObjCObject, "newFunctionWithName:"](
        lib, nsstring(String("fmain")).ptr()
    )
    # An empty source compiles cleanly; it is asking for the function that
    # fails, so this -- not the compile -- is where a missing fmain lands.
    if vfn.addr() == 0:
        raise Error(String(what) + " has no vmain")
    if ffn.addr() == 0:
        raise Error(String(what) + " has no fmain")

    let desc = send[ObjCObject, "init"](
        ObjCObject(Cls["MTLRenderPipelineDescriptor"]().alloc().id)
    )
    _ = send[ObjCObject, "setVertexFunction:"](desc, vfn.ptr())
    _ = send[ObjCObject, "setFragmentFunction:"](desc, ffn.ptr())
    let att0 = send[ObjCObject, "objectAtIndexedSubscript:"](
        send[ObjCObject, "colorAttachments"](desc), Int(0)
    )
    _ = send[ObjCObject, "setPixelFormat:"](
        att0, nsenum["MTLPixelFormatBGRA8Unorm"]()
    )

    var perr = ObjCObject(0)
    let pipeline = send[
        ObjCObject, "newRenderPipelineStateWithDescriptor:error:"
    ](dev, desc.ptr(), Pointer(to=perr).unsafe_bitcast[ObjCObject]()[])
    if pipeline.addr() == 0:
        raise Error(String(what) + " pipeline: " + _error_text(perr))
    return pipeline.addr()


def _begin_pass(frame: Frame, clear: Bool) raises -> Int:
    """Open a render pass on the frame's drawable. `clear` picks the load
    action, which is the entire difference between being layer 0 and being
    a layer above it: Clear paints the ground, Load composites onto what is
    already there."""
    let pass_desc = ObjCObject(
        Cls["MTLRenderPassDescriptor"]().renderPassDescriptor().id
    )
    let c0 = send[ObjCObject, "objectAtIndexedSubscript:"](
        send[ObjCObject, "colorAttachments"](pass_desc), Int(0)
    )
    _ = send[ObjCObject, "setTexture:"](c0, ObjCObject(frame.target).ptr())
    if clear:
        _ = send[ObjCObject, "setLoadAction:"](
            c0, nsenum["MTLLoadActionClear"]()
        )
    else:
        _ = send[ObjCObject, "setLoadAction:"](
            c0, nsenum["MTLLoadActionLoad"]()
        )
    _ = send[ObjCObject, "setStoreAction:"](c0, nsenum["MTLStoreActionStore"]())
    let enc = send[ObjCObject, "renderCommandEncoderWithDescriptor:"](
        ObjCObject(frame.cb), pass_desc.ptr()
    )
    return enc.addr()


# ── Layer 0: the shader pane ────────────────────────────────────────────────


struct ShaderPane(Movable):
    """A full-screen fragment shader and ten floats.

    The caller supplies only `fmain`; the header above supplies `vmain`,
    `VOut` and `Uniforms`, so a shader is a single function and a game can
    carry one as a string. Always `Clear`: this is layer 0, and whatever it
    draws is the base every other layer composites over.
    """

    var pipeline: Int
    var params: ShaderParams
    var start_ns: Int

    def __init__(out self, device: Int, frag_msl: String) raises:
        self.pipeline = _build_pipeline(
            device, SHADER_HEADER + "\n" + frag_msl, String("shader pane")
        )
        self.params = ShaderParams()
        self.start_ns = Int(perf_counter_ns())

    def set_param(mut self, i: Int, value: Float32):
        """`u.p[i]`, for `i` in 0..8. Out of range is ignored."""
        self.params.set_param(i, value)

    def param(self, i: Int) -> Float32:
        return self.params.param(i)

    def set_aspect(mut self, aspect: Float32):
        self.params.set_aspect(aspect)

    def time(self) -> Float32:
        """Seconds since this pane was created -- what `u.time` carries."""
        return Float32(Float64(Int(perf_counter_ns()) - self.start_ns) / 1e9)

    def render(mut self, frame: Frame) raises:
        if not frame.valid:
            return
        self.params.set_time(self.time())
        let enc = ObjCObject(_begin_pass(frame, True))
        _ = send[ObjCObject, "setRenderPipelineState:"](
            enc, ObjCObject(self.pipeline).ptr()
        )
        _ = send[ObjCObject, "setFragmentBytes:length:atIndex:"](
            enc,
            self.params.v.unsafe_ptr().unsafe_bitcast[NoneType](),
            self.params.byte_length(),
            Int(0),
        )
        _ = send[ObjCObject, "drawPrimitives:vertexStart:vertexCount:"](
            enc, nsenum["MTLPrimitiveTypeTriangle"](), Int(0), Int(3)
        )
        _ = send[ObjCObject, "endEncoding"](enc)


# ── The direct pane: a framebuffer the game writes itself ───────────────────


struct DirectPane(Movable):
    """A palette-indexed screen the host writes straight into.

    No command protocol, no upload, no copy: the bytes the game stores are
    the bytes the GPU reads. That works because Apple silicon is unified
    memory, so a Shared buffer's `contents` is ordinary CPU-writable memory
    and a LINEAR texture view over that same buffer is what the shader
    samples. Nothing copies them, and no thread owns the write -- Metal does
    not care which thread stores into a shared buffer; what has thread
    affinity is command encoding and presenting, neither of which happens
    when a game writes a pixel.
    """

    var width: Int
    var height: Int
    var stride: Int
    var buffers: List[Int]
    var textures: List[Int]
    var write: Int
    var palette: Palette
    var palette_buffer: Int
    var pipeline: Int

    def __init__(out self, device: Int, width: Int, height: Int) raises:
        if width <= 0 or height <= 0:
            raise Error("direct pane needs a non-zero size")
        let dev = ObjCObject(device)

        # The alignment the device demands for a buffer-backed R8Uint
        # texture. Rounding the row up to it is what makes
        # newTextureWithDescriptor:offset:bytesPerRow: legal at all, and it
        # is where the stride comes from.
        let align = Int(
            send[Int, "minimumLinearTextureAlignmentForPixelFormat:"](
                dev, nsenum["MTLPixelFormatR8Uint"]()
            )
        )
        self.width = width
        self.height = height
        self.stride = stride_for(width, align)

        let tdesc = ObjCObject(
            Cls["MTLTextureDescriptor"]()
            .texture2DDescriptorWithPixelFormat_width_height_mipmapped(
                nsenum["MTLPixelFormatR8Uint"](), width, height, False
            )
            .id
        )
        _ = send[ObjCObject, "setUsage:"](
            tdesc, nsenum["MTLTextureUsageShaderRead"]()
        )
        # A buffer-backed texture must be described with the SAME storage
        # mode as the buffer it views, which the convenience descriptor does
        # not know.
        _ = send[ObjCObject, "setStorageMode:"](
            tdesc, nsenum["MTLStorageModeShared"]()
        )

        let bytes = buffer_len_for(self.stride, height)
        self.buffers = List[Int]()
        self.textures = List[Int]()
        for _ in range(DIRECT_BUFFERS):
            let buf = send[ObjCObject, "newBufferWithLength:options:"](
                dev, bytes, nsenum["MTLResourceStorageModeShared"]()
            )
            if buf.addr() == 0:
                raise Error("direct pane: no buffer")
            # Zero it: a fresh buffer is whatever the allocator had, and a
            # demo's first frame should be a colour, not garbage.
            let p = Pointer[UInt8, MutUntrackedOrigin](
                unsafe_from_address=Int(
                    send[ObjCObject, "contents"](buf).addr()
                )
            )
            for i in range(bytes):
                p[unsafe_offset=i] = 0
            let tex = send[
                ObjCObject, "newTextureWithDescriptor:offset:bytesPerRow:"
            ](buf, tdesc.ptr(), Int(0), self.stride)
            if tex.addr() == 0:
                raise Error("direct pane: no texture view over the buffer")
            self.buffers.append(buf.addr())
            self.textures.append(tex.addr())

        self.write = 0
        self.palette = Palette()
        let pal = send[ObjCObject, "newBufferWithLength:options:"](
            dev,
            Int(PALETTE_SIZE * 16),
            nsenum["MTLResourceStorageModeShared"](),
        )
        if pal.addr() == 0:
            raise Error("direct pane: no palette buffer")
        self.palette_buffer = pal.addr()
        self.pipeline = _build_pipeline(
            device, DIRECT_SHADER, String("direct pane")
        )

    def stride_bytes(self) -> Int:
        """Bytes per row. A writer addresses `fb[y * stride_bytes() + x]`."""
        return self.stride

    def buffer_len(self) -> Int:
        """Total writable bytes in one buffer -- `stride * height`."""
        return buffer_len_for(self.stride, self.height)

    def buffer_count(self) -> Int:
        return DIRECT_BUFFERS

    def backbuffer_ptr(self) -> Pointer[UInt8, MutUntrackedOrigin]:
        """The buffer to write RIGHT NOW. Changes after every `render`.

        Prefer `buffer_ptrs` when the writer counts its own frames: it
        cannot observe this rotation at the instant `render` performs it, so
        asking for "the current one" races. Publish the whole set instead
        and let both sides pick by frame number.
        """
        return Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=Int(
                send[ObjCObject, "contents"](
                    ObjCObject(self.buffers[self.write])
                ).addr()
            )
        )

    def buffer_ptrs(self) raises -> List[Int]:
        """Every buffer's base address, in rotation order. `render` draws
        buffer `n % count` for the nth frame, so a writer counting frames
        the same way agrees which buffer is safe with no synchronisation."""
        var out = List[Int]()
        for i in range(DIRECT_BUFFERS):
            out.append(
                Int(
                    send[ObjCObject, "contents"](
                        ObjCObject(self.buffers[i])
                    ).addr()
                )
            )
        return out^

    def set_rgb(mut self, index: Int, r: Int, g: Int, b: Int):
        self.palette.set_rgb(index, r, g, b)

    def render(mut self, frame: Frame) raises:
        """Draw the buffer the host just wrote, then rotate so the next
        thing it writes is a buffer the GPU is not reading."""
        if not frame.valid:
            return
        if self.palette.dirty:
            let pp = Pointer[Float32, MutUntrackedOrigin](
                unsafe_from_address=Int(
                    send[ObjCObject, "contents"](
                        ObjCObject(self.palette_buffer)
                    ).addr()
                )
            )
            for i in range(len(self.palette.v)):
                pp[unsafe_offset=i] = self.palette.v[i]
            self.palette.dirty = False

        # `var`, not `let`: a `let` binds to self.write by reference, so
        # the rotation at the end of this function would change what `drawn`
        # reads. Harmless today because every use precedes the write, and a
        # trap the moment anyone adds a use after it -- the compiler says so.
        var drawn = self.write
        var uni = DirectUniforms(Float32(self.width), Float32(self.height))

        let enc = ObjCObject(_begin_pass(frame, True))
        _ = send[ObjCObject, "setRenderPipelineState:"](
            enc, ObjCObject(self.pipeline).ptr()
        )
        _ = send[ObjCObject, "setFragmentBytes:length:atIndex:"](
            enc,
            Pointer(to=uni).unsafe_bitcast[NoneType]()[],
            Int(8),
            Int(0),
        )
        _ = send[ObjCObject, "setFragmentTexture:atIndex:"](
            enc, ObjCObject(self.textures[drawn]).ptr(), Int(0)
        )
        _ = send[ObjCObject, "setFragmentBuffer:offset:atIndex:"](
            enc, ObjCObject(self.palette_buffer).ptr(), Int(0), Int(1)
        )
        _ = send[ObjCObject, "drawPrimitives:vertexStart:vertexCount:"](
            enc, nsenum["MTLPrimitiveTypeTriangle"](), Int(0), Int(3)
        )
        _ = send[ObjCObject, "endEncoding"](enc)

        self.write = (drawn + 1) % DIRECT_BUFFERS


# ── Layer 1: the indexed pane ───────────────────────────────────────────────


# Quoted verbatim from the Rust `HEADER` in indexed_pane.rs. Three things are
# specification rather than style: index 0 discards (so the layer below shows
# through), the scroll offset is added in WORLD space after the viewport
# lookup (so panning costs nothing), and the palette index splits at 16 into
# per-scanline and global halves.
comptime INDEXED_SHADER = String(
    """
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; float2 uv; };
struct Uniforms { float scroll_x; float scroll_y; float viewport_w; float viewport_h; };

vertex VOut vmain(uint vid [[vertex_id]]) {
    float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    VOut out;
    float2 pos = positions[vid];
    out.pos = float4(pos, 0.0, 1.0);
    out.uv = float2((pos.x + 1.0) * 0.5, 1.0 - (pos.y + 1.0) * 0.5);
    return out;
}

fragment float4 fmain(VOut in [[stage_in]],
                       constant Uniforms& u [[buffer(0)]],
                       texture2d<uint> indexTex [[texture(0)]],
                       constant uchar4* palette [[buffer(1)]]) {
    uint screenX = uint(in.uv.x * u.viewport_w);
    uint screenY = uint(in.uv.y * u.viewport_h);
    uint worldX = uint(int(screenX) + int(u.scroll_x));
    uint worldY = uint(int(screenY) + int(u.scroll_y));
    uint ci = indexTex.read(uint2(worldX, worldY)).r;
    if (ci == 0u) { discard_fragment(); }
    uint k;
    if (ci < 16u) { k = screenY * 16u + ci; } else { k = uint(u.viewport_h) * 16u + (ci - 16u); }
    // The palette is RGBA BYTES, not floats: four bytes an entry instead of
    // sixteen, no conversion when a demo sets a colour, and -- the reason it
    // matters -- a layout a guest VM can write directly with ordinary byte
    // stores. Normalising here is one divide in the shader.
    return float4(palette[k]) / 255.0;
}
"""
)


@fieldwise_init
struct IndexedUniforms(Copyable, Movable):
    """`Uniforms{scroll_x, scroll_y, viewport_w, viewport_h}` at buffer 0."""

    var scroll_x: Float32
    var scroll_y: Float32
    var viewport_w: Float32
    var viewport_h: Float32


struct IndexedPane(Movable):
    """Eight index planes, a per-line palette, and a world larger than the
    viewport that the compositor pans across.

    **There is no CPU mirror.** The Rust keeps a `Vec<u8>` per slot, marks it
    dirty, and pushes it to a texture in an `upload()` every frame; here each
    slot is one `DeviceBuffer` with a linear texture view over it, so `pset`
    stores into the exact bytes the fragment shader samples. That deletes the
    mirror, the dirty flags, the upload, and the reason the Rust's blitter
    had to apply every operation twice.

    The overscan is the other half of the same idea: draw once into a world
    bigger than the screen, then move `set_scroll` instead of redrawing.
    """

    var world_width: Int
    var world_height: Int
    var viewport_width: Int
    var viewport_height: Int
    var stride: Int
    var scroll_x: Int
    var scroll_y: Int
    var active: Int
    # The DeviceBuffers, and they MUST be held: the texture views below are
    # borrows over them, and a borrow that outlives its owner is a message to
    # freed memory.
    var planes: List[DeviceBuffer[DType.uint8]]
    var bases: List[Int]
    var views: List[Int]
    # Logical slot -> physical index. swap_buffers permutes THIS rather than
    # moving buffers about, which keeps a move-only DeviceBuffer where it was
    # put and makes the swap two integer stores.
    var slot_of: List[Int]
    var palette_len: Int
    var palette_buffer: Int
    var pipeline: Int

    def __init__(
        out self,
        mut ctx: DeviceContext,
        device: Int,
        world_width: Int,
        world_height: Int,
        viewport_width: Int,
        viewport_height: Int,
    ) raises:
        if world_width < viewport_width or world_height < viewport_height:
            raise Error(
                "world size must be >= viewport size (that is the overscan"
                " margin)"
            )
        self.world_width = world_width
        self.world_height = world_height
        self.viewport_width = viewport_width
        self.viewport_height = viewport_height
        self.stride = stride_for(
            world_width,
            linear_alignment(device, nsenum["MTLPixelFormatR8Uint"]()),
        )
        self.scroll_x = 0
        self.scroll_y = 0
        self.active = FRONT

        self.planes = List[DeviceBuffer[DType.uint8]]()
        self.bases = List[Int]()
        self.views = List[Int]()
        self.slot_of = List[Int]()
        let bytes = self.stride * world_height
        for i in range(NUM_BUFFERS):
            var buf = ctx.enqueue_create_buffer[DType.uint8](bytes)
            let base = host_ptr(buf)
            for b in range(bytes):
                base[unsafe_offset=b] = 0
            let view = index_plane_view(
                metal_buffer(buf),
                metal_offset(buf),
                world_width,
                world_height,
                self.stride,
            )
            self.bases.append(Int(base))
            self.views.append(view)
            self.slot_of.append(i)
            self.planes.append(buf^)

        # The palette lives HERE and nowhere else. There is nothing to upload
        # FROM, so nothing can copy a stale mirror over a game's work -- which
        # is exactly what a mirror would do the moment a guest wrote to it.
        self.palette_len = palette_entries(viewport_height)
        let pal = send[ObjCObject, "newBufferWithLength:options:"](
            ObjCObject(device),
            self.palette_len * 4,
            nsenum["MTLResourceStorageModeShared"](),
        )
        if pal.addr() == 0:
            raise Error("indexed pane: no palette buffer")
        self.palette_buffer = pal.addr()
        let pp = Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=Int(send[ObjCObject, "contents"](pal).addr())
        )
        for i in range(self.palette_len):
            pp[unsafe_offset = i * 4 + 0] = 0
            pp[unsafe_offset = i * 4 + 1] = 0
            pp[unsafe_offset = i * 4 + 2] = 0
            pp[unsafe_offset = i * 4 + 3] = 255

        self.pipeline = _build_pipeline(
            device, INDEXED_SHADER, String("indexed pane")
        )
        self.load_default_palette()

    # ── slots ───────────────────────────────────────────────────────────

    def plane(self, slot: Int) -> Plane:
        """The plane for a slot, ready to draw into. Slots out of range give
        the active one rather than trapping."""
        var s = slot
        if s < 0 or s >= NUM_BUFFERS:
            s = self.active
        return Plane(
            Pointer[UInt8, MutUntrackedOrigin](
                unsafe_from_address=self.bases[self.slot_of[s]]
            ),
            self.stride,
            self.world_width,
            self.world_height,
        )

    def active_plane(self) -> Plane:
        return self.plane(self.active)

    def set_active(mut self, slot: Int):
        if slot >= 0 and slot < NUM_BUFFERS:
            self.active = slot

    def swap_buffers(mut self):
        """Exchange FRONT and BACK -- the views and the buffers, never the
        bytes. Two integer stores in the indirection table, so a page flip
        costs the same whatever the world size is."""
        var f = self.slot_of[FRONT]
        self.slot_of[FRONT] = self.slot_of[BACK]
        self.slot_of[BACK] = f
        if self.active == FRONT:
            self.active = BACK
        elif self.active == BACK:
            self.active = FRONT

    # ── scrolling ───────────────────────────────────────────────────────

    def set_scroll(mut self, x: Int, y: Int):
        """Pan the window the compositor reads. Clamped so the viewport
        never reads outside the world."""
        self.scroll_x = clamp_scroll(x, self.world_width, self.viewport_width)
        self.scroll_y = clamp_scroll(
            y, self.world_height, self.viewport_height
        )

    def scroll(self) -> Tuple[Int, Int]:
        return (self.scroll_x, self.scroll_y)

    # ── palette ─────────────────────────────────────────────────────────

    def palette_ptr(self) -> Pointer[UInt8, MutUntrackedOrigin]:
        """The palette bytes themselves, for a writer that wants stores
        rather than calls -- the copper-bars case, where 240 commands a frame
        become none.

        Layout, stated exactly because a writer has to address it:
        `viewport_height` groups of 16 PER-LINE entries first, so line `y`'s
        colour `i` (1..15) is entry `y * 16 + i`; then the 240 GLOBAL
        entries, so index `c` (16..255) is entry `viewport_height * 16 +
        (c - 16)`. Four bytes each, R G B A, and A should be 255.
        """
        return Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=Int(
                send[ObjCObject, "contents"](
                    ObjCObject(self.palette_buffer)
                ).addr()
            )
        )

    def palette_entry_count(self) -> Int:
        return self.palette_len

    def palette_global_start(self) -> Int:
        """Where the 240 global entries begin, in entries."""
        return palette_global_base(self.viewport_height)

    def _write_palette(self, k: Int, r: Int, g: Int, b: Int) raises:
        if k < 0 or k >= self.palette_len:
            return
        let p = self.palette_ptr()
        p[unsafe_offset = k * 4 + 0] = UInt8(r & 255)
        p[unsafe_offset = k * 4 + 1] = UInt8(g & 255)
        p[unsafe_offset = k * 4 + 2] = UInt8(b & 255)
        p[unsafe_offset = k * 4 + 3] = 255

    def set_rgb(self, index: Int, r: Int, g: Int, b: Int) raises:
        """A global colour, index 16..255. Below 16 is per-line and belongs
        to `set_line_rgb`; asking here is a mistake worth naming."""
        if index < 16 or index > 255:
            raise Error(
                "set_rgb: index 0..15 are per-line -- use set_line_rgb"
            )
        self._write_palette(
            palette_global_entry(self.viewport_height, index), r, g, b
        )

    def set_line_rgb(
        self, line: Int, index: Int, r: Int, g: Int, b: Int
    ) raises:
        """A per-scanline colour: index 1..15, line within the viewport.
        Index 0 is transparent and is never assignable."""
        if index < 1 or index > 15:
            raise Error(
                "set_line_rgb: index 1..15 are per-line -- use set_rgb for"
                " 16..255"
            )
        if line < 0 or line >= self.viewport_height:
            raise Error("set_line_rgb: line out of range")
        self._write_palette(palette_line_entry(line, index), r, g, b)

    def load_default_palette(self) raises:
        """Something usable before a game says anything: a 16-step grey ramp
        on every line, so per-line effects show up with no setup, and a
        240-step hue wheel for the globals."""
        for line in range(self.viewport_height):
            for index in range(1, 16):
                let v = Float32(index) / 15.0
                let c = Int(v * 255.0)
                self.set_line_rgb(line, index, c, c, c)
        for i in range(GLOBAL_COLORS):
            let rgb = hsv_to_rgb(Float32(i) / Float32(GLOBAL_COLORS), 1.0, 1.0)
            self.set_rgb(16 + i, rgb[0], rgb[1], rgb[2])

    # ── the composite ───────────────────────────────────────────────────

    def render(self, frame: Frame, clear: Bool = False) raises:
        """Composite FRONT at the current scroll offset.

        `clear` is False almost always: this draws OVER whatever the shader
        pane already put there, which is what index 0's `discard_fragment`
        is for. Clear only makes sense when this is the bottom layer of a
        frame.
        """
        if not frame.valid:
            return
        var uni = IndexedUniforms(
            Float32(self.scroll_x),
            Float32(self.scroll_y),
            Float32(self.viewport_width),
            Float32(self.viewport_height),
        )
        let enc = ObjCObject(_begin_pass(frame, clear))
        _ = send[ObjCObject, "setRenderPipelineState:"](
            enc, ObjCObject(self.pipeline).ptr()
        )
        _ = send[ObjCObject, "setFragmentBytes:length:atIndex:"](
            enc, Pointer(to=uni).unsafe_bitcast[NoneType]()[], Int(16), Int(0)
        )
        _ = send[ObjCObject, "setFragmentTexture:atIndex:"](
            enc, ObjCObject(self.views[self.slot_of[FRONT]]).ptr(), Int(0)
        )
        _ = send[ObjCObject, "setFragmentBuffer:offset:atIndex:"](
            enc, ObjCObject(self.palette_buffer).ptr(), Int(0), Int(1)
        )
        _ = send[ObjCObject, "drawPrimitives:vertexStart:vertexCount:"](
            enc, nsenum["MTLPrimitiveTypeTriangle"](), Int(0), Int(3)
        )
        _ = send[ObjCObject, "endEncoding"](enc)
