# ===----------------------------------------------------------------------=== #
# A scalar whose bits are a live device address.
#
# The launch path used to classify an argument by LOOKING AT ITS VALUE: an
# eight-byte scalar was treated as a device pointer if it happened to resolve
# inside the allocation registry. That is correct almost always and wrong in
# exactly the case constructed here -- a scalar whose bits collide with a live
# allocation gets bound with setBuffer instead of setBytes, and the kernel
# reads the buffer's contents where it expected an integer.
#
# It is not a hypothetical: device addresses are dense, and any kernel taking
# a 64-bit size, offset, count or seed can produce one by arithmetic.
#
# Reflection settles it without inference -- the kernel's own declaration says
# which slot is a buffer -- so this test is the reason the generated-metallib
# path is required to have a complete reflected contract and forbidden from
# letting caller flags or value inspection override it.
# ===----------------------------------------------------------------------=== #

from max.gpu.host import DeviceContext
from std.gpu import global_idx
from std.testing import assert_equal


def echo_scalar_fn(
    output: UnsafePointer[UInt64, MutAnyOrigin],
    # Deliberately a SCALAR, and deliberately 64-bit: this is the argument
    # whose bits are about to be a valid device address.
    suspicious: UInt64,
    len_dev: Int32,
):
    var tid = global_idx.x
    if Int(tid) >= Int(len_dev):
        return
    # If `suspicious` were bound as a buffer, this reads the first eight bytes
    # of that buffer rather than the integer, and the comparison below fails.
    output[tid] = suspicious


def run_adversarial(ctx: DeviceContext) raises:
    comptime length = 64

    var out_device = ctx.enqueue_create_buffer[DType.uint64](length)
    # A second, real allocation. Its address is what we then hand over as a
    # plain integer -- so the value IS live in the registry and any
    # value-based classifier must misfire on it.
    var decoy = ctx.enqueue_create_buffer[DType.float32](length)

    var decoy_addr = UInt64(Int(decoy.unsafe_ptr()))

    ctx.enqueue_function[echo_scalar_fn](
        out_device,
        decoy_addr,
        Int32(length),
        grid_dim=(1),
        block_dim=(length),
    )
    ctx.synchronize()

    with out_device.map_to_host() as out_host:
        for i in range(4):
            # The kernel must have received the ADDRESS AS A NUMBER, not the
            # contents of the buffer that lives at it.
            assert_equal(out_host[i], decoy_addr)

    _ = decoy


def main() raises:
    with DeviceContext() as ctx:
        run_adversarial(ctx)
    print("arg contract: scalar colliding with a live address stayed a scalar")
