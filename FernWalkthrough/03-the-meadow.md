# 3. A meadow that grows

`ferns/` takes the same four maps and does something the single-fern version
cannot: it shows you the chaos game *happening*.

> *Every frame each fern grows by a few hundred points, so the landscape
> assembles in front of you — stems first, then fronds, then the fine leaf
> texture as points pile up.*

That order is not staged. It is what the chaos game does: map 1 takes 85% of
the traffic, so the spine appears almost immediately, and the outer fronds fill
in only as the rarer maps accumulate hits. Watching it is watching the
probabilities.

## Depth does the design work

```mojo
def make_fern(mut rng: Rng, base_x: Float64, base_y: Float64) -> Fern:
    """A fern for a spot on the ground. Depth does the design work: how far
    below the horizon it stands sets its size, brightness and blue-shift, so
    nearer ferns come up bigger and greener."""
    var t = (base_y - HORIZON) / (Float64(H) - HORIZON)  # 0 far .. 1 near
```

One number — how far below the horizon the fern stands — drives four things at
once:

```mojo
let scale = 5.0 + t * 16.0 + rng.next() * 2.0
let dim = 0.45 + 0.55 * t
let g_ = Int((120.0 + rng.next() * 135.0) * dim)
let b_ = Int((25.0 + rng.next() * 65.0 + (1.0 - t) * 45.0) * dim)
```

Size, brightness, and a **blue shift** that grows with distance — *"yellow-greens
up close, dusty blue-greens in the distance."* That last one is aerial
perspective: distant things in real air lose contrast and shift toward blue.
Implementing it as `(1.0 - t) * 45.0` added to the blue channel is one term,
and it is most of why the meadow reads as having depth.

There is no z-buffer, no sorting, no perspective transform. One parameter, used
four times.

## Everyone matures together

```mojo
# Every fern finishes in about the same number of frames regardless of size,
# so the landscape matures together rather than the big ones dragging on.
comptime GROW_FRAMES = 600
...
# Bigger ferns need more points to fill; everyone matures together.
let target = Int(scale * scale * 380.0)
```

A fern twice as large has four times the area, so it needs roughly four times
the points to reach the same visual density. `scale * scale` is that, and it
means every fern reaches its target at about the same moment.

Without it the small distant ferns would finish in seconds and the near ones
would still be filling in a minute later — which reads as a bug rather than as
depth.

```mojo
let delay = Int(rng.next() * 150.0)
```

And a random head start of up to 150 frames, so they do not all sprout on the
same tick.

## The lawn and the sky

Both are procedural, and both exist to give the ferns somewhere to be.

> *a procedural lawn — fourteen thousand individual grass blades, taller and
> greener up close — under a dusk sky whose clouds come from two octaves of
> value noise.*

The clouds:

```mojo
# The cloud lattice: value noise, bilinearly interpolated. Coarse carries the
# cloud masses, fine breaks their edges up.
```

Two octaves rather than many: one coarse lattice for the shapes, one fine one
to keep the edges from looking interpolated. Then a threshold with a smooth
edge:

```mojo
# Only the upper range of the noise is cloud; the rest stays sky.
var cloud = (n - 0.52) / 0.30
...
cloud = cloud * cloud * (3.0 - 2.0 * cloud)
cloud *= 0.75 - 0.55 * t
```

`x²(3 − 2x)` is smoothstep — it turns the hard cut at 0.52 into a soft edge.
And the last line fades cloud out toward the horizon, *"where real clouds thin
into haze"*: a physical observation implemented as one multiply.

Fourteen thousand grass blades are drawn individually, each with its own
height, lean and shade, and there is a note about the gaps:

> *the gaps between blades read as shadow rather than void*

Which is the difference between a lawn and a field of green lines.

## Why it cannot move

Here is the point of the chapter, and the reason the third example exists. From
the commit that introduced the GPU version:

> *`examples/ferns` cannot move, and the reason is structural: the chaos game
> is one point chasing itself, so the picture is an accumulation and the
> accumulation is the state.*

Follow it through.

Each fern holds one point, and each frame advances that point a few hundred
steps, plotting as it goes. The buffer accumulates. After 600 frames a fern has
perhaps a hundred thousand points in it, and **those points exist only in the
buffer** — there is no list of them, no scene graph, nothing to transform.

So to animate a fern you would have to either:

- **transform the accumulated pixels** — which is smearing an image, not moving
  a plant, and loses the density information the picture is made of; or
- **redraw from scratch each frame** — which throws away the hundred thousand
  points and means recomputing them all, every frame.

The second is the correct answer. It is also, on one CPU thread at a few
hundred points a frame, about a thousand times too slow.

The meadow is therefore *complete* rather than *live*: it grows, it holds for
five seconds, and it reseeds.

```mojo
comptime HOLD_FRAMES = 300  # grown landscape lingers ~5 s, then reseeds
```

That is not a missing feature. It is the honest consequence of an accumulating
renderer, and it is the problem [chapter 4](04-the-flame.md) solves — by making
"redraw from scratch every frame" cheap enough to actually do.

## Two doors for a harness

```
# FERNS_FRAMES=N renders N frames and exits as an unfocused Accessory, so a
# harness run never takes the screen from whoever is working. FERNS_DUMP=path
# writes the final frame as raw BGRA on the way out -- what a harness (or a
# reviewer) needs to see the landscape without a screen.
```

Two environment variables, and the first one's justification is about people
rather than testing: an automated run that activates as a regular application
steals focus from whoever is at the keyboard. Running as an **Accessory**
means the frames render and the window never comes forward.

The same pair appears in `fernwind/` as `FERNWIND_FRAMES` and `FERNWIND_DUMP`,
and in Fluid as `FLUID_AUTOSHOT`. A GUI example that cannot be checked without
a person watching is one that stops being checked.
