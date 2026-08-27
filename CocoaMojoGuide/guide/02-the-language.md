# 2. The language, as it is now

This chapter exists because most Mojo you will find written down does not
compile here, for two separate reasons. Mojo itself moved and the writing did
not; and this fork has since started changing the language deliberately, under
the name cocoa-mojo.

Read this before you write anything substantial. Everything below was taken
from the compiler's own source and standard library at the frozen commit.

## This is cocoa-mojo, not upstream Mojo

The fork has stopped tracking upstream's declaration model and named itself.
Where upstream removed something this port needs, it heals the language
instead of working around the removal. Two keywords have come back with new,
narrower meanings, and they are the first thing to learn.

The stance is recorded in the fork's own
[`COCOA_LET_DESIGN.md`](https://github.com/albanread/MojoCocoa/blob/main/COCOA_LET_DESIGN.md):
new code here is deliberately a different dialect, and migration diagnostics
teach rather than promise compatibility.

## `fn` is back — as the foreign-callable function

Upstream removed `fn`. This fork revived it, but not as the old strict
function. Here `fn` declares a **foreign-callable** function:

- **thin** — no captured context
- **non-raising** — the C boundary has no error channel
- **C ABI** — set automatically by the keyword
- every parameter and return type must be ABI-classifiable

That is exactly the contract an Objective-C `IMP` requires, which is the point.

```mojo
fn add_one(x: Int) -> Int:
    return x + 1

fn button_clicked(self_: P, cmd: P, sender: P):
    clicks()[] += 1
```

You do not write `abi("C")` any more. The keyword says it.

An `fn` is still an ordinary callable from Mojo — `add_one(1)` works — so the
keyword costs you nothing at the call site.

### `fn` in type position

`fn(...) -> R` is sugar for the old `def(...) thin abi("C") -> R`:

```mojo
comptime IntFn = fn(Int) -> Int

def apply(f: IntFn, x: Int) -> Int:
    return f(x)
```

The standard library's IMP aliases are now spelled this way, and read as what
they are:

```mojo
comptime IMP0 = fn(P, P, /) -> None
comptime IMP1 = fn(P, P, P, /) -> None
comptime IMP0Bool = fn(P, P, /) -> Bool
comptime IMP1Bool = fn(P, P, P, /) -> Bool
comptime IMP2 = fn(P, P, P, P, /) -> None
```

### What `fn` rejects

Marking one `raises` is a compile error, and the message teaches rather than
just refusing:

```text
'fn' declares a foreign-callable (C ABI, non-raising) function in cocoa-mojo
and may not be marked 'raises'; use 'def' for an ordinary Mojo function
```

It comes with a FixIt that replaces `fn` with `def`. `async` is rejected the
same way. Old code of the `fn main() raises` shape therefore gets told what
changed instead of a bare contract violation.

## `let` is back — as the immutable binding

`let` declares an **immutable, scope-bound binding**.

```mojo
let win = ObjCObject(window_addr()[])
let n = 41 + 1
```

Three things to know.

**The binding is immutable; the object is not.** This is Swift's rule exactly.
You cannot rebind `win`, but you can send it setters all day.

**It is general.** The design originally proposed gating `let` on a `Retained`
trait so that only reference-counted Cocoa objects could use it. When it came
to implementation the opposite was chosen: `let n = 42` and
`let win = NSWindow(...)` both mean "immutable binding", which is one rule
instead of two.

**Ownership rides the value, not the keyword.** For a Cocoa object held in an
`ObjCRef`, `let` gives you the same +1-at-bind and release-at-scope-exit you
already had with `var`; the ARC behaviour lives in `ObjCRef`. `let` adds only
the immutability of the binding.

### What `let` rejects

Reassignment is a compile error. And `let` is a **function-body** form only —
there is no field or file-scope `let`:

```text
'let' declares an immutable binding inside a function body; use 'var' for a
field or module value
```

### When to reach for it

The fork's own conversion is a good guide: sixteen never-reassigned Cocoa
bindings in `p0_window.mojo` became `let`. If you never rebind it, say so.

## `alias` is deprecated, not removed

`alias` still parses, with a warning:

```text
'alias' is deprecated; use 'comptime'
```

Use `comptime`. `alias` is gone from the standard library's own code.

## `comptime` does the compile-time work

## Argument conventions

There is no `inout`, no `borrowed`, and no `owned`. The conventions are:

Most of them are *contextual* — soft identifiers rather than reserved
words — so `mut`, `imm`, `out` and `deinit` are all still available as ordinary
variable names. Only `var` is a reserved keyword.

| Convention | Meaning |
|:---|:---|
| *(none)* | Borrowed immutably. The default; you do not write it. |
| `imm` | Borrowed immutably, said out loud. `read` is the deprecated spelling. |
| `mut` | Borrowed mutably. |
| `out` | An uninitialised result the function must initialise. Used for `__init__`. |
| `var` | Taken by value; the callee owns it. |
| `deinit` | Consumes the value and ends its lifetime. Used for `__deinit__` and for consuming methods. |

In practice:

```mojo
def __init__(out self, *, adopt: ObjCObject):
    self._obj = adopt

def _add(mut self, selector: StaticString, encoding: String, imp: P):
    ...

def register(deinit self) -> ObjCClass:
    ...

def __iter__(var self) -> Self.IteratorOwnedType:
    ...
```

The transfer sigil `^` moves a value into a consuming position:

```mojo
var cls = b^.register()      # b is consumed here
var delegate = new_instance(cls)
```

Forgetting `^` on a `deinit` method is one of the more common early errors.

## Origins, and how they are spelled

References carry an origin parameter. The names were renamed twice and the old
spellings have now been removed, so a tutorial written a few months ago will
use identifiers that no longer exist.

| Use this | Not this |
|:---|:---|
| `ImmOrigin` | `ImmutOrigin` |
| `ImmUnsafeAnyOrigin` | `ImmutUnsafeAnyOrigin` |
| `ImmStaticOrigin` | `StaticConstantOrigin` |
| `UntrackedOrigin` | `ExternalOrigin` |
| `MutUntrackedOrigin` | `MutExternalOrigin` |
| `ImmUntrackedOrigin` | `ImmutUntrackedOrigin`, `ImmutExternalOrigin` |

`MutUntrackedOrigin` is the one you will type constantly in Cocoa code, because
every pointer that crosses into Objective-C is outside Mojo's lifetime tracking
by definition. Most CocoaMojo files start by shortening it:

```mojo
comptime P = OpaquePointer[MutUntrackedOrigin]
```

## Pointers

`Pointer` is the type. `UnsafePointer` still exists but is deprecated in favour
of it, and the pre-unification aliases — `MutUnsafePointer`, `ImmUnsafePointer`,
`ImmutOpaquePointer`, `OptionalUnsafePointer` and the rest — have been removed
outright.

```mojo
var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=addr)
var q = OpaquePointer[MutUntrackedOrigin](unsafe_from_address=addr)
```

The raw memory functions were renamed to carry an `unsafe_` prefix, and the old
names are gone: use `unsafe_memcpy`, `unsafe_memset`, `unsafe_memset_zero`,
`unsafe_destroy_n`. Likewise the `Pointer` methods are now
`unsafe_deinit_pointee()`, `unsafe_write()`, `unsafe_as_noalias()`.

## Function types, `thin`, and `abi("C")`

`fn` is the spelling you want for a foreign-callable function, but the longhand
still exists and you will meet it in older code and in diagnostics.

```mojo
comptime IMP1 = fn(P, P, P, /) -> None          # cocoa-mojo
comptime IMP1 = def(P, P, P, /) thin abi("C") -> None   # the longhand it sugars
```

`/` ends the positional-only parameters, `thin` means the function carries no
captured context, and `abi("C")` gives it the C calling convention. You need
all three for a Cocoa callback, because the Objective-C runtime calls a bare C
function pointer with no closure environment — which is precisely why `fn`
bundles them into one keyword.

A `thin` function type can also carry trailing `where` clauses constraining the
parameters it declares, so a generic algorithm can state what it requires of a
function handed to it rather than restating the constraint at every binding
site.

One consequence worth knowing: **a thin `fn` is exactly a global block.** An
Objective-C block with no captures is `_NSConcreteGlobalBlock` with no
copy/dispose helpers, so the standard library can build a block around any
`fn` at no cost. That is how block-only Cocoa APIs are reachable today — see
[Concurrency and blocks](08-concurrency.md).

## Parameters and generics

Parameters go in square brackets and are resolved at compile time. Arguments go
in parentheses.

```mojo
def msg_send[
    R: AnyType,
    cls: StaticString,
    selector: StaticString,
    is_class: Bool = False,
    *Ts: AnyType,
](obj: ObjCObject, *args: *Ts) -> R:
    ...
```

That signature shows most of what you need: a type parameter, string
parameters, a defaulted `Bool` parameter, a variadic type-parameter pack, and a
value pack `*args: *Ts` bound to it.

Overloading works on parameter lists as well as argument lists, which is how
`ObjCClassBuilder.add_method` accepts five different IMP shapes under one name.

## Structs and traits

```mojo
@fieldwise_init
struct CGPoint(Copyable, Movable):
    var x: Float64
    var y: Float64
```

`@fieldwise_init` synthesises the memberwise initialiser. Conformances go in
the parentheses. The ones you will meet most in Cocoa code are `Copyable`,
`Movable`, `AnyType` and `TrivialRegisterPassable`.

Two more renames that will bite: `ImplicitlyDestructible` and
`ImplicitlyDeletable` are now `Deinitable`, and `@explicit_destroy` is no
longer required, because implicit deletion is the default.

Destructors are `__deinit__`, taking `deinit self`:

```mojo
def __deinit__(deinit self):
    if not self._obj.is_nil():
        ...
```

## Other removals you are likely to trip over

| Gone | Use instead |
|:---|:---|
| `InlineArray` | `Array` |
| `SIMD.size`, `Array.size`, `SIMDSize` | `length`, `SIMDLength` |
| `String.as_string_slice()` | `StringSpan(my_string)` |
| `as_immutable()`, `get_immutable()` | `as_imm()` |
| `ImmutSpan` | `ImmSpan` |
| `ConditionalType` | the ternary `T if cond else U` |
| `trait_downcast()` | a `where` clause or `comptime assert` with `conforms_to(...)` |
| `.mojopkg` files | `.mojoc` files |
| `memcmp` | `unsafe_memcmp` |
| `List.steal_data()` | `unsafe_take_allocation()` |
| `OwnedPointer.take()` | `into_inner()` |
| `Variant.take()` | `unwrap()` |
| `std.gpu.profiler` / `ProfileBlock` | `perf_counter_ns()`, or a real GPU profiler |

The module system also tightened. Importing same-named functions from different
modules to build one overload set is now an error, and intra-package access
without an explicit `import` is an error. Both had deprecation periods that
have now expired.

## `async` on an `fn`

`fn` cannot be `async`; use `def`. The rest of the async story is unchanged
from upstream, and nothing in CocoaMojo depends on it.

## A note on `async`

`AnyCoroutine`, `Coroutine` and `RaisingCoroutine` are no longer in the prelude
and the module defining them is private. `async def` still works and the
compiler still synthesises those types — you simply cannot name them. Mojo's
async support is unfinished and nothing in CocoaMojo depends on it.

## What you can rely on

The point of the freeze is that this list will not move under you. Code written
against this chapter keeps compiling for as long as you keep the compiler. That
is the trade the fork makes: no upstream fixes and no new features, in exchange
for a language that stays still long enough to build something on.
