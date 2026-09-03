# CocoaMojo

**Writing native macOS applications in Mojo, on a compiler that reads the SDK.**

CocoaMojo is the Cocoa layer of [MojoCocoa](https://github.com/albanread/MojoCocoa),
an unofficial fork of Mojo frozen at one commit. It is a standard-library
package, `std.objc`, and a compiler hook, `cocoakb`, that answers questions
about macOS *while your program is being compiled*.

It was built from the bottom up and **nothing was replaced along the way**.
The first layers are ordinary library code — one hand-bound C call, then
ownership, then the types that cross the boundary constantly — and they still
work exactly as they did. What the later layers add is the compiler knowing
what the SDK knows: first to *check* a call, then to let you declare an
Objective-C class, then to let you write one as a call rather than a
transcription. Every layer is still reachable, and each is what the one above
it is made of. [Chapter 4](guide/04-calling-cocoa.md) lays them out.

The result is that a Cocoa binding states a name and the compiler supplies
everything else. A selector typo is a compile error. A struct that has drifted
from the SDK fails to build. An argument in the wrong register file is a
compile error rather than a corrupted call.
<!-- doccrate:keep-together:start -->


```mojo
let win = Obj["NSWindow"](
    contentRect=CGRect(CGPoint(240.0, 240.0), CGSize(360.0, 140.0)),
    styleMask=(
        nsenum["NSWindowStyleMaskTitled"]()
        | nsenum["NSWindowStyleMaskClosable"]()
    ),
    backing=nsenum["NSBackingStoreBuffered"](),
    defer=False,
)
_ = win.setTitle(nsstring("Mojo").ptr())
```

<!-- doccrate:keep-together:end -->

Nothing there writes a selector string, a type encoding, or a folklore
integer. The keyword labels name the initialiser, and the database resolves
which one they mean; `nsenum` fetches a constant by the name the SDK gives it,
so a window style is `NSWindowStyleMaskTitled` rather than a remembered `1`.
<!-- doccrate:keep-together:start -->


## Getting it

CocoaMojo installs from a signed, notarized disk image published at
[CocoaMojoInstaller](https://github.com/albanread/CocoaMojoInstaller) — one for
Apple Silicon, one for the 2019 Intel Mac Pro. Open it, double-click *Install
Roast*, press Install.

<!-- doccrate:keep-together:end -->

You get the compiler, the standard library, the language server, the debugger,
the examples, and **Roast**, a Mac IDE for Mojo written in Mojo. The installer
also builds the SDK database from the machine it lands on, which takes about
twelve seconds and is the reason none of this is downloaded prebuilt.

[Chapter 1](guide/01-getting-started.md) takes it from there. Building the fork
from source is [Appendix A](guide/11-building-from-source.md), and you do not
need it to write anything.
<!-- doccrate:keep-together:start -->


## These documents

| Document | What it is |
|:---|:---|
| [Programmer's Guide](guide/) | Read this first. Ten chapters and an appendix: installing the toolchain, the frozen dialect, Mojo's own object model, Cocoa from the first message to a walked-through Life implementation, and the fork's own IDE read as a program. |
| [Reference Manual](reference/) | Look things up here. The frozen language dialect, every `std.objc` entry point, every `cocoakb` query, and every diagnostic. |
| [GPU programming](gpu/) | Writing Mojo functions that run on the Apple GPU: the execution model, threads and memory, and how to build, run and verify them. |
| [The examples](examples/) | A walkthrough of all eighteen example projects, and an honest statement of what each one teaches — including the ones that teach nothing. |

<!-- doccrate:keep-together:end -->
<!-- doccrate:keep-together:start -->


## A warning about versions

Mojo has been changing quickly, and most writing about it — including parts of
its own published documentation — describes a language this compiler does not
accept. `@parameter if` and `@parameter for` have given way to `comptime if`
and `comptime for`, and `alias` is deprecated in favour of `comptime`.

<!-- doccrate:keep-together:end -->

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

Which of those differences are *this fork's decisions* — and which are
upstream's own churn, inherited by freezing — is set out in
[Deviations from Modular's compiler](reference/05-deviations.md), with the
argument for each and what it costs. It is the place to start if you are
weighing whether to use this rather than learn from it.
<!-- doccrate:keep-together:start -->


## The state of the port

The Cocoa layer described here works and is verified: nine of nine
verification spikes pass, and the example applications build and run.

<!-- doccrate:keep-together:end -->

The GPU layer is a working vertical slice: kernels compile, run and agree with
a CPU reference, and 96 of 119 in-scope GPU tests pass, with the failures
triaged and named. It has its own [section](gpu/), and nothing in the Cocoa
chapters depends on it.
<!-- doccrate:keep-together:start -->


## Conventions

Code shown in these documents is either taken directly from the fork's
standard library and verification spikes, or is reduced from them. Where a
listing is abbreviated, an ellipsis comment says so.

<!-- doccrate:keep-together:end -->

**The database is a build input, not a runtime dependency.** A compiled
CocoaMojo program has no dependency on `cocoa.sqlite`. By the time code is
generated, every query has already collapsed to a constant.
