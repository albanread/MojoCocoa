# 1. The small ones

Five short projects. One of them states the fork's entire argument; two of them
state nothing at all, on purpose; and two are here to prove a negative.

## `hello`

Seven lines, one file.

```mojo
# The smallest thing that runs. ⌘R.
def main():
    print("Hello from cocoa-mojo.")
    var total = 0
    for i in range(1, 101):
        total += i
    print("The first hundred integers sum to", total)
```

It prints a greeting and `5050`.

The loop is there for one reason: a program that only prints a constant cannot
tell you whether it *ran*. A wrong sum would mean the compiler produced code
and the code is broken, which is a different failure from the toolchain not
working. Seven lines, two distinguishable failure modes.

**The lesson: none.** This is a smoke test. If it prints 5050 your compiler,
your SDK database and your run button all work, and you can stop thinking about
them. That is the whole of its ambition, and it is worth having for exactly the
five seconds it takes.

## `window`

97 lines, and the most important small file in the distribution. A window, a
label, a button; click the button and the label counts. In any other
language-to-Cocoa bridge this is a chapter about generated headers. Here it is
one `class` declaration:

```mojo
class ExampleActions:
    """The button's target.

    `buttonClicked_` becomes the selector `buttonClicked:` -- an underscore is
    a colon -- and the compiler derives its `v@:@` encoding, because this is a
    selector we invented rather than one the SDK declares. There is no `_cmd`
    argument to write and no IMP to register: `ExampleActions()` builds the
    class in the runtime and hands back an instance.
    """

    def buttonClicked_(self, sender: ObjCObject):
        clicks()[] += 1
```

Three things are absent, and their absence is the point. There is no bridging
header. There is no `"v@:@"` typed out anywhere — the compiler derived it. And
there is no `ObjCClassBuilder` call registering the class by hand, because
`ExampleActions()` does that.

The button is made by naming what its arguments *are*, and the labels pick the
constructor:

```mojo
let button = Obj["NSButton"](
    buttonWithTitle="Click me",
    target=actions,
    action=sel["buttonClicked:"]().ptr(),
)
_ = button.setFrame(CGRect(CGPoint(20.0, 30.0), CGSize(160.0, 32.0)))
```

Three things are worth noticing in four lines. The labels are the selector's
parts, so the database resolves `+buttonWithTitle:target:action:` without the
selector being written out. `"Click me"` is a bare Mojo `String` and bridges
to `NSString` because the metadata says that argument is an object — where a
selector takes a non-object, the same `String` is a compile error rather than
a corrupted call. And `setFrame` reads as the method it is.

Get a label wrong and the build fails, naming the class and the labels. In
Objective-C it would compile and crash at run time; here `cocoakb` is asked
during elaboration whether `NSButton` answers anything of that shape.

Two details in this file are load-bearing for every Cocoa program you write
afterwards.

**AppKit must be loaded explicitly.** The comment says why:

```mojo
# AppKit is not linked into a JIT process; without this NSApplication is
# nil and the app exits having drawn nothing.
if not load_framework["AppKit"]():
    raise Error("could not load AppKit")
```

The failure this prevents is silent — no crash, no message, just a program that
exits having done nothing visible.

**A callback cannot reach a local.** `buttonClicked_` needs the click count and
the label, and neither can be a variable in `main`, because Cocoa calls the
method with no path back to `main`'s frame. So both live in named globals:

```mojo
comptime clicks = named_global["example.clicks", Int]
comptime label_addr = named_global["example.label", Int]
```

This constraint reappears in every larger example. `life`, `mandelbrot` and
`othello` all hand-roll their event loops or park state in globals for exactly
this reason, and `othello`'s header states the general form of it: a
`DeviceContext` cannot live in a `named_global`, and a Cocoa callback cannot
reach a local, so the loop that owns the GPU has to be the loop that drives the
app.

**The lesson: this is the fork's thesis at the smallest size it can be
written.** A real Objective-C class, a selector you invented, an encoding
nobody typed, a window style named rather than remembered, and a compile
error for any of them that does not exist. Nothing in the file writes a
selector string, a type encoding, or a folklore integer. Read this one
even if you skip the rest of the section. The full treatment is
[Guide, chapter 6](../guide/06-callbacks.md).

## `operators`

544 lines across three files: `main.mojo`, `my_complex.mojo`, and
`test_my_complex.mojo` beside them. A `Complex` struct wearing the whole
operator set — arithmetic, comparison, indexing, conversion — with a
`std.testing` suite that exercises it.

It is Modular's own example, from `mojo/examples/operators`, carried into this
collection **unmodified**. Not adapted, not ported: the same source.

**The lesson: none that belongs to this fork.** What you learn here is Mojo's
object model, and you would learn it identically from upstream. There is no
Cocoa in it and no GPU in it.

Its value is a negative result, and a genuinely useful one: this fork froze the
language, revived three keywords with narrower meanings, and replaced `alias`
with `comptime` — and ordinary Mojo still compiles and runs here unchanged.
`my_complex.mojo` and `test_my_complex.mojo` are byte-identical to upstream's;
`main.mojo` differs by four lines of comment. When you are wondering whether
some upstream snippet will work, this example is the standing answer for the
non-Cocoa parts of the language.

The pattern worth stealing is the four-overload operator:

```mojo
def __add__(self, rhs: Self) -> Self:      # Complex + Complex
def __add__(self, rhs: Float64) -> Self:   # Complex + Float64
def __radd__(self, lhs: Float64) -> Self:  # Float64 + Complex
def __iadd__(mut self, rhs: Self):         # +=
```

Same-type, mixed-type, *reflected* mixed-type, and in-place. Miss `__radd__`
and `2.0 + c` fails while `c + 2.0` works, which is a confusing afternoon.

One practical caveat. The test suite beside it cannot be run from the IDE.
Roast's entry-point rule returns `main.mojo` whenever a project has one, and
its test-file exclusion matches `_test.mojo`, which `test_my_complex.mojo`
does not. So ⌘R in this project always builds `main.mojo`. To run the suite,
point the compiler at the test file directly.

## `process`

128 lines. Modular's `std.os.Process` example, also carried in unmodified. It
spawns `sleep 1` and waits for it, spawns `sleep 2` and polls it, and kills a
child, printing the exit code or terminating signal at each step.

**The lesson: none that belongs to this fork.** Same as `operators` — it is
here to prove that the standard library beneath the Cocoa layer is intact.

It is worth knowing it exists for one practical reason: it is the example to
crib from when you want to shell out to a tool from a Mojo application, and it
shows the three shapes you actually need — block until done, check without
blocking, and terminate.

## `life-python`

231 lines across `main.mojo` and `gridv1.mojo`. Conway's Life for the second
time in this distribution — but the window belongs to **pygame**, not Cocoa.
The grid logic is Mojo; the drawing goes through CPython:

```mojo
var pygame = Python.import_module("pygame")
pygame.init()
var window = pygame.display.set_mode(
    Python.tuple(window_width, window_height)
)
```

The comparison is the demo. Put it beside the native `life` example — the same
game, the same rules, two windowing worlds — and the difference is immediate.
The README does not oversell it, and neither will I:

> the first thing everyone says is how much faster the Cocoa one feels. That is
> the demo working. (To be fair to Python, upstream's loop also sleeps 0.1s per
> generation; to be fair to Cocoa, nobody has ever asked it to slow down.)

That parenthesis matters. A good part of the visible gap is a deliberate sleep
in upstream's loop, not Python's cost, and a comparison that hid this would be
a worse example. The honest claim is narrower than the dramatic one: the Cocoa
path is the one that can be asked for 60 frames a second, and the pygame path
is the one that gets you a window in four lines.

This is also the only example that needs a Python environment. It ships a
`requirements.txt` naming `pygame-ce` rather than classic pygame, for a
concrete reason worth repeating — the community build publishes wheels for
current CPython, where classic pygame had none for 3.14 and tried to compile
itself against an SDL that was not there. It imports as `pygame` either way.

Two menu items, once, before the first run:

1. Python menu → **Create or Repair Environment**
2. Python menu → **Install Project Dependencies**

Roast builds an environment only for projects that actually use Python, so
opening the other sixteen examples will not create one.

**The lesson: interop is real, and it is a trade rather than a win.** Python
gets you a window and a drawing call immediately, and costs you the frame rate
and a dependency you have to install. Knowing which of those two you are buying
is the entire content of the example.
