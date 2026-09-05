# 3. The six kernels

Every kernel is an ordinary Mojo `def`, compiled through this fork's AIR
backend into a `metallib`. There is no shading language anywhere — the same
source could run on the CPU, and two of the helpers below deliberately do.

They share one shape:

```mojo
var idx = Int(global_idx.x)
if idx < N:
    ...
```

One thread per cell, flat indexing, a bounds guard because the grid is rounded
up to a multiple of `BLOCK = 256`. `N` is 76,800 cells; `GRID` is 300 blocks.

## The two helpers everything rests on

### `_at` — a clamped read

Neighbour reads at the edge of the grid would run off the array. Every
neighbour access goes through a clamp, so the boundary behaves like a wall
that the fluid slides along rather than a cliff it falls off.

### `_bilinear` — the interpolator

```mojo
var top = a + (b - a) * fx
var bot = c + (d - c) * fx
return top + (bot - top) * fy
```

Four samples, two horizontal lerps, one vertical. This is called by
**advection** (to sample a departure point that lands between cells) and by
**render** (to magnify 320×240 into 960×720). It is the most-executed code in
the program by a wide margin.

### `_expf` — and why it is written out by hand

```mojo
@always_inline
def _expf(x: Float32) -> Float32:
    """exp, written out so host and device share one definition.

    Only ever called with x in [-9, 0] (the splat falloff), so the range
    reduction below does not need to be general.
    """
```

A polynomial approximation with a power-of-two scale factor. Two things make
it interesting:

1. **Host and device share one definition.** The same function is correct in
   a kernel and in ordinary CPU code, so the splat looks identical wherever it
   runs — which is what lets the headless smoke test check the real thing.
2. **The domain is documented and narrow.** It is only ever called with
   `x ∈ [-9, 0]`, so the range reduction does not need to be general. That
   comment is doing real work: it tells the next person exactly how far they
   can push this before it stops being true.

## 1. `advect_kernel` — the heart

```mojo
def advect_kernel(dst: F32, src: F32, u: F32, v: F32, dt: Float32, fade: Float32):
    var px = Float32(idx % W) - dt * u[unsafe_offset=idx]
    var py = Float32(idx // W) - dt * v[unsafe_offset=idx]
    dst[unsafe_offset=idx] = _bilinear(src, px, py) * fade
```

Four lines, and the whole reason the simulation is stable. Note the minus
signs: this traces **backwards** in time.

It is called **five times per frame** with different arguments — twice for
velocity (`u`, `v`) and three times for dye (`dr`, `dg`, `db`) — which is why
`fade` is a parameter rather than a constant. Velocity gets `VEL_FADE`, dye
gets `DYE_FADE`.

## 2. `divergence_kernel` — measuring the error

```mojo
div = 0.5 * ((_at(u, x+1, y) - _at(u, x-1, y))
           + (_at(v, x, y+1) - _at(v, x, y-1)))
```

A central difference in each axis. Six lines, one dispatch, and it produces
the right-hand side the pressure solve consumes.

## 3. `jacobi_kernel` — thirty of the thirty-five

```mojo
def jacobi_kernel(p_next: F32, p: F32, div: F32):
    """One Jacobi sweep of the pressure Poisson equation.

    Ping-ponged rather than updated in place: a Jacobi step reads the previous
    iterate's whole neighbourhood, and writing in place would feed half-new
    values back in, silently turning this into Gauss-Seidel with a
    thread-order-dependent answer.
    """
```

**That docstring is the single most important comment in the program.**
[Chapter 1](01-history.md) explains where the hazard comes from — Stam's own
code uses Gauss-Seidel, which is faster and inherently sequential, and a GPU
has no sequence. Here it is enough to say that writing into the buffer you are
reading produces a solver whose answer depends on thread scheduling: it still
converges, still looks like a fluid, and differs every run.

The defence is structural, not careful: separate `p` and `p_next` buffers, and
a loop that swaps them.

```mojo
for _it in range(JACOBI_ITERS // 2):
    ctx.enqueue_function(jacobi, pr0, pr, div, ...)   # pr  -> pr0
    ctx.enqueue_function(jacobi, pr, pr0, div, ...)   # pr0 -> pr
```

Fifteen iterations of two sweeps — thirty dispatches, and the answer ends up
back in `pr` where the projection expects it. The `// 2` is why
`JACOBI_ITERS` must be even.

## 4. `project_kernel` — subtracting the gradient

```mojo
u[unsafe_offset=idx] -= Float32(0.5) * (_at(p, x+1, y) - _at(p, x-1, y))
v[unsafe_offset=idx] -= Float32(0.5) * (_at(p, x, y+1) - _at(p, x, y-1))
```

Two lines. Everything before it existed to make these two lines meaningful.

Note that this one mutates **in place** — and that is safe, unlike the Jacobi
case, because each thread writes only its own cell and reads only `p`, which
nothing is writing.

## 5. `splat_kernel` — how anything gets in

```mojo
if d2 < r2 * Float32(9.0):
    field[unsafe_offset=idx] += amount * _expf(-d2 / r2)
```

A Gaussian blob added to a field. It is called for the mouse, for the opening
puff, and for the `[r]` rain command — and crucially, it is called on **both**
kinds of field: dye channels get colour, velocity channels get motion. One
kernel, six uses.

The `d2 < r2 * 9.0` test is an early-out at three radii, where the Gaussian is
already negligible. Most threads take it, and the exp is never evaluated.

## 6. `render_kernel` — the only one that is not physics

```mojo
var sx = Float32(idx % WIN_W) / Float32(SCALE)
var sy = Float32(idx // WIN_W) / Float32(SCALE)
var r = _bilinear(dr, sx, sy)
...
r = r / (Float32(1) + r)
```

Two decisions, both explained in the source:

**Bilinear, not nearest.** *"the field is smooth, and point-sampling a 320×240
grid into 960×720 would show the simulation's cells rather than the fluid."*
The magnification is where the illusion is won or lost.

**Tone-mapped with x/(1+x).** *"so a heavy drag saturates gracefully instead of
clipping to white."* This is Reinhard tone mapping: it maps [0, ∞) into [0, 1)
smoothly, so dye can accumulate without ever hitting a hard white ceiling.
Drag hard and the plume gets brighter and *keeps* getting brighter, instead of
flattening into a white blob.

Note this kernel runs over `PIXELS` (691,200) rather than `N` (76,800) — it is
the only one on the window's grid rather than the simulation's, which is why
`PIX_GRID` exists alongside `GRID`.

## The count

| kernel | dispatches per frame |
|:---|---:|
| `advect` | 5 — two velocity, three dye |
| `divergence` | 1 |
| `jacobi` | **30** |
| `project` | 1 |
| `render` | 1 |
| `splat` | 0–24, only when painting |
| *memset + copies* | ~6 |
| | **~35 fixed** |
