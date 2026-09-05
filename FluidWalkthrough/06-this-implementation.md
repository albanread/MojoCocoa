# 6. How this demo came to be

Fluid was not written because a fluid simulation is nice to look at, though
it is. It was written because the fork had no way to measure something it
needed to know.

## The gap it was built to fill

By August 2026 the fork had two GPU demos, and neither could answer the
question that mattered:

- **mandelbrot** is *one* dispatch per frame. Every pixel is independent, the
  kernel runs once, and the frame is dominated by arithmetic.
- **life** is *none* — the simulation is on the CPU and the GPU only presents.

So neither says anything about **launch cost**: the fixed price of asking the
GPU to run a kernel at all, paid once per dispatch regardless of how much work
the dispatch does. On a backend as new as this fork's AIR path, that number is
exactly what you want to know and exactly what a one-dispatch demo hides.

A Stable Fluids step is about **thirty-five dependent dispatches** — dependent
being the operative word, since each must finish before the next can read its
output. That makes per-dispatch overhead the dominant term rather than a
rounding error, and it makes the program a measuring instrument.

The origin commit says so in as many words:

> *The point is not that it is nice to look at. mandelbrot is one dispatch per
> frame and life is none, so neither says anything about launch cost.*

## What it measured

The first numbers, on an M4:

| launch mode | per step | spread |
|:---|---:|:---|
| synchronous | **10.19 ms** | 17.31 ms cold — ~70% |
| `APPLEGPU_ASYNC_LAUNCH=1` | **1.99 ms** | ±0.2% |

**5.1×, and the variance collapsed.** That works out to 0.234 ms of round trip
per dispatch — in the same ballpark as the 0.40 ms measured independently for
short kernels, which is the sort of agreement that makes you believe both
numbers.

The conclusion was blunt: run synchronously and *the physics alone eats a whole
60 fps frame* before a single pixel is drawn. Not because the arithmetic is
heavy — 320×240 is nothing — but because thirty-five round trips are.

Those numbers changed the backend. Async launch became the **default** rather
than an opt-in, and command-buffer batching was added to make the slow side
faster. On the same workload today:

| | per step |
|:---|---:|
| `APPLEGPU_SYNC_LAUNCH=1` | 3.87 ms |
| default (async + batched) | **1.49 ms** |

2.6× rather than 5.1×, because the floor moved. The conclusion is unchanged:
**launch overhead, not arithmetic, is what a 35-dispatch step is made of.**

The switches survive, which is unusual and deliberate — a demo that can turn
off the optimisation it motivated is a demo that can prove the optimisation
still matters:

```
./fluid                              # async, batched — the default
APPLEGPU_SYNC_LAUNCH=1 ./fluid       # the old synchronous bring-up mode
APPLEGPU_BATCH_DISPATCHES=0 ./fluid  # async, batching off
```

## The headless twin

`spikes/fluid/fluid_smoke.mojo` runs the same kernels with no window and
checks them, because "it looked right" is not a claim about a solver. It
asserts what a *broken kernel would break*:

- **dye mass** against the dissipation constant — advection conserves mass, so
  the total must track `DYE_FADE` to within 0.6%
- **post-projection divergence** within ±0.05 — the projection's entire job
- **velocity non-zero** — a solver that has quietly died is smooth and still
- **a rendered frame that is not entirely black** — the cheapest possible
  check on the whole pipeline

and it writes a PPM so a human can look. The instruction in the source is
worth keeping: *run that first if this ever looks wrong — it separates "the
physics broke" from "the window broke".*

## Two things it got wrong, and what fixing them taught

### Apple Events, sent and never received

The spike shipped with a control channel — `fluidctl <pid> <verb>` sending a
`FLUD` Apple Event for `snap`, `clr `, `rain`, `paus`, `quit` — and a README
section headed **"implemented, not yet delivered"**. The sending side worked:
`fluidctl` built the target descriptor, sent the event, got a non-nil reply and
no error. The handler never fired.

The two obvious culprits were tried and changed nothing: calling
`-[NSApplication finishLaunching]`, and servicing `CFRunLoopRunInMode`.

The cause was structural, and it is the useful part. Fluid uses mandelbrot's
**hand-rolled `nextEventMatchingMask:` pump** rather than `[NSApp run]`. Apple
Event dispatch is something `-[NSApplication run]` *performs*; it is not
something the event queue *carries*. `nextEventMatchingMask:` with
`distantPast` polls the queue and returns at once — it never services the
**Mach port** Apple Events arrive on.

The fix, now in the shipped example, is four lines and a comment that explains
itself:

```mojo
# Spin the run loop briefly. `nextEventMatchingMask:` with
# distantPast polls the event queue and returns at once -- it never
# services the Mach port Apple Events are delivered on, so without
# this the handlers registered above are simply never called. Zero
# timeout with returnAfterSourceHandled=true: drain what is ready,
# do not block the frame.
```

A 4 ms `CFRunLoopRunInMode` per frame. The handlers fire.

### A missing library, and a build that only worked one way

`[s]` writes a real PNG — deflated through libz, with a real CRC — taken from
*the same host buffer that is about to be presented*, so the file and the
window cannot disagree. That needs `-lz`, and the spike only ever built under
bazel, which passed the flag. Built with the driver the IDE's ⌘B uses, it
failed to link.

The fix was to add `-lz` to `cocoamojo` itself, beside `-lobjc` and the
frameworks. libz ships with macOS at `/usr/lib/libz.dylib`, so it costs
nothing but a load command — and a demo that builds under one build system
and not the other is a demo that will rot.

## The journey to `examples/`

| commit | what changed |
|:---|:---|
| `1262061c` | the spike: Stable Fluids on the GPU, and the launch-cost measurement |
| `365aacf5` | fps to stdout — a title bar is invisible to a captured run |
| `3761ce2f` | ported to `examples/`, converted to `class`, `-lz` added to the driver |
| `16f0e469` | Apple Events and the run-loop spin migrated to the typed-call API |
| `3ad89651` | the title as a property, the mode as a bare string |

The `class` conversion in `3761ce2f` is the one to notice. The Apple Event
target became a *declaration*:

```mojo
class FluidAEHandler:
    def handleEvent_withReplyEvent_(self, event: ObjCObject,
                                    reply: ObjCObject):
```

`handleEvent:withReplyEvent:` is **not** a selector the SDK declares, so its
`v@:@@` encoding is *derived* from the two object arguments rather than looked
up — the two-argument derivation path, which a separate check confirms both
registers and responds to. No `ObjCClassBuilder`, no encoding string, no `cmd`
slot.
