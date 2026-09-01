# 7. A complete application

Everything so far assembles into one shape. This chapter is that shape, in the
order it has to happen, with the reasons.

## The skeleton

```blockgraph
// @id app-skeleton
// @name The startup sequence
step blue | 1. Load AppKit | Or nothing works | icon=lock icon-pos=bottom-right
edge first | gray
step teal | 2. State | Buffers and globals | icon=database icon-pos=bottom-right
edge then | gray
step green | 3. NSApplication | sharedApplication | icon=api icon-pos=bottom-right
edge then | gray
step gold | 4. Classes | Build and register | icon=function icon-pos=bottom-right
edge then | gray
step magenta | 5. Window | Create and show | icon=browser icon-pos=bottom-right
edge last | gray
step red | 6. Run loop | Never returns | icon=clock icon-pos=bottom-right
```

**Order matters.** A class must be registered before anything is instantiated
from it, and the application object must exist before a window is made key.
Getting either backwards produces a silent failure rather than an error.

## Step 0 — load AppKit

```mojo
def main() raises:
    if not load_framework["AppKit"]():
        raise Error("could not load AppKit")
```

Nothing linked AppKit into a `mojo run` process, so without this every AppKit
class lookup returns nil and every message to it silently does nothing. The
program starts and exits with no window and no diagnostic. Put it first.

## Step 1 — state, before anything else

```mojo
    g_alive()[] = alloc_zeroed(CELLS, 1)
    g_next()[] = alloc_zeroed(CELLS, 1)
    g_frame()[] = alloc_zeroed(PIXELS, 4)
    g_running()[] = 1
    randomize()
```

Do this first because the callbacks you are about to install can fire the
moment the run loop starts, and a callback that reads a null global crashes on
the first frame.

## Step 2 — the application object

```mojo
    with autoreleasepool():
        var app = Cls["NSApplication"]().sharedApplication()
        _ = app.setActivationPolicy(
            nsenum["NSApplicationActivationPolicyRegular"]()
        )
```

`NSApplicationActivationPolicyRegular` is the difference between a real
application with a Dock icon and menu bar, and a process that puts a window on
screen that cannot be focused. Skipping it is the most common reason a first
CocoaMojo window appears dead — which is a good argument for the name over the
`0` it stands for.

## Step 3 — classes

They are `class` declarations, written once at the top of the file:

```mojo
class LifeDelegate:
    def applicationShouldTerminateAfterLastWindowClosed_(
        self, sender: ObjCObject
    ) -> Bool:
        return True


class LifeView(NSView):
    def drawRect_(self, dirty: CGRect): ...
    def acceptsFirstResponder(self) -> Bool: return True
    def mouseDown_(self, event: ObjCObject): ...
    def keyDown_(self, event: ObjCObject): ...
```

and instantiated where they are needed:

```mojo
        # Instantiating a class is what registers it, so the delegate exists
        # in the runtime by the time it is handed over.
        var delegate = ObjCObject(LifeDelegate().__objc_id)
        _ = app.setDelegate(delegate)

        var view_instance = ObjCObject(LifeView().__objc_id)
```

An earlier version of this chapter built both with `ObjCClassBuilder` and
`add_method`, which is the library the `class` keyword replaced. That path
still exists for a class you assemble at run time; nothing writes it by hand
any more.

`acceptsFirstResponder` returning `True` is what makes the view eligible to
receive key events at all. Without it `keyDown:` never fires and the view looks
broken in a way that gives no clue.

## Step 4 — window and view

```mojo
        var win = Obj["NSWindow"](
            contentRect=CGRect(CGPoint(100.0, 100.0), CGSize(1080.0, 720.0)),
            styleMask=(
                nsenum["NSWindowStyleMaskTitled"]()
                | nsenum["NSWindowStyleMaskClosable"]()
                | nsenum["NSWindowStyleMaskMiniaturizable"]()
                | nsenum["NSWindowStyleMaskResizable"]()
            ),
            backing=nsenum["NSBackingStoreBuffered"](),
            defer=False,
        )
        g_window()[] = win.addr()
```

No `alloc`, and no `initWithContentRect:styleMask:backing:defer:` written
down: the labels are the selector's parts and the database resolves which
initialiser they name. The style is four flags by the names the SDK gives
them, which is the difference between a line you can read and the `15` this
chapter used to print.

**A window is released when closed**, which is the `NSWindow` default and a
trap if the loop that drives the app later asks whether it is still visible —
the answer then comes from freed memory. Either retain it, or say
`setReleasedWhenClosed(False)`.

Then the view, and making the window visible:

```mojo
        # `LifeView()` is already allocated and initialised -- that is what
        # instantiating a class does -- so the frame is set rather than
        # passed to initWithFrame:.
        var view = view_instance
        _ = Obj["NSView"](view.addr()).setFrame(frame)
        _ = external_call["objc_retain", P](view.ptr())

        _ = win.setContentView(view)
        _ = win.makeFirstResponder(view)
        _ = win.makeKeyAndOrderFront(ObjCObject(0))
        _ = app.activateIgnoringOtherApps(True)
```

The retain is not optional: the Mojo wrapper owns the only reference until
that line, and releases at the end of the statement that made it — after which
AppKit is drawing into a freed object, and the first `drawRect:` traps inside
`_NSViewDrawRect` with a stack that says nothing about ownership.

## Step 5 — the run loop

```mojo
    _ = Cls["NSApplication"]().sharedApplication().run()
```

`run` does not return until the application terminates. Note that it is
deliberately **outside** the `autoreleasepool` block: the pool should drain the
setup objects before the loop begins, and the loop maintains its own pools per
event cycle.

Re-fetching `sharedApplication` rather than reusing `app` is not superstition —
`app` was bound inside the `with` block that has now ended.

## What you get

The fork ships three applications built exactly this way.

`spikes/life/life.mojo` is Conway's Life with mouse drawing, pause and single
step, and cells coloured by age so you can see a pattern's structure rather
than a flat mask. Six hundred lines, and the only non-Cocoa part is the
simulation.

`spikes/playground/playground.mojo` is a Mojo editor and runner written in
Mojo — a thousand lines, a split view, syntax highlighting, and a child process.

`examples/mandelbrot/main.mojo` draws through a `CAMetalLayer`, with every
pixel computed and coloured by a Mojo kernel on the Apple GPU. The GPU stack
this once waited for works now: it times one CPU core against the GPU (a
couple of hundred times apart on an M4 Max), then holds 60fps while it zooms.
`examples/chip/` and `examples/abcplayer/` are the real-time counterpart: a
synthesiser and an ABC-notation player whose audio is produced by a Mojo `fn`
serving as CoreAudio's render callback, on a thread with a 10.7 ms deadline
(chapter 6).

`examples/fluid/` is the deeper GPU example — Stable Fluids, about 35
dependent dispatches a frame, no shader anywhere.

## Debugging, honestly

There is no source-level debugging here yet. What you have is `print`,
`respondsToSelector:` during bring-up, and the compile-time checks doing more
work than they would in most languages.

The three failure modes worth recognising:

A window appears but ignores the keyboard: `acceptsFirstResponder` is missing or
returns `False`.

A window appears but cannot be focused and has no Dock icon:
`setActivationPolicy:` was not called.

A crash inside `objc_msgSend` with a plausible-looking receiver: an object was
released while Cocoa still held it. Look for an `ObjCRef` that went out of scope,
or a `new_instance` result that was never retained.

The first two are configuration. The third is the one the compile-time checks
cannot reach, which is why chapter 5 spends so long on it.
