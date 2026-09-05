# 5. The window and the pump

`main.mojo` is 499 lines: a window, some drawing, and a loop. Almost all of
its interesting decisions follow from one constraint, stated in the header:

> *The event loop is hand-rolled rather than `[NSApp run]` for the reason
> mandelbrot gives: a `DeviceContext` cannot live in a `named_global`, and a
> Cocoa callback cannot reach a local, so the loop that owns the GPU has to be
> the loop that drives the app. The view's handlers only set flags.*

## Why the loop is hand-rolled

Under `[NSApp run]`, AppKit owns the loop and your code runs from callbacks.
That is the normal, correct way to write a Cocoa app, and here it does not
work.

The obstruction is that a `DeviceContext` cannot be stored in a
`named_global`. Process globals in this dialect are zero-initialised, so
anything with a destructor needs a one-element `List` to live in one — and a
`DeviceContext` is not a thing you can conjure from zeroed memory.

So the context has to be a local. And a Cocoa callback — a method on a class,
invoked by AppKit — has no way to reach a local in `main`. The two facts
together leave exactly one arrangement:

> *the loop that owns the GPU has to be the loop that drives the app.*

`main` keeps the `DeviceContext` in a `var`, pumps the event queue itself, and
handles everything. The view's handlers do not compute moves, do not touch
Metal, and do not redraw. They set integers.

```mojo
def mouseDown_(self, event: ObjCObject):
    # Only a flag: the pump owns the game, and the GPU, and the redraw.
```

This is the same shape Fluid uses, arrived at from the same constraint — and
it is worth recognising as a *pattern* rather than a workaround. Anything that
owns a GPU context in this dialect ends up driving its own loop.

## The state, and why it is in globals

```mojo
comptime g_black = named_global["oth.black", Int]
comptime g_white = named_global["oth.white", Int]
comptime g_black_turn = named_global["oth.turn", Int]
comptime g_level = named_global["oth.level", Int]
...
comptime g_click = named_global["oth.click", Int]     # 1 + square, or 0
comptime g_cmd = named_global["oth.cmd", Int]
```

> *The game, in globals, because the view's handlers and the pump both need it
> and neither can pass anything to the other.*

Note `g_click` holds **1 + square**, not the square. Zero has to mean "nothing
clicked", and square 0 is a real square (a1). The offset is what keeps the
sentinel distinct from a legal value — the sort of detail that produces a
board where the top-left corner mysteriously cannot be played.

Note also that the boards are `Int` here and `UInt64` everywhere else, with
`board_black()` / `set_board()` converting at the boundary. The globals are
storage; the rules get the right type.

## The bug that taught the example something

This is the most valuable twenty lines in the file, and they are a comment:

```mojo
# Read the flag out BEFORE clearing it. `let` binds by reference
# here, so `let cmd = g_cmd()[]` is a live view of the global and
# not a snapshot: clearing the global first makes every later
# read of `cmd` return zero, and the command silently evaporates.
```

The original code was the shape everybody writes:

```mojo
let clicked = g_click()[]
if clicked != 0:
    g_click()[] = 0          # <- clicked is a REFERENCE, not a copy
    let m = bit(clicked - 1) # <- bit(-1)
```

In this dialect `let` **binds to a place, not a copy**. `clicked` is another
name for the global, so clearing the global empties it, and `bit(-1)` is
computed from a value that was correct one line earlier.

What makes this worth a chapter rather than a footnote is how it presented.
From the commit message:

> *Every observable signal said the mouse worked: the handler ran, the
> coordinates were right, the square was legal. The failure was one line
> later, in code that reads like an obvious snapshot-then-clear.*

Every diagnostic you would reach for says the code works. The handler fires.
The coordinates map to exactly the four legal opening squares. The square is
legal. And nothing happens — because the only thing wrong is a read that
occurs after a write nobody thinks of as a write.

The fix is to derive what you need *before* clearing:

```mojo
if g_cmd()[] != 0:
    let quit = (g_cmd()[] & CMD_QUIT) != 0
    let fresh = (g_cmd()[] & CMD_NEW) != 0
    g_cmd()[] = 0
```

Test the global directly, extract what you need, *then* clear. The same
pattern is applied to `g_click` immediately below.

The compiler now warns about the tracked form of this — *"this write changes
what 't' reads"* — but it cannot see through the untracked-origin pointer a
`named_global` hands back, which is exactly the case here.

## The other bug in the same commit

The same commit fixed two more, and they had a common cause:

> *An NSPoint is two doubles returned in registers, and that path does not
> describe the return shape to the ABI, so the call yields nothing usable and
> every click computes the same wrong square — with no error anywhere.*

The click point was read through the dynamic path, which does not tell the ABI
that the return is a two-double struct. The keyboard had it too, reading
`charactersIgnoringModifiers`, so N, Q and the level keys were all dead.

Both are now typed calls, and the mouse handler carries a note that reads as
history rather than warning:

```mojo
# The point comes back typed: locationInWindow's @encode says
# NSPoint, and the call path maps that to CGPoint through the kind
# ladder -- two doubles in registers, described to the ABI by the
# database rather than by anyone's memory of it. (It was not always
# so: the hand-typed msg_send here used to be the only safe shape.)
```

Three bugs in one commit, and all three shared a property: **the program
looked like it was working.** Nothing raised, nothing crashed, no diagnostic
fired. That is what makes them worth writing down.

## Drawing

Deliberately plain. No layers, no Core Animation, no image caching — the whole
board is redrawn on demand:

```mojo
class OthelloView(NSView):
    def drawRect_(self, dirty: CGRect):
        draw_board()
        draw_status()
```

Grid lines are drawn as thin rectangles rather than paths:

> *a board this size needs nine of them each way and no path object.*

Discs are `NSBezierPath` ovals. Legal moves for the human are drawn as a small
dot:

> *Small, so it reads as advice rather than as a disc already placed.*

And the one coordinate flip in the program, isolated to the drawing code:

```mojo
# Row 0 is the top of the board; the view is not flipped, so
# the top row is the highest y.
let y = MARGIN + STATUS_H + Float64(7 - row) * CELL
```

The rules use row 0 = top because that is how the board is drawn; the view
uses Cocoa's bottom-left origin because that is what AppKit gives you. The
`7 - row` reconciles them, once, here.

## The pump

```mojo
while running:
    while True:
        var ev = app.nextEventMatchingMask(UInt64.MAX,
                    untilDate=ObjCObject(past.id), inMode=mode, dequeue=True)
        if ev.id == 0:
            break
        _ = app.sendEvent(ObjCObject(ev.id))
    if not win.isVisible():
        break
```

Drain the queue with `distantPast` — poll, do not block — dispatch each event
so the view's handlers run, then act on the flags they set.

Note `_ = app.sendEvent(...)`: Fluid's pump reads events and interprets them
directly, so it never needs to send them on. Here the view has real handlers,
so events must be delivered.

Then, in order: commands, the human's move, the computer's move.

```mojo
if g_over()[] == 0 and g_black_turn()[] == 0:
    g_thinking()[] = 1
    redraw()
    rng = next_random(rng)
    let t0 = perf_counter_ns()
    var move = UInt64(0)
    if g_level()[] == LEVEL_MASTER and have_gpu:
        move = best_by_playouts_gpu(ctx, board_black(), board_white(), False, rng)
    else:
        move = computer_move_cpu(rng)
    let t1 = perf_counter_ns()
    g_last_ms()[] = Int((t1 - t0) // 1000000)
```

This is the only place the `DeviceContext` is used, and it is a local in
`main` — which is the constraint the whole architecture was built around.

The `g_thinking()` flag plus `redraw()` before the search is a nicety with a
sharp edge: the pump blocks for the duration of the move, so the redraw has to
be *requested and drawn* before the block, not after. On the GPU that block is
3.4 ms and nobody would see it. At `Advanced` on a slow machine, or Master
falling back to CPU playouts, it matters.

The elapsed time goes into the status bar in milliseconds, which is how the
numbers in [chapter 2](02-the-argument.md) get taken: the program reports its
own thinking time on every move.

## The GPU probe

```mojo
var have_gpu = False
var ctx = DeviceContext(api="metal")
try:
    _ = best_by_playouts_gpu(ctx, board_black(), board_white(), False, 1)
    have_gpu = True
except:
    have_gpu = False
```

> *The GPU, if this machine has one. Master falls back to CPU playouts if not,
> which is worth doing rather than hiding the level.*

Not a capability query — an actual playout dispatch on the opening position,
discarded. The only reliable way to know whether the kernel compiles, links
and runs on this machine is to compile, link and run it. Any query short of
that would have missed the `llvm.scmp` link failure from
[chapter 4](04-players.md).

The result is visible rather than hidden: the level shows as `Master · GPU` or
`Master · CPU` in the status bar, and the CPU fallback plays the same
algorithm with 512 playouts per move instead of 4,096.
