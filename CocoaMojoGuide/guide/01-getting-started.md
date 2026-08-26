# 1. Getting started

## What you need

| Requirement | Why |
|:---|:---|
| Apple Silicon Mac | The fork targets `arm64` Darwin and hardcodes it deliberately |
| macOS 15 or later | The metadata is built from the live Objective-C runtime on your machine |
| Xcode 16 or later | Supplies the SDK and, if you go near the GPU, the AIR toolchain |
| A checkout of [MojoCocoa](https://github.com/albanread/MojoCocoa) | The compiler and standard library |
| A checkout of [CocoaBaseMCP](https://github.com/albanread/CocoaBaseMCP) | Builds `cocoa.sqlite` |

The two checkouts are expected to sit beside each other. Everything below
assumes that layout; if yours differs, one environment variable fixes it.

## Build the SDK database

The database is built from *your* machine — the live Objective-C runtime plus
BridgeSupport — not downloaded. It takes about twelve seconds.

```bash
python3 ../CocoaBaseMCP/build.py
```

You get roughly 236 MB describing 28,814 classes and 522,170 methods.

Rebuild it after any macOS update. If you do not, the compiler will happily
keep using the old one, and `cocoakb_db_hash()` is how you notice: it returns
the SHA-256 of the database a given compilation consulted, so a binary can
record exactly which revision it was built against.

## Build the compiler

```bash
./bazelw build --config=build-mojo //KGEN:mojo
```

This is a long build the first time. Afterwards, only toolchain or sysroot
changes force a full rebuild — ordinary source changes rebuild KGEN alone, in
seconds rather than the better part of an hour.

The compiler lands at `bazel-bin/KGEN/tools/mojo/mojo-full`.

## Point the compiler at the database

```bash
export MODULAR_MOJO_MAX_COCOAKB_PATH="$PWD/../CocoaBaseMCP/cocoa.sqlite"
```

`local.bazelrc` sets this for Bazel-driven builds. Export it yourself when
invoking the compiler directly.

## Run a program

There is a wrinkle worth knowing before it wastes your afternoon. The raw
`mojo-full` binary cannot locate `std.mojoc` on its own. Run Mojo through the
Bazel wrapper, which supplies the standard-library import paths:

```bash
./bazelw run //KGEN:mojo -- run /absolute/path/to/program.mojo
```

Note the **absolute** path. Bazel runs the wrapper in its own working
directory, so a relative path will not resolve the way you expect.

## Your first program

Save this as `hello_cocoa.mojo`:

```mojo
from std.objc import ObjCClass, ObjCObject, msg_send, autoreleasepool
from std.ffi import c_char
from std.memory import OpaquePointer


def main():
    with autoreleasepool():
        var cls = ObjCClass.lookup["NSString"]()
        var text = String("Hello from Cocoa, via Mojo")

        var s = msg_send[
            ObjCObject, "NSString", "stringWithUTF8String:", is_class=True
        ](cls.as_object(), text.as_c_string_slice())

        var n = msg_send[Int, "NSString", "length"](s)
        print("length:", n)

        var back = msg_send[
            OpaquePointer[MutUntrackedOrigin], "NSString", "UTF8String"
        ](s)
        print("round trip:", String(unsafe_from_utf8_ptr=back.bitcast[c_char]()))
```

Run it, and you should see:

```text
length: 26
round trip: Hello from Cocoa, via Mojo
```

Nothing in that program named a dispatch function, a type encoding, or a
selector address. Those all came from the database while the program was being
compiled.

## Prove the checking is real

The interesting half of the verification suite is the half that must *fail*.
Change `"length"` to `"lenght"` and compile again. You do not get a runtime
crash or a silently wrong answer; you get a compile error naming the selector.

The fork ships this as a test:

```bash
./spikes/run-cocoa-checks.sh
```

It runs twelve spikes that must compile and run, and four that must be
**rejected at compile time** — sixteen checks in all. A run in which the
must-fail spikes quietly succeed is a failed run, because the design's entire
claim is that unknown names cannot reach code generation.

The four must-fail checks are worth knowing individually, because each pins one
guarantee: an unknown metadata name (`must_fail.mojo`), a wrong argument count
(`must_fail_argcount.mojo`), a raising `fn` (`must_fail_fn_raises.mojo`), and
reassigning a `let` (`must_fail_let_assign.mojo`).

## Where to go next

Chapter 2 is not optional. This compiler rejects a good deal of Mojo that
current tutorials still teach, and knowing what changed will save you more time
than anything else in this guide.
