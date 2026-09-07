# 6. What to understand

Eight things about this example are not obvious from watching it.

## 1. There is no network in the code

No graph, no edges, no nodes, no path-finding. An agent holds a position and a
heading and nothing else — no memory of where it has been, and no way to
perceive another agent.

> *No agent knows about any other agent, and no cell of the map knows it is
> part of a network.*

The veins are what 300,000 copies of one rule do to a shared array. That is
**stigmergy**, and it is the same mechanism that builds a termite mound.

## 2. Fading is what makes it work

Without decay, every path ever taken persists, the map saturates, all three
sensors read alike, and the agents turn at random forever — a network that
dissolves by remembering too much.

Decay makes a trail a claim that must be renewed. A route survives only while
agents keep using it, which is exactly the dead-end withdrawal that made the
real organism famous.

> *A trail is a rumour: it spreads to its neighbours and fades unless agents
> keep repeating it.*

<!-- doccrate:keep-together:start -->

## 3. The blur and Gray-Scott's Laplacian are opposites

Both are nine-point stencils over the same neighbourhood.

| | Physarum | Gray-Scott |
|:---|:---|:---|
| weights sum to | **one** | **zero** |
| returns | a value — the local average | a rate of change |
| what it is | a blur | a Laplacian |

<!-- doccrate:keep-together:end -->

Gray-Scott integrates its result into an existing field, so it needs a rate.
Physarum replaces the value outright, so it wants the average.

## 4. The map wraps because the agents do

```mojo
"""The trail map wraps, not clamps: an agent that walks off the right
edge reappears on the left, so the map it senses and deposits into
must wrap the same way or a trail would smear against a false wall
the agents themselves never see."""
```

Gray-Scott clamps, because its cells do not travel and a reflecting boundary
is the physical choice. Physarum's agents travel, so a clamped map would give
them a torus to walk on and a rectangle to sense on.

The two must agree. That is the transferable point: **topology is a property
of the system, not of a function.**

## 5. Structure of arrays, not array of structures

Three separate `Float32` buffers for x, y and angle. Thread *n* reads `px[n]`
and thread *n+1* reads `px[n+1]`, so adjacent threads touch adjacent addresses
and the loads coalesce. An array of `{x, y, a}` structs would stride each
thread past two floats it does not want.

Slightly worse to read, meaningfully better to run.

## 6. The deposit races on purpose

```mojo
trail[unsafe_offset=cidx] = trail[unsafe_offset=cidx] + DEPOSIT
```

Read-modify-write from 300,000 threads, not atomic. Two agents on the same
cell in the same step can lose an increment — and the file says so, and says
why it does not matter:

> *An atomic add would buy correctness this demo has no way to show.*

The lost value is 5.0 on one of 589,824 cells for one frame, before being
averaged with eight neighbours and decayed.

**Compare [fernwind](../FernWalkthrough/index.md)**, which does the same
scattered accumulation and *does* use `Atomic.fetch_add` — because there the
count is a divisor for a mean colour, so lost increments would bias the result
rather than dither it.

Same operation, opposite decisions, both reasoned from what the number is used
for afterwards. *"Is this racy?"* is the wrong question; *"what would a lost
increment change?"* is the right one.

## 7. Hash the index instead of carrying an RNG

```mojo
var r = _rand01(UInt32(idx) * UInt32(747796405) + frame)
```

No per-agent generator state to allocate, seed or advance — and no setup
kernel. Index and frame in, a number out.

The `frame` term is load-bearing: without it, an agent that hit a sensor tie
would break it the same way every frame forever.

Note `_rand01` takes 24 bits, which is what a `Float32` mantissa holds exactly.

## 8. The mouse has no attraction code

> *Nothing forces an agent toward it — the network only bends here because
> sensing a bright patch and turning toward it is all an agent ever does
> anyway; this just gives it something bright to find.*

There is no force, no target, no steering behaviour. The mouse writes into the
map the agents were already reading. Interaction is free because it reuses the
mechanism that was already the entire model.

<!-- doccrate:keep-together:start -->

## Things that will bite: the model

| If you change… | …this happens |
|:---|:---|
| `decay` to 1.0 | trails never fade; the map saturates and the network dissolves into noise |
| the blur weights to sum to something else | the map gains or loses trail everywhere, on its own |
| `_at` to clamp instead of wrap | trails pile against a wall the agents cannot see |
| the tie-break to leave the heading alone | agents walk straight until they chance on a trail; the map stays blank far longer |
| the step to under one pixel | agents redeposit into the same cell; trails come out dotted |

<!-- doccrate:keep-together:end -->

<!-- doccrate:keep-together:start -->

## Things that will bite: the machinery

| If you change… | …this happens |
|:---|:---|
| the three agent arrays into one struct array | the loads stop coalescing |
| `diffuse` to write in place | threads read a mix of old and new neighbours; nondeterministic |
| the `frame` term out of the tie-break hash | an agent breaks every tie the same way, forever |
| the three init multipliers to one seed | every agent starts on a diagonal with a correlated heading |
| the parity flip | the colour kernel draws the pre-diffusion map, every frame |
| `_rand01` to take all 32 bits | the divisor is not exactly representable; the low bits are lost |

<!-- doccrate:keep-together:end -->

<!-- doccrate:keep-together:start -->

## Controls

| | |
|:---|:---|
| **drag** | lay a strong trail — the network bends to it |
| **1–4** | web, coil, sparse, dense — live, map kept |
| **r** | reseed agents, clear both trail buffers |
| **space** / **s** / **q** | pause · save a PNG · quit |
| `PHYSARUM_FRAMES=N` | render N frames unfocused, then exit |

<!-- doccrate:keep-together:end -->

<!-- doccrate:keep-together:start -->

## And beside the others

| example | what couples the work | dispatches per frame |
|:---|:---|---:|
| mandelbrot | nothing | 1 |
| **physarum** | **a shared map, written racily** | **3** |
| grayscott | one cell of diffusion per substep | 21 |
| fluid | a global constraint needing a solver | ~35 |

<!-- doccrate:keep-together:end -->

Physarum is cheap because its coupling is weak — agents affect each other only
through a map that is blurred and decayed anyway. Fluid is expensive because
its coupling is exact. Reading the four together is the clearest picture in
the collection of what coupling actually costs.
