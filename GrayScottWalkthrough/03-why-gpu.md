# 3. Why this belongs on a GPU

The other examples in this collection spend their arguments explaining why a
GPU is the *wrong* tool — alpha-beta's cutoffs diverge, the chaos game is a
recurrence, the logistic map cannot be vectorised. Gray-Scott is the opposite
case, and it is worth being precise about why, because "it's a grid, so it's
parallel" is not the reason.

## The six properties, checked one at a time

### 1. One output per input, and no output depends on another

Within a single step, cell (x, y)'s new value depends on the **old** values of
its neighbourhood and on nothing else. No cell needs to know what any other
cell computed *this* step.

That is a pure map, and it is the strongest form of parallelism there is:
589,824 independent computations, in any order, with any scheduling.

The code enforces it structurally rather than by care:

```mojo
def grayscott_kernel(u_out, v_out, u_in, v_in, feed, kill):
    """One reaction-diffusion step, one cell, reading the OLD pair and
    writing the NEW one -- never in place, since every neighbour read
    needs last step's values, not whatever this thread has already
    written this step."""
```

Separate in and out buffers. Write in place and a thread reads neighbours that
another thread has already updated — some old, some new, depending entirely on
GPU scheduling. The result still looks like a reaction-diffusion system and is
different on every run. Fluid's Jacobi kernel documents the identical hazard,
and both defend against it the same way: two buffers, swapped.

### 2. The control flow is identical in every thread

```mojo
var idx = Int(global_idx.x)
if idx < CELLS:
    ... nine reads, twenty-odd flops, two clamped writes ...
```

One bounds check, then straight-line arithmetic. **No branch depends on the
data.** The `_clampi` calls are min/max, which compile to selects rather than
jumps; the output clamps likewise.

This is the property that separates a good GPU workload from a merely parallel
one. Threads in a warp execute together; when they take different paths the
hardware runs both and masks. Here there are no different paths — every one of
589,824 threads runs the same instruction sequence with different numbers,
which is precisely what the hardware is built for.

Compare Othello's alpha-beta, where every thread would hit its cutoff at a
different moment.

### 3. The stencil is fixed, small, and local

Nine reads at a compile-time-known offset pattern. That means:

- **The addresses are computable, not looked up.** No indirection, no pointer
  chasing, no index array.
- **Neighbouring threads read overlapping data.** Thread *n* and thread *n+1*
  share six of their nine cells. On any GPU with a cache, most of those reads
  are already resident — the effective memory traffic is far below nine loads
  per cell.
- **The working set is a few rows.** A block of 256 consecutive cells touches
  three rows of 256-ish values; that is kilobytes, not megabytes.

### 4. There is no reduction and no global communication

This is the point that distinguishes Gray-Scott from Fluid, and it is the most
interesting comparison in the collection.

Fluid has an **incompressibility constraint**, which is global: the velocity
field must be divergence-free *everywhere at once*, and you cannot satisfy a
global constraint with purely local updates. That is why Fluid needs a
pressure solve, and why the solve is thirty Jacobi iterations — thirty
dispatches propagating information across the grid, each dependent on the last.

Gray-Scott has **no global constraint at all**. Nothing has to be conserved
across the grid, nothing has to be solved. Information travels one cell per
step, and that is not a limitation to be worked around — it is the physics.

| | Fluid | Gray-Scott |
|:---|:---|:---|
| per frame | ~35 dispatches | 21 dispatches |
| of which a solver | 30 Jacobi sweeps | **none** |
| what couples cells | a global constraint | one cell of diffusion |
| buffers | twelve | five |
| synchronisation inside a step | required | none |

Both are 60 fps. Fluid's frame is dominated by *launch overhead* across many
small dependent dispatches; Gray-Scott's twenty substeps are each real work
over 589,824 cells.

### 5. The arithmetic-to-memory ratio is favourable

Per cell, per step: 18 float reads (nine each for U and V), about 24
floating-point operations, and 2 writes. Roughly one flop per byte moved —
which for a stencil with this much neighbour reuse means the caches do most of
the work and the arithmetic units stay busy.

A stencil that read *one* value per cell and did one multiply would be purely
memory-bound and would gain far less from a GPU.

### 6. The batch is large and the result is small

589,824 threads per dispatch, and the only thing that comes back to the host is
one finished image, once per frame. Twenty substeps happen entirely on the
device with nothing crossing the bus between them.

## The one dependency, and where it goes

Steps are strictly ordered: step *n+1* needs all of step *n*. That dependency
is real and unavoidable.

It costs nothing here because it maps onto a boundary the hardware already
has. A dispatch completes before the next begins, so the step boundary *is*
the dispatch boundary — no barrier, no fence, no code.

```mojo
for _step in range(SUBSTEPS // 2):
    ctx.enqueue_function(gs_kern, u2, v2, u, v, feed, kill, ...)
    ctx.enqueue_function(gs_kern, u, v, u2, v2, feed, kill, ...)
```

Twenty enqueues, no synchronise between them. The CPU does not wait; it queues
the batch and blocks once, later, before reading the frame.

## What it is *not* good at, honestly

Two things are worth saying so the argument does not overreach.

**It is redundant at the edges of interest.** Large regions of the grid are
becalmed — U pinned at 1, V at 0 — and those cells are computed at full cost
every step. An adaptive method would skip them. It would also branch per cell,
which is exactly what a GPU punishes, so the uniform version wins anyway. That
is a real trade: the GPU version does *more* arithmetic than necessary and is
still far faster.

**It is not latency-friendly.** Twenty substeps per frame exist because one
step per frame would make the pattern evolve too slowly to watch. That is a
throughput problem, which suits a GPU — but if you needed a single step *now*,
the dispatch overhead would dominate, exactly as it does for Othello's 81 µs
alpha-beta.

<!-- doccrate:keep-together:start -->

## The summary

| what the hardware wants | what Gray-Scott does |
|:---|:---|
| independent work items | 589,824 cells, no intra-step coupling |
| uniform control flow | one bounds check, then straight-line arithmetic |
| local, predictable memory | a fixed 9-cell stencil with 6-cell overlap between neighbours |
| no reduction or atomics | none — there is no global constraint to satisfy |
| a large batch, a small result | one image per frame; 20 substeps never leave the device |
| arithmetic to hide latency | ~24 flops per cell over cached reads |

<!-- doccrate:keep-together:end -->

Six for six, which is unusual. This is the workload the hardware was designed
around, and the useful thing about reading it beside Othello and the fern
examples is seeing what the exceptions actually look like.
