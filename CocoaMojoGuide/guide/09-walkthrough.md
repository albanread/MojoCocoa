# 9. A demo, walked through

This chapter reads one complete program: `examples/life/main.mojo` in the fork.
Conway's Life, 644 lines, in a real window — mouse drawing, keyboard control, a
60 Hz timer, and cells coloured by age so you can see the structure of a
pattern rather than a flat mask. Rendering goes through a `CAMetalLayer`.

It is worth reading because it is the current shape of a CocoaMojo application:
three `class` declarations, no `ObjCClassBuilder`, no encoding strings, no
`cmd` slots.

Everything below is quoted from the source.

```blockgraph
// @id life-walkthrough
// @name What the program builds
step blue | Load AppKit | dlopen, or nothing works | icon=lock icon-pos=bottom-right
edge then | gray
step teal | Buffers | Owned outside Mojo | icon=database icon-pos=bottom-right
edge then | gray
step green | Three classes | Delegate, actions, view | icon=function icon-pos=bottom-right
edge then | gray
step gold | Window and layer | CAMetalLayer for the pixels | icon=browser icon-pos=bottom-right
edge then | gray
step magenta | Timer at 60 Hz | lifeTick: drives everything | icon=clock icon-pos=bottom-right
edge last | gray
step red | NSApp run | Cocoa drives from here | icon=api icon-pos=bottom-right
```

## The three classes

That is the part worth studying, and it is short.

### A delegate

```mojo
class LifeDelegate:
    def applicationShouldTerminateAfterLastWindowClosed_(
        self, app: ObjCObject
    ) -> Bool:
        return True
```

No base, so it subclasses `NSObject`. One method, whose trailing underscore
makes the selector `applicationShouldTerminateAfterLastWindowClosed:`. AppKit
declares that selector, so the encoding is looked up rather than derived, and a
wrong signature would be a compile error quoting the SDK.

Returning `True` is what lets `[NSApp run]` ever finish: closing the window
ends the app.

### A timer target, and a lesson in its docstring

```mojo
class LifeActions:
    """The timer's target.

    Named `lifeTick:` rather than `tick:` on the compiler's advice: the SDK
    declares a `tick:` on CASecureFlipBookLayer taking a double, and a
    selector we invent that collides with one the SDK knows would have been
    registered with that shape -- `v@:d` where we meant `v@:@`. The
    diagnostic said so."""

    def lifeTick_(self, timer: ObjCObject):
        advance_tick()
```

This is the single best illustration in the tree of what the compile-time
checking buys.

The obvious name for a timer callback is `tick:`. But `tick:` already exists in
the SDK — on `CASecureFlipBookLayer`, taking a `double` — and because encodings
are *looked up* when the selector is known, the class would have registered
`v@:d` while the code meant `v@:@`. The timer would then have handed a double
where an object pointer was expected.

That is a silent, hard-to-find corruption in the old world. Here it was a
diagnostic, and the fix was to pick a name nobody else declares — at which
point the encoding is derived from the Mojo signature, correctly.

### A view subclass

```mojo
class LifeView(NSView):
    def mouseDown_(self, event: ObjCObject):
        var p = event_point(event.ptr())
        paint_at(p.x, p.y, event_has_shift(event.ptr()))

    def mouseDragged_(self, event: ObjCObject):
        ...

    def rightMouseDown_(self, event: ObjCObject):
        var p = event_point(event.ptr())
        paint_at(p.x, p.y, True)

    def acceptsFirstResponder(self) -> Bool:
        return True

    def keyDown_(self, event: ObjCObject):
        handle_key(event.ptr())
```

`NSView` as the first base makes it a subclass. Six methods, six selectors,
every encoding from the SDK.

`acceptsFirstResponder` has no underscore and no arguments, so it is the
nullary selector `acceptsFirstResponder`. Returning `True` is what makes the
view eligible for key events at all — without it `keyDown_` never fires and
nothing indicates why.

Note also what is *not* in the class body. `handle_key` and `event_point` are
free functions, and the source says why:

> Key handling, kept a free function so the class body stays a list of
> selectors rather than a wall of logic.

That is a good instinct. A Cocoa class is an interface to the framework; the
logic behind it does not have to live inside it.

## State lives in globals, for now

```mojo
comptime g_alive = named_global["life.alive", Int]   # UInt8*  per cell 0/1
comptime g_next = named_global["life.next", Int]     # UInt8*  scratch
comptime g_age = named_global["life.age", Int]       # UInt16* generations survived
comptime g_frame = named_global["life.frame", Int]   # UInt32* BGRA pixels
comptime g_running = named_global["life.running", Int]
comptime g_speed = named_global["life.speed", Int]
```

Fourteen of these, and they predate class fields. Most are now convertible:
`g_running`, `g_speed`, `g_tick` and the rest are counters and flags on the
view, which is exactly what a field is for.

The ones to leave alone are the buffer pointers. A field's `deinit` does not
run at `dealloc` yet, so a field owning memory leaks with the object — and
these already own memory deliberately, outside Mojo, for the reason the next
section gives. Moving them into fields would buy nothing and cost the clarity
of saying so.

The `life.` prefix on every key is the discipline that keeps two subsystems
from colliding, and it stays worth having for whatever remains a global.

## `main`, in order

### Load AppKit first

```mojo
def main() raises:
    if not load_framework["AppKit"]():
        raise Error("could not load AppKit")
```

Nothing linked AppKit into a JIT-run process, so without this the
`NSApplication` lookup is nil and every message to nil quietly does nothing:
the app starts and exits having drawn nothing.

### Allocate outside Mojo

```mojo
    g_alive()[] = alloc_zeroed(CELLS, 1)
    g_frame()[] = alloc_zeroed(PIXELS, 4)
```

Mojo destroys a value at its **last use**, not at end of scope, so a `List`
whose `unsafe_ptr()` you stash in a global is freed immediately and every
stored pointer dangles — surfacing much later as a corrupted allocator, nowhere
near the cause. Owning the memory outside Mojo makes the lifetime explicit and
correct.

### Instantiate the classes

```mojo
        # Instantiating a class is what registers it, so the delegate exists
        # in the runtime by the time it is handed over.
        var delegate = ObjCObject(LifeDelegate().__objc_id)
        _ = app.setDelegate(delegate.ptr())

        var view_instance = ObjCObject(LifeView().__objc_id)
        var actions = ObjCObject(LifeActions().__objc_id)
        _ = external_call["objc_retain", P](actions.ptr())
```

Three lines where the old version had three builders, six `add_method` calls
and two hand-written encodings.

Two details worth taking away.

**Instantiation is registration.** There is no separate register step, so the
class is in the runtime by the time you hand the instance to AppKit.

**Retain what Cocoa holds by bare pointer.** `actions` is the timer's target
and must outlive this scope; the explicit `objc_retain` is correct for an
object that lives as long as the application.

### A difference from the builder path

```mojo
        # `LifeView()` is already allocated and initialised -- that is what
        # instantiating a class does -- so the frame is set rather than passed
        # to initWithFrame:.
        var view = view_instance
        _ = Obj["NSView"](view.addr()).setFrame(frame)
```

Worth noticing because it changes the code you write. With `ObjCClassBuilder`
you got a class back and did `alloc` then `initWithFrame:` yourself.
`LifeView()` has already done both, so you set the frame afterwards instead.

### The timer

```mojo
        # The tick: a five-label factory, every part checked.
        comptime NSTimer = Obj["NSTimer"]
        _ = NSTimer(
            scheduledTimerWithTimeInterval=Float64(1.0 / 60.0),
            target=actions,
            selector=sel["lifeTick:"]().ptr(),
            userInfo=actions,
            repeats=True,
        )
```

The five labels *are* the selector's five parts, so
`+scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:` is
resolved from them and never written down. Get one label wrong and the build
fails naming the class and the labels you gave it — where the same mistake in
Objective-C is a `doesNotRecognizeSelector:` at run time, if you are lucky
enough to reach that line.

`sel["lifeTick:"]()` is the one place a selector still appears as a value:
target/action wants the `SEL` itself, not a call.

`Float64(1.0 / 60.0)` and not `1.0 / 60.0`: the interval travels in a float
register, and the register-file check would have caught an integer literal.
`repeats=True` needs no `Bool(...)` — the label tells the compiler what the
argument is, so the literal is enough.

### Into the run loop

```mojo
    _ = Cls["NSApplication"]().sharedApplication().run()
```

Outside the `with` block, so the setup pool drains before the loop begins; the
loop keeps its own pools per event cycle. `app` was bound inside the block that
has now ended, hence `app2`.

`run` does not return.

## What the drawing does

The parts this chapter has skipped are ordinary Mojo. `evolve()` runs the Life
rules over the two cell buffers; `render()` writes BGRA pixels into
`g_frame`; `present()` blits that into a `CAMetalLayer` drawable. The Metal
work uses `send` rather than `msg_send`, because a `MTLDevice` is a
protocol-typed object whose concrete class is not something you can name:

```mojo
        var queue = send[ObjCObject, "newCommandQueue"](display_dev)
```

## What to take from it

The Cocoa-facing surface of a 644-line application is three class declarations
totalling about thirty lines, and every selector and encoding in them was
checked at compile time. The rest is Mojo.

That ratio is the point of the whole design.
