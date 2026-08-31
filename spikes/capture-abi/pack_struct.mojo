# The rms_norm adapter failure in miniature: a param-pack member that is a
# POINTER TO A HOST STRUCT. Typed device, the launch binds a stack address
# as a device buffer and dies with "unknown device address 0x16f...". Typed
# constant (the fix), the kernel reads the pack bytes through AS2.
from std.gpu import global_idx
from max.gpu.host import DeviceContext

comptime N = 256


@fieldwise_init
struct Caps:
    var a: Int32
    var b: Int32


def worker(
    dst: UnsafePointer[Float32, MutAnyOrigin],
    src: UnsafePointer[Float32, MutAnyOrigin],
    caps: UnsafePointer[Caps, MutAnyOrigin],
    scale: Float32,
):
    var i = Int(global_idx.x)
    if i < N:
        dst[unsafe_offset=i] = src[unsafe_offset=i] * scale + Float32(
            caps[].a + caps[].b
        )


def main() raises:
    var ctx = DeviceContext()
    var src = ctx.enqueue_create_buffer[DType.float32](N)
    var dst = ctx.enqueue_create_buffer[DType.float32](N)
    with src.map_to_host() as h:
        for i in range(N):
            h[i] = Float32(i)

    var caps = Caps(1, 6)
    var capsp = UnsafePointer(to=caps).unsafe_origin_cast[MutAnyOrigin]()
    var srcp = src.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    var scale = Float32(3)

    @__parameter
    @__copy_capture(srcp, capsp, scale)
    def adapter(target: UnsafePointer[Float32, MutAnyOrigin]):
        worker(target, srcp, capsp, scale)

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
    print("pack-struct: OK")
