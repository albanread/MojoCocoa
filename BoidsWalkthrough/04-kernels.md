# 4. The five kernels
<!-- doccrate:keep-together:start -->


| kernel | threads | when |
|:---|:---|:---|
| `init_boids` | one per boid | once, and on `r` |
| `boid` | one per boid | every frame |
| `splat` | **one per boid** | every frame |
| `decay` | one per pixel | every frame |
| `color` | one per pixel | every frame |

<!-- doccrate:keep-together:end -->

Note the third row. Every other rendering kernel in this collection is
addressed by pixel; this one is not, and the reason is the most interesting
decision in the file.

## 1. `init_boids_kernel`

Physarum's hash, copied — *"example folders are self-contained"* — with the
same three-different-multipliers discipline so position and velocity are
uncorrelated. No host-side random calls before the first frame.

## 2. `boid_kernel`

The three rules, covered in [chapter 2](02-the-rules.md), and the ping-pong,
covered in [chapter 3](03-why-gpu.md).

One thing about its signature: **sixteen parameters**, eight of them buffers.
Four in, four out, plus five weights and a target. The weights are arguments
rather than constants so the number keys can switch character live, and the
in/out split is four pairs because position and velocity must flip together.

## 3. `splat_kernel` — the one that runs backwards

```mojo
"""One thread per BOID, not per pixel -- the opposite direction from
every other kernel in this file, because there are 4,000 boids and
589,824 cells, and a boid painting the few pixels around itself is far
cheaper than every pixel asking 4,000 boids whether it is the nearest
one."""
```

This is a **scatter**, and everywhere else in the collection the choice went
the other way.

The two options for drawing 2,500 points into 589,824 cells:
<!-- doccrate:keep-together:start -->


| | gather (per pixel) | scatter (per boid) |
|:---|:---|:---|
| threads | 589,824 | 2,500 |
| work per thread | check all 2,500 boids | write 25 cells |
| total operations | ~1.5 billion | ~62,500 |
| writes | each thread owns its cell | threads can collide |

<!-- doccrate:keep-together:end -->

Gather is 24,000 times more work, and almost all of it establishes that a
pixel has no boid near it. Scatter is obviously right — and it is chosen
*despite* being the awkward shape for a GPU, because the arithmetic is not
close.

The cost is that scatter has to write where it lands, so two boids painting
the same pixel do a racing read-modify-write:

```mojo
gr[unsafe_offset=wi] = gr[unsafe_offset=wi] + r * amt
```

Non-atomic, same as [Physarum's deposit](../PhysarumWalkthrough/03-why-gpu.md)
— and the same reasoning applies: a lost increment is a fraction of one
frame's glow on one pixel, immediately decayed. Physarum's kernel documents
its version of this race explicitly; this one does not, which is the one place
the file is quieter than its sibling.

Each boid paints a 5 × 5 neighbourhood with a radial falloff:

```mojo
var falloff = Float32(1.0) - d2 / Float32(9.0)
if falloff > Float32(0.0):
```

`d2` is up to 8 at the corners, so `1 − d2/9` makes the corners faint and the
extremes of the square drop out entirely — a disc, not a square, from a square
loop.

## The colour, and a missing `atan2f`

```mojo
var speed = sqrt(bvx * bvx + bvy * bvy) + Float32(1e-6)
var nx = bvx / speed
var ny = bvy / speed
var r = Float32(0.55) + Float32(0.45) * nx
var g = Float32(0.55) + Float32(0.45) * ny
var b = Float32(0.55) - Float32(0.45) * nx
```

> *The colour is the boid's own heading... so two boids painted the same colour
> are, right now, flying the same way, and a flock turning together turns the
> SAME colour together. Aligned is not just a rule here; it is what you see.*

That is a genuinely good visualisation decision. Alignment is the rule you
cannot see directly — position is obvious, spacing is obvious, but *heading*
is invisible in a still image. Mapping it to colour makes the abstract rule the
most visible thing on screen.

And the implementation has a story:

> *(Not a hue wheel through atan2: this fork's AIR backend has no `atan2f`,
> discovered as a metallib link failure rather than a Mojo-level error — the
> direction vector's own components make just as good a colour key and need
> nothing but `sqrt`.)*

Note **how** it was discovered. Not a compile error, not a type error — an
`xcrun metallib` **link** failure, naming a symbol. The Mojo code was
well-typed and the function existed in the standard library; there is simply no
lowering for it in this backend.

This is the same class of finding as Othello's `llvm.scmp`, where a three-way
comparison folded into an intrinsic the Metal backend cannot lower and the
kernel failed to link with a message naming an LLVM intrinsic and nothing
about Othello. **A link error naming a maths symbol in a GPU build is a
lowering gap, not your bug** — and the fix is usually to compute the same thing
a different way.

Here the different way is arguably better. `atan2` would give a hue angle,
which then needs an HSV-to-RGB conversion; the normalised direction vector's
own components *are* two of the three channels. Fewer operations and the same
property.

## 4. `decay_kernel` — and why it needs no second buffer

```mojo
gr[unsafe_offset=idx] = gr[unsafe_offset=idx] * GLOW_DECAY
```

> *No neighbour is read here — unlike Physarum's trail, which spreads, a boid's
> glow only ever fades — so this runs safely in place, with no second buffer
> needed.*

Each thread reads and writes only its own cell, so there is no old-versus-new
question. Physarum's equivalent kernel **blurs** before it decays, which reads
eight neighbours, which is precisely why that one needs double buffering.

Two kernels, both "fade a buffer", and one neighbour read is the whole
difference.

Three separate float buffers rather than one, because the glow carries colour —
and separate buffers keep each thread's three writes contiguous.

## 5. `color_kernel`

```mojo
r = r / (Float32(1.0) + r)
```

Fluid's tone curve, per channel:

> *The glow buffers are already coloured — `fluid`'s x/(1+x) tone-map per
> channel is all that is left, so a dense knot of overlapping boids compresses
> toward white instead of blowing out to a flat clip.*

Applying it **per channel** rather than to a luminance is what makes a bright
knot go white: the channel that saturates first keeps rising more slowly while
the others catch up, so overlapping trails desaturate toward white rather than
clipping to whichever colour got there first.

That is the fourth appearance of `x/(1+x)` in this collection — Fluid's dye,
Physarum's trail, Fernwind's density, and now a flock's glow. Any accumulation
with an unbounded range and a bounded display needs one, and this is the
cheapest that behaves.
