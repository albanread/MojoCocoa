# ===----------------------------------------------------------------------=== #
# Sprint G0 — the render-pipeline spike.
#
# Nothing in this tree has ever built a Metal RENDER pipeline from Mojo. Every
# example so far computes pixels and hands the buffer to a CAMetalLayer with
# `replaceRegion:`; a compositor needs the other half — compile MSL, make a
# pipeline, encode a draw, read the result back.
#
# This file answers, before a single layer of the game pane is written:
#
#   1. does newLibraryWithSource:options:error: work from Mojo, and does a
#      bad shader come back as an error that names itself?
#   2. can a render pipeline be built from a typed descriptor?
#   3. does a draw into an offscreen texture produce the pixels we asked for
#      (which also proves MTLClearColor and MTLRegion by value)?
#
# Run: cocoamojo run gamepane/tests/spike_pipeline.mojo
# ===----------------------------------------------------------------------=== #

from std.objc import (
    load_framework,
    Cls,
    Obj,
    ObjCObject,
    send,
    nsenum,
    nsstring,
    ns_to_string,
    autoreleasepool,
    MTLOrigin,
    MTLSize,
    MTLRegion,
    MTLClearColor,
)
from std.ffi import external_call
from std.memory import OpaquePointer, Pointer

comptime P = OpaquePointer[MutUntrackedOrigin]

comptime W = 4
comptime H = 4


# The full-screen triangle, and a fragment shader that returns a colour the
# test can recognise. The vertex half is the same "big triangle from
# vertex_id" the game pane's own layers will use.
comptime SHADER = String(
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

fragment float4 fmain(VOut in [[stage_in]]) {
    return float4(0.25, 0.50, 0.75, 1.0);
}
"""
)


# The indexed pane's own shader: sample an R8 index, discard on 0, look the
# colour up in a palette buffer. This is the layer-1 fragment function, and
# proving it here proves the whole "one buffer, three readers" model.
comptime INDEXED = String(
    """
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; float2 uv; };
struct U { float w; float h; };

vertex VOut vmain(uint vid [[vertex_id]]) {
    float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    VOut out;
    float2 pos = positions[vid];
    out.pos = float4(pos, 0.0, 1.0);
    out.uv = float2((pos.x + 1.0) * 0.5, 1.0 - (pos.y + 1.0) * 0.5);
    return out;
}

fragment float4 fmain(VOut in [[stage_in]],
                      constant U& u [[buffer(0)]],
                      texture2d<uint> indexTex [[texture(0)]],
                      constant uchar4* palette [[buffer(1)]]) {
    uint x = uint(in.uv.x * u.w);
    uint y = uint(in.uv.y * u.h);
    uint ci = indexTex.read(uint2(x, y)).r;
    if (ci == 0u) { discard_fragment(); }
    return float4(palette[ci]) / 255.0;
}
"""
)


@fieldwise_init
struct U(Copyable, Movable):
    var w: Float32
    var h: Float32


def error_text(err: ObjCObject) -> String:
    """An NSError's localizedDescription, or empty when there is none."""
    if err.addr() == 0:
        return String()
    return ns_to_string(
        ObjCObject(Obj["NSError"](err.addr()).localizedDescription().id)
    )


def main() raises:
    if not load_framework["Metal"]():
        raise Error("could not load Metal")

    var failures = 0

    with autoreleasepool():
        # ── the device ────────────────────────────────────────────────────
        let device = ObjCObject(
            Int(external_call["MTLCreateSystemDefaultDevice", P]())
        )
        if device.addr() == 0:
            raise Error("no Metal device")
        let dev_name = ns_to_string(
            ObjCObject(send[ObjCObject, "name"](device).addr())
        )
        print("device:", dev_name)

        # ── 1. compile a library from source ──────────────────────────────
        var err = ObjCObject(0)
        let lib = send[ObjCObject, "newLibraryWithSource:options:error:"](
            device,
            nsstring(SHADER).ptr(),
            ObjCObject(0).ptr(),
            Pointer(to=err).unsafe_bitcast[P]()[],
        )
        if lib.addr() == 0:
            print("FAIL  library did not compile:", error_text(err))
            failures += 1
        else:
            print("ok    library compiled")

        let vfn = send[ObjCObject, "newFunctionWithName:"](
            lib, nsstring(String("vmain")).ptr()
        )
        let ffn = send[ObjCObject, "newFunctionWithName:"](
            lib, nsstring(String("fmain")).ptr()
        )
        if vfn.addr() == 0 or ffn.addr() == 0:
            print("FAIL  vmain/fmain not found in the library")
            failures += 1
        else:
            print("ok    vmain and fmain found")

        # ── the negative: a source with no fmain must fail, and say so ────
        var err2 = ObjCObject(0)
        let bad = send[ObjCObject, "newLibraryWithSource:options:error:"](
            device,
            nsstring(String("// no fmain here")).ptr(),
            ObjCObject(0).ptr(),
            Pointer(to=err2).unsafe_bitcast[P]()[],
        )
        # An empty source compiles; asking for the function is what fails.
        var missing = ObjCObject(0)
        if bad.addr() != 0:
            missing = send[ObjCObject, "newFunctionWithName:"](
                bad, nsstring(String("fmain")).ptr()
            )
        if missing.addr() == 0:
            print("ok    a source without fmain yields no function")
        else:
            print("FAIL  a source without fmain produced a function")
            failures += 1

        # ── 2. the render pipeline ────────────────────────────────────────
        # MTLRenderPipelineDescriptor IS a class the database knows, but the
        # runtime enumeration records only a handful of its methods --
        # `setVertexFunction:` and the rest of the ordinary properties are
        # not among them (checked: the class has 16 selectors and none is a
        # property setter). So descriptors take `send` too, exactly like the
        # protocol-typed device calls. The enums are all present, so nsenum
        # still names every constant.
        let desc = send[ObjCObject, "init"](
            ObjCObject(Cls["MTLRenderPipelineDescriptor"]().alloc().id)
        )
        _ = send[ObjCObject, "setVertexFunction:"](desc, vfn.ptr())
        _ = send[ObjCObject, "setFragmentFunction:"](desc, ffn.ptr())

        let attachments = send[ObjCObject, "colorAttachments"](desc)
        let att0 = send[ObjCObject, "objectAtIndexedSubscript:"](
            attachments, Int(0)
        )
        _ = send[ObjCObject, "setPixelFormat:"](
            att0, nsenum["MTLPixelFormatBGRA8Unorm"]()
        )

        var perr = ObjCObject(0)
        let pipeline = send[
            ObjCObject, "newRenderPipelineStateWithDescriptor:error:"
        ](device, desc.ptr(), Pointer(to=perr).unsafe_bitcast[P]()[])
        if pipeline.addr() == 0:
            print("FAIL  no pipeline:", error_text(perr))
            failures += 1
        else:
            print("ok    render pipeline built")

        # ── 3. draw into an offscreen texture, and read it back ───────────
        # The 2D convenience constructor IS in the metadata, so the typed
        # surface builds the descriptor; only the usage flags need `send`.
        let tdesc = ObjCObject(
            Cls["MTLTextureDescriptor"]()
            .texture2DDescriptorWithPixelFormat_width_height_mipmapped(
                nsenum["MTLPixelFormatBGRA8Unorm"](), W, H, False
            )
            .id
        )
        # RenderTarget | ShaderRead, so it can be drawn into and read back.
        _ = send[ObjCObject, "setUsage:"](
            tdesc,
            nsenum["MTLTextureUsageRenderTarget"]()
            | nsenum["MTLTextureUsageShaderRead"](),
        )
        let target = send[ObjCObject, "newTextureWithDescriptor:"](
            device, tdesc.ptr()
        )
        if target.addr() == 0:
            print("FAIL  no target texture")
            failures += 1

        let pass_desc = ObjCObject(
            Cls["MTLRenderPassDescriptor"]().renderPassDescriptor().id
        )
        let colors = send[ObjCObject, "colorAttachments"](pass_desc)
        let c0 = send[ObjCObject, "objectAtIndexedSubscript:"](colors, Int(0))
        _ = send[ObjCObject, "setTexture:"](c0, target.ptr())
        _ = send[ObjCObject, "setLoadAction:"](
            c0, nsenum["MTLLoadActionClear"]()
        )
        _ = send[ObjCObject, "setStoreAction:"](
            c0, nsenum["MTLStoreActionStore"]()
        )
        # Four doubles by value: the second ABI shape this spike checks.
        _ = send[ObjCObject, "setClearColor:"](
            c0, MTLClearColor(0.0, 0.0, 0.0, 1.0)
        )

        let queue = send[ObjCObject, "newCommandQueue"](device)
        let cb = send[ObjCObject, "commandBuffer"](queue)
        let enc = send[ObjCObject, "renderCommandEncoderWithDescriptor:"](
            cb, pass_desc.ptr()
        )
        _ = send[ObjCObject, "setRenderPipelineState:"](enc, pipeline.ptr())
        # MTLPrimitiveTypeTriangle = 3.
        _ = send[ObjCObject, "drawPrimitives:vertexStart:vertexCount:"](
            enc, nsenum["MTLPrimitiveTypeTriangle"](), Int(0), Int(3)
        )
        _ = send[ObjCObject, "endEncoding"](enc)
        _ = send[ObjCObject, "commit"](cb)
        _ = send[ObjCObject, "waitUntilCompleted"](cb)

        # Read the pixels back. BGRA8Unorm, so the bytes are B G R A.
        var pixels = List[UInt8](length=W * H * 4, fill=0)
        let region = MTLRegion(MTLOrigin(0, 0, 0), MTLSize(W, H, 1))
        _ = send[
            ObjCObject, "getBytes:bytesPerRow:fromRegion:mipmapLevel:"
        ](
            target,
            pixels.unsafe_ptr().unsafe_bitcast[NoneType](),
            Int(W * 4),
            region,
            Int(0),
        )

        let b = Int(pixels[0])
        let g = Int(pixels[1])
        let r = Int(pixels[2])
        let a = Int(pixels[3])
        print("pixel(0,0) BGRA =", b, g, r, a)
        # The shader returns rgba(0.25, 0.50, 0.75, 1.0); in 8-bit that is
        # r=64 g=128 b=191, and BGRA8Unorm stores them B first.
        if abs(b - 191) <= 2 and abs(g - 128) <= 2 and abs(r - 64) <= 2 and a == 255:
            print("ok    the drawn pixel is the colour the shader returned")
        else:
            print("FAIL  wrong pixel; expected B=191 G=128 R=64 A=255")
            failures += 1

        # ── 4. one buffer, two readers: CPU stores, shader samples ────────
        # The model the whole game pane rests on. A Shared MTLBuffer is
        # ordinary CPU memory; a LINEAR TEXTURE VIEW over it is what the
        # fragment shader reads. No upload, no mirror, no second copy.
        #
        # The stride is not the width: bytesPerRow must be a multiple of the
        # device's linear alignment for the format, which is exactly the rule
        # the Rust engine records as the one that bites.
        let align = Int(
            send[Int, "minimumLinearTextureAlignmentForPixelFormat:"](
                device, nsenum["MTLPixelFormatR8Uint"]()
            )
        )
        var stride = W
        if align > 0:
            stride = ((W + align - 1) // align) * align
        print("linear alignment:", align, " stride for width", W, "=", stride)

        let idx_buf = send[ObjCObject, "newBufferWithLength:options:"](
            device,
            Int(stride * H),
            nsenum["MTLResourceStorageModeShared"](),
        )
        if idx_buf.addr() == 0:
            print("FAIL  no index buffer")
            failures += 1

        # Write indices straight into the buffer: this is `pset`.
        let idx_ptr = Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=Int(
                send[ObjCObject, "contents"](idx_buf).addr()
            )
        )
        for i in range(stride * H):
            idx_ptr[unsafe_offset=i] = 0
        idx_ptr[unsafe_offset = 1 * stride + 1] = 7  # (1,1) = palette entry 7

        let vdesc = ObjCObject(
            Cls["MTLTextureDescriptor"]()
            .texture2DDescriptorWithPixelFormat_width_height_mipmapped(
                nsenum["MTLPixelFormatR8Uint"](), W, H, False
            )
            .id
        )
        _ = send[ObjCObject, "setUsage:"](
            vdesc, nsenum["MTLTextureUsageShaderRead"]()
        )
        let view = send[
            ObjCObject, "newTextureWithDescriptor:offset:bytesPerRow:"
        ](idx_buf, vdesc.ptr(), Int(0), Int(stride))
        if view.addr() == 0:
            print("FAIL  no linear texture view over the buffer")
            failures += 1
        else:
            print("ok    linear texture view created over a shared buffer")

        # The palette, RGBA bytes, entry 7 = a colour we can recognise.
        let pal_buf = send[ObjCObject, "newBufferWithLength:options:"](
            device, Int(256 * 4), nsenum["MTLResourceStorageModeShared"]()
        )
        let pal_ptr = Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=Int(
                send[ObjCObject, "contents"](pal_buf).addr()
            )
        )
        for i in range(256 * 4):
            pal_ptr[unsafe_offset=i] = 0
        pal_ptr[unsafe_offset = 7 * 4 + 0] = 10   # R
        pal_ptr[unsafe_offset = 7 * 4 + 1] = 20   # G
        pal_ptr[unsafe_offset = 7 * 4 + 2] = 30   # B
        pal_ptr[unsafe_offset = 7 * 4 + 3] = 255

        # A second pipeline, for the indexed shader.
        var ierr = ObjCObject(0)
        let ilib = send[ObjCObject, "newLibraryWithSource:options:error:"](
            device,
            nsstring(INDEXED).ptr(),
            ObjCObject(0).ptr(),
            Pointer(to=ierr).unsafe_bitcast[P]()[],
        )
        if ilib.addr() == 0:
            print("FAIL  indexed shader did not compile:", error_text(ierr))
            failures += 1
        let ivfn = send[ObjCObject, "newFunctionWithName:"](
            ilib, nsstring(String("vmain")).ptr()
        )
        let iffn = send[ObjCObject, "newFunctionWithName:"](
            ilib, nsstring(String("fmain")).ptr()
        )
        let idesc = send[ObjCObject, "init"](
            ObjCObject(Cls["MTLRenderPipelineDescriptor"]().alloc().id)
        )
        _ = send[ObjCObject, "setVertexFunction:"](idesc, ivfn.ptr())
        _ = send[ObjCObject, "setFragmentFunction:"](idesc, iffn.ptr())
        let iatt = send[ObjCObject, "objectAtIndexedSubscript:"](
            send[ObjCObject, "colorAttachments"](idesc), Int(0)
        )
        _ = send[ObjCObject, "setPixelFormat:"](
            iatt, nsenum["MTLPixelFormatBGRA8Unorm"]()
        )
        var iperr = ObjCObject(0)
        let ipipe = send[
            ObjCObject, "newRenderPipelineStateWithDescriptor:error:"
        ](device, idesc.ptr(), Pointer(to=iperr).unsafe_bitcast[P]()[])
        if ipipe.addr() == 0:
            print("FAIL  no indexed pipeline:", error_text(iperr))
            failures += 1

        # Draw it, over a red clear so a discarded pixel is visibly the clear.
        let pass2 = ObjCObject(
            Cls["MTLRenderPassDescriptor"]().renderPassDescriptor().id
        )
        let c2 = send[ObjCObject, "objectAtIndexedSubscript:"](
            send[ObjCObject, "colorAttachments"](pass2), Int(0)
        )
        _ = send[ObjCObject, "setTexture:"](c2, target.ptr())
        _ = send[ObjCObject, "setLoadAction:"](
            c2, nsenum["MTLLoadActionClear"]()
        )
        _ = send[ObjCObject, "setStoreAction:"](
            c2, nsenum["MTLStoreActionStore"]()
        )
        _ = send[ObjCObject, "setClearColor:"](
            c2, MTLClearColor(1.0, 0.0, 0.0, 1.0)
        )

        var uni = U(Float32(W), Float32(H))
        let cb2 = send[ObjCObject, "commandBuffer"](queue)
        let enc2 = send[ObjCObject, "renderCommandEncoderWithDescriptor:"](
            cb2, pass2.ptr()
        )
        _ = send[ObjCObject, "setRenderPipelineState:"](enc2, ipipe.ptr())
        _ = send[ObjCObject, "setFragmentBytes:length:atIndex:"](
            enc2,
            Pointer(to=uni).unsafe_bitcast[NoneType]()[],
            Int(8),
            Int(0),
        )
        _ = send[ObjCObject, "setFragmentTexture:atIndex:"](
            enc2, view.ptr(), Int(0)
        )
        _ = send[ObjCObject, "setFragmentBuffer:offset:atIndex:"](
            enc2, pal_buf.ptr(), Int(0), Int(1)
        )
        _ = send[ObjCObject, "drawPrimitives:vertexStart:vertexCount:"](
            enc2, nsenum["MTLPrimitiveTypeTriangle"](), Int(0), Int(3)
        )
        _ = send[ObjCObject, "endEncoding"](enc2)
        _ = send[ObjCObject, "commit"](cb2)
        _ = send[ObjCObject, "waitUntilCompleted"](cb2)

        var px2 = List[UInt8](length=W * H * 4, fill=0)
        _ = send[
            ObjCObject, "getBytes:bytesPerRow:fromRegion:mipmapLevel:"
        ](
            target,
            px2.unsafe_ptr().unsafe_bitcast[NoneType](),
            Int(W * 4),
            region,
            Int(0),
        )
        # (1,1) carried index 7 -> palette 10/20/30. Everything else was 0
        # and must have been discarded, leaving the red clear.
        let o = (1 * W + 1) * 4
        print(
            "pixel(1,1) BGRA =",
            Int(px2[o]), Int(px2[o + 1]), Int(px2[o + 2]), Int(px2[o + 3]),
        )
        print(
            "pixel(0,0) BGRA =",
            Int(px2[0]), Int(px2[1]), Int(px2[2]), Int(px2[3]),
        )
        if (
            abs(Int(px2[o]) - 30) <= 2
            and abs(Int(px2[o + 1]) - 20) <= 2
            and abs(Int(px2[o + 2]) - 10) <= 2
        ):
            print("ok    the CPU-written index reached the shader")
        else:
            print("FAIL  index 7 did not resolve to palette 10/20/30")
            failures += 1
        if Int(px2[2]) >= 250 and Int(px2[0]) <= 5:
            print("ok    index 0 discarded; the clear shows through")
        else:
            print("FAIL  index 0 was not transparent")
            failures += 1

    print()
    if failures == 0:
        print("G0 pipeline spike: PASS")
    else:
        print("G0 pipeline spike: FAILED", failures, "check(s)")
        raise Error("spike failed")
