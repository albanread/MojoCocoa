# 3. Why this belongs on a GPU

Boids is the third kernel demo in the collection, and its GPU argument is
different from both the others. The difference is worth stating precisely
because the commit does:

> *`grayscott` is a field talking to itself, `physarum` is agents talking
> **through** a shared field, this is agents talking to each **other**
> directly, no field between them.*

## What direct coupling costs

In Gray-Scott a cell reads nine neighbours at fixed offsets. In Physarum an
agent reads three points of a shared map. Neither ever reads another *agent*.

Here, boid *i* reads the position and velocity of all 2,499 others. That has
two consequences, and they point in opposite directions.

**It is a lot of work.** 2,500 × 2,499 = 6.25 million pairs per frame, each
with a wrapped-distance calculation and two conditionals.

**It is beautiful work for a GPU.** Every one of those pairs is independent.
There is no ordering, no accumulation shared between threads, no
communication. Thread *i* reads the whole input array and writes four values —
which is a *gather*, the friendliest shape there is, because gathers never
collide.

And the read pattern is ideal in a way stencils are not: **all 2,500 threads
walk the same array in the same order at the same time.** At step *j*, every
thread in the grid wants `px_in[j]`. That is one broadcast, not 2,500 loads —
the best possible case for a cache, and the reason brute force performs far
better here than the pair count suggests.

## O(n²), on purpose, with numbers

The kernel says so at length, and the honesty is the interesting part:

> *Every boid against every other boid — brute force, on purpose. 2,500 is a
> visual choice, not a performance ceiling: this GPU held 60fps up to 12,000
> boids (144 million pairs a frame) and was still doing 24fps at 20,000 (400
> million pairs), so the honest limit is far above what ships here.*

So the shipped number is nearly **five times below** the 60 fps limit, and the
reason is not performance:

> *Past a few thousand, the glowing trails stop reading as individual birds and
> fuse into a continuous flow-field texture — striking in its own right, but no
> longer showing the thing this demo is FOR: three simple rules, and enough
> negative space to still see each one's trail and the small flocks it belongs
> to.*

That is a real result, measured, and then deliberately not shipped. It would
have been easy to put 12,000 boids on screen and call it a benchmark.

And the optimisation everybody asks about is named and declined:

> *The interesting, harder trick — bucketing boids into a grid so each one only
> checks its own neighbourhood — is the right answer for pushing PAST tens of
> thousands; at a few thousand it is a real optimisation with nothing yet to
> optimise.*

Worth expanding, because it is the standard next step and it is not free.
Spatial binning turns O(n²) into roughly O(n), and it costs:

- a bin-assignment pass, plus a sort or an atomic counter per bin
- **variable work per thread** — a boid in a dense flock checks far more
  neighbours than one alone, so threads in a warp diverge
- **scattered reads** — neighbours are wherever the bin table points, losing
  the broadcast pattern above entirely

At 6.25 million perfectly-coalesced, perfectly-uniform pairs, none of that
pays. At 400 million it would. The threshold is real and the file says which
side of it this is on.

## The discipline direct coupling forces

This is the part that would be a silent bug rather than a slow program.

```mojo
def boid_kernel(px_out, py_out, vx_out, vy_out,
                px_in, py_in, vx_in, vy_in, ...):
    """Reads ONLY the `_in` arrays and writes ONLY the `_out` ones -- see the
    file header for why that split, not an in-place update, is the whole
    point: every boid this frame has to see the same frozen instant of
    everyone else, the same discipline `grayscott` uses for its u/v pair."""
```

Update in place and boid 400's *new* position is visible to boid 50's read of
it — but only if boid 400's thread happened to run first. From the header:

> *updating in place would let boid 400's new position leak into boid 50's read
> of it purely by scheduling luck*

The result would still be a flock. It would differ on every run, on every
machine, at every occupancy — and there is no test that catches it, because
"it looks like birds" is true either way.

This is the third appearance of the same hazard in this tree: Fluid's Jacobi
sweep, Gray-Scott's `u`/`v` pair, and now a flock. All three defend
structurally — two buffers, swapped — rather than by care. The header calls it
exactly that: *"by construction rather than by hope."*

Note it is **four** arrays ping-ponged here, not two, and they must flip
together. Position and velocity are both read by every boid, so a frame that
saw new positions with old velocities would be just as wrong.

## The cheap half

The rendering side is ordinary and worth contrasting.

`decay_kernel` fades the glow buffers, and gets a concession the simulation
does not:

> *No neighbour is read here — unlike Physarum's trail, which spreads, a boid's
> glow only ever fades — so this runs safely in place, with no second buffer
> needed.*

A pure per-pixel multiply. Each thread touches only its own cell, so there is
no old-versus-new question to have. Physarum's trail kernel **blurs**, which
reads neighbours, which is exactly why that one needs a second buffer and this
one does not.

Two kernels that look similar — decay a buffer — and one needs double
buffering because of a neighbour read the other does not make.

## Where it sits
<!-- doccrate:keep-together:start -->


| example | what couples the work | dispatches/frame |
|:---|:---|---:|
| mandelbrot | nothing | 1 |
| physarum | a shared map, written racily | 3 |
| **boids** | **every agent to every other, directly** | **4** |
| grayscott | one cell of diffusion per substep | 21 |
| fluid | a global constraint needing a solver | ~35 |

<!-- doccrate:keep-together:end -->

Boids has the strongest coupling of any of them — every pair, every frame —
and among the fewest dispatches. Those are not in tension: the coupling is
*wide* but it is **not sequential**. All 6.25 million interactions can happen
at once.

Fluid's coupling is weaker per-pair and vastly more expensive, because
incompressibility must hold everywhere *at once*, and that cannot be done in
one pass however many threads you have. Thirty Jacobi sweeps is the price of a
constraint that is genuinely global.

**Wide coupling is cheap. Deep coupling is not.** That is the clearest single
thing the five examples together demonstrate.
