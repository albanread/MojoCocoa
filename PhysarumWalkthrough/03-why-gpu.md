# 3. Why this belongs on a GPU

Physarum is a good GPU workload for different reasons than
[Gray-Scott](../GrayScottWalkthrough/03-why-gpu.md), and the differences are
the interesting part.

## Two populations, which is the new shape

Every other GPU example in this collection dispatches over **one** thing.
Mandelbrot: pixels. Fluid: grid cells. Gray-Scott: grid cells. Fernwind:
chaos-game streams.

Physarum has two, and the commit names it as the point of the example:

> *one genuinely new shape: two different populations on the GPU at once, an
> agent kernel addressed by agent index and a trail kernel addressed by pixel
> index, rather than grayscott's one grid doing everything.*

```mojo
comptime GRID = (CELLS + BLOCK - 1) // BLOCK          # 2,304 blocks
comptime AGENT_GRID = (AGENTS + BLOCK - 1) // BLOCK   # 1,172 blocks
```

Two grid sizes, and each kernel is launched with the one matching what it
iterates over. The agent kernel does not know the map is 768 × 768 except as a
wrap modulus; the diffuse kernel does not know agents exist at all.

They share exactly one thing: a `Pointer[Float32]` to the trail map.

## Agents are a structure of arrays

```mojo
def agent_kernel(px: Pointer[Float32, MutAnyOrigin],
                 py: Pointer[Float32, MutAnyOrigin],
                 pa: Pointer[Float32, MutAnyOrigin], ...)
```

Not an array of `Agent {x, y, angle}` structs. Three separate arrays.

That is **structure-of-arrays** layout, and on a GPU it is not a style
preference. Thread *n* reads `px[n]`, thread *n+1* reads `px[n+1]` — adjacent
threads touch adjacent addresses, so the hardware coalesces 32 loads into one
transaction. With an array of structs, thread *n* would read offset 12*n* and
consecutive threads would stride past two floats they do not want, turning one
transaction into several.

Three arrays, three coalesced streams, for a layout that reads slightly worse
in source and runs meaningfully better.

## What each half looks like to the hardware

### The trail kernels: textbook

`diffuse_kernel` is a nine-point stencil over 589,824 cells with a fixed
neighbourhood, uniform control flow, no reduction and no atomics. Everything
Gray-Scott's chapter 3 says applies unchanged.

`color_kernel` and `attract_kernel` are the same shape, one thread per pixel.

### The agent kernel: mostly good, honestly

Per agent: three `_at` reads, six trig calls, a handful of comparisons, three
writes to its own slots, one read-modify-write into the map.

Two properties are excellent:

- **Perfectly independent.** No agent reads another agent's position. There is
  no neighbour search and no spatial data structure — the map does the
  coupling.
- **No dynamic allocation, no variable work.** Every agent does exactly the
  same amount of work every step. Nothing is born, nothing dies, nothing has
  a list.

And two are worth being honest about:

- **The turn is a branch.** `if sc > sl and sc > sr` … `elif` … `else` is
  data-dependent, and adjacent agents will take different arms. It is short —
  the arms differ by one addition — so the hardware masks rather than
  serialising anything expensive, but it is not free the way Gray-Scott's
  straight-line arithmetic is.
- **The trail reads are scattered.** Agents at adjacent indices are at
  unrelated positions after a few hundred frames, so their sensor reads land
  anywhere in the map. This is the opposite of the stencil kernels' neat
  locality, and it is the agent kernel's real cost. Nothing can be done about
  it without sorting agents by position, which would cost more than it saves
  at this scale.

## The race the file accepts on purpose

```mojo
trail[unsafe_offset=cidx] = trail[unsafe_offset=cidx] + DEPOSIT
```

Read, add, write — from 300,000 threads into one shared array, **without an
atomic**. Two agents landing on the same cell in the same step can lose an
increment.

The kernel says so itself, in its own docstring:

> *The deposit at the end is a plain, non-atomic add: two agents landing on the
> same cell in the same step can lose one increment to the other, and at
> 300,000 agents over 589,824 cells that collision is rare and, once it
> happens, invisible — a fraction of one step's trail on one pixel,
> immediately blurred and decayed with everything around it. An atomic add
> would buy correctness this demo has no way to show.*

Three separate claims, and each is checkable.

**Rare.** 300,000 agents over 589,824 cells is roughly one agent per two cells.
If they were uniformly scattered, collisions would be a small fraction of
deposits. They are *not* uniformly scattered — agents concentrate on trails,
which is the whole point — so the real rate is higher on a busy trunk route
than the average suggests.

**Invisible.** A lost deposit is 5.0 on one cell for one frame. That cell is
then averaged with its eight neighbours and multiplied by ~0.94, and it is one
of 589,824. There is no display path on which the difference could appear.

**An atomic would buy correctness the demo cannot show.** This is the honest
version of the argument, and the one worth keeping. It is not "atomics are
slow" — it is that the *only* consequence of the race is a value nobody can
distinguish from the value without it.

Compare [fernwind](../FernWalkthrough/04-the-flame.md), which does the same
kind of scattered accumulation and **does** use `Atomic.fetch_add` — because
there the accumulated count is divided to produce a mean colour, so lost
increments would bias the result systematically rather than dither it.

Same operation, opposite decisions, both reasoned from what the number is
afterwards used for. That is the transferable part: *"is this racy?"* is the
wrong question, and *"what would a lost increment change?"* is the right one.

## No RNG state anywhere

A conventional agent simulation gives each agent a random-number generator and
advances it. That is per-agent state to allocate, initialise and carry.

This one hashes instead:

```mojo
# GPU threads have no shared RNG state to advance -- each one HASHES its own
# index (and the frame count, when the same agent needs a fresh number every
# step) instead, which is embarrassingly parallel by construction and needs
# no setup kernel of its own.
```

```mojo
var r = _rand01(UInt32(idx) * UInt32(747796405) + frame)
```

Index and frame in, a number out, no state and no ordering. The initial
scatter uses the same trick with three different multipliers, so 300,000
agents get random positions and headings **on the GPU** with no host-side
random calls at all.

<!-- doccrate:keep-together:start -->

## The cost, and the comparison

Three dispatches per frame — agent, diffuse, colour. That is the cheapest
frame of any simulation in the collection.

| example | dispatches per frame | what couples the work |
|:---|---:|:---|
| mandelbrot | 1 | nothing |
| **physarum** | **3** | **a shared map, written racily** |
| grayscott | 21 | one cell of diffusion per substep |
| fluid | ~35 | a global constraint, needing a solver |

<!-- doccrate:keep-together:end -->

Physarum is cheap because its coupling is *weak*: agents affect each other
only through a map that is blurred and decayed every frame anyway. Fluid is
expensive because its coupling is *exact* — incompressibility has to hold
everywhere, at once, to a tolerance.

Reading those four together is the clearest picture in the collection of what
coupling costs.
