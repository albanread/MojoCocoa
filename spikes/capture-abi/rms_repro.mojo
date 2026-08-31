# The differential test's rms_norm gpu path, in miniature: the real
# dispatcher, real TileTensors, the real Row-lambda form.
from layout import Coord, TileTensor, row_major
from nn.normalization import rms_norm
from max.gpu.host import DeviceContext
from std.utils import IndexList
from std.testing import assert_equal

comptime ROWS = 8
comptime COLS = 64


def main() raises:
    var ctx = DeviceContext()
    comptime shape = IndexList[2](ROWS, COLS)
    comptime lt = row_major(Coord(shape))

    var src_h = ctx.enqueue_create_buffer[DType.float32](ROWS * COLS)
    var tt_h = ctx.enqueue_create_buffer[DType.float32](ROWS * COLS)
    var dst = ctx.enqueue_create_buffer[DType.float32](ROWS * COLS)
    var gamma = TileTensor(tt_h.unsafe_ptr(), row_major(Coord(IndexList[1](COLS))))

    with src_h.map_to_host() as s, tt_h.map_to_host() as g:
        for i in range(ROWS * COLS):
            s[i] = Float32(i % 7)
            g[i] = Float32(1)

    var src_tt = TileTensor(src_h.unsafe_ptr(), lt)
    var out_tt = TileTensor(dst.unsafe_ptr(), lt)

    @always_inline
    def gpu_in[
        width: Int, alignment: Int, coord_rank: Int
    ](coords: IndexList[coord_rank]) {var src_tt} -> SIMD[DType.float32, width]:
        return src_tt.raw_load[width=width](
            src_tt.layout(Coord(rebind[IndexList[2]](coords)))
        )

    @always_inline
    def gpu_out[
        width: SIMDLength, _rank: Int, alignment: Int
    ](coords: IndexList[_rank], val: SIMD[DType.float32, width]) {var out_tt}:
        out_tt.raw_store[width=width, alignment=alignment](
            out_tt.layout(Coord(rebind[IndexList[2]](coords))), val
        )

    rms_norm[DType.float32, 2, target="gpu"](
        gpu_in, gpu_out, Coord(shape), COLS, gamma, 1e-5, 0.0, ctx
    )
    ctx.synchronize()

    with dst.map_to_host() as o, src_h.map_to_host() as s:
        for r in range(ROWS):
            var sq = Float64(0)
            for c in range(COLS):
                var v = Float64(s[r * COLS + c])
                sq += v * v
            var rms = (sq / COLS) ** 0.5
            var want = Float32(rms)
            if rms > 0:
                want = Float32(Float64(s[r * COLS]) / rms)
            var got = o[r * COLS]
            if abs(Float64(got) - Float64(want)) > 0.01:
                raise Error(
                    "rms repro mismatch at row " + String(r) + ": got "
                    + String(got) + " want " + String(want)
                )
    print("rms-repro: OK")
