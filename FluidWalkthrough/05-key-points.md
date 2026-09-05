# 5. What to understand

Eight things about this demo are not obvious from watching it, and most of
them are things that would bite you if you changed the code.

## 1. It is a benchmark wearing a demo's clothes

The thirty Jacobi dispatches are not a lazily-written solver. They are the
*point*. A step of thirty-five **dependent** dispatches is the cheapest honest
way to measure per-dispatch launch overhead, and that is why the program was
written. If you optimise the pressure solve down to five dispatches, you will
have made a nicer fluid and destroyed the instrument.

The switches are the tell:

```bash
./fluid                              # async, batched — the default
APPLEGPU_SYNC_LAUNCH=1 ./fluid       # the old synchronous bring-up mode
APPLEGPU_BATCH_DISPATCHES=0 ./fluid  # async, batching off
```

Those exist so the optimisation this demo motivated can still be turned off
and re-measured. Run all three and watch the printed ms/step change by 2.6×.

## 2. Advection runs backwards, and that is why it never explodes

The single most counter-intuitive line in the program is a minus sign.

```mojo
var px = Float32(idx % W) - dt * u[unsafe_offset=idx]
```

Forwards advection — push each cell's contents to where they are going —
is conditionally stable: exceed a time-step limit and it diverges. Backwards
advection — ask each cell where its contents *came from*, and interpolate —
can only ever produce values between values that already existed. It is
**unconditionally stable at any time step**.

`DT = 0.125` is therefore a choice about how fast the fluid looks, not a
stability limit you are tiptoeing around. You can raise it and the simulation
will get soupy and smeared long before it becomes unstable, because it cannot
become unstable.

## 3. The Jacobi ping-pong is a correctness requirement, not a style

If you take one thing from this walkthrough, take this. From the source:

> *Ping-ponged rather than updated in place: a Jacobi step reads the previous
> iterate's whole neighbourhood, and writing in place would feed half-new
> values back in, silently turning this into Gauss-Seidel with a
> thread-order-dependent answer.*

Write `pr` while reading `pr` and the program will not crash, will not warn,
and will still look like a fluid. It will simply produce a different answer on
every run, on every machine, at every occupancy — because which neighbours a
thread sees as "already updated" is decided by the GPU scheduler.

This is the shape of GPU bug that costs weeks: no symptom, no reproduction, no
stack trace. The defence is structural — two buffers, swapped — rather than
careful, and `JACOBI_ITERS` must stay **even** because the loop runs
`JACOBI_ITERS // 2` pairs and the answer has to land back in `pr`.

## 4. Dye rides the *corrected* field

```mojo
ctx.enqueue_function(project, u0, v0, pr, ...)          # first
ctx.enqueue_function(advect, s0, dr, u0, v0, ...)       # then dye, on u0/v0
```

Advect the dye before projection and it is carried by a field that is still
compressible — dye will visibly bunch and thin in ways the motion does not
explain, and it will look *slightly* wrong in a way nobody can name. Order
matters here in a way it does not elsewhere in the frame.

## 5. `ctx.synchronize()` is the only place the CPU waits

Everything in a frame is `enqueue_`: create, memset, function, copy. One
`synchronize()` sits between the render kernel and `map_to_host`, and that is
where the entire batch is paid for.

That single sync point is why async launch mattered so much. Adding a second
one — say, a debug read-back in the middle of the solve — would not "cost one
read"; it would split the batch and reintroduce the round trips the whole
design exists to avoid. If you are ever tempted to inspect a buffer mid-frame,
use `fluid_smoke.mojo` instead.

## 6. Magnification is where the illusion lives

The simulation is 320×240. The window is 960×720. Nine screen pixels per
simulation cell, and the difference between a fluid and a mosaic is entirely
in how those nine are filled:

- **Bilinear, not nearest**, because *"point-sampling a 320×240 grid into
  960×720 would show the simulation's cells rather than the fluid."*
- **Reinhard tone mapping**, `r / (1 + r)`, because *"a heavy drag saturates
  gracefully instead of clipping to white."* Dye can accumulate without limit
  and the image keeps getting brighter rather than flattening into a white
  blob.

Both are one line each in `render_kernel`, and both are doing more for the
demo's appearance than any physics constant.

## 7. Nothing here is a shader

There is no Metal Shading Language in this program. The six kernels are
ordinary Mojo `def`s compiled through this fork's AIR backend into a
`metallib`. Two consequences you can actually use:

- `_expf` is written out by hand so **host and device share one definition** —
  the same function is correct in a kernel and in CPU code. That is what lets
  `fluid_smoke.mojo` test the real splat rather than an imitation of it.
- The kernel source and the application source are the same language, the same
  file, and the same build. There is no shader-compilation step to get wrong.

The Cocoa side is the same story: the window, the `CAMetalLayer`, the Apple
Event handler are all Mojo. `FluidAEHandler` is a real Objective-C class
declared with `class`, and its `handleEvent:withReplyEvent:` encoding is
*derived* from the two object arguments rather than looked up, because that
selector is not one the SDK declares.

## 8. Run the headless twin first

```bash
./bazel-bin/spikes/fluid/fluid_smoke
```

Same kernels, no window. It reports dye mass against `DYE_FADE`,
post-projection divergence, whether velocity is non-zero, and whether a
rendered frame is anything but black — and it writes a PPM you can look at.

The source is explicit that these are *observations to read, not thresholds it
enforces*: 0.6% mass drift and ±0.05 divergence on a good run. The instruction
matters more than the numbers:

> *Run it first if this ever looks wrong: it separates "the physics broke" from
> "the window broke".*

Those are two completely different investigations, and five seconds of smoke
test tells you which one you are in.

<!-- doccrate:keep-together:start -->

## A short list of things that will bite

| If you change… | …this happens |
|:---|:---|
| `JACOBI_ITERS` to an odd number | the loop runs one pair fewer and the answer ends up in `pr0`, which nothing reads |
| jacobi to write in place | nondeterministic results, no error, no symptom |
| dye advection to before `project` | dye bunches and thins for no visible reason |
| advection to write in place | threads read neighbours from the future |
| `DYE_FADE`/`VEL_FADE` to 1.0 | the screen saturates and never recovers |
| nearest-neighbour sampling in render | a visible 320×240 mosaic |
| an extra `synchronize()` per frame | the batch splits; back to the 2.6× slow path |
| `-lz` removed from the driver | links under bazel, fails under `cocoamojo` |

<!-- doccrate:keep-together:end -->

## Controls

| | |
|:---|:---|
| **drag** | paint dye and push the fluid; the hue advances as you go |
| **space** | pause |
| **c** | clear |
| **r** | rain — random splats |
| **s** | save a PNG of exactly the frame about to be presented |
| `fluidctl <pid> snap\|clear\|rain\|pause\|quit` | the same verbs over Apple Events |
| `FLUID_AUTOSHOT=<n>` | save frame *n* and quit — headless capture |

Keys and Apple Events set the same command bits, so each verb has one
implementation regardless of where it came from.
