# 2. Threads, blocks and memory

Chapter 1 used one index and one buffer. Real kernels need to know where they
sit in the grid, cooperate with their neighbours, and use faster memory than
the device buffer. This chapter is those three things.

## Knowing where you are

```mojo
from std.gpu import (
    thread_idx, block_idx, block_dim, grid_dim, global_idx,
    lane_id, warp_id, WARP_SIZE,
)
```

| Name | What it tells you |
|:---|:---|
| `thread_idx.x/.y/.z` | This thread's position **within its block** |
| `block_idx.x/.y/.z` | This block's position within the grid |
| `block_dim.x/.y/.z` | How many threads per block |
| `grid_dim.x/.y/.z` | How many blocks in the grid |
| `global_idx.x/.y/.z` | Position across the whole grid |
| `lane_id` | This thread's lane within its SIMD group |
| `warp_id` | Which SIMD group within the block |
| `WARP_SIZE` | Lanes per SIMD group |

`global_idx` is the convenience you will use most; it is `block_idx * block_dim
+ thread_idx` computed for you.

For 2D work, index both axes:

```mojo
def blur(out: Pointer[Float32, MutAnyOrigin], w: Int, h: Int):
    var x = Int(global_idx.x)
    var y = Int(global_idx.y)
    if x < w and y < h:
        var i = y * w + x
        ...
```

launched with `grid_dim=(gx, gy), block_dim=(16, 16)`.

### A note on `WARP_SIZE`

**Do not hardcode it.** Apple SIMD groups are 32 lanes; AMD's wave64 is 64.
`WARP_SIZE` is a compile-time constant for the target you are building for, and
a kernel that assumes 32 or 64 is a kernel that silently produces wrong answers
on the other vendor. This is one of the commonest portability bugs in GPU code
and it costs nothing to avoid.

## Shared memory

Every thread can reach the device buffers you passed in, but that memory is
comparatively slow. Threads *within a block* also share a small, fast scratchpad
— Metal calls it threadgroup memory, CUDA calls it shared memory — and using it
well is most of what separates a fast kernel from a slow one.

```mojo
from std.memory import unsafe_stack_allocation, AddressSpace

comptime TILE = 16

def tiled_matmul(...):
    var a_shared = unsafe_stack_allocation[
        TILE * TILE, Float32, address_space=AddressSpace.SHARED,
    ]()
    var b_shared = unsafe_stack_allocation[
        TILE * TILE, Float32, address_space=AddressSpace.SHARED,
    ]()
```

The allocation is per block, and its size must be a compile-time constant. Ask
for too much and the pipeline will not create.

The classic use is tiling: each block cooperatively loads a tile of input into
shared memory, then every thread in the block reads that tile many times
without touching device memory again.

## Barriers

Shared memory is only useful if the threads agree about when it is filled. That
is what a barrier is for:

```mojo
from max.gpu.sync import barrier

    a_shared[unsafe_offset=local] = a[unsafe_offset=global_a]   # load
    barrier()                                                    # all loaded
    ...read a_shared freely...
    barrier()                                                    # all finished
```

`barrier()` synchronises **every thread in the block** — it is CUDA's
`__syncthreads()`. Memory operations before it are visible to all threads after
it.

Two rules that are not negotiable:

**Every thread in the block must reach every barrier.** Putting one inside an
`if` that only some threads take is a hang or worse, not an error message. If
you need a conditional load, do the condition *inside* the guarded region and
put the barrier outside it.

**You need the second barrier too.** Without one before the next tile is
loaded, a fast thread can overwrite shared memory a slow thread is still
reading.

`syncwarp(mask)` synchronises only within a SIMD group, which is cheaper and
occasionally what you want.

## SIMD-group operations

Threads in the same SIMD group run in lockstep and can exchange values directly
— no shared memory, no barrier. This is the fastest cooperation available.

```mojo
from std.gpu.primitives.warp import (
    shuffle_idx, shuffle_up, shuffle_down, shuffle_xor,
    reduce, lane_group_reduce,
)
```

| Operation | What it does |
|:---|:---|
| `shuffle_idx` | Read another lane's value by absolute lane index |
| `shuffle_up` / `shuffle_down` | Read from a lane a fixed distance away |
| `shuffle_xor` | Read from the lane whose id differs by a mask — the butterfly pattern |
| `reduce` | Combine a value across the whole SIMD group |
| `lane_group_reduce` | The same across a sub-group of lanes |

The idiom worth knowing is the reduction. To sum across a SIMD group, halve the
distance each step:

```mojo
    var v = my_value
    var offset = WARP_SIZE // 2
    while offset > 0:
        v += shuffle_down(v, offset)
        offset //= 2
    # lane 0 now holds the sum
```

A block-wide reduction is this, then one value per SIMD group written to shared
memory, a barrier, and one more SIMD-group reduction over those.

## Which memory to reach for

| Scope | Reach | Cost | Use for |
|:---|:---|:---|:---|
| Registers | one thread | fastest | everything, by default |
| SIMD-group shuffles | 32 lanes | very fast | reductions, scans, neighbour exchange |
| Shared memory | one block | fast | tiles, staging, block-wide cooperation |
| Device buffers | whole grid, and the host | slow | inputs and outputs |

The usual shape of a fast kernel: read device memory once, coalesced; keep the
working set in shared memory and registers; cooperate through shuffles where
possible and barriers where not; write device memory once.

## Coalescing

When adjacent threads read adjacent addresses, the hardware services them as
one wide transaction. When they stride, it cannot. This is usually the
difference between a kernel that is memory-bound at a sensible fraction of
bandwidth and one that is ten times slower for no visible reason.

In practice: map the **fastest-varying thread index to the fastest-varying data
index**. If your matmul reads `B[k][n]`, let `thread_idx.x` walk `n`, not `k`.
The tiled matmul in this tree carries exactly that comment — *map thread x to
column for coalesced access in B*.

## Divergence

Threads in a SIMD group share one instruction pointer. When they take different
branches, both sides execute with the inactive lanes masked off, so a
two-way branch inside a SIMD group costs the sum of both sides.

Divergence across *different* SIMD groups is free. So a condition on
`block_idx`, or on `global_idx / WARP_SIZE`, costs nothing; a condition on
`lane_id` costs. Data-dependent branches — like the Mandelbrot escape loop —
inevitably diverge, and that is fine; it is worth knowing rather than worth
avoiding at all costs.
