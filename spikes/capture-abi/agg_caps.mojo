# Multi-capture with a POINTER member, through an adapter: the rms_norm
# adapter shape in miniature. The pointer capture travels as pack bytes
# ("captures are raw values"), and the question is whether the kernel's
# parameter for it is typed constant (right) or device (the bug).
from std.gpu import global_idx
from max.gpu.host import DeviceContext

comptime N = 256


def worker(
    dst: UnsafePointer[Float32, MutAnyOrigin],
    src: UnsafePointer[Float32, MutAnyOrigin],
    scale: Float32,
    bias: Int32,
):
    var i = Int(global_idx.x)
    if i < N:
        dst[unsafe_offset=i] = src[unsafe_offset=i] * scale + Float32(bias)


def main() raises:
    var ctx = DeviceContext()
    var src = ctx.enqueue_create_buffer[DType.float32](N)
    var dst = ctx.enqueue_create_buffer[DType.float32](N)
    with src.map_to_host() as h:
        for i in range(N):
            h[i] = Float32(i)

    var srcp = src.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    var scale = Float32(3)
    var bias = Int32(7)

    @__parameter
    @__copy_capture(srcp, scale, bias)
    def adapter(target: UnsafePointer[Float32, MutAnyOrigin]):
        worker(target, srcp, scale, bias)

    var f = ctx.compile_function[adapter]()
    ctx.enqueue_function(f, dst, grid_dim=(1), block_dim=(N))
    ctx.synchronize()

    with dst.map_to_host() as host:
        for i in range(N):
            var want = Float32(i) * 3 + 7
            if host[i] != want:
                raise Error(
                    "pack mismatch at " + String(i) + ": got " + String(host[i])
                )
    print("pack-capture: OK")
