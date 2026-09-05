# 6. What to understand

Eight things about these three programs are not obvious from watching them.

## 1. The fern is twenty-eight numbers

Four affine maps and their probabilities. No code anywhere knows what a stem or
a frond is:

> *Barnsley's fern: four maps, and the shape is in the numbers.*

Every visual property — the spine, the curl of the fronds, the density
falloff — is a consequence of those numbers and the chaos game's statistics.

## 2. A recurrence has nothing to divide

`x, y = map[k](x, y)` — step *n* depends on step *n−1* and nothing else. There
is no loop to split and no thread to hand it to. It is the same structural
obstacle the logistic map hits in
[bifurcation](../examples/bifurcation), and the same one that keeps alpha-beta
off the GPU in [Othello](../OthelloWalkthrough/index.md).

**The answer is not to parallelise it.** It is to notice that the starting
point does not matter, and run 24,576 short independent games instead of one
long one. A different algorithm sampling the same attractor.

## 3. Density is the picture; hit-or-miss throws it away

> *Chaos-game pictures are all about density — plotting hit-or-miss throws
> away most of the picture, which is exactly what the old text version was
> doing.*

The chaos game visits the fern in proportion to how much fern is there. Record
a boolean and you get a flat silhouette; record a count and you get a plant.

And having kept the density you must compress it — the spine gets thousands of
hits and an outer frond gets three:

| | |
|:---|:---|
| `fern/` | `log(h+1) / log(peak+1)` — needs a second pass to find the peak |
| `fernwind/` | `n/(n+3)` — needs only the pixel, which is what a kernel can afford |

## 4. Burn-in is not optional

```mojo
comptime SETTLE = 20   # fern/
comptime BURN = 12     # fernwind/
```

The first points are not on the fern — they are travelling towards it. Plot
them and you get a stray trail from wherever you started. Harmless once. In
`fernwind/` it would be 24,576 trails, every frame, and would read as haze.

## 5. `ferns/` cannot move, and it is structural

> *the chaos game is one point chasing itself, so the picture is an
> accumulation and the accumulation is the state*

There is no list of points to transform — the hundred thousand points in a
grown fern exist only as counts in a buffer. Animating means redrawing from
scratch, which means recomputing everything, every frame.

That is not a missing feature. It is what an accumulating renderer *is*, and
recognising it is what produced the third program.

## 6. Twenty-four thousand threads need twenty-four thousand dice — per frame

```mojo
# A stream's randomness must differ per thread AND per frame, or every
# frame replots the same points and the flame strobes.
```

Two independent requirements. Share across threads and 24,576 streams trace one
trajectory. Share across frames and every frame plots identical points — which
still looks like a fern, and visibly strobes.

Note the frame seed is `frames % 8388608` — 2²³, the largest integer a
`Float32` holds exactly, because the parameter block is floats.

And note that `fern/` needs the **opposite** property: a fixed seed, so *"the
picture is the same every run — an example that draws something different each
time is hard to check."* Same generator, opposite requirement, both commented.

## 7. The wind is applied to the maps, not the picture

Rotating the climb map by a fraction of a degree bends the entire plant,
because that map applies **recursively** — once at the base, about twenty times
at the tip:

> *because that map applies recursively up the plant, a uniform rotation
> compounds into a progressive bend: stems lean, tips whip*

Nobody wrote a stiffness gradient. The correct curve falls out of the
recursion, and it is the same reason a real stem bends that way: the deflection
at each height is the sum of everything below it.

This is only possible because the frame is rebuilt from nothing — so solving
the throughput problem made the animation free rather than merely faster.

## 8. Probe an unproven runtime behaviour before you build on it

> *The design rests on two facts proved by a probe before anything was built on
> them, since nothing in this fork's AIR path had used either: `Atomic.fetch_add`
> lowers through the backend without losing increments (4096 threads, 4096
> counted), and host writes through `map_to_host` reach the next dispatch.*

Both failures would have been silent. Dropped atomic increments give a meadow
that is subtly thin — indistinguishable from the tone curve being wrong. Stale
host writes give a wind that does not move — with no error either.

Two four-line probes answered both in isolation. Debugging them afterwards
would have meant debugging them through a fern.

<!-- doccrate:keep-together:start -->

## Things that will bite: drawing the fern

| If you change… | …this happens |
|:---|:---|
| plotting to hit-or-miss | a flat silhouette; the density that *is* the picture is gone |
| the log or `n/(n+K)` curve to linear | everything but the spine goes black |
| `STREAMS` or `ITERS` without retuning K | the meadow blows out to white, or vanishes |
| the burn-in to zero | a stray trail per stream — 24,576 of them, every frame |
| the per-thread seed to a shared one | one trajectory at 24,576× density |
| the per-frame seed to a fixed one | identical points every frame; visible strobing |
| the atomic adds to plain adds | hits lost, silently, in proportion to contention |

<!-- doccrate:keep-together:end -->

<!-- doccrate:keep-together:start -->

## Things that will bite: moving it

| If you change… | …this happens |
|:---|:---|
| rotating map 1's linear part but not its translation | the fern bends about the wrong point and detaches from the ground |
| the per-fern phase offset | the whole meadow leans as one object |
| dropping `flip` from the bend | mirrored ferns bend into the wind |

<!-- doccrate:keep-together:end -->

## Running them

```bash
cocoamojo --build examples/fern/main.mojo -I examples/fern -o /tmp/fern
```

| | |
|:---|:---|
| `fern/` | writes `fern.png` beside where it was run, and prints a rough copy |
| `ferns/` | click plants · space pauses · `r` reseeds · `q` quits |
| `fernwind/` | click plants · space stills the air · `r` reseeds · `q` quits |
| `FERNS_FRAMES=N`, `FERNWIND_FRAMES=N` | render N frames unfocused, then exit |
| `FERNS_DUMP=path`, `FERNWIND_DUMP=path` | write the final frame as raw BGRA |

One dialect note from building the last of them: **`fn` is a keyword**, and
cannot be used to name a float.
