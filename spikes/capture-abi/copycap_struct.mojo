# Minimal: does @__copy_capture of a STRUCT-typed local crash the parser?
from std.gpu import global_idx
from std.traits.copyable import ImplicitlyCopyable
from max.gpu.host import DeviceContext

comptime N = 64


@fieldwise_init
struct Pair(ImplicitlyCopyable):
    var a: Float32
    var b: Float32


def main() raises:
    var ctx = DeviceContext()
    var d = ctx.enqueue_create_buffer[DType.float32](N)
    var p = Pair(2, 3)

    @__parameter
    @__copy_capture(p)
    def k(dst: UnsafePointer[Float32, MutAnyOrigin]):
        var i = Int(global_idx.x)
        if i < N:
            dst[unsafe_offset=i] = p.a + p.b

    var f = ctx.compile_function[k]()
    ctx.enqueue_function(f, d, grid_dim=(1), block_dim=(N))
    ctx.synchronize()
    with d.map_to_host() as h:
        for i in range(N):
            if h[i] != 5:
                raise Error("copycap mismatch at " + String(i))
    print("copycap-struct: OK")
