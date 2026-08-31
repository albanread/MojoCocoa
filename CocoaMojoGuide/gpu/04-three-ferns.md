# 4. Three ferns: when a GPU kernel is worth writing

Three examples in this distribution draw the same plant. `fern/` writes one to
a file, `ferns/` grows a meadow of them live, and `fernwind/` makes that meadow
sway. They were built in that order, and the interesting thing is not that the
last one uses the GPU — it is *where* the crossing happens, and that the first
two are right to stay on the CPU.

The rule this chapter argues for, ahead of the evidence:

> Move work to the GPU when it is **wide** and you are **out of time**. Width
> without a deadline does not need one. A deadline with narrow work cannot use
> one.

Both halves matter, and the three ferns separate them cleanly.

## The shape of the problem

All three draw a Barnsley fern by the **chaos game**. Four affine maps, each
with a probability; start anywhere, pick a map at random, apply it, plot where
you land, repeat. The picture emerges from the density of visits.

```mojo
var r = rng.next()          # pick a map by weight
...
var nx = m.a * x + m.b * y + m.e
var ny = m.c * x + m.d * y + m.f
x = nx
y = ny                      # the next point depends on this one
```

That last line is the whole difficulty. The chaos game is a **recurrence**:
point *n+1* is a function of point *n*. You cannot compute the millionth point
without computing the 999,999th, so a single stream **cannot be parallelised
across time**, not by a GPU and not by anything. Any thought of "just put the
fern on the GPU" runs into that wall immediately.

What *is* parallel is something else, and noticing the difference is the whole
chapter: **independent streams**. A hundred separate chaos games, each starting
from its own seed, are a hundred independent recurrences. They do not need to
talk to each other. That is the parallelism — not within a fern's history, but
across many short histories.

## `fern/` — no deadline, so no question

Two million points, one stream, straight down the CPU, into a histogram:

```mojo
var hits = List[UInt32](length=W * H, fill=0)
...
hits[idx] += 1
```

Then a log curve to colour (linear brightness leaves the fronds invisible
beside the stem) and a PNG.

Measured: **2,000,000 points, a 720×960 PNG encoded, and an ASCII preview
printed, in 44.8 ms** total.

There is nothing here for a GPU to do. Not because the work is small — 2M
iterations is not nothing — but because **nobody is waiting**. The program runs
once, writes a file, exits. A GPU would add device setup, a kernel launch and a
readback to a job that finishes in the time it takes to blink. The right
hardware for work with no deadline is whatever is simplest to write, and that
is the CPU.

`fern/` is also the example that shows what a project looks like: three files —
`main.mojo`, `ifs.mojo`, `png.mojo` — side by side in one folder, because
`cocoamojo` follows imports from `main.mojo` and a project's files live in the
project's folder.

## `ferns/` — a deadline arrives, and the CPU still wins

Now a live window: a dozen ferns growing in front of you, over a procedural
lawn of fourteen thousand grass blades, under a two-octave value-noise sky.
There is a deadline now — 60 frames a second, 16.7 ms a frame — and the example
still does everything on the CPU. That is not laziness. It is the design.

The trick is in one comment in the source:

> *The chaos-game point (x, y) is the whole growing state — the picture so far
> lives in the framebuffer, not here.*

Each fern keeps only its **current point**. Every frame it advances that point
a few dozen steps and plots them into a framebuffer that is **never cleared**.
The picture accumulates. Nothing already drawn is ever drawn again.

So the per-frame cost is not "draw twelve ferns" — it is "add about sixty
points to each of twelve ferns", on the order of **a thousand points a frame**.
On the measured CPU rate below that is roughly **four microseconds** of chaos
game per frame, inside a 16,700 µs budget. The lawn and sky are painted once
per landscape, not per frame, for the same reason.

Measured: **240 frames at 61.1 fps.**

A GPU kernel here would be strictly worse. Fourteen thousand grass blades and a
thousand chaos-game steps do not fill an M4 Max's width; you would pay a
dispatch and a synchronise to save four microseconds of a sixteen-millisecond
budget. **Accumulation is what keeps this cheap** — and it is also exactly what
forbids the next thing.

## The wall: why `ferns` cannot move

Wind means the ferns change shape. Change the shape and every point already in
that framebuffer is wrong. The accumulation — the thing that made `ferns` cheap
— is only valid while nothing moves.

So animating the meadow is not an optimisation problem. It is a different
problem: **every fern must be drawn from scratch, every frame**, at full
density. The work per frame goes from about a thousand points to about seven
million.

That is the crossing. Not "the GPU is faster" — the *requirement changed*.

## `fernwind/` — wide work, and now out of time

The answer is the fractal-flame one: stop trying to make one stream long, and
run an enormous number of short ones.

```mojo
comptime STREAMS = 24576
comptime BURN    = 12     # unplotted, to land on the attractor
comptime ITERS   = 280    # plotted
```

24,576 threads, each running its own small chaos game: twelve iterations
discarded so the point is genuinely *on* the attractor before anyone sees it,
then 280 plotted. That is **6,881,280 plotted points per frame**, and at 60 fps,
**413 million points a second**.

The burn-in is worth pausing on. A chaos game started at an arbitrary point
takes a few iterations to converge onto the fern; plot those and you get a
scatter of wrong dots leading in from nowhere. Twelve throwaway iterations per
stream is the price of 24,576 independent starting points, and it is why the
picture is clean.

Threads meet only in the density buffers, through atomics:

```mojo
_ = Atomic.fetch_add(nacc.unsafe_offset(pat), UInt32(1))
_ = Atomic.fetch_add(racc.unsafe_offset(pat), cr)
_ = Atomic.fetch_add(gacc.unsafe_offset(pat), cg)
_ = Atomic.fetch_add(bacc.unsafe_offset(pat), cb)
```

A count, and the fern's colour weighted in — so where two ferns overlap they
blend **by evidence rather than by draw order**, which is a thing painters'
algorithms cannot do at all.

### The wind is in the mathematics, not the geometry

Nothing bends a fern. Each fern's *climb map* — the affine map that carries the
plant upward, chosen 85% of the time — is rotated a fraction of a degree per
frame by a gusting wind field. Because that map is applied **recursively** up
the plant, a uniform rotation compounds: the stem barely moves, the tips whip.
The bend is a consequence of recursion, not of any code that draws a curve.

This is the payoff for redrawing from scratch. Once the maps can change per
frame, the motion is free — it costs nothing beyond the redraw you were already
doing. `ferns` could never have this at any price, because its picture is its
history.

## The measurement

The same work — one `fernwind` frame's 6,881,280 plotted points — on each
processor. M4 Max, warm, three trials each:

| | per frame | rate |
|---|---|---|
| **CPU**, one thread | **26.6 ms** | 259 M points/s |
| **GPU**, 24,576 streams | **0.256 ms** | 26,900 M points/s |

**104× faster on the GPU** — and the number that actually decides it is the
first column against a 16.7 ms frame budget. The CPU is not hopeless here; it
is *close*. At 26.6 ms it would sustain about 37 fps for the chaos game alone,
before compositing 655,360 pixels or painting anything else. Close, and on the
wrong side of the line.

That is what makes this a good example rather than a flattering one. The GPU is
not rescuing a hopeless computation. It is turning work that misses the
deadline by 1.6× into work that uses 1.5% of the frame — and hands the rest of
the frame back for the shade pass, the present, and the whole of AppKit.

Measured with the same source shape as the example, dispatching and awaiting
only the chaos kernel. The frame rate of `fernwind` itself cannot show this:
it is vsync-locked, so it reads 60.2 fps whether the kernel takes 0.26 ms or
14 ms. **A frame-rate number tells you a deadline was met, never by how much.**

## What stayed on the CPU, deliberately

`fernwind` did not move everything. The lawn and the cloud sky are still
painted by the CPU, once per landscape, and uploaded — because they do not
change between frames, and work that does not change should not be recomputed
by anyone. Only the part that genuinely changes every frame went to the GPU,
and a second small kernel composites densities over that backdrop.

The design also rests on two facts that were **proved by a probe before the
example was written**: that `Atomic.fetch_add` lowers through the AIR backend
without losing increments, and that host writes through `map_to_host` reach the
next dispatch. Both are assumptions that would have been extremely painful to
discover as bugs later, and cheap to establish first.

## The rule, restated

| | width | deadline | verdict |
|---|---|---|---|
| `fern/` | 2M sequential points | none | **CPU** — nobody is waiting |
| `ferns/` | ~1k points/frame | 16.7 ms | **CPU** — accumulation keeps it tiny |
| `fernwind/` | 6.9M points/frame | 16.7 ms | **GPU** — 26.6 ms doesn't fit |

Ask, in this order:

1. **Is anything waiting?** No deadline, no reason. Write it on the CPU.
2. **Can I avoid the work instead?** `ferns` beats `fernwind` at its own game
   by never redrawing. The cheapest kernel is the one you didn't dispatch.
3. **Is the work actually wide?** Not "is it big" — is it *many independent
   things*? A chaos game is not parallel across time and never will be; it is
   parallel across streams. Find the axis that is independent, or there is
   nothing for the hardware to do.
4. **Measure both.** Not the frame rate — the work. A vsync-locked 60 fps looks
   identical at 0.26 ms and 14 ms.

The GPU chapter before this one shows how to write the kernel. This one is
about whether to.
