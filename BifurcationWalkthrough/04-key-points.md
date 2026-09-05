# 4. What to understand

Seven things about this example are not obvious from looking at the picture.

## 1. The division is measured, not asserted

Every run prints the ratio it measured on that machine. Nothing here relies on
a number from somewhere else, and the number is checked against the same
algorithm on both sides:

```
  Mojo     23.8 ms  for all 1600 columns
  CPython   8.5 ms  for 24 columns  ->  0.6 s extrapolated
  ratio    20.2 x
```

## 2. Twenty is the honest number, and it is enough

> *On this machine the honest answer is about 20×, not the 100× a badly-set-up
> comparison would report.*

You could get 100× by leaving the histogram write out, or by timing at module
scope instead of in a function, or by comparing against code that allocates in
its loop. The example does none of those and reports the smaller figure.

And it says why twenty suffices:

> *Half a second is tolerable once and intolerable in a loop, and the figure is
> not the part that costs anything.*

Nobody claims 0.6 s is unusable. The claim is about the inner loop of an
exploration — sweep, refine, re-run — where half a second per iteration decides
whether a tool is interactive.

## 3. A recurrence is where "just use NumPy" stops working

```mojo
"""Every iteration depends on the one before it, so there is nothing to
vectorise and nothing to hand a GPU -- it is simply a lot of arithmetic,
done in order."""
```

NumPy makes Python fast by pushing whole-array operations into C, which needs
the elements to be independent. `x[n]` needs `x[n-1]`, so the loop stays in the
interpreter at one bytecode dispatch per multiply.

Recognising this shape is the transferable part. It is the same obstacle the
[chaos game](../FernWalkthrough/index.md) has, and the same one that keeps
alpha-beta off the GPU in [Othello](../OthelloWalkthrough/index.md).

## 4. Not everything that could be parallel should be

The 1,600 columns *are* independent — a GPU could take them. The example does
not, and at 23.8 ms it should not: a dispatch, a buffer and a read-back would
cost more than the whole computation.

**You cannot speed up something that has already finished.** Othello measures
alpha-beta at 81 µs and reaches the same conclusion.

## 5. The bridge is where the performance goes

```mojo
# The alternative -- appending 1.4 million values across the bridge one at a
# time -- is the slow path, and this is the reason that module exists.
var dens = copy_to_numpy_tensor(density, Coord(H, W))
```

Two bulk copies instead of 1.44 million appends. Get this wrong and the
compute is fast, the handover is slow, and the whole argument for splitting the
work collapses.

## 6. Density plots need a compression chosen for their data

Three examples in this collection plot density, and none uses the same curve:

| | |
|:---|:---|
| `fern/` | `log(h+1) / log(peak+1)` — needs a pass to find the peak |
| `fernwind/` | `n/(n+3)` — needs only the pixel; a kernel can afford it |
| `bifurcation/` | `PowerNorm(0.35)` — because **most buckets are exactly zero**, and `log(0)` is not a colour |

The reflex here is a log norm, and it is wrong for this data specifically.

## 7. Small ordering and layout facts that are easy to get backwards

**`mpl.use("Agg")` before importing `pyplot`.** The backend is chosen at
import; afterwards it is too late, and the program either wants a window it
should not need or fails on a headless machine.

**A colorbar takes space from the axes you give it.** Attaching it to the top
panel alone narrows that panel while the bottom stays full width — and two
panels sharing an x-axis that do not line up defeat the whole figure, because
you can no longer read a window in one against the λ dip in the other.

**Let the orbit settle.** 2,000 discarded iterations per column, or every
column carries a smear leading down from x = 0.5.

<!-- doccrate:keep-together:start -->

## A short list of things that will bite

| If you change… | …this happens |
|:---|:---|
| the transient to zero | every column smears down from the starting x |
| `PowerNorm` to a log norm | the empty buckets stop being background |
| the colorbar to `ax=top` | the panels misalign and cannot be read against each other |
| `use("Agg")` to after the `pyplot` import | it wants a window, or fails headless |
| the bulk copy to a per-element append | the handover costs more than the computation |
| the CPython statement, without changing the Mojo | the comparison stops comparing the same work |
| `number=1` in `timeit` | the default is a million runs — about two and a half hours |
| the `1e-12` guard on the derivative | `log(0)` at every superstable orbit centre |

<!-- doccrate:keep-together:end -->

## Running it

```bash
cocoamojo --build examples/bifurcation/main.mojo -o /tmp/bifurcation
```

matplotlib lives in the project's own Python environment. Once, from the IDE:

1. Python menu → **Create or Repair Environment**
2. Python menu → **Install Project Dependencies**

Then ⌘R. It prints the ratio it measured, writes `bifurcation.png` beside the
project, and opens it.

The other half of this example's argument — writing the PNG by hand, when a
bitmap is all you want — is the [fern walkthrough](../FernWalkthrough/index.md).
