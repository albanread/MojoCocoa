# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026, Modular Inc. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ===----------------------------------------------------------------------=== #
"""Differential test: the same kernel body on CPU and on GPU.

This fork changes only the GPU path -- the MLIR lowering to Apple AIR and the
Metal runtime under it. The CPU path is stock upstream Mojo compiled for the
host, so on this tree it is an *independent oracle*, which a hand-written
reference inside a test file is not:

  - a hand-written reference can drift from the kernel it is meant to check,
    or repeat the kernel's own mistake, and it only ever covers the shapes
    somebody remembered to write down;
  - a second GPU kernel is not independent at all -- a backend bug cancels on
    both sides and the comparison passes;
  - the CPU path shares the kernel's *source* but none of its *codegen*, so a
    divergence localises directly to the thing this fork actually modifies.

`normalization.rms_norm` is written on the `rowwise` dual-target surface: one
body, dispatched by `comptime if is_cpu[params.target]()`. Calling it twice --
once with `target="cpu"` and no `DeviceContext`, once with `target="gpu"` and
one -- runs identical arithmetic through two different backends over
bit-identical inputs.

Tolerances are for accumulation order, not for correctness. CPU and GPU reduce
a row in a different order, so results differ in the last bits; they must not
differ in any way a reordering cannot explain. A backend defect -- a dropped
row, a zeroed output, a mis-strided load -- is orders of magnitude outside
these bounds, which is the point.
"""

from std.math import sqrt
from std.random import rand
from std.testing import assert_true

from layout import Coord, TileTensor, row_major
from std.utils.coord import ComptimeInt
from max.gpu.host import DeviceContext
from nn.normalization import *
from max.gpu.host.info import *

from std.utils.index import Index, IndexList


def diff_rms_norm[
    rank: Int, //,
    dtype: DType,
    COLS: Int,
](
    ctx: DeviceContext,
    shape: IndexList[rank],
    label: StaticString,
    rtol: Float64 = 1e-5,
) raises -> Int:
    """Run rms_norm on both backends over one input; return mismatch count.

    `COLS` is a parameter because `rms_norm` takes the reduction extent as a
    `CoordLike`, and the concrete implementation of that is `ComptimeInt` --
    the row width is a compile-time quantity here, exactly as it is at the real
    call sites in `graph_compiler/builtin_kernels/reductions.mojo`.
    """
    var cols = shape[rank - 1]
    debug_assert(cols == COLS, "COLS parameter must match shape[rank-1]")
    var rows = shape.flattened_length() // cols
    var n = rows * cols

    # One input, used by both backends. `rand` fills the host buffer once; the
    # CPU copy and the device copy are made from it, so the two runs cannot
    # differ because of their inputs.
    var src = ctx.enqueue_create_host_buffer[dtype](n)
    var gamma_h = ctx.enqueue_create_host_buffer[dtype](cols)
    rand[dtype](src.as_span())
    for i in range(cols):
        gamma_h[i] = (Float64(i + cols) / Float64(cols)).cast[dtype]()

    var epsilon = Scalar[dtype](0.001)
    var weight_offset = Scalar[dtype](0.0)
    var param_shape = Index(cols)

    # ---- CPU: host buffers, no DeviceContext -------------------------------
    # Read and write sides are separate buffers: the dispatcher takes the input
    # and output closures as distinct mutable captures and rejects aliasing
    # them, and keeping the input pristine makes the comparison unambiguous.
    var cpu_in_buf = ctx.enqueue_create_host_buffer[dtype](n)
    var cpu_buf = ctx.enqueue_create_host_buffer[dtype](n)
    for i in range(n):
        cpu_in_buf[i] = src[i]
        cpu_buf[i] = Scalar[dtype](0)
    var cpu_src_tt = TileTensor(cpu_in_buf.unsafe_ptr(), row_major(Coord(shape)))
    var cpu_tt = TileTensor(cpu_buf.unsafe_ptr(), row_major(Coord(shape)))
    var gamma_cpu = TileTensor(
        gamma_h.unsafe_ptr(), row_major(Coord(param_shape))
    )

    # The `rms_norm` dispatcher takes the Row 3-arg lambda form
    # (width, alignment, rank) over `IndexList`, unlike `rms_norm_gpu` which
    # takes `Coord` -- see graph_compiler/builtin_kernels/reductions.mojo:1030.
    @always_inline
    def cpu_in[
        width: Int, alignment: Int, coord_rank: Int
    ](coords: IndexList[coord_rank]) {var cpu_src_tt} -> SIMD[dtype, width]:
        return cpu_src_tt.raw_load[width=width](
            cpu_src_tt.layout(Coord(rebind[IndexList[rank]](coords)))
        )

    @always_inline
    def cpu_out[
        width: SIMDLength, _rank: Int, alignment: Int
    ](coords: IndexList[_rank], val: SIMD[dtype, width]) {var cpu_tt}:
        cpu_tt.raw_store[width=width, alignment=alignment](
            cpu_tt.layout(Coord(rebind[IndexList[rank]](coords))), val
        )

    rms_norm[dtype, rank, target="cpu"](
        cpu_in,
        cpu_out,
        Coord(shape),
        ComptimeInt[COLS](),
        gamma_cpu,
        epsilon,
        weight_offset,
    )

    # ---- GPU: device buffers, with the DeviceContext ------------------------
    var src_d = ctx.enqueue_create_buffer[dtype](n)
    var data_d = ctx.enqueue_create_buffer[dtype](n)
    var gamma_d = ctx.enqueue_create_buffer[dtype](cols)
    ctx.enqueue_copy(src_d, src)
    ctx.enqueue_copy(gamma_d, gamma_h)
    # Zero the output so a kernel that never writes is distinguishable from one
    # that writes zeros -- both fail, but the log says which.
    var zeros = ctx.enqueue_create_host_buffer[dtype](n)
    for i in range(n):
        zeros[i] = Scalar[dtype](0)
    ctx.enqueue_copy(data_d, zeros)

    var gpu_src_tt = TileTensor(src_d, row_major(Coord(shape)))
    var gpu_tt = TileTensor(data_d, row_major(Coord(shape)))
    var gamma_gpu = TileTensor(gamma_d, row_major(Coord(param_shape)))

    # The `rms_norm` dispatcher takes the Row 3-arg lambda form
    # (width, alignment, rank) over `IndexList`, unlike `rms_norm_gpu` which
    # takes `Coord` -- see graph_compiler/builtin_kernels/reductions.mojo:1030.
    @always_inline
    def gpu_in[
        width: Int, alignment: Int, coord_rank: Int
    ](coords: IndexList[coord_rank]) {var gpu_src_tt} -> SIMD[dtype, width]:
        return gpu_src_tt.raw_load[width=width](
            gpu_src_tt.layout(Coord(rebind[IndexList[rank]](coords)))
        )

    @always_inline
    def gpu_out[
        width: SIMDLength, _rank: Int, alignment: Int
    ](coords: IndexList[_rank], val: SIMD[dtype, width]) {var gpu_tt}:
        gpu_tt.raw_store[width=width, alignment=alignment](
            gpu_tt.layout(Coord(rebind[IndexList[rank]](coords))), val
        )

    rms_norm[dtype, rank, target="gpu"](
        gpu_in,
        gpu_out,
        Coord(shape),
        ComptimeInt[COLS](),
        gamma_gpu,
        epsilon,
        weight_offset,
        ctx,
    )

    var gpu_res = ctx.enqueue_create_host_buffer[dtype](n)
    ctx.enqueue_copy(gpu_res, data_d)
    ctx.synchronize()

    # ---- validate the oracle before trusting it -----------------------------
    # A two-way comparison cannot tell which side is wrong. rms_norm has a
    # closed form, so check the CPU result against it first: if the CPU path
    # disagrees with the arithmetic, the fault is in this test or in the shared
    # kernel body, and any GPU divergence reported below is uninterpretable.
    comptime accum = get_accum_type[dtype]()
    var cpu_vs_formula = 0
    for r in range(rows):
        var ss = Scalar[accum](0)
        for c in range(cols):
            var v = Float64(src[r * cols + c]).cast[accum]()
            ss += v * v
        var rms = sqrt(ss / Scalar[accum](cols) + epsilon.cast[accum]())
        for c in range(cols):
            var i = r * cols + c
            var want = (Float64(src[i]) / Float64(rms)) * (
                Float64(gamma_h[c]) + Float64(weight_offset)
            )
            var got = Float64(cpu_buf[i])
            var denom = abs(want) if abs(want) > 1e-30 else 1.0
            if abs(want - got) / denom > rtol:
                cpu_vs_formula += 1
    if cpu_vs_formula != 0:
        print(
            "  ORACLE-FAIL ", label,
            ": the CPU path disagrees with the closed form in ",
            cpu_vs_formula, " element(s); GPU comparison below is not"
            " meaningful",
        )

    # ---- compare ------------------------------------------------------------
    var bad = 0
    var first = -1
    var worst = Float64(0.0)
    var all_zero = True
    for i in range(n):
        var c = Float64(cpu_buf[i])
        var g = Float64(gpu_res[i])
        if g != 0.0:
            all_zero = False
        # NaN loses every comparison, so name it rather than let it slide.
        if c != c or g != g:
            if first < 0:
                first = i
            bad += 1
            continue
        var denom = abs(c) if abs(c) > 1e-30 else 1.0
        var rel = abs(c - g) / denom
        if rel > worst:
            worst = rel
        if rel > rtol:
            if first < 0:
                first = i
            bad += 1

    if bad == 0:
        print(
            "  PASS ", label, " rows=", rows, " cols=", cols,
            " worst_rel=", worst,
        )
    else:
        print(
            "  FAIL ", label, " rows=", rows, " cols=", cols,
            " mismatched=", bad, "/", n,
            " first=", first,
            " cpu=", cpu_buf[first], " gpu=", gpu_res[first],
            " worst_rel=", worst,
        )

    # An all-zero GPU output with a non-trivial CPU result is the signature of
    # the address-space class of defect, where writes land in one space and
    # reads come back from another. It would already be caught above, but it is
    # worth naming explicitly rather than reporting as N mismatches.
    if all_zero and n > 0:
        print("  NOTE ", label, ": GPU output is entirely zero")

    _ = src_d
    _ = data_d
    _ = gamma_d
    return bad + cpu_vs_formula


def main() raises:
    var failed = 0
    with DeviceContext() as ctx:
        print("== rms_norm: CPU vs GPU, identical inputs")
        # Shapes chosen to straddle the dispatcher's internal thresholds: a
        # single short row, widths either side of a warp and a threadgroup, and
        # deliberately ragged column counts that no tiling divides evenly.
        # KNOWN LIMIT: this harness faults once the tensor exceeds roughly
        # 4096 elements (3899 passes, 4096 does not), and it still faults with
        # the GPU call removed -- so the fault is on the host side, in this
        # file or in the CPU rms_norm path, NOT in the Apple backend. Until
        # that is root-caused the shapes below stay under the limit; they are
        # already enough to expose the GPU defect. Do not read the limit as a
        # statement about the backend.
        failed += diff_rms_norm[DType.float32, 5](ctx, Index(2, 5), "tiny        ")
        failed += diff_rms_norm[DType.float32, 55](ctx, Index(2, 55), "sub-warp    ")
        failed += diff_rms_norm[DType.float32, 64](ctx, Index(8, 64), "warp-aligned")
        failed += diff_rms_norm[DType.float32, 65](ctx, Index(8, 65), "warp+1      ")
        failed += diff_rms_norm[DType.float32, 557](ctx, Index(7, 557), "ragged-557  ")
        failed += diff_rms_norm[DType.bfloat16, 128](
            ctx, Index(8, 128), "bf16-128    ", rtol=3e-2
        )

    if failed != 0:
        raise Error(
            "CPU/GPU differential: "
            + String(failed)
            + " element(s) diverged beyond accumulation-order tolerance"
        )
    print("cpu/gpu differential complete")
