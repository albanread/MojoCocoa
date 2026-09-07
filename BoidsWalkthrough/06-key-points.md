# 6. What to understand

Eight things about this example are not obvious from watching it.

## 1. Direct coupling forces the ping-pong

A boid reads every *other* boid. Update in place and boid 400's new position
leaks into boid 50's read of it — but only if 400's thread ran first.

> *purely by scheduling luck*

The result is still a flock. It differs on every run, on every machine, at
every occupancy, and **no test catches it**, because "it looks like birds" is
true either way.

Four buffers, flipped together, so every boid sees the same frozen instant:
*"by construction rather than by hope."* This is the third appearance of the
hazard in this tree, after Fluid's Jacobi sweep and Gray-Scott's `u`/`v` pair.

<!-- doccrate:keep-together:start -->

## 2. Brute force is a measured choice, not a shortcut

6.25 million pairs a frame, and the numbers were taken before the count was
picked:

| boids | pairs/frame | result |
|:---|---:|:---|
| 2,500 | 6.25 M | ships |
| 12,000 | 144 M | 60 fps |
| 20,000 | 400 M | 24 fps |

<!-- doccrate:keep-together:end -->

2,500 is nearly five times *below* the 60 fps limit, and the reason is
editorial:

> *Past a few thousand, the glowing trails stop reading as individual birds and
> fuse into a continuous flow-field texture — striking in its own right, but no
> longer showing the thing this demo is FOR.*

## 3. Spatial binning is the right answer, later

Bucketing boids into a grid turns O(n²) into roughly O(n) — and costs a
bin-assignment pass, **variable work per thread** (dense flocks check more
neighbours, so warps diverge), and **scattered reads** in place of the current
broadcast pattern.

> *at a few thousand it is a real optimisation with nothing yet to optimise*

## 4. Brute force is unusually cache-friendly

At step *j*, every one of the 2,500 threads wants `px_in[j]` — the same
address. That is a broadcast, not 2,500 loads, and it is why brute force runs
better than the pair count suggests. Binning would destroy exactly this.

## 5. A torus has to be a torus everywhere

```mojo
if dx > Float32(WIDTH) * Float32(0.5):
    dx -= Float32(WIDTH)
```

Two boids across the seam are at x = 766 and x = 3; naive subtraction says 763
apart. Without the minimum-image fix, flocks come apart at the edges **and
only there**, which reads as a rendering bug.

Same class as [Physarum's wrap-not-clamp](../PhysarumWalkthrough/index.md):
once the world wraps, everything measuring distance in it must know.

## 6. Cohesion accumulates offsets, not positions

```mojo
avg_px += dx        # the already-wrapped offset
```

So the average is relative and cohesion is one multiply. Averaging *absolute*
positions would need a subtraction afterwards and — much worse — would be
meaningless across a seam, since the mean of x = 766 and x = 3 is the middle of
the screen.

## 7. A missing `atan2f`, found at link time

The colour was going to be a hue wheel through `atan2`. This fork's AIR
backend has no `atan2f`, and it surfaced as an **`xcrun metallib` link
failure** — not a compile error, not a type error. The Mojo was well-typed and
the function existed; there is no lowering for it.

Same class as Othello's `llvm.scmp`. **A link error naming a maths symbol in a
GPU build is a lowering gap, not your bug.**

The replacement is arguably better: the normalised velocity's own components
*are* two channels, where `atan2` would give an angle still needing an HSV
conversion.

## 8. Heading is mapped to colour, and that is the visualisation

Position and spacing are visible in a still frame. **Heading is not.**
Colouring by direction makes alignment — the one rule you could not otherwise
see — the most obvious thing on screen:

> *a flock turning together turns the SAME colour together. Aligned is not just
> a rule here; it is what you see.*

<!-- doccrate:keep-together:start -->

## Things that will bite: the model

| If you change… | …this happens |
|:---|:---|
| the minimum-image wrap | flocks tear apart at the seams, and only there |
| cohesion to average absolute positions | it is meaningless across a seam |
| the `d2 > 0.01` separation guard | two coincident boids divide by zero and poison their neighbours |
| the speed clamp to per-component | a fast diagonal silently changes heading |
| `MIN_SPEED` to zero | a boid whose forces cancel stops dead and becomes an obstacle |
| alignment weight toward 1.0 | boids snap to the flock heading; turns stop propagating as waves |

<!-- doccrate:keep-together:end -->

<!-- doccrate:keep-together:start -->

## Things that will bite: the machinery

| If you change… | …this happens |
|:---|:---|
| the boid kernel to update in place | nondeterministic flocking, no error, no failing test |
| the four buffers to flip separately | new positions paired with old velocities |
| `splat` to one thread per pixel | ~1.5 billion checks instead of 62,500 writes |
| `decay` to read a neighbour | it stops being safe in place and needs a second buffer |
| the tone map to luminance instead of per channel | bright knots clip to a colour instead of going white |
| `atan2` back into the colour | the metallib link fails, naming a symbol |

<!-- doccrate:keep-together:end -->

<!-- doccrate:keep-together:start -->

## Controls

| | |
|:---|:---|
| **hold** | the flock steers toward the cursor |
| **1–4** | flock, swarm, school, scatter — live, positions kept |
| **r** / **space** / **s** / **q** | reseed · pause · save a PNG · quit |
| `BOIDS_FRAMES=N` | render N frames unfocused, then exit |

<!-- doccrate:keep-together:end -->

<!-- doccrate:keep-together:start -->

## And beside the others

| example | what couples the work | dispatches/frame |
|:---|:---|---:|
| mandelbrot | nothing | 1 |
| physarum | a shared map, written racily | 3 |
| **boids** | **every agent to every other, directly** | **4** |
| grayscott | one cell of diffusion per substep | 21 |
| fluid | a global constraint needing a solver | ~35 |

<!-- doccrate:keep-together:end -->

Boids has the strongest coupling here and among the fewest dispatches, and
those are not in tension: its coupling is **wide** but not **sequential** — all
6.25 million interactions happen at once. Fluid's is weaker per pair and far
more expensive, because incompressibility must hold everywhere simultaneously
and no number of threads collapses that into one pass.

**Wide coupling is cheap. Deep coupling is not.**
