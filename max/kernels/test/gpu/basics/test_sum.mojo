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

from std.math import ceildiv, iota

from std.gpu import global_idx
from std.gpu.primitives import warp
from max.gpu.primitives import block
from std.gpu.globals import WARP_SIZE
from max.gpu.host import DeviceContext
from std.testing import assert_equal

comptime dtype = DType.uint64


def warp_sum_kernel[
    dtype: DType,
](
    output: UnsafePointer[Scalar[dtype], MutAnyOrigin],
    input: UnsafePointer[Scalar[dtype], ImmutAnyOrigin],
    size_dev: Int32,
):
    var size = Int(size_dev)
    var tid = global_idx.x
    if tid >= size:
        return
    output[tid] = warp.sum(input[tid])


def test_warp_sum(ctx: DeviceContext) raises:
    comptime size = WARP_SIZE
    comptime BLOCK_SIZE = WARP_SIZE

    # Allocate and initialize host memory
    var in_host = ctx.enqueue_create_host_buffer[dtype](size)
    iota(in_host.as_span())
    var out_host = ctx.enqueue_create_host_buffer[dtype](size)

    # Create device buffers and copy input data
    var in_device = ctx.enqueue_create_buffer[dtype](size)
    var out_device = ctx.enqueue_create_buffer[dtype](size)
    ctx.enqueue_copy(in_device, in_host)

    # Launch kernel
    var grid_dim = ceildiv(size, BLOCK_SIZE)
    comptime kernel = warp_sum_kernel[dtype=dtype]
    ctx.enqueue_function[kernel](
        out_device,
        in_device,
        Int32(size),
        block_dim=BLOCK_SIZE,
        grid_dim=grid_dim,
    )

    # Copy results back and verify
    ctx.enqueue_copy(out_host, out_device)
    ctx.synchronize()

    for i in range(size):
        var expected: Scalar[dtype] = UInt64(size * (size - 1) // 2)

        assert_equal(
            out_host[i],
            expected,
            msg=String(t"out_host[{i}] = {out_host[i]} expected = {expected}"),
        )
    _ = in_host^


def block_sum_kernel[
    dtype: DType,
    block_size: Int,
](
    output: UnsafePointer[Scalar[dtype], MutAnyOrigin],
    input: UnsafePointer[Scalar[dtype], ImmutAnyOrigin],
    size_dev: Int32,
):
    var size = Int(size_dev)
    var tid = global_idx.x
    # The early `return` this replaces put the block.sum barrier under a
    # thread-varying conditional -- the exact shape the divergent-barrier
    # legality rule refuses, because lanes that returned early reach a
    # different barrier instance and the threadgroup never synchronises.
    # The collective must be reached by every thread: clamp the load index
    # instead and guard only the store. The test's sizes are full blocks,
    # where the clamp is the identity.
    var idx = Int(0) if size <= 0 else min(tid, size - 1)
    var s = block.sum[block_size=block_size, broadcast=True](input[idx])
    if tid < size:
        output[tid] = s


def test_block_sum(ctx: DeviceContext) raises:
    # Initialize a block with several warps. The sum for each warp is tested
    # above.
    comptime BLOCK_SIZE = WARP_SIZE * 2
    comptime size = BLOCK_SIZE

    # Allocate and initialize host memory
    var in_host = ctx.enqueue_create_host_buffer[dtype](size)
    iota(in_host.as_span())
    var out_host = ctx.enqueue_create_host_buffer[dtype](size)

    # Create device buffers and copy input data
    var in_device = ctx.enqueue_create_buffer[dtype](size)
    var out_device = ctx.enqueue_create_buffer[dtype](size)
    ctx.enqueue_copy(in_device, in_host)

    # Launch kernel
    var grid_dim = ceildiv(size, BLOCK_SIZE)
    comptime kernel = block_sum_kernel[dtype=dtype, block_size=BLOCK_SIZE]
    ctx.enqueue_function[kernel](
        out_device,
        in_device,
        Int32(size),
        block_dim=BLOCK_SIZE,
        grid_dim=grid_dim,
    )

    # Copy results back and verify
    ctx.enqueue_copy(out_host, out_device)
    ctx.synchronize()

    for i in range(size):
        var expected: Scalar[dtype] = UInt64(size * (size - 1) // 2)

        assert_equal(
            out_host[i],
            expected,
            msg=String(t"out_host[{i}] = {out_host[i]} expected = {expected}"),
        )


def main() raises:
    with DeviceContext() as ctx:
        test_warp_sum(ctx)

        test_block_sum(ctx)
