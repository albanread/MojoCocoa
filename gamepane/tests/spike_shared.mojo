# ===----------------------------------------------------------------------=== #
# Sprint G0 — one memory, three readers.
#
# The design's central claim: an index plane is ONE buffer that
#
#   * the CPU stores into      (pset, fill_rect, line)
#   * a Mojo GPU kernel writes (the blitter)
#   * a fragment shader samples through a linear texture view (the compositor)
#
# with no CPU mirror, no dirty flag and no upload step -- the three things the
# Rust engine needs because a Vec<u8> and an MTLTexture are two copies there.
#
# spike_pipeline.mojo proved the CPU and shader halves. This proves the third
# reader, which needs the buffer accessor added to the fork's own GPU runtime
# (AsyncRT_DeviceBuffer_metal_buffer, beside the metal_device that was already
# there).
#
# Run: cocoamojo run gamepane/tests/spike_shared.mojo
# ===----------------------------------------------------------------------=== #

from std.objc import (
    load_framework, Cls, ObjCObject, send, nsenum, nsstring, autoreleasepool,
    MTLOrigin,
    MTLSize,
    MTLRegion,
    MTLClearColor,
)
from std.ffi import external_call, c_char
from std.memory import OpaquePointer, Pointer
from std.gpu import global_idx
from max.gpu.host import DeviceContext

comptime P = OpaquePointer[MutUntrackedOrigin]

comptime W = 8
comptime H = 8


comptime INDEXED = String(
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
                      constant uchar4* pal [[buffer(1)]]) {
    uint x = uint(in.uv.x * u.w), y = uint(in.uv.y * u.h);
    uint ci = idx.read(uint2(x, y)).r;
    if (ci == 0u) { discard_fragment(); }
    return float4(pal[ci]) / 255.0;
}
"""
)


@fieldwise_init
struct U(Copyable, Movable):
    var w: Float32
    var h: Float32


# The blitter, in miniature: fill a rectangle with an index. The real one
# takes a source plane too; the mechanism being proved is identical.
# A kernel is a `def` compiled with compile_function and launched by value,
# the way fernwind's own two kernels are.
# Kernel arguments must be FIXED WIDTH: Int and UInt do not conform to
# DevicePassable, and the diagnostic says so in as many words.
def blit_clear_kernel(
    dst: Pointer[UInt8, MutAnyOrigin],
    stride: Int32,
    x0: Int32,
    y0: Int32,
    w: Int32,
    h: Int32,
    value: UInt8,
):
    var gx = Int(global_idx.x)
    var gy = Int(global_idx.y)
    if gx >= Int(w) or gy >= Int(h):
        return
    dst[
        unsafe_offset = (Int(y0) + gy) * Int(stride) + (Int(x0) + gx)
    ] = value


def main() raises:
    if not load_framework["Metal"]():
        raise Error("could not load Metal")

    var failures = 0
    var ctx = DeviceContext(api="metal")

    # The device both halves use -- proven the same object in spike_device.
    var dslot = List[Int](length=1, fill=0)
    _ = external_call["AsyncRT_DeviceContext_metal_device", P](
        dslot.unsafe_ptr(), ctx._handle
    )
    let device = ObjCObject(dslot[0])
    if device.addr() == 0:
        raise Error("no runtime device")

    let align = Int(
        send[Int, "minimumLinearTextureAlignmentForPixelFormat:"](
            device, nsenum["MTLPixelFormatR8Uint"]()
        )
    )
    var stride = W
    if align > 0:
        stride = ((W + align - 1) // align) * align
    print("stride:", stride, "(width", W, "align", align, ")")

    # The plane: a device buffer, so a KERNEL can write it.
    var plane = ctx.enqueue_create_buffer[DType.uint8](stride * H)
    ctx.synchronize()

    # Zero it, then let the kernel paint a 3x3 of index 5 at (2,2).
    with plane.map_to_host() as host:
        var p = host.unsafe_ptr()
        for i in range(stride * H):
            p[unsafe_offset=i] = 0

    var blit_clear = ctx.compile_function[blit_clear_kernel]()
    ctx.enqueue_function(
        blit_clear, plane, Int32(stride), Int32(2), Int32(2),
        Int32(3), Int32(3), UInt8(5),
        grid_dim=(3, 3), block_dim=(1, 1),
    )
    ctx.synchronize()

    # ── the accessor: the id<MTLBuffer> behind that DeviceBuffer ──────────
    # Two parameters, exactly like AsyncRT_DeviceBuffer_hostPtr: one
    # out-slot and the handle. The offset is a SEPARATE call returning a
    # size_t -- passing it here as a third argument put the handle in x2 and
    # left the `buffer` parameter holding the offset slot's data pointer,
    # which the C side then dereferenced as a DeviceBuffer. It read a
    # plausible non-null `mtl` out of that list's storage and crashed
    # locking the mutex of a context that was never a context.
    # hostPtr first, as the cross-check: it is the address Mojo writes the
    # plane through, and `contents` on the MTLBuffer below must be the same
    # address or the texture is not looking at the bytes the kernel wrote.
    var hslot = List[Int](length=1, fill=0)
    _ = external_call["AsyncRT_DeviceBuffer_hostPtr", P](
        hslot.unsafe_ptr(), plane._handle
    )

    var bslot = List[Int](length=1, fill=0)
    let berr = external_call["AsyncRT_DeviceBuffer_metal_buffer", P](
        bslot.unsafe_ptr(), plane._handle
    )
    let view_offset = Int(
        external_call["AsyncRT_DeviceBuffer_metal_offset", Int](plane._handle)
    )
    if Int(berr) != 0:
        print(
            "FAIL  metal_buffer:",
            String(unsafe_from_utf8_ptr=berr.unsafe_bitcast[c_char]()),
        )
        failures += 1
    let mtl_buf = ObjCObject(bslot[0])
    print("MTLBuffer:", hex(bslot[0]), " offset:", view_offset)
    if mtl_buf.addr() == 0:
        print("FAIL  the runtime gave no MTLBuffer")
        failures += 1
    else:
        print("ok    got the id<MTLBuffer> behind a DeviceBuffer")

    with autoreleasepool():
        # A linear texture view over the SAME bytes the kernel just wrote.
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
        # Is this really an MTLBuffer, and what storage does it have? A
        # buffer-backed texture must be described with the SAME storage mode
        # as the buffer it views, which is the one thing the convenience
        # descriptor does not know.
        let blen = Int(send[Int, "length"](mtl_buf))
        let bmode = Int(send[Int, "storageMode"](mtl_buf))
        print("  buffer length:", blen, " storageMode:", bmode)
        let contents = Int(send[ObjCObject, "contents"](mtl_buf).addr())
        if contents != hslot[0]:
            print("FAIL  contents", hex(contents), "!= hostPtr", hex(hslot[0]))
            failures += 1
        else:
            print("ok    one allocation: hostPtr and MTLBuffer.contents agree")
        _ = send[ObjCObject, "setStorageMode:"](vdesc, bmode)
        let view = send[
            ObjCObject, "newTextureWithDescriptor:offset:bytesPerRow:"
        ](mtl_buf, vdesc.ptr(), view_offset, Int(stride))
        if view.addr() == 0:
            print("FAIL  no texture view over the kernel's buffer")
            failures += 1
        else:
            print("ok    texture view over the kernel's own buffer")

        # Palette: entry 5 is a colour we can recognise.
        let pal = send[ObjCObject, "newBufferWithLength:options:"](
            device, Int(256 * 4), nsenum["MTLResourceStorageModeShared"]()
        )
        let pp = Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=Int(send[ObjCObject, "contents"](pal).addr())
        )
        for i in range(256 * 4):
            pp[unsafe_offset=i] = 0
        pp[unsafe_offset = 5 * 4 + 0] = 90
        pp[unsafe_offset = 5 * 4 + 1] = 80
        pp[unsafe_offset = 5 * 4 + 2] = 70
        pp[unsafe_offset = 5 * 4 + 3] = 255

        # Pipeline, target, draw.
        var err = ObjCObject(0)
        let lib = send[ObjCObject, "newLibraryWithSource:options:error:"](
            device, nsstring(INDEXED).ptr(), ObjCObject(0).ptr(),
            Pointer(to=err).unsafe_bitcast[P]()[],
        )
        let vfn = send[ObjCObject, "newFunctionWithName:"](
            lib, nsstring(String("vmain")).ptr()
        )
        let ffn = send[ObjCObject, "newFunctionWithName:"](
            lib, nsstring(String("fmain")).ptr()
        )
        let pdesc = send[ObjCObject, "init"](
            ObjCObject(Cls["MTLRenderPipelineDescriptor"]().alloc().id)
        )
        _ = send[ObjCObject, "setVertexFunction:"](pdesc, vfn.ptr())
        _ = send[ObjCObject, "setFragmentFunction:"](pdesc, ffn.ptr())
        _ = send[ObjCObject, "setPixelFormat:"](
            send[ObjCObject, "objectAtIndexedSubscript:"](
                send[ObjCObject, "colorAttachments"](pdesc), Int(0)
            ),
            nsenum["MTLPixelFormatBGRA8Unorm"](),
        )
        var perr = ObjCObject(0)
        let pipe = send[
            ObjCObject, "newRenderPipelineStateWithDescriptor:error:"
        ](device, pdesc.ptr(), Pointer(to=perr).unsafe_bitcast[P]()[])
        if pipe.addr() == 0:
            print("FAIL  no pipeline")
            failures += 1

        let tdesc = ObjCObject(
            Cls["MTLTextureDescriptor"]()
            .texture2DDescriptorWithPixelFormat_width_height_mipmapped(
                nsenum["MTLPixelFormatBGRA8Unorm"](), W, H, False
            )
            .id
        )
        _ = send[ObjCObject, "setUsage:"](
            tdesc,
            nsenum["MTLTextureUsageRenderTarget"]()
            | nsenum["MTLTextureUsageShaderRead"](),
        )
        let target = send[ObjCObject, "newTextureWithDescriptor:"](
            device, tdesc.ptr()
        )

        let pass_desc = ObjCObject(
            Cls["MTLRenderPassDescriptor"]().renderPassDescriptor().id
        )
        let c0 = send[ObjCObject, "objectAtIndexedSubscript:"](
            send[ObjCObject, "colorAttachments"](pass_desc), Int(0)
        )
        _ = send[ObjCObject, "setTexture:"](c0, target.ptr())
        _ = send[ObjCObject, "setLoadAction:"](
            c0, nsenum["MTLLoadActionClear"]()
        )
        _ = send[ObjCObject, "setStoreAction:"](
            c0, nsenum["MTLStoreActionStore"]()
        )
        _ = send[ObjCObject, "setClearColor:"](
            c0, MTLClearColor(1.0, 0.0, 0.0, 1.0)
        )

        var uni = U(Float32(W), Float32(H))
        let queue = send[ObjCObject, "newCommandQueue"](device)
        let cb = send[ObjCObject, "commandBuffer"](queue)
        let enc = send[ObjCObject, "renderCommandEncoderWithDescriptor:"](
            cb, pass_desc.ptr()
        )
        _ = send[ObjCObject, "setRenderPipelineState:"](enc, pipe.ptr())
        _ = send[ObjCObject, "setFragmentBytes:length:atIndex:"](
            enc, Pointer(to=uni).unsafe_bitcast[NoneType]()[], Int(8), Int(0)
        )
        _ = send[ObjCObject, "setFragmentTexture:atIndex:"](
            enc, view.ptr(), Int(0)
        )
        _ = send[ObjCObject, "setFragmentBuffer:offset:atIndex:"](
            enc, pal.ptr(), Int(0), Int(1)
        )
        _ = send[ObjCObject, "drawPrimitives:vertexStart:vertexCount:"](
            enc, nsenum["MTLPrimitiveTypeTriangle"](), Int(0), Int(3)
        )
        _ = send[ObjCObject, "endEncoding"](enc)
        _ = send[ObjCObject, "commit"](cb)
        _ = send[ObjCObject, "waitUntilCompleted"](cb)

        var px = List[UInt8](length=W * H * 4, fill=0)
        _ = send[ObjCObject, "getBytes:bytesPerRow:fromRegion:mipmapLevel:"](
            target,
            px.unsafe_ptr().unsafe_bitcast[NoneType](),
            Int(W * 4),
            MTLRegion(MTLOrigin(0, 0, 0), MTLSize(W, H, 1)),
            Int(0),
        )

        # (3,3) is inside the kernel's rectangle -> palette entry 5.
        let i = (3 * W + 3) * 4
        print(
            "pixel(3,3) BGRA =",
            Int(px[i]), Int(px[i + 1]), Int(px[i + 2]), Int(px[i + 3]),
        )
        if (
            abs(Int(px[i]) - 70) <= 2
            and abs(Int(px[i + 1]) - 80) <= 2
            and abs(Int(px[i + 2]) - 90) <= 2
        ):
            print("ok    a Mojo KERNEL's write reached the fragment shader")
        else:
            print("FAIL  the kernel's index did not reach the shader")
            failures += 1
        # (0,0) is outside it, still index 0 -> discarded, red clear shows.
        if Int(px[2]) >= 250 and Int(px[0]) <= 5:
            print("ok    untouched cells stayed transparent")
        else:
            print("FAIL  index 0 was not transparent")
            failures += 1

    # KEEPALIVE. The id<MTLBuffer> the accessor hands back is a BORROW: the
    # runtime does not retain it for us, so it lives exactly as long as the
    # DeviceBuffer that owns it. Mojo destroys a value at its LAST USE, not
    # at the end of the scope, so without this line `plane` dies at the
    # `plane._handle` above -- and every message sent to `mtl_buf` after
    # that goes to freed memory. It crashed on `length`, the first one.
    _ = plane

    print()
    if failures == 0:
        print("G0 shared memory: PASS")
    else:
        print("G0 shared memory: FAILED", failures, "check(s)")
        raise Error("shared spike failed")
