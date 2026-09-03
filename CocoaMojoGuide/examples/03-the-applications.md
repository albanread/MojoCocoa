# 3. The applications

Four real programs: a window with a simulation in it, twice on the GPU, once
not, and one that plays a board game. Between them they answer a question the
smaller examples cannot, and it is worth stating before the walkthroughs
because it is the reason to read all four rather than one.

> The moment you own a `DeviceContext`, you lose `[NSApp run]`.

`life` is the only one of the four that hands control to Cocoa in the ordinary
way. The other three hand-roll an event pump, and all three give the same
reason: a `DeviceContext` cannot live in a `named_global`, and a Cocoa callback
cannot reach a local — so the loop that owns the GPU has to be the loop that
drives the application. Neither file teaches that alone. The pair does.
<!-- doccrate:keep-together:start -->


## `life`

592 lines. Conway's Life at 180×120, cells coloured by age, mouse drawing,
keyboard control, a 60 Hz timer, presented through a `CAMetalLayer`.

<!-- doccrate:keep-together:end -->

This chapter will not walk it line by line, because
[Guide, chapter 9](../guide/09-walkthrough.md) already does — that chapter
exists to read this exact program. What belongs here is why it earns a place
next to three GPU applications while using **no GPU at all**.

Metal appears in `life` only to put pixels on screen. `evolve()` is a plain
double loop over 21,600 cells on the CPU. That is the correct decision, and it
follows the rule the [ferns chapter](../gpu/04-three-ferns.md) argues for:
21,600 cells at 60 Hz is 1.3 million cell-updates a second, which a single core
does without noticing. The work is wide, but there is no deadline being missed,
so there is nothing for a kernel to buy.

The architectural payoff is that because nothing is a local that a callback
needs, `life` can use the normal Cocoa shape — and it is the only example here
that shows it:
<!-- doccrate:keep-together:start -->


| `class` | How Cocoa reaches it |
|:---|:---|
| `LifeDelegate` | `applicationShouldTerminateAfterLastWindowClosed:`, via `setDelegate:` |
| `LifeActions` | `lifeTick:`, the target of a 60 Hz `NSTimer` |
| `LifeView` | `mouseDown:`, `mouseDragged:`, `rightMouseDown:`, `keyDown:` … |

<!-- doccrate:keep-together:end -->

Three classes, three different ways Cocoa calls into your code, and `[NSApp
run]` on the last line.

Two comments in this file are worth more than the simulation. The first states
a Mojo rule that will eventually bite everyone:
<!-- doccrate:keep-together:start -->


```mojo
"""Zeroed heap memory that nothing in Mojo owns.

The buffers must outlive `main`'s locals: Mojo destroys a value at its LAST
USE, not at end of scope, so a `List` whose `.unsafe_ptr()` we stash is
freed immediately and every stored pointer dangles -- which shows up much
later as a corrupted allocator, nowhere near the cause.
"""
```

<!-- doccrate:keep-together:end -->

Destruction at last use, **not** at end of scope. Stash a pointer into a
`List` and the list can be gone before the next line.

The second is a diagnostic nobody would predict: the timer's selector is
`lifeTick:` rather than the obvious `tick:`, because the SDK already declares
`tick:` on `CASecureFlipBookLayer` taking a double. An invented selector that
collides with a known one gets registered with the SDK's shape — `v@:d` where
`v@:@` was meant. The compiler said so, which is the part worth noticing.

**The lesson: this is what a normal CocoaMojo application looks like**, and a
demonstration that declining a GPU is a legitimate answer.
<!-- doccrate:keep-together:start -->


## `mandelbrot`

469 lines. A live-zooming fractal at 60 fps, every pixel computed *and*
coloured by one Mojo kernel. There is no shader anywhere in the pipeline.

<!-- doccrate:keep-together:end -->

One dispatch per frame does everything: `mandelbrot_color_kernel` computes the
escape count and applies the cosine palette in the same kernel, so the CPU
receives finished BGRA and its entire job is `map_to_host`, a copy, and
`replaceRegion:` into the drawable's texture.

Before the window opens, it times itself honestly:
<!-- doccrate:keep-together:start -->


```mojo
# Warm, then time: the first launch carries compilation and wiring.
ctx.enqueue_function(kern, dev, cx, cy, scale, grid_dim=(GRID), block_dim=(BLOCK))
ctx.synchronize()
var g0 = perf_counter_ns()
ctx.enqueue_function(kern, dev, cx, cy, scale, grid_dim=(GRID), block_dim=(BLOCK))
ctx.synchronize()
var g1 = perf_counter_ns()
```

<!-- doccrate:keep-together:end -->

A discarded warm-up launch, then the measured one. The first launch of any
kernel carries compilation and pipeline setup; timing it and reporting the
number is the most common way GPU benchmarks lie. The same file runs the
identical arithmetic on one CPU core and prints both.

Three details worth stealing:

**`isFlipped` instead of arithmetic.** Cocoa's origin is bottom-left and the
kernel counts pixels from the top. Rather than subtracting in every handler,
the view says:
<!-- doccrate:keep-together:start -->


```mojo
def isFlipped(self) -> Bool:
    # Origin at the top-left, exactly as the kernel counts pixels, so a
    # click converts to a pixel without anyone flipping an axis.
    return True
```

<!-- doccrate:keep-together:end -->

`life` does the same conversion by hand. This is better.

**`send` rather than the typed surface, for Metal.** The concrete classes
behind `MTLDevice` and friends are private, so there is no public class name
for `cocoakb` to check a selector against. That is the rule for choosing: the
typed form — `Obj["NSWindow"](...)`, `Cls["NSApplication"]()` — whenever the
database knows the class, and dynamic `send` when it cannot.

`life` shows the seam directly. `+layer`'s result class is not in the
metadata, so `CAMetalLayer` is named once at the wrap and every call after it
is checked against the class that was meant:
<!-- doccrate:keep-together:start -->


```mojo
var layer = ObjCObject(Cls["CAMetalLayer"]().layer().id)
var mlayer = Obj["CAMetalLayer"](layer.addr())
_ = send[ObjCObject, "setDevice:"](layer, display_dev.ptr())
_ = mlayer.setPixelFormat(nsenum["MTLPixelFormatBGRA8Unorm"]())
```

<!-- doccrate:keep-together:end -->

One dynamic call, because the device is private; the rest checked, because
the layer is not.

**A headless mode that does not steal focus.** `MANDEL_FRAMES=N` renders N
frames and exits, with the window brought up as an Accessory and unfocused so a
benchmark run does not take the desktop from whoever is working. The header
notes that this lesson "was learned the loud way." Frame rate goes to stdout as
well as the title bar, because a title bar is invisible to a captured run.

Correctness is checked outside the example, in
`spikes/mandelbrot/compute_smoke.mojo`, and the threshold is worth
understanding: **exact agreement on more than 99.0% of pixels**, not a float
tolerance. The GPU fuses multiply-add where the CPU does not, which shifts
escape counts in the thin chaotic band at the set's boundary. That is inherent
to a Float32 Mandelbrot, not a bug, and a tolerance-based check would have been
the wrong instrument.

**The lesson: one kernel can own the whole frame**, and this is the smallest
honest CPU-versus-GPU timing harness in the distribution.
<!-- doccrate:keep-together:start -->


## `fluid`

873 lines. Stable Fluids — drag the mouse, dye swirls through a velocity field
that is advected along itself and then made divergence-free by a Jacobi
pressure solve. Six kernels, all Mojo, no shader.

<!-- doccrate:keep-together:end -->

It exists for a reason its own header states, and the reason is more
interesting than the fluid:

> mandelbrot is one dispatch per frame and life is none, so neither measures
> launch cost.

A fluid step is roughly **35 dependent dispatches** — two advections,
divergence, thirty Jacobi sweeps ping-ponged in pairs, projection, dye
advection and a shade pass. Each waits on the one before. That makes
per-dispatch round-trip the dominant term rather than a rounding error, and
`fluid` is the only example in the set shaped to measure it.

The measurement has moved as the runtime improved, so take the *shape* of the
result rather than any single ratio. The example's header records an early
figure of 10.19 ms/step synchronous against 1.99 ms/step asynchronous on an M4,
with the synchronous path also showing a 70% spread between cold and warm runs
while the asynchronous path held to ±0.2%. Later measurements with dispatch
batching added put the same 35-dispatch workload at 3.87 ms/step synchronous
against 1.49 batched-and-asynchronous, and on an M4 Max batching alone moves
1.06 to 0.93. The ratio has fallen from 5.1× to 2.6× because the slow side got
faster; the conclusion has not moved at all. Launch overhead, not arithmetic,
is what a many-kernel step is made of.

> **Note.** The header's instruction to set `APPLEGPU_ASYNC_LAUNCH=1` is stale.
> Asynchronous, command-buffer-batched launch is now the default;
> `APPLEGPU_SYNC_LAUNCH=1` is what restores the old synchronous behaviour, and
> `APPLEGPU_BATCH_DISPATCHES=0` isolates batching.

Two ideas here are worth more than the benchmark.

**The Jacobi solve is ping-ponged, and the comment says why:**
<!-- doccrate:keep-together:start -->


```mojo
Ping-ponged rather than updated in place: a Jacobi step reads the previous
iterate's whole neighbourhood, and writing in place would feed half-new
values back in, silently turning this into Gauss-Seidel with a
thread-order-dependent answer.
```

<!-- doccrate:keep-together:end -->

"Silently" is the operative word. In-place would converge to something
plausible and wrong, and differently wrong on different hardware.

**There are two run loops, and a hand-rolled pump only services one of them.**
This is the single most valuable paragraph in the four applications:
<!-- doccrate:keep-together:start -->


```mojo
# Spin the run loop briefly. `nextEventMatchingMask:` with
# distantPast polls the event queue and returns at once -- it never
# services the Mach port Apple Events are delivered on, so without
# this the handlers registered above are simply never called.
```

<!-- doccrate:keep-together:end -->

`fluid` is scriptable — it registers an Apple Event handler for five verbs — and
draining the AppKit event queue does not deliver Apple Events, which arrive on
a different Mach port. Without an explicit `CFRunLoopRunInMode` spin, a
correctly registered, correctly addressed, perfectly well-formed event is
simply never delivered. The same applies to `finishLaunching`, which a
hand-rolled pump must call itself because it is where AppKit attaches that port
to the run loop.

Two things to keep in mind if you use this file as a reference. Its header
claims the companion `spikes/fluid/fluid_smoke.mojo` checks mass conservation
to 0.6% and post-projection divergence within ±0.05; the smoke test actually
enforces three qualitative conditions — dye did not vanish, dye did not blow
up, the splat landed — and prints those two figures for a human to read. They
are observations, not asserted tolerances. And unlike `life` and `mandelbrot`,
`fluid` declares no view class at all: it picks events apart by integer type
inside the pump.

**The lesson: dispatch cost is a real budget line**, and a hand-rolled pump
silently drops any input channel it does not explicitly service.
<!-- doccrate:keep-together:start -->


## `othello`

1,000 lines across `board.mojo`, `ai.mojo` and `main.mojo`. The board game on a
green felt board, with four computer players — and the only example in the
distribution that makes a falsifiable engineering argument and then declines to
take the flattering side of it.

<!-- doccrate:keep-together:end -->

The question is where a GPU helps a computer player. The answer is: for one of
the two classic search algorithms, and not the other.

**Alpha-beta does not want a GPU**, and the file says so at the top of `ai.mojo`:
<!-- doccrate:keep-together:start -->


```
# Alpha-beta is the classic answer and it does NOT want a GPU. Its whole
# advantage is that a branch which cannot beat what you already have is never
# examined, so the work each thread does depends on what every other thread
# found -- the opposite of what a GPU is for. Threads would diverge on the
# first cutoff, and an 8x8 board at four ply is a few hundred microseconds of
# CPU anyway. Shipping that on the GPU would be slower and dishonest.
```

<!-- doccrate:keep-together:end -->

The measurements back it: depth 3 is 22 µs, depth 4 is 81 µs, depth 6 is
1,009 µs. There is no deadline being missed, and the pruning that makes the
algorithm good is exactly what threads in lockstep would have to give up.

**Monte-Carlo playouts do.** Play the position out at random a few thousand
times per candidate move and count wins: every game is independent, holds its
whole state in two registers, touches no memory until it writes a single
`Int32`, and runs the same instructions as its neighbours. Threads are laid out
as `(move, playout)` so a whole warp shares a candidate. Measured here:
**16,384 playouts take 136.8 ms on the CPU and 3.4 ms on the GPU — 40×**, and
both pick the same move.

So the Master level is a GPU player and the other three are not. Master beats
Advanced 6–0.

The reduction is done on the host on purpose: an atomic per playout "would
serialise exactly the thing that is supposed to be parallel."

Two traps in this example are worth carrying away.

**A legal construct that the Metal backend cannot link.** The winner test is
written as arithmetic rather than the obvious three-way branch:
<!-- doccrate:keep-together:start -->


```mojo
# The obvious `if b > w: 1 elif w > b: -1 else: 0` is folded into LLVM's
# three-way compare intrinsic, and the Metal backend has no such
# instruction -- the kernel then fails to link with "Undefined symbols:
# llvm.scmp.i32.i64", which says nothing about what wrote it.
# `Int(b > w) - Int(w > b)` is ALSO folded: zext(a>b) - zext(b>a) is the
# canonical shape LLVM turns into scmp. This one is not that shape.
return Int(b > w) * 2 - Int(b != w)
```

<!-- doccrate:keep-together:end -->

Note that the *obvious rewrite is also wrong*. Both the branch and the
subtraction fold into the same intrinsic; only the third form survives.

> **This has since been fixed in the backend.** AIR legalisation now expands
> `llvm.scmp` and `llvm.ucmp` into selects, so the obvious three-way branch
> compiles and runs, and a surviving intrinsic fails the build by rule rather
> than reaching the reader as an undefined symbol. The workaround is still in
> othello's source and still correct — it is simply no longer required. The
> lesson that outlives the bug is the shape of the failure: a legal construct
> the optimiser *introduced*, invisible to a target-agnostic verifier, and
> named only at pipeline creation.

**A struct return, and a trap that has since been closed.** An `NSPoint` comes
back in two registers, and for a while the hand-typed `msg_send` was the only
shape that described that to the ABI — the dynamic path returned nothing
usable, and every click landed on the same wrong square, silently. The example
now reads:
<!-- doccrate:keep-together:start -->


```mojo
# The point comes back typed: locationInWindow's @encode says NSPoint, and
# the call path maps that to CGPoint through the kind ladder -- two doubles
# in registers, described to the ABI by the database rather than by anyone's
# memory of it.
let at = Obj["NSEvent"](event.addr()).locationInWindow()
```

<!-- doccrate:keep-together:end -->

The lesson survives the fix, and it is the one this whole layer rests on: the
thing that knows how a value crosses is the metadata, not the programmer. What
changed is that you no longer have to say it twice.

The move generator underneath all this is 121 lines of bitboard shifts with no
struct at all — two bare `UInt64`s are the board — validated against published
perft counts (4, 12, 56, 244, 1396, 8200, 55092). That representation is what
makes the parallel player *possible*, not merely faster: a playout fits in
registers because the board does.

**The lesson: "can this use a GPU?" is the wrong question.** "Is this work wide,
and am I out of time?" is the right one, and the same program can answer it
differently for two of its own features.
