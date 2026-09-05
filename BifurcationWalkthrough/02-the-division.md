# 2. The division of labour

This is the chapter the example exists for, and its argument is stated in the
first paragraph of the source:

> *The thing Python is very good at is not arithmetic. It is everything that
> surrounds a result: axes with sensible ticks, a colour map with a legend, a
> log-scaled norm, two panels sharing an x-axis, a label in the right place,
> and a PNG at the end. That is thousands of decisions somebody has already
> made well, and reimplementing them is a career rather than an afternoon.*

## The pair it is half of

The example is explicitly one of two answers, and names the other:

> *`fern/` in this collection writes a PNG by hand — 125 lines to put pixels in
> a file, with no axes, no ticks, no scale and no legend. It is the right
> answer when a bitmap is all you want. This example is the other answer.*

Compare what the two figures need:

| `fern/` | `bifurcation/` |
|:---|:---|
| a bitmap | two panels sharing an x-axis |
| no axes | axes with chosen ticks on both |
| one colour ramp, hand-written | a named colour map with a legend |
| — | a norm that makes a sparse histogram readable |
| — | filled regions under a curve, conditionally |
| 125 lines of PNG writer | one `savefig` |

The fern needs none of it, so writing the PNG by hand is 125 readable lines and
zero dependencies. The bifurcation diagram needs all of it, and each item is a
small pile of decisions — where to put the ticks, how to space them, what to do
when a label collides — that somebody has already made well.

Neither is the general answer. **The two sit side by side on purpose**, so that
"write it yourself" and "use the library" both appear as reasonable, with the
distinguishing question visible: *does this output need presentation, or is a
bitmap all you want?*

## Why the arithmetic does not go with it

The other half of the argument is that the compute cannot follow the figure
across, because it is exactly the shape CPython is worst at:

> *the map itself is a **recurrence** — x depends on the x before it — so it
> cannot be vectorised away, and 6.4 million iterations of it is real work that
> Mojo does in milliseconds and CPython does in tens of seconds.*

The words *vectorised away* are doing real work there. NumPy makes Python fast
by moving whole-array operations into C — but that requires the operations to
be independent. A recurrence has no such structure: `x[n]` needs `x[n-1]`, so
the loop stays in the interpreter, one bytecode dispatch per multiply.

This is the case where "just use NumPy" does not apply, and it is worth being
able to recognise.

## Measuring it, unflatteringly

The program does not assert the ratio; it measures it, every run, and it takes
several deliberate steps to avoid measuring something too favourable.

**The same algorithm on both sides.**

```mojo
# Deliberately the same work, including the histogram write and the log,
# so the comparison is not flattered by leaving something out.
```

The CPython statement does the transient, the record loop, the bounds check,
the histogram increment, the derivative, the absolute value, the guard and the
logarithm — every operation the Mojo version does. It would be easy to compare
Mojo-with-histogram against Python-without, and it would be meaningless.

**CPython's best case, on purpose.**

```mojo
"""The same algorithm, in CPython, timed by `timeit`."""
```

From the README:

> *It is also measured with `timeit`, which runs the loop in a function scope
> with the collector off — CPython's best case, deliberately.*

`timeit` disables the garbage collector and executes in a function scope, where
local variable access is an array index rather than a dictionary lookup. Both
make CPython meaningfully faster than the same code at module level. The
comparison uses them because a benchmark should give the other side its best
showing.

**Only 24 columns, extrapolated and labelled as such.**

```mojo
comptime PY_COLS = 24      # columns CPython is asked to do, for the comparison
```

```mojo
var py_full_s = py_s * Float64(W) / Float64(PY_COLS)
print("  CPython ", one_dp(py_s * 1000.0), "ms  for", PY_COLS,
      "columns  ->", one_dp(py_full_s), "s extrapolated")
```

1,600 columns of CPython would take most of a second every time the example
runs, so it does 24 and scales. The output says **"extrapolated"** rather than
printing a number that looks measured. The extrapolation is sound because the
work per column is identical — but it is still an extrapolation, and the print
says so.

**And the result is reported to one decimal place:**

```mojo
def one_dp(v: Float64) -> String:
    """One decimal place, because six of them is not a measurement."""
```

A ratio printed as `20.238471` claims a precision the experiment does not have.

## What the number means

```
  grid   1600 columns x 900 rows
  work   6400000 iterations, each depending on the one before it

  Mojo     23.8 ms  for all 1600 columns
  CPython   8.5 ms  for 24 columns  ->  0.6 s extrapolated
  ratio    20.2 x
```

And the README refuses to inflate it:

> *On this machine the honest answer is about 20×, not the 100× a badly-set-up
> comparison would report.*

Twenty is a real number and a hundred is a set-up artefact. You can get a
hundred by leaving the histogram out, or by timing at module scope, or by
comparing against a version that allocates in the loop. The example does none
of those, and reports the smaller number.

Then it says why twenty is enough:

> *Twenty times is the whole argument. Half a second is tolerable once and
> intolerable in a loop, and the figure is not the part that costs anything.*

That is the sharpest sentence in the example. Nobody is arguing 0.6 seconds is
unusable. The argument is about the **inner loop of an exploration** — sweeping
a parameter, re-running with a finer grid, checking whether a feature is real —
where half a second per iteration is the difference between a tool you play
with and one you wait on.

And the second clause matters just as much: *the figure is not the part that
costs anything*. matplotlib's share of the runtime is irrelevant, so there is
no reason to reimplement it. Speed matters where the time is; convenience
matters everywhere else.

## The failure path is a repair instruction

```mojo
except e:
    print("could not plot:", e)
    print()
    print("matplotlib lives in this project's Python environment:")
    print("  Python menu -> Create or Repair Environment")
    print("  Python menu -> Install Project Dependencies")
```

The likeliest way this example fails on a new machine is a missing matplotlib,
which is a setup problem rather than a bug. So the error path prints the two
menu items that fix it.

Note also that the comparison is wrapped in its own `try`:

```mojo
except e:
    print("  CPython  (comparison skipped:", e, ")")
```

No Python, no comparison — but the Mojo timing still prints and the figure is
still attempted. The parts fail independently.
