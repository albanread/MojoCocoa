# 4. The five kernels

Five kernels, all ordinary Mojo `def`s through this fork's AIR backend. Two
are addressed by agent index, three by pixel index.

<!-- doccrate:keep-together:start -->

| kernel | threads | when |
|:---|:---|:---|
| `init_agents` | one per agent | once, and on `r` |
| `agent` | one per agent | every frame |
| `diffuse` | one per cell | every frame |
| `attract` | one per cell | only while dragging |
| `color` | one per cell | every frame |

<!-- doccrate:keep-together:end -->

## The hash that replaces a random generator

```mojo
def _hash_u32(x: UInt32) -> UInt32:
    var h = x
    h = (h ^ UInt32(61)) ^ (h >> UInt32(16))
    h = h + (h << UInt32(3))
    h = h ^ (h >> UInt32(4))
    h = h * UInt32(0x27D4EB2D)
    h = h ^ (h >> UInt32(15))
    return h
```

Six operations, no memory, no state. Shifts and xors mix the low bits upward
and the high bits downward; the odd multiplier spreads everything; the final
shift-xor finishes the avalanche.

```mojo
def _rand01(seed: UInt32) -> Float32:
    return Float32(_hash_u32(seed) & UInt32(0xFFFFFF)) / Float32(0xFFFFFF)
```

Twenty-four bits, which is exactly what a `Float32` mantissa holds without
rounding. Taking all 32 would divide by a number the float cannot represent
and quietly lose the low bits.

The reason it is a hash rather than a generator is in the comment: a
generator has **state**, and state has to be allocated, seeded and carried
between calls. 300,000 of them would need their own buffer and their own setup
kernel. A hash of the index needs nothing.

## 1. `init_agents_kernel`

```mojo
var rx = _rand01(UInt32(idx) * UInt32(2654435761) + UInt32(1))
var ry = _rand01(UInt32(idx) * UInt32(2246822519) + UInt32(2))
var ra = _rand01(UInt32(idx) * UInt32(3266489917) + UInt32(3))
```

> *entirely on the GPU, hashing each agent's own index rather than needing
> 300,000 separate host-side random calls before the first frame can run*

Three different large odd multipliers and three different offsets, so the same
`idx` produces three uncorrelated values. Using the same seed three times
would put every agent on the diagonal with a heading proportional to its
position, and the first frame would look like a diffraction grating.

## 2. `agent_kernel` — the whole behaviour

Covered in [chapter 2](02-the-rule.md). Two things about its *shape*:

**Parameters are arguments, not constants.** `sensor_angle`, `turn_angle`,
`sensor_dist` arrive per dispatch, so the number keys switch regime live
without recompiling — the same choice Gray-Scott makes with `feed` and `kill`.

**`frame` is an argument too**, and it is what makes the tie-breaking random
number differ from step to step for the same agent. Without it, an agent that
found a tie would break it the same way every frame forever.

## 3. `diffuse_kernel` — spread and fade

```mojo
out_t[unsafe_offset=idx] = (s / Float32(9.0)) * decay
```

A nine-point box average and a multiply. Separate in and out buffers, for the
same reason every stencil in this tree has them: a cell's new value depends on
its neighbours' **old** values, and writing in place would let a thread read
neighbours another thread has already updated.

`_at` wraps here rather than clamping, matching the agents' own topology —
[chapter 2](02-the-rule.md) covers why that has to be consistent.

## 4. `attract_kernel` — the mouse

```mojo
if dx * dx + dy * dy <= r2:
    trail[unsafe_offset=idx] = Float32(400.0)
```

Sets a disc of the trail map to a large value — note **set**, not add, so
holding the mouse still does not accumulate without limit.

The docstring is the best sentence in the file:

> *A strong trail laid down under the cursor. Nothing forces an agent toward
> it — the network only bends here because sensing a bright patch and turning
> toward it is all an agent ever does anyway; this just gives it something
> bright to find.*

There is no attraction code. There is no force, no target, no steering
behaviour. The mouse writes into the same map the agents were already reading,
and the network bends because of a rule that was there before the mouse
existed.

That is what a well-factored emergent system looks like: the interaction is
free because it uses the mechanism that was already the whole model.

## 5. `color_kernel` — tone mapping, borrowed

```mojo
var m = t / (Float32(1.0) + t)
var r = m
var g = m * m * Float32(0.85)
var b = m * m * m * Float32(0.55)
```

> *`fluid`'s own x/(1+x) curve, reused for the same reason it was needed there:
> raw deposit totals span a huge range between a cell one agent grazed once and
> a cell on a busy trunk route, and a linear map would blow the second one out
> to solid white while the first stayed too dark to see.*

`x/(1+x)` maps [0, ∞) into [0, 1) — a cell with 5.0 comes out at 0.83, one
with 400 at 0.9975, and nothing ever reaches 1.0.

The colour ramp is three different **powers of the same value**: red linear,
green squared, blue cubed. So faint trails are red, brighter ones warm through
orange, and only the brightest go toward white — each channel switching on at a
different intensity, from one tone-mapped number.

> *A warm amber ramp on black reads as bioluminescence rather than a heat map.*

The alternative — a rainbow palette, which the same three-cosine trick from
Gray-Scott would have given for free — would have made this look like a
thermal image of something. The choice is about what the picture claims to be.

<!-- doccrate:keep-together:start -->

## Where the borrowing shows

Three of these five are lifted from siblings, and each is labelled:

| from | what |
|:---|:---|
| `fluid` | the `x/(1+x)` tone curve; `save_png` verbatim |
| `grayscott` | the `_at` discipline, the flags-only view class, `_pack` |
| `mandelbrot` | no shader: the colour kernel writes BGRA the drawable takes directly |

<!-- doccrate:keep-together:end -->

> *example folders are self-contained by this tree's own convention, so this
> is a copy, not an import*

Copying rather than sharing keeps every example a folder that opens and runs
on its own. It costs duplication and it is stated as the trade each time it is
taken.
