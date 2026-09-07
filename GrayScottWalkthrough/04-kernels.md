# 4. The three kernels

Three kernels, all ordinary Mojo `def`s compiled through this fork's AIR
backend. There is no shading language anywhere.

They share one shape:

```mojo
var idx = Int(global_idx.x)
if idx < CELLS:
    ...
```

One thread per cell, flat indexing, a bounds guard because 589,824 cells round
up to 2,304 blocks of 256.

## The helpers

### `_at` — a clamped read

```mojo
def _at(f: Pointer[Float32, MutAnyOrigin], x: Int, y: Int) -> Float32:
    return f[unsafe_offset=_clampi(y, 0, HEIGHT - 1) * WIDTH
             + _clampi(x, 0, WIDTH - 1)]
```

This is Fluid's `_at`, copied verbatim, and the commit says why that is the
right kind of reuse:

> *edge cells are never special-cased, only the neighbour reads they make are
> clamped — fluid's own `_at`, copied verbatim.*

The distinction in that sentence is the whole discipline. There is **no branch
for edge cells** — every one of the 589,824 threads runs the identical code. It
is only the *read* that clamps, and a clamp is two min/max operations, which
compile to selects rather than jumps.

The alternative — `if (x > 0 && y > 0 && ...)` around the stencil — would put a
data-dependent branch in every thread, and the ~3,000 edge cells would diverge
from the 587,000 interior ones. For 0.5% of the grid, you would pay divergence
on all of it.

Physically the clamp is a reflecting boundary: a cell at the edge sees itself
where its missing neighbour would be, so nothing leaks out and nothing wraps
around.

### `_laplacian` — nine reads, weights summing to zero

```mojo
s += _at(f, x - 1, y - 1) * Float32(0.05)
s += _at(f, x,     y - 1) * Float32(0.2)
...
s += _at(f, x,     y)     * Float32(-1.0)
```

Written out flat rather than as a loop over offsets. Nine `_at` calls, all
`@always_inline`, all with compile-time-known offsets — so the compiler folds
the index arithmetic and the whole thing becomes nine loads and nine
multiply-adds with no loop overhead and no branch.

A loop over an offset table would be shorter to read and would introduce an
indirection through that table, per cell, per step, 589,824 times over.

[Chapter 2](02-the-model.md) covers why the weights sum to zero.

## 1. `grayscott_kernel` — twenty of the twenty-one dispatches

```mojo
var u = _at(u_in, x, y)
var v = _at(v_in, x, y)
var uvv = u * v * v
var du = DU * _laplacian(u_in, x, y) - uvv + feed * (Float32(1.0) - u)
var dv = DV * _laplacian(v_in, x, y) + uvv - (feed + kill) * v
var nu = u + du * DT
var nv = v + dv * DT
```

Four lines of model and two of Euler integration. Everything in
[chapter 2](02-the-model.md) is here and nowhere else.

Two things about its *shape* rather than its physics:

**`feed` and `kill` are kernel arguments, not constants.** That is what lets
the number keys switch preset live without recompiling — the same compiled
kernel, dispatched with different scalars. Baking them in as `comptime` would
have been marginally faster and would have made six kernels out of one.

**In and out are separate parameters,** which is what makes the ping-pong in
[chapter 5](05-a-frame.md) a matter of argument order rather than of copying.

## 2. `seed_kernel` — a disc of catalyst

```mojo
var dx = x - cx
var dy = y - cy
if dx * dx + dy * dy <= r2:
    u[unsafe_offset=idx] = Float32(0.5)
    v[unsafe_offset=idx] = Float32(1.0)
```

Every cell tests whether it is inside the disc; most are not and write nothing.
That is 589,824 threads to paint a disc of radius 14 — about 600 cells. Wildly
redundant, and correct: a dispatch is one launch whatever it touches, and the
alternative is a separate code path for a job that happens a handful of times
per session.

It is used for **both** the initial seeding and the mouse, which is why
dragging feeds the pattern by hand with exactly the physics the simulation
started with.

The docstring records a dialect constraint worth knowing:

> *Int32, not Int: a kernel argument must be fixed-width to conform to
> DevicePassable -- plain Int (and UInt) do not, a constraint that only bites
> here because this is the one kernel in the file passing a bare integer rather
> than a Pointer or a Float32.*

`Int` is pointer-width and its size is a host-side property; a kernel argument
has to have a size both sides agree on. The other two kernels never hit it
because their arguments are pointers and `Float32`s.

## 3. `color_kernel` — the only one that is not chemistry

```mojo
var tt = t * Float32(2.2) + phase
var r = Float32(0.5) + Float32(0.5) * cos(TAU * (tt + Float32(0.10)))
var g = Float32(0.5) + Float32(0.5) * cos(TAU * (tt + Float32(0.45)))
var b = Float32(0.5) + Float32(0.5) * cos(TAU * (tt + Float32(0.65)))
var shade = t * Float32(3.0)
```

A **cosine palette**: three cosines a third of a cycle apart, each mapped from
[−1, 1] into [0, 1]. Every value of `t` gets a colour, the ramp is smooth and
cyclic, and there is no lookup table — three cosines and three adds.

> *Mandelbrot's own trick here tuned to a different register — deep water
> climbing through coral toward bone.*

Two details beyond the palette:

**`phase` drifts.** It advances 0.0015 per frame, so the colour mapping rotates
slowly under a pattern that is itself changing on a different timescale. The
picture never looks static even when the chemistry has nearly settled.

**`shade` is separate, and it is doing real work:**

> *a separate shade term darkens the untouched sea toward black rather than
> letting the cosines paint a colour where nothing is actually happening.*

At `t = 0` the three cosines still evaluate to *something* — a cosine palette
has no black. Without `shade`, the empty regions of the grid would come out a
uniform mid-tone, and the pattern would read as texture on a coloured field
rather than as structure in the dark. `t * 3.0`, clamped at 1, means anything
below V = 0.33 is progressively darkened toward black.

The packing is direct:

```mojo
# BGRA8Unorm little-endian: byte0=B, byte1=G, byte2=R, byte3=A.
return b | (g << 8) | (r << 16) | (UInt32(255) << 24)
```

The kernel writes the exact 32-bit words the drawable's texture wants. No
shader, no sampler, no conversion pass — `replaceRegion:` takes this buffer as
it stands.

<!-- doccrate:keep-together:start -->

## The count

| kernel | dispatches per frame |
|:---|---:|
| `grayscott` | **20** — ten ping-pong pairs |
| `color` | 1 |
| `seed` | 0, except when seeding or dragging |
| | **21 fixed** |

<!-- doccrate:keep-together:end -->
