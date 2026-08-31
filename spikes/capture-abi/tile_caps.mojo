# The MOCO-4045 test: a copy-captured TileTensor (memory-passable,
# DevicePassable) must cross the device boundary BY VALUE and read
# correctly. Before the fix this boxed thin and died with
# "unknown device address".
from layout import TileTensor, row_major
from std.gpu import global_idx
from max.gpu.host import DeviceContext
from layout import Coord
from std.utils import IndexList

comptime N = 64


def main() raises:
    var ctx = DeviceContext()
    var src = ctx.enqueue_create_buffer[DType.float32](N)
    var dst = ctx.enqueue_create_buffer[DType.float32](N)
    with src.map_to_host() as h:
        for i in range(N):
            h[i] = Float32(i)

    comptime lt = row_major(Coord(IndexList[1](N)))
    var tt = TileTensor(src.unsafe_ptr(), lt)

    @__parameter
    @__copy_capture(tt)
    def k(target: UnsafePointer[Float32, MutAnyOrigin]):
        var i = Int(global_idx.x)
        if i < N:
            target[unsafe_offset=i] = tt.raw_load[width=1](tt.layout(Coord(IndexList[1](Int(i)))))[0] * Float32(3)

    var f = ctx.compile_function[k]()
    ctx.enqueue_function(f, dst, grid_dim=(1), block_dim=(N))
    ctx.synchronize()
    with dst.map_to_host() as o:
        for i in range(N):
            if o[i] != Float32(i) * 3:
                raise Error(
                    "tile-capture mismatch at " + String(i) + ": got "
                    + String(o[i])
                )
    print("tile-capture: OK")
