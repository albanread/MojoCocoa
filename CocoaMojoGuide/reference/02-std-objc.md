# 2. `std.objc`

The complete exported surface. Throughout, `P` abbreviates
`OpaquePointer[MutUntrackedOrigin]`.

```mojo
from std.objc import (
    ObjCClass, ObjCObject, SEL, sel, msg_send, send, autoreleasepool,
    load_framework,
    ObjCRef, ObjCWeakRef,
    NSString, nsstring, extern_object, ns_to_string,
    msg_send_raising, msg_send_raising_check,
    ObjCClassBuilder, IMP0, IMP1, IMP0Bool, IMP1Bool, IMP2,
    new_instance, named_global, sel_dynamic,
)

# GCD lives in its own module
from std.objc.dispatch import (
    Semaphore, async_f, global_queue, main_queue, sync_f, with_block,
)
```

## Runtime handles

### `SEL`

A registered Objective-C selector — an interned string pointer.

| Member | Signature |
|:---|:---|
| `ptr` | `def ptr(self) -> P` |

Conforms to `TrivialRegisterPassable`.

### `ObjCClass`

A handle on a class object.

| Member | Signature |
|:---|:---|
| `lookup` | `@staticmethod def lookup[name: StaticString]() -> ObjCClass` |
| `is_nil` | `def is_nil(self) -> Bool` |
| `as_object` | `def as_object(self) -> ObjCObject` |

`lookup` calls `objc_getClass`. A nil result means the framework is not loaded.

### `ObjCObject`

A borrowed `id`.

| Member | Signature |
|:---|:---|
| `is_nil` | `def is_nil(self) -> Bool` |
| `addr` | `def addr(self) -> Int` |
| `ptr` | `def ptr(self) -> P` |

Construct directly from an address with `ObjCObject(Int(raw_pointer))`.

## Selectors

### `sel`

```mojo
def sel[name: StaticString]() -> SEL
```

Registers the selector once and caches the result in a per-selector global slot,
deduplicated by name in the KGEN lowering. After the first send the cost is one
load and a null check.

### `sel_dynamic`

```mojo
def sel_dynamic(name: StaticString) -> P
```

Registers a selector by name at run time, returning the raw pointer. Accepts
custom selectors the SDK does not know. Use when calling `class_addMethod`
directly.

## Message sending

### `msg_send`

```mojo
def msg_send[
    R: AnyType,
    cls: StaticString,
    selector: StaticString,
    is_class: Bool = False,
    *Ts: AnyType,
](obj: ObjCObject, *args: *Ts) -> R
```

Sends `selector` to `obj`, returning `R`.

| Parameter | Meaning |
|:---|:---|
| `R` | Return type; must be register-passable |
| `cls` | Class the selector is looked up on; inheritance-resolved |
| `selector` | The selector, colons included |
| `is_class` | `True` for a `+` method |
| `Ts` | Argument types, inferred |

Compile-time checks: the selector must exist on `cls` or a superclass; the
argument count must equal the selector's declared count; each argument must be
in the register file the ABI expects, for the cases that can be determined
certainly; and the `@encode` signature must be modelable.

### `send`

```mojo
def send[R: AnyType, selector: StaticString, *Ts: AnyType](
    obj: ObjCObject, *args: *Ts
) -> R
```

Sends to a **protocol-typed** receiver whose concrete class is unknown at
compile time — every Metal object, every delegate. The dispatch stub and
argument classes come from the database keyed by selector alone.

Argument count and register-file checks still apply. Receiver-class
verification does not.

## Ownership

### `ObjCRef`

An owning handle on one +1 reference. Conforms to `Movable`; deliberately not
implicitly `Copyable`.

| Member | Signature | Notes |
|:---|:---|:---|
| init | `def __init__(out self, *, adopt: ObjCObject)` | Takes ownership of an object already at +1 |
| init | `def __init__(out self, *, retain: ObjCObject)` | Adds a +1 to a borrowed object |
| `copy` | `def copy(self) -> Self` | Explicit retain |
| `object` | `def object(self) -> ObjCObject` | Borrowed handle, valid for this ref's lifetime |
| `is_nil` | `def is_nil(self) -> Bool` | |
| `autorelease` | `def autorelease(deinit self) -> ObjCObject` | Hands to the current pool; consumes the ref |
| deinit | `def __deinit__(deinit self)` | Releases if not nil |

Use `adopt=` after `alloc`, `new`, `copy`, `mutableCopy`; `retain=` otherwise.

Backed by the ARC entry points `objc_retain`, `objc_release`,
`objc_autorelease`, so it interoperates with ARC code.

### `autoreleasepool`

A scoped pool.

```mojo
with autoreleasepool():
    ...
```

Pushes on `__enter__`, pops on `__exit__`, and guards against a double pop —
popping a token twice corrupts the pool page.

## Foundation

### `NSString`

A leak-safe owning wrapper. Conforms to `Movable`.

| Member | Signature |
|:---|:---|
| init | `def __init__(out self, *, adopt: ObjCObject)` |
| init | `def __init__(out self, text: String)` |
| `object` | `def object(self) -> ObjCObject` |
| `length` | `def length(self) -> Int` |
| `to_string` | `def to_string(self) -> String` |
| `equals` | `def equals(self, other: NSString) -> Bool` |
| `appending` | `def appending(self, other: NSString) -> NSString` |

`length` is UTF-16 code units, matching `-[NSString length]`.

### `nsstring`

```mojo
def nsstring(s: String) -> ObjCObject
```

An **autoreleased** `NSString`. For handing to AppKit setters, which retain.
Use inside an autorelease pool.

### `extern_object`

```mojo
def extern_object[name: StaticString]() -> ObjCObject
```

The object held in an extern Cocoa constant, such as
`NSForegroundColorAttributeName`. These are globals whose address the linker
resolves, not compile-time values; this takes a link-time reference to the data
symbol and loads the pointer out of it.

## Defining classes

### IMP type aliases

| Alias | Signature |
|:---|:---|
| `IMP0` | `fn(P, P, /) -> None` |
| `IMP1` | `fn(P, P, P, /) -> None` |
| `IMP0Bool` | `fn(P, P, /) -> Bool` |
| `IMP1Bool` | `fn(P, P, P, /) -> Bool` |
| `IMP2` | `fn(P, P, P, P, /) -> None` |

The first two arguments are always `self` and `_cmd`.

### `ObjCClassBuilder`

```mojo
struct ObjCClassBuilder[superclass: StaticString = "NSObject"]
```

| Member | Signature |
|:---|:---|
| init | `def __init__(out self, name: String)` |
| `add_method` | `def add_method[selector: StaticString, encoding: StaticString = ""](mut self, imp: IMPn)` |
| `register` | `def register(deinit self) -> ObjCClass` |

`add_method` is overloaded across the five IMP shapes. When `encoding` is
omitted the SDK's `@encode` for the selector is used, with frame offsets
stripped; an unknown selector with no `encoding` is a compile error.

`register` consumes the builder, so call it as `builder^.register()`.

### `new_instance`

```mojo
def new_instance(cls: ObjCClass) -> ObjCObject
```

`+[cls new]` — an owned (+1) instance. Retain it explicitly if it must outlive
the enclosing scope while Cocoa holds a bare pointer to it.

### `named_global`

```mojo
def named_global[name: StaticString, T: AnyType]() -> Pointer[T, MutUntrackedOrigin]
```

A zero-initialised process global of type `T`, shared by name across every call
site, because KGEN deduplicates the global. The standard answer to callbacks
having no closure.

```mojo
comptime g_running = named_global["life.running", Int]
g_running()[] = 1
```

## Frameworks

### `load_framework`

```mojo
def load_framework[name: StaticString]() -> Bool
```

`dlopen` of `/System/Library/Frameworks/<name>.framework/<name>` with
`RTLD_NOW`. Returns whether the handle is non-null. Idempotent and cheap after
the first call.

Foundation arrives in every process; AppKit does not unless the binary linked
it, which a `mojo run` process did not. Without this, `ObjCClass.lookup` for an
AppKit class returns nil and every message to it silently no-ops.

## Errors

### `msg_send_raising`

```mojo
def msg_send_raising[
    cls: StaticString, selector: StaticString,
    T0: AnyType, ..., is_class: Bool = False,
](obj: ObjCObject, a0: T0, ...) raises -> ObjCObject
```

Sends an object-returning `...error:` selector and raises when the result is
nil. **The trailing error argument is created and appended by the wrapper —
pass the message arguments without it.**

### `msg_send_raising_check`

```mojo
def msg_send_raising_check[
    cls: StaticString, selector: StaticString,
    T0: AnyType, ..., is_class: Bool = False,
](obj: ObjCObject, a0: T0, ...) raises
```

The `BOOL` convention: raises when the result is `NO`. Returns nothing. Same
error-slot handling.

Both are declared at explicit arities up to five leading arguments, because
nothing may follow an unpacked `*args`. The raised `Error` carries the
`NSError`'s `localizedDescription`, domain and code, copied into a Mojo
`String`. An API that returns failure without writing an error produces a
message saying exactly that.

## Weak references

### `ObjCWeakRef`

A zeroing weak reference. Conforms to `Movable`.

| Member | Signature | Notes |
|:---|:---|:---|
| init | `def __init__(out self, target: ObjCObject)` | Registers via `objc_initWeak`; a nil target is legal |
| `load` | `def load(self) -> ObjCRef` | The object at +1 if alive, else a nil `ObjCRef` |
| `copy` | `def copy(self) -> Self` | An independent registration |
| deinit | `def __deinit__(deinit self)` | `objc_destroyWeak` plus `free` |

The registration slot is heap-allocated — one pointer-sized `malloc` per weak
reference — because the runtime tracks weak references by the *address of the
slot* and Mojo values move. A struct field would leave the runtime pointing
into a dead frame after any move.

`load()` goes through `objc_loadWeakRetained` and therefore returns an owned
reference, so the object cannot be deallocated between the nil-check and the
use.

Use this wherever Cocoa expects weakness — delegates and observer targets —
because an `ObjCRef` there is a retain cycle.

## Strings, the other direction

### `ns_to_string`

```mojo
def ns_to_string(s: ObjCObject) -> String
```

`NSString` to Mojo `String`, by copy, UTF-8. The result does not depend on the
pool owning the `NSString`.

## `std.objc.dispatch`

Grand Central Dispatch. Imported directly, not re-exported from `std.objc`.

| Name | Signature | Notes |
|:---|:---|:---|
| `DispatchFn` | `fn(_RawPtr) -> None` | The work-function contract |
| `global_queue` | `def global_queue() -> _RawPtr` | Default-priority concurrent queue |
| `main_queue` | `def main_queue() -> _RawPtr` | `&_dispatch_main_q`, as the C macro takes it |
| `sync_f` | `def sync_f(queue, context, work: DispatchFn)` | Runs before returning |
| `async_f` | `def async_f(queue, context, work: DispatchFn)` | Returns immediately |
| `Semaphore` | `struct Semaphore(Movable)` | `.wait()`; one wait per expected signal |
| `with_block` | `def with_block[work: fn() -> None](queue, *, wait: Bool)` | Builds a real ObjC block around an `fn` |

`with_block` works because a thin `fn` is exactly a global block —
`_NSConcreteGlobalBlock`, no captures, so no copy/dispose helpers. The
`wait=True` path uses a stack literal; `wait=False` lets the runtime
`Block_copy` the 32 bytes off the frame.

Capturing closures as heap blocks are not implemented.

## Method type encodings

The strings `class_addMethod` expects, as returned by the database with frame
offsets stripped.

| Encoding | Meaning |
|:---|:---|
| `v@:` | `void method(id self, SEL _cmd)` |
| `v@:@` | `void method(id self, SEL _cmd, id arg)` |
| `c@:` | `BOOL method(id self, SEL _cmd)` |
| `c@:@` | `BOOL method(id self, SEL _cmd, id arg)` |
| `@@:` | `id method(id self, SEL _cmd)` |

Single-character type codes: `v` void, `c` `BOOL` (a signed char), `@` object,
`:` selector, `i` int, `q` long long, `Q` unsigned long long, `d` double,
`f` float, `*` C string, `^` pointer to.

`BOOL` is `c`, not `B`. This is the encoding most often written wrongly by hand.
