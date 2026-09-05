"""The bridge between `max.gpu`'s device objects and Metal's own.

A plane in this game pane is one allocation with three readers: the CPU
stores into it, a Mojo kernel reads and writes it, and the fragment shader
samples it through a texture view. `max.gpu` gives the first two -- a
`DeviceBuffer` is host-writable under unified memory and is what a kernel
takes -- but it does not expose the `id<MTLBuffer>` underneath, and without
that there is no texture view and no third reader.

These four functions are that missing half. They are thin wrappers over
entry points in this fork's own GPU runtime (`AppleGPURT.cpp`), added for
exactly this; nothing here reaches into Metal behind the runtime's back.

**The lifetime rule, which is the whole hazard.** `metal_buffer` returns a
BORROW. It is not retained, it lives exactly as long as the `DeviceBuffer`
that owns it, and Mojo destroys a value at its LAST USE rather than at the
end of the scope. So a struct that keeps a texture view must also keep the
`DeviceBuffer` the view is over, as a field, for as long as it keeps the
view. Every pane here does; getting it wrong costs a message to freed
memory at the first `send`, which is what it did on 2026-09-05.
"""

from std.objc import Cls, ObjCObject, send, nsenum
from std.ffi import external_call, c_char
from std.memory import OpaquePointer, Pointer
from max.gpu.host import DeviceContext, DeviceBuffer

comptime P = OpaquePointer[MutUntrackedOrigin]


def metal_device(ctx: DeviceContext) raises -> Int:
    """The `id<MTLDevice>` the runtime runs kernels on.

    Use THIS for every layer, pipeline and texture rather than
    `MTLCreateSystemDefaultDevice`: a texture made by one device and sampled
    by another is undefined. G0 established they are the same object on a
    single-GPU Mac, which makes this belt and braces rather than a fix --
    and it stays correct on a Mac where they would not be.
    """
    var slot = List[Int](length=1, fill=0)
    let err = external_call["AsyncRT_DeviceContext_metal_device", P](
        slot.unsafe_ptr(), ctx._handle
    )
    if Int(err) != 0:
        raise Error(
            "metal_device: "
            + String(unsafe_from_utf8_ptr=err.unsafe_bitcast[c_char]())
        )
    return slot[0]


def metal_buffer[
    dtype: DType
](buf: DeviceBuffer[dtype]) raises -> Int:
    """The `id<MTLBuffer>` behind a `DeviceBuffer` -- a borrow; see above."""
    var slot = List[Int](length=1, fill=0)
    let err = external_call["AsyncRT_DeviceBuffer_metal_buffer", P](
        slot.unsafe_ptr(), buf._handle
    )
    if Int(err) != 0:
        raise Error(
            "metal_buffer: "
            + String(unsafe_from_utf8_ptr=err.unsafe_bitcast[c_char]())
        )
    return slot[0]


def metal_offset[dtype: DType](buf: DeviceBuffer[dtype]) -> Int:
    """The view offset within that buffer -- non-zero only for a sub-buffer.

    A separate call rather than a second out-parameter: the shape that works
    from Mojo is `hostPtr`'s, one out-slot and the handle, and passing a
    third argument to a two-parameter C function is how an afternoon goes
    missing.
    """
    return Int(
        external_call["AsyncRT_DeviceBuffer_metal_offset", Int](buf._handle)
    )


def linear_alignment(device: Int, pixel_format: Int) -> Int:
    """The row alignment a buffer-backed texture of this format demands.

    Rounding a row up to it is what makes
    `newTextureWithDescriptor:offset:bytesPerRow:` legal at all, and it is
    where every stride in the game pane comes from. It is 16 for `R8Uint`
    on Apple silicon, so the stride is almost never the width.
    """
    let a = Int(
        send[Int, "minimumLinearTextureAlignmentForPixelFormat:"](
            ObjCObject(device), pixel_format
        )
    )
    return a if a > 0 else 1


def index_plane_view(
    mtl_buffer: Int, offset: Int, width: Int, height: Int, stride: Int
) raises -> Int:
    """An `R8Uint` texture view over `stride`-byte rows of a shared buffer.

    The convenience 2D descriptor does not know the storage mode, and a
    buffer-backed texture must be described with the SAME one as the buffer
    it views -- Shared here, because that is what makes the bytes CPU-
    writable and GPU-samplable at once.
    """
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
    _ = send[ObjCObject, "setStorageMode:"](
        tdesc, nsenum["MTLStorageModeShared"]()
    )
    let view = send[
        ObjCObject, "newTextureWithDescriptor:offset:bytesPerRow:"
    ](ObjCObject(mtl_buffer), tdesc.ptr(), offset, stride)
    if view.addr() == 0:
        raise Error("no texture view over the index plane")
    return view.addr()


def host_ptr[
    dtype: DType
](buf: DeviceBuffer[dtype]) raises -> Pointer[UInt8, MutUntrackedOrigin]:
    """The CPU address of a `DeviceBuffer`'s bytes.

    Under unified memory a device buffer has a perfectly good CPU pointer,
    which is the entire reason there is no upload step anywhere in this
    package.
    """
    var slot = List[Int](length=1, fill=0)
    let err = external_call["AsyncRT_DeviceBuffer_hostPtr", P](
        slot.unsafe_ptr(), buf._handle
    )
    if Int(err) != 0:
        raise Error(
            "hostPtr: " + String(unsafe_from_utf8_ptr=err.unsafe_bitcast[c_char]())
        )
    if slot[0] == 0:
        raise Error("hostPtr: this buffer is not host-visible")
    return Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=slot[0])
