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
"""GPU random number generation, checked with a Barnsley fern.

The previous version of this file ran the RNG and printed 256 values per
dtype. Nothing in it could fail: all-zeros, all-NaN, or a generator stuck on
one value printed just as happily and the test reported success. On a compiler
backend port that is worse than no test, because it occupies a slot in the pass
count while proving nothing.

A Barnsley fern is a stricter instrument than a histogram. It is an iterated
function system: from a point, pick one of four affine maps with probabilities
1% / 85% / 7% / 7% and apply it, forever. The attractor is a fern -- but only
if the *distribution* of the choices is right. Range alone is not enough:

  - a generator stuck at 0 always selects map 1 (`x' = 0, y' = 0.16y`), which
    drives every point to the origin, so the cloud collapses and `max_y`
    collapses with it;
  - a generator stuck at any other value picks a single map forever, and every
    one of the remaining three has a single fixed point, so the cloud again
    collapses to one dot;
  - weights that are merely skewed distort the frond lengths and change how
    much of the bounding box is occupied.

So the test asserts on three independent consequences -- the selection
frequencies, the attractor's bounding box, and how much of the grid it fills --
and prints the fern so a human can see the same thing the assertions checked.
Both a collapsed cloud and uniform noise fail: one fills too few cells, the
other fills too many.

Fern geometry and the canonical probabilities are Barnsley's; the bounding box
of the attractor is x in [-2.182, 2.656], y in [0, 9.998].
"""

from std.gpu import global_idx
from std.math import ceildiv, sqrt
from std.random import NormalRandom, Random
from std.sys import has_apple_gpu_accelerator
from std.testing import assert_almost_equal, assert_true

from max.gpu.host import DeviceContext

comptime N_CHAINS = 256
comptime ITERS = 1024
comptime BURN_IN = 24  # discard the walk in from (0,0) onto the attractor
comptime KEEP = ITERS - BURN_IN
comptime N_POINTS = N_CHAINS * KEEP
comptime BLOCK = 64
comptime SEED = 0x5EED_FE47

# Rendering grid for the printed fern.
comptime GRID_W = 68
comptime GRID_H = 96

# The attractor's true extent, used both to map points onto the grid and as
# the reference for the bounding-box assertions.
comptime FERN_MIN_X = -2.182
comptime FERN_MAX_X = 2.6558
comptime FERN_MIN_Y = 0.0
comptime FERN_MAX_Y = 9.9983


def fern_kernel(
    pts_ptr: UnsafePointer[Scalar[DType.float32], MutAnyOrigin],
    sel_ptr: UnsafePointer[Scalar[DType.int32], MutAnyOrigin],
):
    """Run one IFS chain per thread; record its points and its map choices.

    Each thread takes its own Philox subsequence, so the chains are independent
    streams of the same generator rather than the same stream re-seeded --
    which is what the parallel case actually needs to be correct.
    """
    var tid = Int(global_idx.x)
    if tid >= N_CHAINS:
        return

    var rng = Random(seed=UInt64(SEED), subsequence=UInt64(tid))
    var x = Float32(0.0)
    var y = Float32(0.0)

    var n0 = Int32(0)
    var n1 = Int32(0)
    var n2 = Int32(0)
    var n3 = Int32(0)

    # step_uniform() yields 4 values at a time; spend them before stepping.
    var cache = rng.step_uniform()
    var ci = 0

    for i in range(ITERS):
        if ci == 4:
            cache = rng.step_uniform()
            ci = 0
        var r = cache[ci]
        ci += 1

        var nx: Float32
        var ny: Float32
        if r < 0.01:
            nx = 0.0
            ny = 0.16 * y
            n0 += 1
        elif r < 0.86:
            nx = 0.85 * x + 0.04 * y
            ny = -0.04 * x + 0.85 * y + 1.6
            n1 += 1
        elif r < 0.93:
            nx = 0.20 * x - 0.26 * y
            ny = 0.23 * x + 0.22 * y + 1.6
            n2 += 1
        else:
            nx = -0.15 * x + 0.28 * y
            ny = 0.26 * x + 0.24 * y + 0.44
            n3 += 1
        x = nx
        y = ny

        if i >= BURN_IN:
            var k = tid * KEEP + (i - BURN_IN)
            pts_ptr[2 * k] = x
            pts_ptr[2 * k + 1] = y

    sel_ptr[tid * 4 + 0] = n0
    sel_ptr[tid * 4 + 1] = n1
    sel_ptr[tid * 4 + 2] = n2
    sel_ptr[tid * 4 + 3] = n3


def run_fern(ctx: DeviceContext) raises:
    var pts_dev = ctx.enqueue_create_buffer[DType.float32](2 * N_POINTS)
    var sel_dev = ctx.enqueue_create_buffer[DType.int32](4 * N_CHAINS)

    ctx.enqueue_function[fern_kernel](
        pts_dev,
        sel_dev,
        grid_dim=(ceildiv(N_CHAINS, BLOCK),),
        block_dim=(BLOCK,),
    )

    var pts = ctx.enqueue_create_host_buffer[DType.float32](2 * N_POINTS)
    var sel = ctx.enqueue_create_host_buffer[DType.int32](4 * N_CHAINS)
    ctx.enqueue_copy(pts, pts_dev)
    ctx.enqueue_copy(sel, sel_dev)
    ctx.synchronize()

    # --- 1. selection frequencies -------------------------------------------
    # This is the direct measurement of the generator's distribution: the four
    # branch probabilities are just four thresholds on a uniform variate.
    var c0 = 0
    var c1 = 0
    var c2 = 0
    var c3 = 0
    for t in range(N_CHAINS):
        c0 += Int(sel[t * 4 + 0])
        c1 += Int(sel[t * 4 + 1])
        c2 += Int(sel[t * 4 + 2])
        c3 += Int(sel[t * 4 + 3])
    var total = Float64(c0 + c1 + c2 + c3)
    assert_true(total > 0.0, "no IFS steps were recorded at all")

    var f0 = Float64(c0) / total
    var f1 = Float64(c1) / total
    var f2 = Float64(c2) / total
    var f3 = Float64(c3) / total
    print("map selection frequencies (want 0.01 / 0.85 / 0.07 / 0.07):")
    print("  f1 =", f0, " f2 =", f1, " f3 =", f2, " f4 =", f3)

    # ~262k draws; these bands are wide enough never to flake and far too tight
    # for a degenerate or badly skewed generator to slip through.
    assert_almost_equal(f0, 0.01, atol=0.004, msg="map-1 probability is wrong")
    assert_almost_equal(f1, 0.85, atol=0.010, msg="map-2 probability is wrong")
    assert_almost_equal(f2, 0.07, atol=0.008, msg="map-3 probability is wrong")
    assert_almost_equal(f3, 0.07, atol=0.008, msg="map-4 probability is wrong")

    # --- 2. the attractor's bounding box -------------------------------------
    var min_x = Float32(1.0e30)
    var max_x = Float32(-1.0e30)
    var min_y = Float32(1.0e30)
    var max_y = Float32(-1.0e30)
    for k in range(N_POINTS):
        var px = pts[2 * k]
        var py = pts[2 * k + 1]
        # NaN would silently lose every comparison below, so reject it here.
        assert_true(px == px and py == py, "IFS produced a NaN coordinate")
        if px < min_x:
            min_x = px
        if px > max_x:
            max_x = px
        if py < min_y:
            min_y = py
        if py > max_y:
            max_y = py
    print("bounding box: x [", min_x, ",", max_x, "]  y [", min_y, ",", max_y, "]")

    # A collapsed cloud (the all-zeros failure mode) dies on max_y.
    assert_true(
        Float64(min_x) > -2.35 and Float64(min_x) < -1.85,
        "fern min_x outside the attractor's known extent",
    )
    assert_true(
        Float64(max_x) > 2.35 and Float64(max_x) < 2.85,
        "fern max_x outside the attractor's known extent",
    )
    assert_true(
        Float64(min_y) >= -0.02 and Float64(min_y) < 0.25,
        "fern min_y outside the attractor's known extent",
    )
    assert_true(
        Float64(max_y) > 9.40 and Float64(max_y) < 10.15,
        "fern max_y outside the attractor's known extent -- a collapsed point"
        " cloud looks like this",
    )

    # --- 3. occupancy, and the picture ---------------------------------------
    var grid = Array[Scalar[DType.int32], GRID_W * GRID_H](fill=0)
    comptime sx = Float64(GRID_W - 1) / (FERN_MAX_X - FERN_MIN_X)
    comptime sy = Float64(GRID_H - 1) / (FERN_MAX_Y - FERN_MIN_Y)
    for k in range(N_POINTS):
        var gx = Int((Float64(pts[2 * k]) - FERN_MIN_X) * sx + 0.5)
        var gy = Int((Float64(pts[2 * k + 1]) - FERN_MIN_Y) * sy + 0.5)
        if gx >= 0 and gx < GRID_W and gy >= 0 and gy < GRID_H:
            grid[gy * GRID_W + gx] += 1

    var occupied = 0
    for i in range(GRID_W * GRID_H):
        if grid[i] > 0:
            occupied += 1
    var frac = Float64(occupied) / Float64(GRID_W * GRID_H)
    print("occupied cells:", occupied, "of", GRID_W * GRID_H, "=", frac)

    print("")
    for row in range(GRID_H - 1, -1, -1):
        var line = String("  ")
        for col in range(GRID_W):
            var n = Int(grid[row * GRID_W + col])
            if n == 0:
                line += " "
            elif n < 4:
                line += "."
            elif n < 20:
                line += "+"
            else:
                line += "#"
        print(line)
    print("")

    # Occupancy of the attractor on this grid is a property of the fern, not of
    # the generator, so it can be pinned rather than merely bounded. An
    # independent CPU implementation of the same IFS -- different generator,
    # different seed -- gives 0.491; this GPU run gives 0.492. The band below is
    # +/-0.05 around that, which is far outside run-to-run drift and far inside
    # either failure mode: a collapsed cloud lands near 0.00, and noise filling
    # the bounding box lands near 1.00.
    assert_true(
        frac > 0.44,
        "fern covers too little of the grid -- the point cloud collapsed"
        " toward a fixed point",
    )
    assert_true(
        frac < 0.55,
        "fern covers too much of the grid -- this is noise filling the"
        " bounding box, not an attractor",
    )


def run_distribution_checks(ctx: DeviceContext) raises:
    """Keep the plain statistical coverage the old file gestured at.

    The fern exercises `step_uniform` through its branch thresholds; these two
    check the raw moments, and that `step_normal` is wired up at all.
    """
    comptime N = 4096

    def uniform_kernel(
        out_ptr: UnsafePointer[Scalar[DType.float32], MutAnyOrigin],
    ):
        var tid = Int(global_idx.x)
        if tid >= N // 4:
            return
        var rng = Random(seed=UInt64(SEED), subsequence=UInt64(tid))
        var v = rng.step_uniform()
        comptime for i in range(4):
            out_ptr[tid * 4 + i] = v[i]

    def normal_kernel(
        out_ptr: UnsafePointer[Scalar[DType.float32], MutAnyOrigin],
    ):
        var tid = Int(global_idx.x)
        if tid >= N // 8:
            return
        var rng = NormalRandom(seed=UInt64(SEED), subsequence=UInt64(tid))
        var v = rng.step_normal()
        comptime for i in range(8):
            out_ptr[tid * 8 + i] = v[i]

    var dev = ctx.enqueue_create_buffer[DType.float32](N)
    var host = ctx.enqueue_create_host_buffer[DType.float32](N)

    ctx.enqueue_function[uniform_kernel](
        dev, grid_dim=(ceildiv(N // 4, BLOCK),), block_dim=(BLOCK,)
    )
    ctx.enqueue_copy(host, dev)
    ctx.synchronize()
    var usum = Float64(0.0)
    for i in range(N):
        var u = Float64(host[i])
        assert_true(u >= 0.0 and u < 1.0, "step_uniform left [0,1)")
        usum += u
    var umean = usum / Float64(N)
    print("uniform mean:", umean, "(want 0.5)")
    assert_almost_equal(umean, 0.5, atol=0.03, msg="uniform mean is off")

    ctx.enqueue_function[normal_kernel](
        dev, grid_dim=(ceildiv(N // 8, BLOCK),), block_dim=(BLOCK,)
    )
    ctx.enqueue_copy(host, dev)
    ctx.synchronize()
    var nsum = Float64(0.0)
    for i in range(N):
        nsum += Float64(host[i])
    var nmean = nsum / Float64(N)
    var nvar = Float64(0.0)
    for i in range(N):
        var d = Float64(host[i]) - nmean
        nvar += d * d
    var nsd = sqrt(nvar / Float64(N))
    print("normal mean:", nmean, "stddev:", nsd, "(want 0.0 / 1.0)")
    assert_almost_equal(nmean, 0.0, atol=0.06, msg="normal mean is off")
    assert_almost_equal(nsd, 1.0, atol=0.06, msg="normal stddev is off")


def main() raises:
    with DeviceContext() as ctx:
        run_fern(ctx)
        run_distribution_checks(ctx)
        print("ALL RANDOM TESTS PASSED")
