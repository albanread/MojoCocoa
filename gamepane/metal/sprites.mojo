"""Layer 2: sprites, composited by the GPU.

This layer draws QUADS. It never writes into the indexed pane's planes and
never goes near the blitter: each visible instance is a textured quad in
this layer's own render pass, blended source-alpha over whatever the layers
below already put on the drawable. That is what makes per-instance scale,
rotation and alpha cost nothing, and it is why a sprite that moves does not
have to repair the background it was covering -- there is no background
underneath it, only an earlier pass.

Per DEFINITION, and persisted rather than rebuilt each frame: one index
plane per frame (a `DeviceBuffer` with an `R8Uint` view, the same shape as
every other plane in the pane) and one 16-entry `float4` palette buffer.
Per INSTANCE: nothing on the GPU at all -- the transform is four vertices
computed on the CPU and handed over with `setVertexBytes:`.
"""

from std.objc import Cls, ObjCObject, send, nsenum, nsstring
from std.memory import Pointer
from max.gpu.host import DeviceContext, DeviceBuffer

from gamepane.api import (
    SpriteBitmap,
    SpriteInstance,
    parse_sprite_rows,
    sprites_overlap,
    quad_vertices,
    SPRITE_COLORS,
    stride_for,
)
from .window import Frame
from .device import (
    metal_buffer, metal_offset, host_ptr, linear_alignment, index_plane_view,
)
from .layers import _build_pipeline


# Quoted verbatim from the Rust `SHADER` in sprites.rs. Note what the
# fragment function does NOT do: there is no scroll, no viewport, no
# transform. All of that has already happened on the CPU and arrived as four
# vertex positions, so the shader's only jobs are the texel lookup, the
# transparent-index discard, and folding the instance's alpha into the
# palette colour so the blend stage can do the rest.
comptime SPRITE_SHADER = String(
    """
#include <metal_stdlib>
using namespace metal;

struct VIn { float2 pos; float2 uv; };
struct VOut { float4 pos [[position]]; float2 uv; };
struct Uniforms { float alpha; };

vertex VOut vmain(constant VIn* verts [[buffer(0)]], uint vid [[vertex_id]]) {
    VOut out;
    out.pos = float4(verts[vid].pos, 0.0, 1.0);
    out.uv = verts[vid].uv;
    return out;
}

fragment float4 fmain(VOut in [[stage_in]],
                       constant Uniforms& u [[buffer(0)]],
                       texture2d<uint> indexTex [[texture(0)]],
                       constant float4* palette [[buffer(1)]]) {
    uint2 size = uint2(indexTex.get_width(), indexTex.get_height());
    uint2 texel = uint2(in.uv.x * float(size.x), in.uv.y * float(size.y));
    uint ci = indexTex.read(texel).r;
    if (ci == 0u) { discard_fragment(); }
    float4 c = palette[ci];
    c.a *= u.alpha;
    return c;
}
"""
)


def _build_sprite_pipeline(device: Int) raises -> Int:
    """The same pipeline every other layer builds, plus the blend state.

    Blending is the entire difference between this layer and the ones
    below, so it is not shared with `_build_pipeline`: source-alpha over
    one-minus-source-alpha, on both colour and alpha, which is what makes
    `set_alpha` a fade rather than a switch.
    """
    let dev = ObjCObject(device)
    var err = ObjCObject(0)
    let lib = send[ObjCObject, "newLibraryWithSource:options:error:"](
        dev,
        nsstring(SPRITE_SHADER).ptr(),
        ObjCObject(0).ptr(),
        Pointer(to=err).unsafe_bitcast[ObjCObject]()[],
    )
    if lib.addr() == 0:
        raise Error("sprite shader did not compile")
    let vfn = send[ObjCObject, "newFunctionWithName:"](
        lib, nsstring(String("vmain")).ptr()
    )
    let ffn = send[ObjCObject, "newFunctionWithName:"](
        lib, nsstring(String("fmain")).ptr()
    )
    if vfn.addr() == 0 or ffn.addr() == 0:
        raise Error("sprite shader has no vmain/fmain")

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
    _ = send[ObjCObject, "setBlendingEnabled:"](att0, True)
    _ = send[ObjCObject, "setRgbBlendOperation:"](
        att0, nsenum["MTLBlendOperationAdd"]()
    )
    _ = send[ObjCObject, "setAlphaBlendOperation:"](
        att0, nsenum["MTLBlendOperationAdd"]()
    )
    _ = send[ObjCObject, "setSourceRGBBlendFactor:"](
        att0, nsenum["MTLBlendFactorSourceAlpha"]()
    )
    _ = send[ObjCObject, "setSourceAlphaBlendFactor:"](
        att0, nsenum["MTLBlendFactorSourceAlpha"]()
    )
    _ = send[ObjCObject, "setDestinationRGBBlendFactor:"](
        att0, nsenum["MTLBlendFactorOneMinusSourceAlpha"]()
    )
    _ = send[ObjCObject, "setDestinationAlphaBlendFactor:"](
        att0, nsenum["MTLBlendFactorOneMinusSourceAlpha"]()
    )

    var perr = ObjCObject(0)
    let pipeline = send[
        ObjCObject, "newRenderPipelineStateWithDescriptor:error:"
    ](dev, desc.ptr(), Pointer(to=perr).unsafe_bitcast[ObjCObject]()[])
    if pipeline.addr() == 0:
        raise Error("sprite pipeline failed to build")
    return pipeline.addr()


@fieldwise_init
struct SpriteDef(Movable):
    """One sprite definition: its size, its frames, and its palette.

    The `DeviceBuffer`s are held for the same reason every plane's owner
    holds them -- the texture views are borrows over them, and Mojo destroys
    a value at its last use.
    """

    var width: Int
    var height: Int
    var stride: Int
    var frames: List[DeviceBuffer[DType.uint8]]
    var views: List[Int]
    var palette: List[Float32]
    var palette_buffer: Int
    var palette_dirty: Bool

    def frame_count(self) -> Int:
        return len(self.views)


struct Sprites(Movable):
    """Every definition and every instance, and the one pass that draws
    them."""

    var device: Int
    var defs: List[SpriteDef]
    var instances: List[SpriteInstance]
    var pipeline: Int

    def __init__(out self, device: Int) raises:
        self.device = device
        self.defs = List[SpriteDef]()
        self.instances = List[SpriteInstance]()
        self.pipeline = _build_sprite_pipeline(device)

    # ── definitions ─────────────────────────────────────────────────────

    def _make_plane(
        self, mut ctx: DeviceContext, bmp: SpriteBitmap, stride: Int
    ) raises -> DeviceBuffer[DType.uint8]:
        """One frame's plane, holding the bitmap re-packed to `stride`.

        The view is NOT made here. A move-only value cannot be moved out of
        a tuple, so returning `(buffer, view)` does not compile -- and the
        caller has to hold the buffer anyway, since the view is a borrow
        over it. So it makes the view itself, from the buffer it now owns.
        """
        var buf = ctx.enqueue_create_buffer[DType.uint8](stride * bmp.height)
        let base = host_ptr(buf)
        for y in range(bmp.height):
            for x in range(stride):
                base[unsafe_offset = y * stride + x] = (
                    bmp.pixels[y * bmp.width + x] if x < bmp.width else 0
                )
        return buf^

    def define_sprite(
        mut self, mut ctx: DeviceContext, rows: String
    ) raises -> Int:
        """Define a sprite from its text rows; returns the handle."""
        let bmp = parse_sprite_rows(rows)
        let stride = stride_for(
            bmp.width,
            linear_alignment(self.device, nsenum["MTLPixelFormatR8Uint"]()),
        )
        var plane = self._make_plane(ctx, bmp, stride)
        let view = index_plane_view(
            metal_buffer(plane), metal_offset(plane),
            bmp.width, bmp.height, stride,
        )

        # 16 float4s. Opaque black rather than transparent black, so an
        # index a game never assigns still reads as a colour.
        var pal = List[Float32](length=SPRITE_COLORS * 4, fill=0.0)
        for i in range(SPRITE_COLORS):
            pal[i * 4 + 3] = 1.0
        let pbuf = send[ObjCObject, "newBufferWithLength:options:"](
            ObjCObject(self.device),
            Int(SPRITE_COLORS * 16),
            nsenum["MTLResourceStorageModeShared"](),
        )
        if pbuf.addr() == 0:
            raise Error("sprite: no palette buffer")

        var frames = List[DeviceBuffer[DType.uint8]]()
        var views = List[Int]()
        frames.append(plane^)
        views.append(view)
        self.defs.append(
            SpriteDef(
                bmp.width, bmp.height, stride, frames^, views^, pal^,
                pbuf.addr(), True,
            )
        )
        return len(self.defs) - 1

    def add_frame(
        mut self, mut ctx: DeviceContext, id: Int, rows: String
    ) raises -> Bool:
        """Append another frame. Its dimensions must match the first's --
        a sprite whose frames are different sizes would change size as it
        animated, which is never what anyone meant."""
        if id < 0 or id >= len(self.defs):
            return False
        let bmp = parse_sprite_rows(rows)
        if bmp.width != self.defs[id].width or bmp.height != self.defs[id].height:
            return False
        var plane = self._make_plane(ctx, bmp, self.defs[id].stride)
        let view = index_plane_view(
            metal_buffer(plane), metal_offset(plane),
            bmp.width, bmp.height, self.defs[id].stride,
        )
        self.defs[id].frames.append(plane^)
        self.defs[id].views.append(view)
        return True

    def sprite_rgb(mut self, id: Int, index: Int, r: Int, g: Int, b: Int):
        """A colour in this definition's own 16-entry palette."""
        if id < 0 or id >= len(self.defs):
            return
        if index < 0 or index >= SPRITE_COLORS:
            return
        self.defs[id].palette[index * 4 + 0] = Float32(r) / 255.0
        self.defs[id].palette[index * 4 + 1] = Float32(g) / 255.0
        self.defs[id].palette[index * 4 + 2] = Float32(b) / 255.0
        self.defs[id].palette[index * 4 + 3] = 1.0
        self.defs[id].palette_dirty = True

    def frame_count(self, id: Int) -> Int:
        if id < 0 or id >= len(self.defs):
            return 0
        return self.defs[id].frame_count()

    # ── instances ───────────────────────────────────────────────────────

    def place(mut self, definition: Int, x: Float64, y: Float64) -> Int:
        self.instances.append(SpriteInstance(definition, x, y))
        return len(self.instances) - 1

    def _live(self, inst: Int) -> Bool:
        return inst >= 0 and inst < len(self.instances)

    def move_to(mut self, inst: Int, x: Float64, y: Float64):
        if self._live(inst):
            self.instances[inst].x = x
            self.instances[inst].y = y

    def set_scale(mut self, inst: Int, s: Float64):
        if self._live(inst):
            self.instances[inst].scale = s

    def set_rotation(mut self, inst: Int, degrees: Float64):
        if self._live(inst):
            self.instances[inst].rotation_degrees = degrees

    def set_alpha(mut self, inst: Int, a: Float64):
        """Clamped: an alpha outside 0..1 is a blend factor nobody meant."""
        if self._live(inst):
            var v = a
            if v < 0.0:
                v = 0.0
            elif v > 1.0:
                v = 1.0
            self.instances[inst].alpha = v

    def set_frame(mut self, inst: Int, frame: Int):
        if self._live(inst):
            self.instances[inst].frame = frame

    def animate(mut self, inst: Int, fps: Float64):
        """`fps` above zero cycles frames on every `tick`; zero stops."""
        if self._live(inst):
            self.instances[inst].animate_fps = fps

    def show(mut self, inst: Int):
        if self._live(inst):
            self.instances[inst].visible = True

    def hide(mut self, inst: Int):
        if self._live(inst):
            self.instances[inst].visible = False

    def sprite_x(self, inst: Int) -> Float64:
        return self.instances[inst].x if self._live(inst) else 0.0

    def sprite_y(self, inst: Int) -> Float64:
        return self.instances[inst].y if self._live(inst) else 0.0

    def sprite_frame(self, inst: Int) -> Int:
        return self.instances[inst].frame if self._live(inst) else 0

    def tick(mut self, dt: Float64):
        """Advance every auto-animating instance. Once a frame, before
        `render`."""
        for i in range(len(self.instances)):
            let d = self.instances[i].definition
            if d < 0 or d >= len(self.defs):
                continue
            self.instances[i].advance(dt, self.defs[d].frame_count())

    def hit(self, a: Int, b: Int) -> Bool:
        """Do two instances' scaled bounding boxes overlap?"""
        if not self._live(a) or not self._live(b):
            return False
        let ia = self.instances[a]
        let ib = self.instances[b]
        if ia.definition >= len(self.defs) or ib.definition >= len(self.defs):
            return False
        let da = self.defs[ia.definition]
        let db = self.defs[ib.definition]
        return sprites_overlap(
            ia.x, ia.y,
            Float64(da.width) * ia.scale, Float64(da.height) * ia.scale,
            ib.x, ib.y,
            Float64(db.width) * ib.scale, Float64(db.height) * ib.scale,
        )

    # ── the pass ────────────────────────────────────────────────────────

    def render(
        mut self,
        frame: Frame,
        scroll_x: Float64,
        scroll_y: Float64,
        viewport_w: Float64,
        viewport_h: Float64,
    ) raises:
        """Composite every visible instance over the drawable.

        Always `Load`: sprites draw over whatever the layers below left, and
        the blend state does the rest. The scroll is subtracted here rather
        than stored on the instance, so a sprite placed in world coordinates
        scrolls with the background without being told to.
        """
        if not frame.valid:
            return

        for i in range(len(self.defs)):
            if self.defs[i].palette_dirty:
                let pp = Pointer[Float32, MutUntrackedOrigin](
                    unsafe_from_address=Int(
                        send[ObjCObject, "contents"](
                            ObjCObject(self.defs[i].palette_buffer)
                        ).addr()
                    )
                )
                for k in range(SPRITE_COLORS * 4):
                    pp[unsafe_offset=k] = self.defs[i].palette[k]
                self.defs[i].palette_dirty = False

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

        for i in range(len(self.instances)):
            let inst = self.instances[i]
            if not inst.visible:
                continue
            if inst.definition < 0 or inst.definition >= len(self.defs):
                continue
            let d = self.defs[inst.definition]
            if d.frame_count() == 0:
                continue
            var verts = quad_vertices(
                inst, d.width, d.height,
                scroll_x, scroll_y, viewport_w, viewport_h,
            )
            _ = send[ObjCObject, "setVertexBytes:length:atIndex:"](
                enc,
                verts.unsafe_ptr().unsafe_bitcast[NoneType](),
                Int(len(verts) * 4),
                Int(0),
            )
            var alpha = Float32(inst.alpha)
            _ = send[ObjCObject, "setFragmentBytes:length:atIndex:"](
                enc,
                Pointer(to=alpha).unsafe_bitcast[NoneType]()[],
                Int(4),
                Int(0),
            )
            var f = inst.frame
            if f < 0 or f >= d.frame_count():
                f = 0
            _ = send[ObjCObject, "setFragmentTexture:atIndex:"](
                enc, ObjCObject(d.views[f]).ptr(), Int(0)
            )
            _ = send[ObjCObject, "setFragmentBuffer:offset:atIndex:"](
                enc, ObjCObject(d.palette_buffer).ptr(), Int(0), Int(1)
            )
            _ = send[ObjCObject, "drawPrimitives:vertexStart:vertexCount:"](
                enc, nsenum["MTLPrimitiveTypeTriangleStrip"](), Int(0), Int(4)
            )
        _ = send[ObjCObject, "endEncoding"](enc)
