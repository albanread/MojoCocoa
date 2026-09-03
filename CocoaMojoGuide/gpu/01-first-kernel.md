# 1. Your first kernel
<!-- doccrate:keep-together:start -->


## A kernel is a function

There is no kernel keyword and no attribute. A kernel is a `def` whose
parameters can cross to the device, which asks for its own thread index and
does one element's worth of work:

<!-- doccrate:keep-together:end -->
<!-- doccrate:keep-together:start -->


```mojo
from std.gpu import global_idx

def mandelbrot_kernel(
    escape: Pointer[UInt32, MutAnyOrigin],
    center_x: Float32,
    center_y: Float32,
    scale: Float32,
):
    var idx = Int(global_idx.x)
    if idx < PIXELS:
        var px = idx % WIDTH
        var py = idx // WIDTH
        var cx = center_x + (Float32(px) - Float32(WIDTH) * 0.5) * scale
        var cy = center_y + (Float32(py) - Float32(HEIGHT) * 0.5) * scale

        var zx = Float32(0)
        var zy = Float32(0)
        var n = UInt32(0)
        while n < UInt32(MAX_ITER) and zx * zx + zy * zy <= Float32(4):
            var nzx = zx * zx - zy * zy + cx
            zy = Float32(2) * zx * zy + cy
            zx = nzx
            n += 1

        escape[unsafe_offset=idx] = n
```

<!-- doccrate:keep-together:end -->

Three things in that signature are worth pausing on.

**`Pointer[UInt32, MutAnyOrigin]`** — device buffers use `MutAnyOrigin`, not
the `MutUntrackedOrigin` that Cocoa code uses. The pointer is tracked; it just
has no single named origin.

**Scalars pass by value.** `center_x`, `scale` and friends are copied into the
launch, so small parameters cost nothing to pass and need no buffer.

**The bounds check is not optional.** Grids are rounded up to whole blocks, so
the final block runs threads past the end of your data. Without `if idx < n`
those threads write outside the buffer.
<!-- doccrate:keep-together:start -->


## The host side, in five calls

```mojo
from max.gpu.host import DeviceContext

def main() raises:
    var ctx = DeviceContext(api="metal")
    var dev = ctx.enqueue_create_buffer[DType.uint32](PIXELS)
    var f = ctx.compile_function[mandelbrot_kernel]()

    comptime block = 256
    comptime grid = (PIXELS + block - 1) // block

    ctx.enqueue_function(f, dev, cx, cy, scale,
                         grid_dim=(grid), block_dim=(block))
    ctx.synchronize()
```

<!-- doccrate:keep-together:end -->
<!-- doccrate:keep-together:start -->


| Call | What it does |
|:---|:---|
| `DeviceContext(api="metal")` | Opens the device |
| `enqueue_create_buffer[DType.T](n)` | Allocates `n` elements of device memory |
| `compile_function[kernel]()` | Compiles the kernel and builds its pipeline |
| `enqueue_function(f, args…, grid_dim=, block_dim=)` | Launches it |
| `synchronize()` | Waits for completion |

<!-- doccrate:keep-together:end -->

`compile_function` is the expensive call. Hoist it out of any loop — compile
once, launch many times.
<!-- doccrate:keep-together:start -->


## Choosing the grid

```mojo
comptime block = 256
comptime grid = (PIXELS + block - 1) // block
```

<!-- doccrate:keep-together:end -->

`block_dim` is how many threads are in each block; `grid_dim` is how many
blocks. The ceiling division is the standard idiom for "enough blocks to cover
`n` items", and it is exactly why the bounds check inside the kernel is
required.

256 is a reasonable default block size. Both take tuples for 2D and 3D work —
`grid_dim=(gx, gy)`, `block_dim=(16, 16)` — and then your kernel reads
`global_idx.x` and `global_idx.y`.
<!-- doccrate:keep-together:start -->


## Getting the answer back

Apple Silicon has unified memory, so reading results is a mapping rather than a
copy:

<!-- doccrate:keep-together:end -->
<!-- doccrate:keep-together:start -->


```mojo
with dev.map_to_host() as host_view:
    for i in range(PIXELS):
        ...host_view[i]...
```

<!-- doccrate:keep-together:end -->

It is a context manager, so the mapping is released at scope exit.

For explicit transfers — and for portability to discrete GPUs — buffers also
carry `enqueue_copy_to`, `enqueue_copy_from` and `enqueue_fill`, and the
context can allocate a host buffer with `enqueue_create_host_buffer`.
<!-- doccrate:keep-together:start -->


## The whole program

Putting it together, with a CPU reference to check against:

<!-- doccrate:keep-together:end -->

```mojo
from std.gpu import global_idx
from max.gpu.host import DeviceContext
from std.time import perf_counter_ns

comptime WIDTH = 1024
comptime HEIGHT = 768
comptime PIXELS = WIDTH * HEIGHT
comptime MAX_ITER = 256


def main() raises:
    comptime cx = Float32(-0.75)
    comptime cy = Float32(0.0)
    comptime scale = Float32(3.0) / Float32(WIDTH)

    # CPU reference
    var cpu_list = List[UInt32](length=PIXELS, fill=0)
    var cpu_buf = cpu_list.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    mandelbrot_cpu(cpu_buf, cx, cy, scale)

    # GPU
    var ctx = DeviceContext(api="metal")
    var dev = ctx.enqueue_create_buffer[DType.uint32](PIXELS)
    var f = ctx.compile_function[mandelbrot_kernel]()
    comptime block = 256
    comptime grid = (PIXELS + block - 1) // block

    ctx.enqueue_function(f, dev, cx, cy, scale,
                         grid_dim=(grid), block_dim=(block))
    ctx.synchronize()

    var agree = 0
    with dev.map_to_host() as gpu_buf:
        for i in range(PIXELS):
            if gpu_buf[i] == cpu_buf[i]:
                agree += 1
    print("agreement:", Float64(agree) / Float64(PIXELS) * 100.0, "%")
```

On the reference M4 Max the most recent run of this reports:
<!-- doccrate:keep-together:start -->


```text
GPU: 0.413 ms   speedup: 197.96 x
exact agreement: 100.0 % ( 0 boundary-band pixels differ)
```

<!-- doccrate:keep-together:end -->

Before you take that as a benchmark, read
[Running and checking](03-running-and-checking.md) — both the timing and the
comparison need more care than they look like they do.
<!-- doccrate:keep-together:start -->


## Running it

From the CocoaMojo distribution, one command either way:

<!-- doccrate:keep-together:end -->
<!-- doccrate:keep-together:start -->


```bash
cocoamojo --run   mandelbrot.mojo      # JIT: compile and run
cocoamojo --build mandelbrot.mojo      # -> ./mandelbrot
```

<!-- doccrate:keep-together:end -->

**Both work for GPU code.** `--run` JITs the program, GPU kernels included, and
`--build` produces an ordinary double-clickable binary.

No `-I` flags, no `MODULAR_*` variables, no Bazel — the distribution carries
the compiler, the runtimes, the packages and the SDK database beside each
other, and `cocoamojo` wires them up. [Chapter 3](03-running-and-checking.md)
covers the details, including what to do when you are building against the
source tree rather than a distribution.
