# 5. Python, used well

Two examples in this distribution reach into CPython, and they answer different
questions. [`life-python`](01-the-small-ones.md#life-python) asks what it costs
to borrow another windowing world. `bifurcation` asks something more useful:
**what is Python actually better at than Mojo, and how do you arrange a program
so each does that part?**

The answer this example argues for:

> Python is very good at everything that *surrounds* a result — axes, scales,
> legends, labels, colour maps, file formats. It is poor at the loop that
> produced the result. Put the loop in Mojo and the presentation in Python, and
> measure the boundary rather than assuming it.

## `bifurcation`

The logistic map, `x → r x (1 − x)`, swept across 1,600 values of `r` with
2,000 iterations recorded per value. The attractor doubles, doubles again, and
falls into chaos — with windows of order inside it. A second panel plots the
Lyapunov exponent, which is positive exactly where the map is chaotic and dips
below zero exactly where the windows are.

### Why the compute stays in Mojo

The map is a **recurrence**: every iterate depends on the one before it. There
is nothing to vectorise, and nothing to hand a GPU — this is the same shape the
[ferns chapter](../gpu/04-three-ferns.md) identifies in the chaos game, and it
reaches the same conclusion for the same reason. It is simply a lot of
arithmetic that has to happen in order, 6.4 million steps of it.

The program measures the boundary instead of asserting it, running **the same
algorithm** on both sides — histogram write and logarithm included:

```text
  Mojo     23.8 ms  for all 1600 columns
  CPython   8.5 ms  for 24 columns  ->  0.6 s extrapolated
  ratio    20.2 x
```

Two things about that measurement are deliberate.

It uses `timeit`, which runs the loop **in a function scope with the collector
off**. That is CPython's best case: the same loop written at module scope,
where every name is a global lookup, is about twice as slow again. Choosing the
favourable number is the point — a comparison you have tilted in your own
favour proves nothing.

And the honest answer here is about **20×**, not the 100× a careless benchmark
would report. Twenty is still the whole argument: half a second is tolerable
once and intolerable in a loop, while the figure itself costs nothing worth
measuring.

### Why the picture comes from Python

`fern/` in this collection writes a PNG by hand. Its `png.mojo` is 125 lines of
CRC, Adler-32 and deflate's stored mode, and what you get for that is pixels in
a file: no axes, no ticks, no scale, no legend, and a 2 MB output because it
compresses nothing. That is the right answer when a bitmap is all you want.

This example wants the other thing, and matplotlib has already solved it:

```mojo
var im = top.imshow(
    dens,
    extent=extent, origin="lower", aspect="auto",
    cmap="magma", norm=mcolors.PowerNorm(0.35),
    interpolation="nearest",
)
var cb = fig.colorbar(im, ax=Python.list(top, bottom), pad=0.01)
```

Every keyword there is a decision somebody made well, and reimplementing the
set of them is a career rather than an afternoon.

### How the data crosses

Not one value at a time. `std.python.numpy` copies a flat Mojo `Span` straight
into a real NumPy array:

```mojo
var dens = copy_to_numpy_tensor(density, Coord(H, W))
var lam = copy_to_numpy_array(lyap)
```

Appending 1.4 million values across the bridge individually is the slow path,
and avoiding it is precisely why that module exists — its own docstring names
matplotlib as the case it was written for.

### Two details worth stealing

**Give the colorbar both axes.** A colorbar takes its space from the axes you
hand it, so `ax=top` alone makes the top panel narrower than the bottom, and
two panels that share an x-axis but do not line up are worse than no colorbar
at all. `ax=[top, bottom]` steals from both and keeps them aligned — which is
what lets you read a window in the diagram and see its λ dip directly beneath.

**`PowerNorm`, not a log norm.** Most buckets in a bifurcation histogram are
empty, and the log of zero is not a colour.

**The lesson: measure the boundary, then put each half where it belongs.** The
interesting claim is not "Mojo is faster" — it is that the 20× matters for one
half of this program and is irrelevant for the other, and that you can tell
which is which by timing it rather than by taste.
