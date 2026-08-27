# 9. A demo, walked through

This chapter reads one complete program line by line:
`spikes/playground/p0_window.mojo` in the fork. It is 225 lines, it puts a real
window on screen with a button, a label and a timer, and every callback in it
is Mojo. It is also the program the fork converted to the cocoa-mojo surface,
so it shows `fn` and `let` doing their jobs in a real setting rather than in a
test.

Everything below is quoted from the source. Nothing here has been simplified.

```blockgraph
// @id p0-walkthrough
// @name What the program builds
step blue | Load AppKit | dlopen, or nothing works | icon=lock icon-pos=bottom-right
edge then | gray
step teal | State | Five named globals | icon=database icon-pos=bottom-right
edge then | gray
step green | Two classes | Delegate and action target | icon=function icon-pos=bottom-right
edge then | gray
step gold | Window and views | Label, button, timer | icon=browser icon-pos=bottom-right
edge then | gray
step magenta | NSApp run | Cocoa drives from here | icon=clock icon-pos=bottom-right
```

## The header

```mojo
from std.objc import (
    load_framework, ObjCClass, ObjCObject, msg_send, nsstring,
    autoreleasepool, ObjCClassBuilder, IMP1, IMP1Bool,
    new_instance, named_global, sel,
)
from std.memory import OpaquePointer
from std.os import getenv

comptime P = OpaquePointer[MutUntrackedOrigin]
```

`load_framework` leads the import list for a reason we will get to in ten
lines. `P` is the abbreviation every CocoaMojo file makes for the raw pointer
type that crosses into Objective-C.

## Geometry, checked

```mojo
@fieldwise_init
struct CGPoint(Copyable, Movable):
    var x: Float64
    var y: Float64
```

`CGSize` and `CGRect` follow the same shape. In a program you intend to keep,
add the layout assertions from [chapter 4](04-calling-cocoa.md#struct-layouts) —
this demo omits them, and that is the one shortcut in it worth not copying.

## State the callbacks can reach

```mojo
comptime clicks = named_global["p0.clicks", Int]
comptime ticks = named_global["p0.ticks", Int]
comptime label_addr = named_global["p0.label", Int]
comptime window_addr = named_global["p0.window", Int]
comptime autoclose = named_global["p0.autoclose", Int]
```

Five named process globals, zero until `main` sets them. This is the answer to
the constraint that runs through the whole guide: a Cocoa callback is a bare C
function pointer and gets no closure, so anything it needs must be reachable by
name.

Note the naming discipline — every key is prefixed `p0.` Globals are
deduplicated by name across the whole program, so a bare `"count"` is an
invitation to collide with someone else's.

## A helper that is not a callback

```mojo
def set_label(text: String):
    with autoreleasepool():
        let label = ObjCObject(label_addr()[])
        _ = msg_send[ObjCObject, "NSTextField", "setStringValue:"](
            label, nsstring(text).ptr()
        )
```

`def`, not `fn` — Cocoa never calls this, Mojo does. It gets its own
autorelease pool because `nsstring` produces an autoreleased object and this is
called from timer ticks; without the pool those accumulate until the run loop
drains, which on a 0.1-second timer is a slow leak.

`let label` because the binding is written once and only sent messages.

## The callbacks

```mojo
fn did_finish_launching(self_: P, cmd: P, note: P):
    print("delegate: applicationDidFinishLaunching: (Cocoa -> Mojo)")


fn should_terminate_after_last_window(self_: P, cmd: P, app: P) -> Bool:
    return True


fn button_clicked(self_: P, cmd: P, sender: P):
    clicks()[] += 1
    print("action: buttonClicked: (Cocoa -> Mojo), clicks =", clicks()[])
    set_label(String("Clicked ") + String(clicks()[]) + " times")
```

Five of these, all `fn`. Before the conversion each carried the `def ...
abi("C")` costume; now the keyword states the contract, and a callback that
tried to `raise` would fail at its own definition instead of crashing inside
AppKit's event loop.

`should_terminate_after_last_window` returning `True` is what makes
`[NSApp run]` ever finish — closing the window ends the app.

The `self_: P, cmd: P` prefix is still hand-written. The design proposes a
trampoline that injects `_cmd`; it is not implemented, so every callback still
declares all three.

```mojo
fn timer_tick(self_: P, cmd: P, timer: P):
    ticks()[] += 1
    set_label(...)
    let limit = autoclose()[]
    if limit > 0 and ticks()[] >= limit:
        let win = ObjCObject(window_addr()[])
        _ = msg_send[ObjCObject, "NSWindow", "performClose:"](win, win.ptr())
```

The autoclose path is what makes the demo testable unattended: set
`P0_AUTOCLOSE_TICKS=N` and the whole lifecycle — launch, ticks, close,
terminate — runs without a human.

## `main`, in order

### Load AppKit before anything else

```mojo
def main() raises:
    if not load_framework["AppKit"]():
        raise Error("could not load AppKit")
```

This is the line the fork learned the hard way. In a `mojo run` process nothing
linked AppKit, so `ObjCClass.lookup["NSApplication"]()` returns nil and every
message to nil silently does nothing. The program starts, prints nothing
unusual, and exits without a window.

### The application object

```mojo
    with autoreleasepool():
        let NSApplication = ObjCClass.lookup["NSApplication"]()
        let app = msg_send[
            ObjCObject, "NSApplication", "sharedApplication", is_class=True
        ](NSApplication.as_object())
        _ = msg_send[Bool, "NSApplication", "setActivationPolicy:"](app, Int(0))
```

`0` is `NSApplicationActivationPolicyRegular` — the difference between an
application with a Dock icon and menu bar, and a process that puts up a window
nobody can focus.

### Two classes, built at runtime

```mojo
        var db = ObjCClassBuilder("PlaygroundAppDelegate")
        db.add_method["applicationDidFinishLaunching:"](did_finish_launching)
        db.add_method["applicationShouldTerminateAfterLastWindowClosed:"](
            should_terminate_after_last_window
        )
        db.add_method["applicationWillTerminate:"](will_terminate)
        let delegate = new_instance(db^.register())
```

Three real AppKit selectors, so no encodings are written — the database
supplies them. `db` stays `var` because `add_method` mutates it; `delegate` is
`let`.

```mojo
        var ab = ObjCClassBuilder("PlaygroundActions")
        ab.add_method["buttonClicked:", encoding="v@:@"](button_clicked)
        ab.add_method["timerTick:", encoding="v@:@"](timer_tick)
        let actions = new_instance(ab^.register())
```

These two selectors are invented, so the SDK has never heard of them and the
encoding must be given. `v@:@` reads: returns void, then `self`, then `_cmd`,
then one object argument.

### The window

```mojo
        var win = msg_send[ObjCObject, "NSWindow", "alloc", is_class=True](
            NSWindow.as_object()
        )
        win = msg_send[
            ObjCObject, "NSWindow",
            "initWithContentRect:styleMask:backing:defer:",
        ](
            win,
            CGRect(CGPoint(200.0, 200.0), CGSize(420.0, 160.0)),
            Int(15), Int(2), Bool(False),
        )
```

`win` is one of the few `var` bindings left, because `alloc` and `init` are two
steps and the second rebinds it. The `15` is a style mask and the `2` is
`NSBackingStoreBuffered`; both should be `cocoakb_enum_value` lookups, and this
is the second shortcut in the demo worth not copying.

### Label, button, timer

```mojo
        let label = msg_send[
            ObjCObject, "NSTextField", "labelWithString:", is_class=True
        ](NSTextField.as_object(), nsstring(String("waiting…")).ptr())
        label_addr()[] = label.addr()
        _ = msg_send[ObjCObject, "NSView", "addSubview:"](content, label.ptr())
```

The label's address goes into a global so `set_label` can reach it from a
callback. This is the pattern in miniature: Cocoa owns the object, a global
holds the address, and the callback goes through the global.

```mojo
        let button = msg_send[
            ObjCObject, "NSButton", "buttonWithTitle:target:action:",
            is_class=True,
        ](
            NSButton.as_object(),
            nsstring(String("Click me (Mojo)")).ptr(),
            actions.ptr(),
            sel["buttonClicked:"]().ptr(),
        )
```

`sel["buttonClicked:"]()` is the one place a selector is needed as a value
rather than as a `msg_send` parameter — target/action wants the `SEL` itself.

```mojo
        _ = msg_send[
            ObjCObject, "NSTimer",
            "scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:",
            is_class=True,
        ](
            NSTimer.as_object(), Float64(0.1), actions.ptr(),
            sel["timerTick:"]().ptr(), actions.ptr(), Bool(True),
        )
```

Five arguments, and `msg_send` counted the colons to check you passed five.
Note `Float64(0.1)` rather than `0.1` — the interval travels in a float
register, and the register-file check would have caught an integer literal
here.

### Into the run loop

```mojo
    print("entering [NSApp run]")
    let app2 = msg_send[
        ObjCObject, "NSApplication", "sharedApplication", is_class=True
    ](ObjCClass.lookup["NSApplication"]().as_object())
    _ = msg_send[ObjCObject, "NSApplication", "run"](app2)
```

Outside the `with` block, so the setup pool drains before the loop starts; the
loop maintains its own pools per event cycle. `app` was bound inside the block
that has now ended, hence `app2`.

`run` does not return. `-terminate:` exits the process after
`applicationWillTerminate:` has run, which is where the demo prints its verdict.

## What the conversion changed

The fork's own summary of this file: *five callbacks lose their `def ...
abi("C")` costume and become what they are — `fn`, foreign-callable by keyword.
Sixteen never-reassigned Cocoa bindings become `let`.*

Behaviour is identical. What changed is that two contracts the compiler could
not previously see — this function is callable from C, this binding is never
rebound — are now stated in the source and enforced.

## A caveat on running it

Windowed behaviour beyond this program's baseline could not be exercised from
the fork's own shell, and that limitation predates the conversion. What is
verified is that it compiles, that the sixteen-check suite passes, and that
`p0_window` reaches `[NSApp run]` with output unchanged from before. Treat the
window itself as reported rather than demonstrated.
