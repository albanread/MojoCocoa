# 5. Deviations from Modular's compiler

This fork is not a patched Mojo that happens to build on a Mac. It changes what
the language *is* in specific, deliberate ways, and this document states every
one of them and argues for it.

Each entry says what upstream does, what this compiler does instead, **why that
is the right answer for this target**, and what the choice costs. The cost
column is not decoration — a deviation with no cost is usually one nobody
thought about.

> **Read the last section first if you are debugging.** A good deal of what
> looks like a deviation is upstream's own churn, inherited by freezing at a
> commit. Those are listed at the end under
> [Not ours](#not-ours-upstream-churn-we-inherited), and blaming the fork for
> them will send you looking in the wrong place.

## The shape of the divergence

| Deviation | Kind |
|:---|:---|
| [`fn` is the foreign-callable function](#fn-is-the-foreign-callable-function) | Revived keyword, narrower contract |
| [`let` binds by reference](#let-binds-by-reference) | Revived keyword |
| [`class` declares an Objective-C class](#class-declares-an-objective-c-class) | Reserved word given a meaning |
| [`@objc`](#objc) | New decorator |
| [`cocoakb`: the compiler asks the SDK](#cocoakb-the-compiler-asks-the-sdk) | New compiler capability |
| [An Apple GPU target](#an-apple-gpu-target) | New backend and runtime |
| [`std.objc`](#stdobjc) | New standard-library package |
| [One host, one CPU, one accelerator](#one-host-one-cpu-one-accelerator) | Narrowed scope |

Three of these are keywords, and they are the ones that will bite a reader
coming from current Mojo documentation, because the code still *parses*.

## `fn` is the foreign-callable function

**Upstream** used `fn` for the strict-mode function — declared argument
mutability, no implicit raising — and has since folded that distinction away.

**Here** `fn` means something narrower and load-bearing: thin (no captures),
non-raising, C ABI, every parameter and return type ABI-classifiable. That is
exactly the Objective-C `IMP` contract, and exactly a C function pointer.

```mojo
comptime AURenderCallback = fn(P, P, P, UInt32, UInt32, P, /) -> Int32
```

**Why this is right.** A language that talks to an operating system needs a way
to say *this function is callable by C*, and it needs the compiler to enforce
it rather than hope. Every Cocoa callback, every `IMP`, and every C function
pointer the platform hands you has the same contract, so the contract deserves
a keyword rather than a decorator and a convention.

Making it a declaration makes it checkable. A `fn` marked `raises` is a compile
error — one of the four must-fail checks in the verification suite — instead of
an exception unwinding into CoreAudio's render thread, where there is no
handler and no way to report one. `examples/chip/` installs a Mojo `fn` as
CoreAudio's render callback with no C shim anywhere, which is the whole
argument in one file.

**What it costs.** `fn` cannot call a `def`, because a `def` may raise. That
reaches further than it first appears: `std.math.sin` is a `def`, so the chip
synthesiser carries a hand-written sine series. The restriction is real and it
is the price of the guarantee.

## `let` binds by reference

**Upstream** removed `let` entirely.

**Here** `let` is an immutable, function-scope binding that **names storage
rather than copying it**. `let x = g[]` does not snapshot `g`; it is another
way to say the same location.

**Why this is right.** Cocoa code is mostly borrowed references. A `let` that
copied would either retain and release an object nobody wanted duplicated, or
silently take a snapshot of something the runtime is still mutating. Naming the
storage is the honest description of what a borrowed reference *is*, and it
makes the common case free — no copy, no lifetime question.

Keeping ownership out of the keyword is deliberate. `let` says nothing about
retain and release; `ObjCRef` does. One concept per construct means you can
read a line and know which question it answers.

**What it costs.** This is the sharpest edge in the language, and it is not
hypothetical — it has cost real debugging time five separate times in this
project. A value read into a `let` and then mutated at the source reads back
*mutated*:

```mojo
for a in range(1, len(times)):
    let t = times[a]        # names the slot; the shift below writes over it
    var b = a - 1
    while b >= 0 and times[b] > t:
        times[b + 1] = times[b]
```

That sorts `5 3 9 1` into `5 5 9 9`. `var t = times[a]` is correct and is the
only difference.

**The compiler now says so**, which it did not when this was first written:

```text
warning: this write changes what 't' reads: 'let t' is bound to a place rooted
at 'times' and reads through it live; for a snapshot use `var t = ...`
note: 't' bound here
```

It points at the *write* rather than the binding, because the write is what
makes the binding wrong, and it names the fix. The semantics are unchanged --
`let` still binds by reference, and this program still sorts incorrectly -- but
the failure has moved from silent to announced, which is the difference
between an afternoon and a second.

Read the value **out** before touching the source, or bind a genuine copy with
`var`. The compiler does catch the related case where the container is *grown*
rather than written — that is `use of invalidated interior reference`, and it
names both the read and the invalidation.

## `class` declares an Objective-C class

**Upstream** reserved `class` for a Python-style class that never arrived; it
was lexed, classified, and never parsed.

**Here** it declares a real Objective-C class, registered in the runtime.

```mojo
class ExampleActions:
    def buttonClicked_(self, sender: ObjCObject):
        ...
```

The selector comes from the method name — an underscore is a colon, so
`buttonClicked_` answers `buttonClicked:`. The type encoding is derived: from
the SDK when the selector is one Cocoa declares, and from the signature when it
is one you invented. Instantiating the class registers it.

**Why this is right.** Cocoa is a callback architecture. You cannot put a
window on screen without being called back — by a button, a timer, a delegate,
an Apple Event. Every other language reaching Cocoa expresses this with
generated glue: a bridging header, a class-builder API, hand-written `v@:@`
strings, an `IMP` and a `_cmd` slot.

All of that is bookkeeping the compiler already has the information to do. It
knows the method names, it knows the signatures, and through `cocoakb` it knows
what the SDK declares. Making the class a *declaration* rather than a sequence
of library calls is what removes the bridging header — not as a convenience,
but because a declaration can be checked and a sequence of calls cannot.

The check is real in a way worth stating: an invented selector that collides
with one the SDK already declares is caught. `life/` names its timer callback
`lifeTick:` rather than `tick:` because `CASecureFlipBookLayer` declares
`tick:` taking a double, and the compiler said so — a collision that would
otherwise have registered the method with the wrong encoding.

**What it costs.** Fields have no initializers yet, and the class model took
the largest single share of the compiler work in this fork.

## `@objc`

A decorator, on methods and on classes, that makes the Objective-C exposure
explicit where the default is not what you want. New here; upstream has no
equivalent because it has nothing to expose to.

## `cocoakb`: the compiler asks the SDK

This is the deviation the rest of the fork is built on, and it is not a
language change at all — it is a change to what the compiler *does*.

**Upstream** compiles Mojo. **Here** the compiler additionally holds an open
connection to a database describing macOS, and resolves questions against it
during elaboration, at the point of use:

```mojo
comptime assert size_of[CGRect]() == cocoakb_struct_size["CGRect"]()
```

Fifteen-odd builtins answer struct sizes and field offsets, enum values,
superclasses, method encodings, which `objc_msgSend` variant a return type
requires, and the hash of the database a compilation consulted.

**Why this is right.** The alternative is code generation, and generated
bindings drift. A tool reads the SDK once, emits a large body of source, and
from that moment the emitted code and the real SDK diverge silently — usually
discovered as a crash on a machine with a different macOS.

A compile-time query cannot drift, because there is no intermediate artifact to
go stale. The answer is produced when your program is compiled, from the SDK on
the machine compiling it. That is why a selector typo is a compile error, why a
struct that has changed shape fails to build rather than corrupting a call, and
why an argument in the wrong register file is rejected instead of producing
garbage.

It also means the database is built from *your* Mac rather than downloaded —
roughly 236 MB describing 28,814 classes and 522,170 methods, read out of the
live Objective-C runtime and BridgeSupport.

**What it costs.** The compiler has a build input it must be pointed at. Get it
wrong and every Cocoa name in the program fails to resolve, which looks like a
source error and is a configuration one. `cocoakb_db_hash()` exists so a binary
can record which revision it was built against.

## An Apple GPU target

**Upstream** targets NVIDIA and AMD. **Here** there is a complete Metal/AIR
backend — roughly 4,750 lines of lowering, legality checking and object
emission — and an Apple GPU runtime of about 2,750 lines beneath it.

**Why this is right.** Mojo's premise is that one source file specialises to
whatever silicon you point it at. On a Mac the silicon is the Apple GPU, and
without this backend the premise is not merely unimplemented — it is
untestable on the hardware most people actually own. A kernel here is ordinary
Mojo: no shading language, no source compiled at run time, no second toolchain.

The claim is checkable rather than asserted. `examples/tiled-matmul` and the
rest of the carried GPU examples are Modular's own, running **unmodified** —
`DeviceContext`, `TileTensor`, `enqueue_function`, `barrier()` and
`AddressSpace.SHARED` all survive the new backend as written.

**What it costs.** LLVM is target-agnostic by construction, so it cannot see
AIR's rules. Every defect this backend has shipped was legal LLVM IR that was
illegal for the target, discovered one crash at a time from an error naming
nothing. That is why the backend carries a data-driven legality firewall with
per-rule permit/log/fail and recorded evidence for each rule — see
[Patches](06-patches.md).

## `std.objc`

About 9,800 lines of standard library that upstream has no reason to carry:
class lookup, message dispatch in its typed and dynamic forms, autorelease
pools, ownership through `ObjCRef`, selectors, framework loading, named
globals, and the typed calling layer.

**Why this is right.** The compiler deviations above give you a *checked* way
to reach Cocoa; this package is the surface you actually write against. Keeping
it in the standard library rather than a side package means the compiler and
the library are versioned together, which matters when half the guarantees are
enforced at compile time.

## One host, one CPU, one accelerator

**Upstream** supports Linux on x86-64 and aarch64, and macOS on ARM64.

**Here** the target is Apple Silicon macOS, and the 2019 Intel Mac Pro with its
Radeon Pro Vega II is a *separate fork*, described the same way and shipped as
its own image.

**Why this is right.** The alternative to narrowing is a matrix nobody can
test. Each port here targets one host, one CPU and one accelerator, and each is
described with the same three statements: what runs, what does not, and what
has merely been built rather than tested. A port that claims five platforms and
has measured one is a port that will be wrong about four of them.

**What it costs.** Shared lowering changes have to be made in each fork, and
the NVIDIA, AMD and Snapdragon paths still in this tree are reference material
rather than supported targets.

## Not ours: upstream churn we inherited

Freezing at a commit inherits whatever upstream had already changed by then.
The following differ from a good deal of published Mojo writing, **including
Modular's own documentation**, and none of them is a decision of this fork:

- `alias` is deprecated in favour of **`comptime`**
- `@parameter if` and `@parameter for` have given way to **`comptime if`** and
  **`comptime for`**
- `InlineArray` became `Array`; `.size` became `.length`
- `trait_downcast()` gave way to `conforms_to(...)`
- `memcmp` became `unsafe_memcmp`; `List.steal_data()` became
  `unsafe_take_allocation()`
- the async task API moved out of `std.runtime.asyncrt`

The full list is in the [Language reference](01-language.md#removed-library-apis).

Also not a compiler deviation, but worth stating once: the contributor process
files — `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, the issue and PR templates,
`CODEOWNERS`, the CLA workflow — were **removed** rather than left pointing at
Modular's trackers and review teams. This is an unaffiliated fork; nothing here
goes upstream, and an issue filed against Modular for a defect in this AIR
backend wastes someone's afternoon. `LICENSE` and `Licenses/` stay, because the
tree is overwhelmingly Modular's Apache-2.0 code and a derivative work has to
ship the licence.
