# 1. Language reference

The dialect accepted by this frozen compiler. Where it differs from published
Mojo documentation, this document describes the compiler.

## Declarations

### Functions

Two keywords, with different contracts.

```mojo
def name(arg: T, ...) -> R:          # ordinary Mojo function
def name(arg: T) raises -> R:
def name[param: T](arg: T) -> R:

fn name(a: P, b: P) -> Bool:         # foreign-callable: thin, C ABI, non-raising
```

`raises` marks a `def` that can raise. `abi("C")` on a `def` gives the C
calling convention and belongs before the return arrow; `fn` implies it.

**`fn` — the foreign-callable function.** Thin (no captures), non-raising, C
ABI, all parameter and return types ABI-classifiable. Exactly the Objective-C
`IMP` contract. Callable from Mojo as an ordinary function. May not be marked
`raises` or `async`.

### Bindings

```mojo
var x = expr        # mutable binding
let x = expr        # immutable binding, function body only
comptime X = expr   # compile-time binding
```

`let` is immutable in the *binding*, not the object: `let win = ...` still
permits `setTitle:`. It is general — it applies to values as well as
reference-counted objects. Ownership semantics for Cocoa objects live in
`ObjCRef`, not in the keyword. There is no field or file-scope `let`.

### Function types

```mojo
fn(T1, T2, /) -> R                   # sugar for the line below
def(T1, T2, /) thin abi("C") -> R
def[w: Int](Int) thin -> None where (w > 0, "width must be positive")
```

`/` ends the positional-only parameters. `thin` means no captured context. A
`thin` function type may carry trailing `where` clauses constraining the
parameters it declares; the clause binds to the innermost function type, so a
declaration-level `where` after a function-type result needs that result
parenthesised:

```mojo
def make[n: Int]() -> (def() thin -> None) where n > 0: ...
```

Binding a constrained function to a function type that declares no matching
`where` clause is an error. Passing an unconstrained function where a
constrained type is expected is allowed and free.

### Compile-time bindings

```mojo
comptime NAME = expression
comptime Alias = SomeType[Param]
```

`alias` still parses but is deprecated: `'alias' is deprecated; use 'comptime'`.

### Compile-time control flow

```mojo
comptime if cond:
    ...
else:
    ...

comptime for i in range(n):
    ...

comptime assert condition, "message"
```

`@parameter if` and `@parameter for` still parse but are deprecated. The
`@parameter` decorator on parametric closures is now `@__parameter`.

### Structs

```mojo
@fieldwise_init
struct Name(Trait1, Trait2):
    var field: T

    def __init__(out self, ...):
    def method(self) -> T:
    def mutator(mut self):
    def consume(deinit self) -> T:
    def __deinit__(deinit self):
```

Struct parameters are declared in brackets after the name:

```mojo
struct ObjCClassBuilder[superclass: StaticString = "NSObject"]:
```

`__new__` is not supported on structs; use `__init__`.

## Argument conventions

| Convention | Meaning |
|:---|:---|
| *(omitted)* | Immutable borrow. The default. |
| `mut` | Mutable borrow. |
| `out` | Uninitialised result the callee must initialise. |
| `var` | By value; callee owns it. |
| `deinit` | Consumes the value, ending its lifetime. |

`inout`, `borrowed` and `owned` do not exist.

The transfer sigil `^` moves a value into a consuming position:

```mojo
var cls = builder^.register()
```

## Origins

| Spelling | Removed alias |
|:---|:---|
| `ImmOrigin` | `ImmutOrigin` |
| `ImmUnsafeAnyOrigin` | `ImmutUnsafeAnyOrigin` |
| `ImmStaticOrigin` | `StaticConstantOrigin` |
| `UntrackedOrigin` | `ExternalOrigin` |
| `MutUntrackedOrigin` | `MutExternalOrigin` |
| `ImmUntrackedOrigin` | `ImmutUntrackedOrigin`, `ImmutExternalOrigin` |

Also in use: `MutAnyOrigin`, `MutOrigin`.

## Pointers

`Pointer[T, Origin]` is the type. `OpaquePointer[Origin]` is the untyped one.
`UnsafePointer` exists but is deprecated in favour of `Pointer`.

Removed aliases: `MutUnsafePointer`, `ImmUnsafePointer`, `ImmutUnsafePointer`,
`ImmutOpaquePointer`, `ImmutPointer`, `OptionalUnsafePointer`. Use
`MutPointer`, `ImmPointer`, `ImmOpaquePointer`, `OptionalPointer`.

Construction and use:

```mojo
Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=addr)
OpaquePointer[MutUntrackedOrigin](unsafe_from_address=addr)
p[]                                  # dereference
Pointer(to=value).unsafe_bitcast[T]()
p.bitcast[T]()
```

Renamed methods: `unsafe_as_noalias()`, `unsafe_deinit_pointee()`,
`unsafe_deinit_pointee_with()`, `unsafe_write()`, `unsafe_write_move_from()`.
`Pointer.type` is now `Pointer.T`.

Renamed free functions: `unsafe_memcpy`, `unsafe_memset`, `unsafe_memset_zero`,
`unsafe_uninit_move_n`, `unsafe_uninit_copy_n`, `unsafe_destroy_n`,
`unsafe_memcmp`.

## Traits in common use

`AnyType`, `Copyable`, `Movable`, `Deinitable`, `TrivialRegisterPassable`.

`ImplicitlyDestructible` and `ImplicitlyDeletable` were renamed to `Deinitable`.
`@explicit_destroy` is no longer required. The `register_passable` and
`escaping` function effects are no longer supported.

## Decorators

`@fieldwise_init`, `@always_inline`, `@staticmethod`, `@export("name")`,
`@deprecated(...)`, `@__parameter`.

## MLIR escape hatches

Used by the standard library where no surface syntax exists:

```mojo
__mlir_op.`pop.global_alloc`[...]()
__mlir_op.`pop.extern_ptr_symbol`[...]()
__mlir_attr[`#kgen.param.expr<...>`]
```

These are internal, carry no stability guarantee, and are documented here only
so that reading the standard library is possible.

## Modules

Directories may have namespace semantics: one directory name may resolve across
distinct locations on disk that share the name.

Importing same-named functions from different modules to form one overload set
is an error. Intra-package access without an explicit `import` is an error.

`.mojopkg` is gone; the package format is `.mojoc`.

## Removed library APIs

| Removed | Replacement |
|:---|:---|
| `InlineArray` | `Array` |
| `SIMD.size`, `Array.size`, `TypeList.size`, `SIMDSize` | `length`, `SIMDLength` |
| `String.as_string_slice()` | `StringSpan(s)` |
| `String.set_byte_length()` | *(internal, none)* |
| `as_immutable()`, `get_immutable()` | `as_imm()` |
| `ImmutSpan` | `ImmSpan` |
| `ConditionalType`, `std.utils.type_functions` | `T if cond else U` |
| `trait_downcast()` | `conforms_to(...)` in `where` or `comptime assert` |
| `memcmp` | `unsafe_memcmp` |
| `List.steal_data()`, `OwnedPointer.steal_data()` | `unsafe_take_allocation()` |
| `OwnedPointer.take()` | `into_inner()` |
| `Variant.take()`, `Variant.unsafe_take()` | `unwrap()`, `unsafe_unwrap()` |
| `b64decode(validate=...)` | always validates; drop the parameter |
| `std.gpu.profiler`, `ProfileBlock` | `perf_counter_ns()`, external profiler |
| `benchmark.run[func]()` | `run(f)` |
| `AnyCoroutine`, `Coroutine`, `RaisingCoroutine` | *(unnameable; `async def` still works)* |
| async task API in `std.runtime.asyncrt` | `initialize_runtime()`, `parallelism_level()` from `std.runtime` |
