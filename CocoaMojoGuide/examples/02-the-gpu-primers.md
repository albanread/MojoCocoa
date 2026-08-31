# 2. The GPU primers

Three GPU examples come from Modular's own collection and run here
**unmodified** — the fork added a comment to the top of each and changed
nothing else. `vector-add/main.mojo` and `grayscale/main.mojo` differ from
upstream by four and three comment lines respectively; `tiled-matmul/main.mojo`
by four.

That is the point of having them. This fork wrote its own Metal backend for the
GPU path, and the question a reader most wants answered is whether ordinary
Mojo GPU code survives it. These three answer it without the fork getting a
vote: upstream's `DeviceContext`, `TileTensor`, `enqueue_function`, `barrier()`
and `AddressSpace.SHARED` compile and run here as written.

Read them for the idioms. Do not read them for a lesson about this fork, and be
aware of how little two of the three actually check.

## `vector-add`

80 lines. Three ten-element buffers, one thread per element, `1.25 + 2.5` ten
times. It prints `Resulting vector:` and ten copies of `3.75`.

The launch is the whole reason to read the file:

```mojo
ctx.enqueue_function[vector_addition](
    lhs_tensor, rhs_tensor, out_tensor, Int32(VECTOR_WIDTH),
    grid_dim=grid_dim,
    block_dim=BLOCK_SIZE,
)

with out_buffer.map_to_host() as host_buffer:
    var host_tensor = TileTensor(host_buffer, layout)
    print("Resulting vector:", host_tensor)
```

The kernel is a compile-time parameter, its arguments are positional, and the
geometry is keyword-only at the end. Reading the result back is a `with` block.
That five-line shape is the entire API surface a first GPU program needs, and
it does not get more complicated in the larger examples — `mandelbrot` and
`fluid` call `enqueue_function` exactly like this, just more often.

Note the guard, because the three examples do not agree on it:

```mojo
comptime assert has_accelerator(), "This example requires a supported GPU"
```

That is a *compile-time* assert. On a machine with no Metal device this example
fails to build rather than degrading to a message.

**The lesson: none specific to this fork.** It is a hello-world that happens to
touch the GPU. It is also worth saying plainly that **it never checks its own
answer** — the ten values are printed for a human to look at, and nothing would
fail if they were wrong. As a compatibility proof it is the weakest of the
three. Read it for the launch idiom, then move on.

## `grayscale`

115 lines, and the 2D sibling of `vector-add`. It builds a 10×5 RGB image on
the host, converts it to single-channel grey on the GPU, and prints the result
as a table of integers.

One idea, and it is the one everybody gets wrong once:

```mojo
var row = global_idx.y
var col = global_idx.x

if col < WIDTH and row < HEIGHT:
    var red = rgb_tensor[row, col, 0].cast[float_dtype]()
    ...
    gray_tensor[row, col] = gray.cast[int_dtype]()
```

`global_idx.y` is the row and `global_idx.x` is the column. Transpose those two
and you get a kernel that runs, writes plausible-looking numbers, and is wrong
in a way that only shows up as a picture that looks sheared. The bounds check
matters here too: the grid is one block of 16×16 for a 50-pixel image, so about
80% of the threads launched exist only to fail that `if`.

Two things to know before you trust it as a reference. The luma weights are
`0.21 / 0.71 / 0.07`, which sum to 0.99 and are not the Rec.601 coefficients
(`0.299 / 0.587 / 0.114`) — an approximation, and upstream's. And because the
synthetic image spans so little range, every output value lands between 17 and
29: a near-uniform grey. The example is exercising the plumbing, not producing
an image.

**The lesson: none beyond `vector-add`, except the `y`-is-row convention.**
Like `vector-add` it never validates anything. If you have read `vector-add`,
the only new information here is two-dimensional indexing, and you now have it.

## `tiled-matmul`

345 lines, and the one carried example that teaches something real. It
multiplies two 64×64 matrices using 16×16 shared-memory tiles, 4×4 blocks of
16×16 threads.

The lesson is the barrier — specifically that there are **two** of them per
iteration:

```mojo
# Ensure all threads finish loading tiles before any thread starts computing
barrier()

comptime for k in range(TILE_K):
    var a_element = tile_a_shared[thread_y, k]
    var b_element = tile_b_shared[k, thread_x]
    accumulator += a_element * b_element

# Ensure all threads finish computing before any thread loads next tiles
barrier()
```

The first barrier is obvious: do not compute on a tile that is still being
filled. The second is the one people omit, and omitting it is a genuinely nasty
bug — a fast thread races ahead to the next iteration and overwrites shared
memory that a slower thread in the same block is still reading. The kernel
still runs. The answer is wrong in a way that depends on scheduling.

This pattern generalises to every shared-memory algorithm you will write, and
it is the only idea in this chapter that does.

`tiled-matmul` also guards itself differently from the other two:

```mojo
comptime if not has_accelerator():
    print("No GPU detected...")
```

A message at run time, not a failed build. Worth knowing that the two styles
exist and that upstream uses both.

**The lesson: real, and not fork-specific.** Shared-memory tiling with correct
double barriers is worth understanding wherever you write GPU code.

**One caveat, and it matters.** The program prints:

```
Validating GPU results against CPU reference...
```

There is no CPU reference implementation in the file. What actually runs is
five hard-coded closed-form spot checks — `(0,0)`, `(0,1)`, `(1,0)`, `(1,1)`
and `(3,3)` — against `C[i,j] = (i+1) × 64 × (j+1)`. That is 5 of 4,096
elements, all inside the first block, none of them at a tile boundary. The
`✓ Validation PASSED` line is real but it is checking far less than its own
wording claims, and a bug in the later K-loop iterations or across tile
boundaries would sail straight past it.

It is still the strongest compatibility proof in the carried set, because it is
the only one that checks its arithmetic at all. Just do not upgrade "five spot
checks passed" into "verified against a CPU reference" — the program does that
for you, and it should not.
