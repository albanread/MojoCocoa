# 2. The model

You do not need chemistry to read this program, but you do need three ideas.
Each is one term in the kernel, which is why the kernel is four lines.

## What is being simulated

Two scalar fields on a 768 × 768 grid:

- **U** — the substrate. Starts at 1.0 everywhere: a full tank.
- **V** — the catalyst. Starts at 0.0 everywhere except a few seeded discs.

Both are held in [0, 1]. There is no velocity field, no pressure, no
constraint linking distant cells. Two numbers per cell, and that is the entire
state.

## Idea one: diffusion, and the Laplacian that measures it

Diffusion spreads a substance from where there is more of it to where there is
less. The rate at which a point's concentration changes is proportional to how
much that point differs from its surroundings — which is what the **Laplacian**
measures.

```mojo
def _laplacian(f: Pointer[Float32, MutAnyOrigin], x: Int, y: Int) -> Float32:
    """The standard nine-point weighted Laplacian: corners a twentieth,
    edges a fifth, the centre minus one whole. The weights sum to zero,
    which is what makes this a rate of CHANGE rather than a blur -- a
    perfectly flat field produces zero here no matter what value it is
    flat at."""
```

```
    0.05   0.2   0.05
    0.2   -1.0   0.2
    0.05   0.2   0.05
```

The docstring names the property that matters: **the weights sum to zero**.
0.05 × 4 + 0.2 × 4 − 1.0 = 0.

That is the difference between a Laplacian and a blur. A blur's weights sum to
one, so it returns an average — a flat field blurs to the same flat field, but
the *value* comes back. These weights return **zero** for any flat field,
whatever it is flat at. What comes back is not a concentration; it is a rate
of change.

Get the weights wrong by a little and they no longer sum to zero, which means
a flat field spontaneously gains or loses substance everywhere — and the
simulation drifts in a way that looks like a physics bug rather than an
arithmetic one.

The nine-point form — including diagonals at a quarter of the edge weight —
is the standard discrete Laplacian for this model. A five-point version
(edges only) works but is visibly more square: patterns grow along the axes
because the operator itself prefers them.

## Idea two: reaction, and why `u·v²` is the whole personality

```mojo
var uvv = u * v * v
```

One multiply chain, and it is the reason anything interesting happens.

The reaction is `U + 2V → 3V`: V consumes U and turns it into more V. The rate
depends on U being present, and on V being present **squared** — because two
molecules of V have to meet one of U.

Three consequences, all visible on screen:

- **V cannot appear where V is absent.** `v = 0` makes the term zero however
  much U is there. Seed a blank grid with U only and nothing ever happens.
- **Growth is along the boundary.** In the interior of a V patch, U has already
  been eaten, so `u ≈ 0` and the term is small. At the edge, both are present.
  So a disc of catalyst spreads as a *ring*.
- **It is self-limiting.** Consuming U removes the thing the reaction needs.

The source puts the same point in one sentence:

> *V can only eat U where both are already present, which is why a single
> catalyst speck grows outward along its own edge rather than consuming
> everything at once.*

That is why the seed kernel does what it does:

```mojo
u[unsafe_offset=idx] = Float32(0.5)
v[unsafe_offset=idx] = Float32(1.0)
```

> *U half-consumed, V present -- exactly what a real drop of the second
> chemical looks like the instant after it lands.*

Not `u = 0`. Leaving some U inside the disc gives the reaction something to
work with immediately, which is what a real drop looks like a moment after
landing.

## Idea three: feed and kill, the two numbers that decide everything

```mojo
var du = DU * _laplacian(u_in, x, y) - uvv + feed * (Float32(1.0) - u)
var dv = DV * _laplacian(v_in, x, y) + uvv - (feed + kill) * v
```

Read the two lines as a pair. `uvv` appears **negative in `du` and positive in
`dv`** — the same quantity, moved from one species to the other. Whatever U
loses, V gains, which is what a chemical reaction is.

Then:

- **`feed * (1 - u)`** replenishes U everywhere, and note the `(1 − u)`: the
  further U is below 1, the harder it is topped up. Where U is untouched the
  term is zero. It is a pull toward full, not a constant inflow.
- **`(feed + kill) * v`** removes V everywhere, in proportion to how much is
  there. The `feed +` part is the outflow of a reactor carrying V away with
  everything else; `kill` is V's own decay on top.

Now the balance. V is created only where the pattern already is, and destroyed
*everywhere*. So a V region survives only if its edge produces V faster than
its interior loses it — and that comparison is exactly what `feed` and `kill`
set.

- **Kill too high** relative to feed: removal wins, V dies out, the field
  relaxes to U = 1 everywhere.
- **Kill too low**: V's growth outruns removal, V floods the grid, and the
  field becomes uniform the other way.
- **Between them** is a narrow band where neither wins, and the boundary
  between the two states becomes a permanent, moving structure.

Every pattern this program draws lives in that band, which is why the presets
sit within a few thousandths of one another and why the file bothers to say
that guessing produces *"a uniform grey instead of staying alive."*

## The clamps

```mojo
if nu < Float32(0.0):
    nu = Float32(0.0)
elif nu > Float32(1.0):
    nu = Float32(1.0)
```

Concentrations are physically in [0, 1] and the explicit Euler step
(`u + du·dt`) can overshoot. The clamp is not a numerical fudge so much as a
statement about what these numbers are: a negative concentration is not a
small error, it is a meaningless value that would feed straight back into
`u*v*v` next step and never recover.

`DT = 1.0` looks bold, but the units are the model's own — the diffusion
constants and rates are all scaled to it, and this is the standard discrete
form.

## Only V is drawn

```mojo
"""V alone carries the picture: everywhere U has not been eaten sits
at the same becalmed 1.0, so V's shape IS the pattern."""
```

Both fields are simulated; only one is displayed, and the reason is that U is
almost entirely uninformative. Away from the pattern it is pinned at 1.0 by
the feed term, so a picture of U is a flat field with holes in it. V is zero
except where something is happening, so V's shape is exactly the structure.
