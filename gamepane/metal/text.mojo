"""Layer 3, both ways: the retained overlay and the cell grid.

`TextOverlay` rasterises glyphs into an RGBA buffer when you call
`draw_text`, and composites that buffer over everything else. It is
RETAINED, which is what makes it right for a title or a label attached to
an object -- and quietly expensive for a HUD, because a picture that has not
changed still costs one call per string per frame, and the only defence is
remembering not to.

`TextPlane` removes the defence by removing the calls. It is a grid of
CELLS in a shared buffer -- four bytes each, `[char, fg, bg, flags]` -- and
a shader that samples a font atlas to draw them. Writing a character is a
byte store; a whole text screen is one copy. There is no call to make too
often.

The honest limit, recorded because it decides what each is FOR: a grid snaps
glyphs to six-pixel boundaries, so it cannot centre a digit in a sixteen-
pixel square or put a card's rank at +3,+4 inside a thirty-four-pixel card.
Object-attached glyphs stay in the overlay, or stay pixel art in the picture
itself. The plane is for text SCREENS -- HUDs, menus, help pages, consoles.

Both blend, and both draw last.
"""

from std.objc import Cls, ObjCObject, send, nsenum, nsstring
from std.memory import Pointer

from gamepane.api import (
    RgbaCanvas,
    glyph_for,
    text_cols,
    text_rows,
    GLYPH_W,
    GLYPH_H,
    CELL_W,
    CELL_H,
    CELL_BYTES,
    FLAG_TRANSPARENT_BG,
)
from .window import Frame, MTLOrigin, MTLSize, MTLRegion


# The overlay's shader, quoted from the Rust: a full-screen triangle and a
# nearest-sampled RGBA texture. The overlay's buffer is already one pixel per
# screen pixel, so the sampler never interpolates -- `filter::nearest` is
# there to say so rather than to do anything.
comptime OVERLAY_SHADER = String(
    """
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut vmain(uint vid [[vertex_id]]) {
    float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    VOut out;
    float2 pos = positions[vid];
    out.pos = float4(pos, 0.0, 1.0);
    out.uv = float2((pos.x + 1.0) * 0.5, 1.0 - (pos.y + 1.0) * 0.5);
    return out;
}

fragment float4 fmain(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(coord::normalized, filter::nearest);
    return tex.sample(s, in.uv);
}
"""
)


# The plane's shader, quoted verbatim. Three rules live in it: char 0 draws
# nothing at all (so an untouched plane is invisible over whatever is
# beneath it), flags bit 0 drops the background, and a lit glyph pixel takes
# fg while an unlit one takes bg.
comptime PLANE_SHADER = String(
    """
#include <metal_stdlib>
using namespace metal;
struct VOut { float4 pos [[position]]; float2 uv; };
struct U { float vw; float vh; float cols; float rows; };
vertex VOut vmain(uint vid [[vertex_id]]) {
    float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
    VOut o;
    o.pos = float4(p[vid], 0, 1);
    o.uv = float2((p[vid].x + 1) * 0.5, 1.0 - (p[vid].y + 1) * 0.5);
    return o;
}
fragment float4 fmain(VOut in [[stage_in]],
                      constant U& u [[buffer(0)]],
                      constant uchar4* cells [[buffer(1)]],
                      constant float4* pal [[buffer(2)]],
                      texture2d<uint> atlas [[texture(0)]]) {
    uint px = uint(in.uv.x * u.vw);
    uint py = uint(in.uv.y * u.vh);
    uint col = px / 6u, row = py / 8u;
    if (col >= uint(u.cols) || row >= uint(u.rows)) return float4(0, 0, 0, 0);
    uchar4 cell = cells[row * uint(u.cols) + col];
    if (cell.x == 0) return float4(0, 0, 0, 0);
    uint gx = px % 6u, gy = py % 8u;
    bool inGlyph = (gx < 5u) && (gy < 7u);
    uint bit = 0;
    if (inGlyph) bit = atlas.read(uint2(gx, uint(cell.x) * 7u + gy)).r;
    if (bit != 0) return float4(pal[cell.y].rgb, 1.0);
    if ((cell.w & 1u) != 0u) return float4(0, 0, 0, 0);
    return float4(pal[cell.z].rgb, 1.0);
}
"""
)


@fieldwise_init
struct PlaneUniforms(Copyable, Movable):
    var vw: Float32
    var vh: Float32
    var cols: Float32
    var rows: Float32


def _blend_pipeline(device: Int, source: String, what: String) raises -> Int:
    """A pipeline that composites over what is already on the drawable.

    Layer 3 always draws last and always blends: an unused cell and a
    transparent background both emit alpha 0 and must leave the picture
    alone.
    """
    let dev = ObjCObject(device)
    var err = ObjCObject(0)
    let lib = send[ObjCObject, "newLibraryWithSource:options:error:"](
        dev,
        nsstring(source).ptr(),
        ObjCObject(0).ptr(),
        Pointer(to=err).unsafe_bitcast[ObjCObject]()[],
    )
    if lib.addr() == 0:
        raise Error(String(what) + " shader did not compile")
    let vfn = send[ObjCObject, "newFunctionWithName:"](
        lib, nsstring(String("vmain")).ptr()
    )
    let ffn = send[ObjCObject, "newFunctionWithName:"](
        lib, nsstring(String("fmain")).ptr()
    )
    if vfn.addr() == 0 or ffn.addr() == 0:
        raise Error(String(what) + " shader has no vmain/fmain")

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
    _ = send[ObjCObject, "setBlendingEnabled:"](att, True)
    _ = send[ObjCObject, "setRgbBlendOperation:"](
        att, nsenum["MTLBlendOperationAdd"]()
    )
    _ = send[ObjCObject, "setAlphaBlendOperation:"](
        att, nsenum["MTLBlendOperationAdd"]()
    )
    _ = send[ObjCObject, "setSourceRGBBlendFactor:"](
        att, nsenum["MTLBlendFactorSourceAlpha"]()
    )
    _ = send[ObjCObject, "setSourceAlphaBlendFactor:"](
        att, nsenum["MTLBlendFactorSourceAlpha"]()
    )
    _ = send[ObjCObject, "setDestinationRGBBlendFactor:"](
        att, nsenum["MTLBlendFactorOneMinusSourceAlpha"]()
    )
    _ = send[ObjCObject, "setDestinationAlphaBlendFactor:"](
        att, nsenum["MTLBlendFactorOneMinusSourceAlpha"]()
    )

    var perr = ObjCObject(0)
    let pipeline = send[
        ObjCObject, "newRenderPipelineStateWithDescriptor:error:"
    ](dev, desc.ptr(), Pointer(to=perr).unsafe_bitcast[ObjCObject]()[])
    if pipeline.addr() == 0:
        raise Error(String(what) + " pipeline failed to build")
    return pipeline.addr()


def _open_pass(frame: Frame) raises -> Int:
    """A Load pass on the frame's drawable -- layer 3 never clears."""
    let pass_desc = ObjCObject(
        Cls["MTLRenderPassDescriptor"]().renderPassDescriptor().id
    )
    let c0 = send[ObjCObject, "objectAtIndexedSubscript:"](
        send[ObjCObject, "colorAttachments"](pass_desc), Int(0)
    )
    _ = send[ObjCObject, "setTexture:"](c0, ObjCObject(frame.target).ptr())
    _ = send[ObjCObject, "setLoadAction:"](c0, nsenum["MTLLoadActionLoad"]())
    _ = send[ObjCObject, "setStoreAction:"](c0, nsenum["MTLStoreActionStore"]())
    return send[ObjCObject, "renderCommandEncoderWithDescriptor:"](
        ObjCObject(frame.cb), pass_desc.ptr()
    ).addr()


# ── the retained overlay ────────────────────────────────────────────────────


struct TextOverlay(Movable):
    """Glyphs rasterised into an RGBA buffer, composited over everything.

    This is the ONE layer in the game pane that keeps an upload. Everywhere
    else a plane is index bytes and a linear texture view removes the copy;
    here the natural home for RGBA at one texel per screen pixel is an
    ordinary sampled 2D texture, so the buffer is uploaded when it changes.
    Guarded by a dirty flag: a HUD that says the same thing this frame as
    last costs nothing.
    """

    var width: Int
    var height: Int
    var pixels: List[UInt8]
    var texture: Int
    var dirty: Bool
    var pipeline: Int

    def __init__(out self, device: Int, width: Int, height: Int) raises:
        self.width = width
        self.height = height
        self.pixels = List[UInt8](length=width * height * 4, fill=0)
        let tdesc = ObjCObject(
            Cls["MTLTextureDescriptor"]()
            .texture2DDescriptorWithPixelFormat_width_height_mipmapped(
                nsenum["MTLPixelFormatRGBA8Unorm"](), width, height, False
            )
            .id
        )
        _ = send[ObjCObject, "setUsage:"](
            tdesc, nsenum["MTLTextureUsageShaderRead"]()
        )
        let tex = send[ObjCObject, "newTextureWithDescriptor:"](
            ObjCObject(device), tdesc.ptr()
        )
        if tex.addr() == 0:
            raise Error("text overlay: no texture")
        self.texture = tex.addr()
        self.dirty = True
        self.pipeline = _blend_pipeline(
            device, OVERLAY_SHADER, String("text overlay")
        )

    def canvas(mut self) -> RgbaCanvas:
        """The buffer, as something the neutral tier can draw into."""
        return RgbaCanvas(
            Pointer[UInt8, MutUntrackedOrigin](
                unsafe_from_address=Int(self.pixels.unsafe_ptr())
            ),
            self.width,
            self.height,
        )

    def clear(mut self):
        self.canvas().clear()
        self.dirty = True

    def draw_text(
        mut self,
        x: Int,
        y: Int,
        text: String,
        r: Int,
        g: Int,
        b: Int,
        scale: Int = 1,
    ):
        self.canvas().draw_text(x, y, text, r, g, b, scale)
        self.dirty = True

    def upload(mut self) raises:
        if not self.dirty:
            return
        _ = send[
            ObjCObject, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:"
        ](
            ObjCObject(self.texture),
            MTLRegion(MTLOrigin(0, 0, 0), MTLSize(self.width, self.height, 1)),
            Int(0),
            self.pixels.unsafe_ptr().unsafe_bitcast[NoneType](),
            Int(self.width * 4),
        )
        self.dirty = False

    def render(mut self, frame: Frame) raises:
        if not frame.valid:
            return
        self.upload()
        let enc = ObjCObject(_open_pass(frame))
        _ = send[ObjCObject, "setRenderPipelineState:"](
            enc, ObjCObject(self.pipeline).ptr()
        )
        _ = send[ObjCObject, "setFragmentTexture:atIndex:"](
            enc, ObjCObject(self.texture).ptr(), Int(0)
        )
        _ = send[ObjCObject, "drawPrimitives:vertexStart:vertexCount:"](
            enc, nsenum["MTLPrimitiveTypeTriangle"](), Int(0), Int(3)
        )
        _ = send[ObjCObject, "endEncoding"](enc)


# ── the cell grid ───────────────────────────────────────────────────────────


struct TextPlane(Movable):
    """A character screen the host writes straight into.

    Cell `(col, row)` is four bytes at `(row * cols + col) * 4`:
    `[char, fg, bg, flags]`. Char 0 means UNUSED and draws nothing -- which
    is what lets this plane sit over every other layer always, because a
    game that never touches it sees no difference. Use space with an opaque
    background to paint a block.
    """

    var cols: Int
    var rows: Int
    var viewport_w: Int
    var viewport_h: Int
    var cells: Int
    var palette: List[Float32]
    var palette_buffer: Int
    var palette_dirty: Bool
    var atlas: Int
    var pipeline: Int

    def __init__(
        out self, device: Int, viewport_w: Int, viewport_h: Int
    ) raises:
        self.viewport_w = viewport_w
        self.viewport_h = viewport_h
        self.cols = text_cols(viewport_w)
        self.rows = text_rows(viewport_h)
        let dev = ObjCObject(device)

        let cbuf = send[ObjCObject, "newBufferWithLength:options:"](
            dev,
            self.cols * self.rows * CELL_BYTES,
            nsenum["MTLResourceStorageModeShared"](),
        )
        if cbuf.addr() == 0:
            raise Error("text plane: no cell buffer")
        self.cells = cbuf.addr()
        let cp = Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=Int(send[ObjCObject, "contents"](cbuf).addr())
        )
        for i in range(self.cols * self.rows * CELL_BYTES):
            cp[unsafe_offset=i] = 0

        # The atlas: 256 glyphs stacked vertically, one byte a pixel, baked
        # from the SAME table the overlay rasterises from. One font, two
        # renderers, no second table to drift.
        let adesc = ObjCObject(
            Cls["MTLTextureDescriptor"]()
            .texture2DDescriptorWithPixelFormat_width_height_mipmapped(
                nsenum["MTLPixelFormatR8Uint"](), GLYPH_W, GLYPH_H * 256, False
            )
            .id
        )
        _ = send[ObjCObject, "setUsage:"](
            adesc, nsenum["MTLTextureUsageShaderRead"]()
        )
        let atex = send[ObjCObject, "newTextureWithDescriptor:"](
            dev, adesc.ptr()
        )
        if atex.addr() == 0:
            raise Error("text plane: no atlas")
        self.atlas = atex.addr()
        var bytes = List[UInt8](length=GLYPH_W * GLYPH_H * 256, fill=0)
        for ch in range(256):
            let g = glyph_for(ch)
            for r in range(GLYPH_H):
                let mask = Int(g[r])
                for c in range(GLYPH_W):
                    if mask & (1 << (GLYPH_W - 1 - c)) != 0:
                        bytes[(ch * GLYPH_H + r) * GLYPH_W + c] = 1
        _ = send[
            ObjCObject, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:"
        ](
            atex,
            MTLRegion(MTLOrigin(0, 0, 0), MTLSize(GLYPH_W, GLYPH_H * 256, 1)),
            Int(0),
            bytes.unsafe_ptr().unsafe_bitcast[NoneType](),
            Int(GLYPH_W),
        )

        # White everywhere except slot 0 and the default sixteen: an index a
        # game has not set should be VISIBLE, not a mystery.
        self.palette = List[Float32](length=256 * 4, fill=1.0)
        self.palette[0] = 0.0
        self.palette[1] = 0.0
        self.palette[2] = 0.0
        # The sixteen colours the rest of the pane uses, at slots 16..31, so
        # a demo's existing colour constants mean the same thing here. A
        # runtime `var`, not a `comptime`: a comptime array cannot be
        # indexed by a loop variable without materialising it, and the
        # diagnostic for that is longer than the fix.
        var default16: List[Int] = [
            0, 0, 0,        29, 43, 83,      126, 37, 83,    0, 135, 81,
            171, 82, 54,    95, 87, 79,      194, 195, 199,  255, 241, 232,
            255, 0, 77,     255, 163, 0,     255, 236, 39,   0, 228, 54,
            41, 173, 255,   131, 118, 156,   255, 119, 168,  255, 204, 170,
        ]
        for i in range(16):
            self.palette[(16 + i) * 4 + 0] = Float32(default16[i * 3 + 0]) / 255.0
            self.palette[(16 + i) * 4 + 1] = Float32(default16[i * 3 + 1]) / 255.0
            self.palette[(16 + i) * 4 + 2] = Float32(default16[i * 3 + 2]) / 255.0
            self.palette[(16 + i) * 4 + 3] = 1.0
        let pbuf = send[ObjCObject, "newBufferWithLength:options:"](
            dev, Int(256 * 16), nsenum["MTLResourceStorageModeShared"]()
        )
        if pbuf.addr() == 0:
            raise Error("text plane: no palette buffer")
        self.palette_buffer = pbuf.addr()
        self.palette_dirty = True

        self.pipeline = _blend_pipeline(
            device, PLANE_SHADER, String("text plane")
        )

    def cells_ptr(self) -> Pointer[UInt8, MutUntrackedOrigin]:
        return Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=Int(
                send[ObjCObject, "contents"](ObjCObject(self.cells)).addr()
            )
        )

    def cells_len(self) -> Int:
        return self.cols * self.rows * CELL_BYTES

    def clear(self):
        let p = self.cells_ptr()
        for i in range(self.cells_len()):
            p[unsafe_offset=i] = 0

    def put(
        self,
        col: Int,
        row: Int,
        ch: Int,
        fg: Int = 23,
        bg: Int = 16,
        flags: Int = 0,
    ):
        """One cell. Out of range is a no-op."""
        if col < 0 or row < 0 or col >= self.cols or row >= self.rows:
            return
        let p = self.cells_ptr()
        let i = (row * self.cols + col) * CELL_BYTES
        p[unsafe_offset = i + 0] = UInt8(ch & 255)
        p[unsafe_offset = i + 1] = UInt8(fg & 255)
        p[unsafe_offset = i + 2] = UInt8(bg & 255)
        p[unsafe_offset = i + 3] = UInt8(flags & 255)

    def write(
        self,
        col: Int,
        row: Int,
        text: String,
        fg: Int = 23,
        bg: Int = 16,
        flags: Int = 0,
    ):
        var i = 0
        for c in text.codepoints():
            self.put(col + i, row, Int(c.to_u32()), fg, bg, flags)
            i += 1

    def set_rgb(mut self, index: Int, r: Int, g: Int, b: Int):
        if index < 0 or index > 255:
            return
        self.palette[index * 4 + 0] = Float32(r) / 255.0
        self.palette[index * 4 + 1] = Float32(g) / 255.0
        self.palette[index * 4 + 2] = Float32(b) / 255.0
        self.palette[index * 4 + 3] = 1.0
        self.palette_dirty = True

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
            for i in range(256 * 4):
                pp[unsafe_offset=i] = self.palette[i]
            self.palette_dirty = False

        var uni = PlaneUniforms(
            Float32(self.viewport_w),
            Float32(self.viewport_h),
            Float32(self.cols),
            Float32(self.rows),
        )
        let enc = ObjCObject(_open_pass(frame))
        _ = send[ObjCObject, "setRenderPipelineState:"](
            enc, ObjCObject(self.pipeline).ptr()
        )
        _ = send[ObjCObject, "setFragmentBytes:length:atIndex:"](
            enc, Pointer(to=uni).unsafe_bitcast[NoneType]()[], Int(16), Int(0)
        )
        _ = send[ObjCObject, "setFragmentBuffer:offset:atIndex:"](
            enc, ObjCObject(self.cells).ptr(), Int(0), Int(1)
        )
        _ = send[ObjCObject, "setFragmentBuffer:offset:atIndex:"](
            enc, ObjCObject(self.palette_buffer).ptr(), Int(0), Int(2)
        )
        _ = send[ObjCObject, "setFragmentTexture:atIndex:"](
            enc, ObjCObject(self.atlas).ptr(), Int(0)
        )
        _ = send[ObjCObject, "drawPrimitives:vertexStart:vertexCount:"](
            enc, nsenum["MTLPrimitiveTypeTriangle"](), Int(0), Int(3)
        )
        _ = send[ObjCObject, "endEncoding"](enc)
