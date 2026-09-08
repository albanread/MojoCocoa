# Presentation ideas

A running backlog, not a design doc: things worth building for the channel
that haven't been started yet. Each entry should say what it is, why it's
worth doing, and roughly what it would take -- enough to pick back up cold,
not a full spec. Move an entry into its own `_design.md` (`grayscott` and
`physarum` didn't get one; `chipdeluxe` and `gamepane` did) once it's
actually being built.

---

## Interactive GPU kernel builder

**What.** A live playground: type a Mojo compute kernel, see it compiled
and running on the Metal GPU immediately, displayed through the same
window/blit pipeline `mandelbrot`, `grayscott`, `physarum` and `boids`
already proved out (a `UInt32` BGRA buffer, `replaceRegion:` straight onto
the drawable, no shader). Kernel parameters exposed as live sliders rather
than recompiled constants, so a viewer can feel what `feed`/`kill` or a
sensor angle actually does without touching code.

**Why.** Everything built this session was entertaining-first: satisfying
to watch, not something a viewer could pick up and use. This is the
deliberate pivot -- from "watch this" to "build this yourself" -- and it's
useful in the literal sense: it lowers the barrier to trying Mojo GPU
programming at all, for someone who has no interest in ever watching
another demo.

**What it would take.** A different KIND of work than the last four
examples, not more of the same: less shader math, more UI/UX and
error-surface design --

- An editor pane and a compile step, in-process, showing real compiler
  diagnostics rather than a terminal dump. Every trap this session
  actually hit is a candidate for a friendlier inline message instead of
  an afternoon of grepping: the `DevicePassable` fixed-width rule (a
  bare `Int` kernel argument fails with a constraint error naming
  `Int32`/`Int64`, buried several frames deep in `_device_context_extras.mojo`
  and `simd.mojo`), the `xcrun metallib` link failure for a genuinely
  missing AIR builtin (`atan2f`, fixed properly this session -- see
  `mojo/stdlib/std/math/math.mojo`) versus a `comptime assert` failure
  for one that's merely unwired (`tan`/`atan` before the same fix), the
  ping-pong discipline a kernel needs the moment it reads another
  thread's output rather than only its own (`grayscott`'s u/v pair,
  `boids`' position/velocity, `physarum`'s pinned agent state).
- A way to declare "this constant is a live parameter" and get a slider
  for free, rather than a recompile per value -- something `grayscott`'s
  six presets and `physarum`/`boids`' four each currently fake by
  branching on an index.
- Decide the sandboxing story before anything else: a kernel a viewer
  typed is untrusted code running with GPU memory access, which is a
  different risk profile than every example so far, all authored by us.

**Depends on.** Nothing new at the infrastructure level -- the AIR
backend, the window/blit pattern, and the specific failure modes above
are all already proven or fixed. The work is entirely in exposing that
compile/run/diagnose loop live, safely, and interactively.
