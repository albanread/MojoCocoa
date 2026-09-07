# 6. What to understand

Eight things about this example are not obvious from watching it.

## 1. Two numbers decide which pattern you get

`feed` and `kill`, and nothing else. The same four-line kernel produces
gliders, bubbles, maze, worms, spirals or spots depending on where those two
sit — and the presets are a few thousandths apart.

> *get these even a few thousandths wrong and the field relaxes to a uniform
> grey instead of staying alive*

Which is why the values are looked up rather than invented. The failure has no
error and no crash; the simulation just stops being interesting.

Switching preset changes two floats and nothing else — not the kernel, not the
field — so you watch one regime reorganise into another.

## 2. Diffusion is what makes the pattern, not what destroys it

The counter-intuitive core of Turing's 1952 result. Diffusion smooths, so
diffusion plus reaction ought to smooth faster. It does not: when the two
species diffuse at **different rates**, a uniform state becomes unstable and
structure grows out of noise.

```mojo
comptime DU = Float32(1.0)
comptime DV = Float32(0.5)
```

Set those equal and the patterns do not form.

## 3. `u * v * v` is the whole personality

V can only grow where V already is, so a catalyst speck spreads as a *ring*
along its own boundary rather than consuming the grid. In the interior of a
patch U is already eaten, so the term is small; at the edge both are present.

Everything the program draws follows from that one product.

## 4. The Laplacian's weights sum to zero

```
0.05  0.2  0.05
0.2  -1.0  0.2
0.05  0.2  0.05
```

That is what makes it a rate of *change* rather than a blur. A flat field
returns exactly zero, whatever it is flat at. Weights that sum to something
else make a flat field gain or lose substance everywhere, and the drift looks
like a physics bug rather than an arithmetic one.

## 5. Never write in place

```mojo
"""reading the OLD pair and writing the NEW one -- never in place, since
every neighbour read needs last step's values, not whatever this thread
has already written this step."""
```

Write into the buffer you are reading and threads see a mixture of old and new
neighbours, decided by GPU scheduling. It still looks like reaction-diffusion
and differs on every run. Fluid's Jacobi kernel documents the same hazard and
uses the same defence: two buffers, swapped.

## 6. `SUBSTEPS` must be even

Ten ping-pong pairs leave the settled state back in `u, v`, so the colour
kernel never has to ask which buffer is current. Make it odd and the answer
finishes in `u2, v2`, the colour kernel reads `v`, and you display the state
from one step ago — every frame, consistently, which looks like nothing is
wrong at all.

## 7. Clamp the reads, not the cells

```mojo
def _at(f, x, y) -> Float32:
    return f[unsafe_offset=_clampi(y, 0, HEIGHT - 1) * WIDTH
             + _clampi(x, 0, WIDTH - 1)]
```

> *edge cells are never special-cased, only the neighbour reads they make are
> clamped*

Every one of 589,824 threads runs identical code; only the address arithmetic
clamps, and a clamp is a select rather than a branch. Guarding the *cells*
instead would make 0.5% of the grid diverge from the rest, and you would pay
for it across all of it.

## 8. The verification was looking at the picture

> *Verified by actually looking at the output, not just a clean exit... proof
> the parameter wiring changes what is actually computed, not just a label.*

A clean exit proves the dispatches ran. It does not prove `feed` and `kill`
reached the kernel — a preset switch that only updated the window title would
pass every automated check. Two presets producing *visibly different physics*
is what proves the wiring.

`GRAYSCOTT_FRAMES=N` leaves a PNG behind so a headless run produces something
a person can look at rather than an exit code.

<!-- doccrate:keep-together:start -->

## Things that will bite: the physics

| If you change… | …this happens |
|:---|:---|
| `DU` and `DV` to be equal | no Turing instability; the patterns never form |
| the Laplacian weights so they do not sum to zero | a flat field drifts; looks like a physics bug |
| `feed` or `kill` by a few thousandths | a different pattern, or a uniform grey |
| the `shade` term out of the colour kernel | empty regions become a flat mid-tone, not black |

<!-- doccrate:keep-together:end -->

<!-- doccrate:keep-together:start -->

## Things that will bite: the machinery

| If you change… | …this happens |
|:---|:---|
| `SUBSTEPS` to an odd number | the display shows the state from one step ago, always |
| the kernel to write in place | nondeterministic results, no error, no symptom |
| `_at`'s clamp to a per-cell branch | the edge diverges from the interior, warp-wide |
| `Int32` to `Int` on a kernel argument | it is not `DevicePassable`; the kernel will not build |
| a `synchronize()` between substeps | the batch splits and 20 dispatches are paid for separately |

<!-- doccrate:keep-together:end -->

<!-- doccrate:keep-together:start -->

## Controls

| | |
|:---|:---|
| **drag** | paint catalyst under the cursor — the same seed kernel the simulation started with |
| **1–6** | gliders, bubbles, maze, worms, spirals, spots — live |
| **r** | reseed with fresh blobs at the current parameters |
| **space** | pause |
| **q** / **esc** | quit |
| `GRAYSCOTT_FRAMES=N` | render N frames unfocused, save a PNG, exit |

<!-- doccrate:keep-together:end -->

<!-- doccrate:keep-together:start -->

## And beside the others

| example | what the GPU is for | dispatches per frame |
|:---|:---|---:|
| mandelbrot | one independent value per pixel | 1 |
| **grayscott** | **a local stencil, no global constraint** | **21** |
| fluid | a *global* constraint needing a solver | ~35 |
| fernwind | many short independent random walks, with atomics | 2 |
| othello | independent playouts, one batch per move | 1 |

<!-- doccrate:keep-together:end -->

Gray-Scott sits between mandelbrot and fluid, and reading the three together
is the clearest way to see what the middle of that range costs.
