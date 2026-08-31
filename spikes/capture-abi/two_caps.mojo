# Two-capture reproducer for the param-pack address-space case.
#
# One capture works (probe 06 / test_index_tensor since the byval fix); an
# adapter closure capturing MULTIPLE values is the documented remainder --
# the captures arrive as a kgen param pack and its pointer members take Mut
# convention, so the byval pack typing never fires and the pack is typed
# device. Expected symptom, from the rms_norm adapter:
#
#   [applegpu] '<kernel>' arg N: caller says constant, reflection says device
#
# The host verifies every element; run under GPU validation on our side.
from std.gpu import global_idx
from max.gpu.host import DeviceContext

comptime N = 256


@__parameter
def worker[
    width: Int
](dst: Pointer[Float32, MutAnyOrigin], scale: Float32, bias: Int32):
    var i = Int(global_idx.x)
    if i < N:
        dst[unsafe_offset=i] = Float32(i) * scale + Float32(bias)


def main() raises:
    var ctx = DeviceContext()
    var d = ctx.enqueue_create_buffer[DType.float32](N)

    # Two captures through an adapter layer -- the nesting depth that packs.
    var scale = Float32(3)
    var bias = Int32(7)

    @__parameter
    @__copy_capture(scale, bias)
    def adapter(dst: Pointer[Float32, MutAnyOrigin]):
        worker[1](dst, scale, bias)

    var f = ctx.compile_function[adapter]()
    ctx.enqueue_function(f, d, grid_dim=(1), block_dim=(N))
    ctx.synchronize()

    with d.map_to_host() as host:
        for i in range(N):
            var expected = Float32(i) * 3 + 7
            if host[i] != expected:
                raise Error(
                    "two-capture mismatch at "
                    + String(i)
                    + ": got "
                    + String(host[i])
                    + " want "
                    + String(expected)
                )
    print("two-capture: OK")
