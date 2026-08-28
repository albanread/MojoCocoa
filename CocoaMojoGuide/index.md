# CocoaMojo

**Writing native macOS applications in Mojo, on a compiler that reads the SDK.**

CocoaMojo is the Cocoa layer of [MojoCocoa](https://github.com/albanread/MojoCocoa),
an unofficial fork of Mojo frozen at one commit. It is two things at once: a
small standard-library package, `std.objc`, and a compiler hook, `cocoakb`,
that answers questions about macOS *while your program is being compiled*.

The result is that a Cocoa binding states a name and the compiler supplies
everything else. A selector typo is a compile error. A struct that has drifted
from the SDK fails to build. An argument in the wrong register file is a
compile error rather than a corrupted call.

```mojo
comptime assert size_of[CGRect]() == cocoakb_struct_size["CGRect"]()

var s = msg_send[
    ObjCObject, "NSString", "stringWithUTF8String:", is_class=True
](cls.as_object(), text.as_c_string_slice())
```

## These documents

| Document | What it is |
|:---|:---|
| [Programmer's Guide](guide/) | Read this first. Ten chapters: the frozen dialect, Mojo's own object model, Cocoa from the first message to a walked-through Life implementation, and the fork's own IDE read as a program. |
| [Reference Manual](reference/) | Look things up here. The frozen language dialect, every `std.objc` entry point, every `cocoakb` query, and every diagnostic. |
| [GPU programming](gpu/) | Writing Mojo functions that run on the Apple GPU: the execution model, threads and memory, and how to build, run and verify them. |

## A warning about versions

Mojo has been changing quickly, and most writing about it — including parts of
its own published documentation — describes a language this compiler does not
accept. `@parameter if` and `@parameter for` have given way to `comptime if`
and `comptime for`, and `alias` is deprecated in favour of `comptime`.

This fork has also stopped following upstream's declaration model and named
itself **cocoa-mojo**. Three keywords carry revived, narrower meanings:
**`fn`** is now the foreign-callable function — thin, non-raising, C ABI,
exactly the Objective-C `IMP` contract — **`let`** is an immutable,
scope-bound binding, and **`class`**, which upstream reserved for a
Python-style class that never came, declares a real Objective-C class. None
of the three means what it meant in older Mojo, and none means what upstream
would mean by it.

**Everything in these documents was checked against the source tree of this
frozen compiler, not against published documentation.** Where the two disagree,
the compiler is right and the documentation is stale. The
[Language reference](reference/01-language.md) lists the differences explicitly,
because they are the single largest source of code that looks correct and will
not build.

## The state of the port

The Cocoa layer described here works and is verified: nine of nine
verification spikes pass, and the example applications build and run.

The GPU layer is a working vertical slice: kernels compile, run and agree with
a CPU reference, and 96 of 119 in-scope GPU tests pass, with the failures
triaged and named. It has its own [section](gpu/), and nothing in the Cocoa
chapters depends on it.

## Conventions

Code shown in these documents is either taken directly from the fork's
standard library and verification spikes, or is reduced from them. Where a
listing is abbreviated, an ellipsis comment says so.

**The database is a build input, not a runtime dependency.** A compiled
CocoaMojo program has no dependency on `cocoa.sqlite`. By the time code is
generated, every query has already collapsed to a constant.
