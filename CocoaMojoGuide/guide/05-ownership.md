# 5. Ownership and memory

Cocoa manages memory by reference counting. An object is created at +1, every
`retain` adds one, every `release` takes one away, and at zero it is
deallocated. Autorelease pools defer a release to the end of a scope.

Mojo has value semantics and deterministic destruction. CocoaMojo binds the two
so that the Objective-C reference count follows the lifetime of the Mojo value
holding it — which means **you opt out of correct memory management, never
into it**.

## `ObjCRef` owns a +1

```mojo
struct ObjCRef(Movable):
    ...
```

An `ObjCRef` holds one owned reference. It releases when the Mojo value is
destroyed. There are two ways to make one, and picking the right one is the
whole skill.

```mojo
var owned = ObjCRef(adopt=obj)    # you already own a +1
var shared = ObjCRef(retain=obj)  # you only borrowed it; add a +1
```

The rule that decides which is the oldest rule in Cocoa, and it is mechanical:

| Selector you called | You own the result? | Use |
|:---|:---|:---|
| `alloc`, `new`, `copy`, `mutableCopy` | yes, +1 | `adopt=` |
| anything else | no, borrowed | `retain=` |

Get this backwards in the `adopt` direction and you over-release, which crashes
somewhere unrelated. Get it backwards in the `retain` direction and you leak.

## The classic +1 chain

```mojo
def make_array() -> ObjCRef:
    var cls = ObjCClass.lookup["NSMutableArray"]()
    var allocated = msg_send[
        ObjCObject, "NSMutableArray", "alloc", is_class=True
    ](cls.as_object())
    var inited = msg_send[ObjCObject, "NSObject", "init"](allocated)
    return ObjCRef(adopt=inited)
```

`alloc` returns +1, `init` consumes and returns it, and `adopt=` takes over. The
caller cannot forget to release, because there is nothing to forget: the
`ObjCRef` releases when it dies.

The raw sends are deliberate here: the two halves of the chain are the lesson,
and the keyword form hides them. Ordinary code writes
`Obj["NSMutableArray"](...)`, which does the `alloc` and the `init` for you —
but it is worth knowing once what that line is standing in for, because the
ownership rule it obeys is the one every Cocoa API answers to.

The fork's ownership test cycles a million of these and watches memory stay
flat.

## Copying is an explicit retain

`ObjCRef` is `Movable` but not implicitly `Copyable`. Sharing an Objective-C
object means retaining it, and the design makes that visible:

```mojo
var a = make_array()
var b = a.copy()     # a visible +1
```

If you want to move rather than share, use the transfer sigil:

```mojo
var b = a^
```

## Autorelease pools

```mojo
with autoreleasepool():
    var s = make_autoreleased()
    print("live inside the pool:", not s.is_nil())
# pool drained here
```

`autoreleasepool` pushes a pool on entry and pops it on exit. It guards against
a double pop internally, because popping a token twice corrupts the pool page
and produces a hard crash a long way from the cause.

Wrap `main` in one. Wrap any loop that creates many temporary Cocoa objects in
one. Do **not** wrap an AppKit callback in one — AppKit's own event dispatch
already has a pool active, and every object you read from an event is
autoreleased by the caller.

## Returning an object without leaking

Sometimes you want to hand an object back without making the caller own it —
exactly what an Objective-C method returning an autoreleased object does.
`autorelease()` consumes the `ObjCRef` and gives the object to the current pool:

```mojo
def make_autoreleased() -> ObjCObject:
    var owned = make_array()
    return owned^.autorelease()
```

Note the `^`. `autorelease` takes `deinit self`, so the reference is consumed;
without the sigil you get a compile error.

The returned `ObjCObject` is valid until the pool drains. Using it afterwards
is a use-after-free, and no amount of compile-time checking can save you from
that one — it is the one place in CocoaMojo where the discipline is yours.

## The lifetime, as a state machine

```mermaid
stateDiagram-v2
    [*] --> Owned: ObjCRef(adopt=) / ObjCRef(retain=)
    Owned --> Owned: copy() adds +1
    Owned --> Pooled: autorelease() hands to the pool
    Owned --> [*]: __deinit__ releases
    Pooled --> [*]: pool drains
```

## `let` for the bindings you never rebind

Everything above works the same whether you bind with `var` or `let`. The ARC
behaviour lives in `ObjCRef`, not in the keyword.

```mojo
let obj = make_array()          # +1 at bind, released at scope exit
let s = nsstring("hello")
```

What `let` adds is that the *binding* cannot be reassigned, which is worth
having precisely because Cocoa code is full of handles you obtain once and then
only send messages to. If you never rebind it, say so; the compiler will hold
you to it.

The object stays mutable. `let win = ...` then `setTitle:` is fine — you are
mutating the object, not rebinding the name.

## Weak references

`ObjCRef` is the strong half of the story. `ObjCWeakRef` is the other half, and
you need it more often than you might expect, because **Cocoa's delegate
convention is weak**. A window does not own its delegate; an observer does not
own its target. Holding an `ObjCRef` where Cocoa expects weakness is a retain
cycle that leaks both sides.

```mojo
var strong = make_object()
var weak = ObjCWeakRef(strong.object())

var loaded = weak.load()        # an ObjCRef: the object at +1, or nil
if loaded.is_nil():
    print("gone")
```

It is a **zeroing** weak reference: while the object lives, `load()` returns
it; after the last strong reference goes, `load()` returns nil. A weak
reference to nil is legal and simply loads nil.

Three details that matter in use.

**`load()` returns an owned `ObjCRef`, not a bare handle.** It goes through
`objc_loadWeakRetained`, so the object cannot be deallocated between your
nil-check and your use. That is the entire reason to load a weak reference
rather than peek at it.

**Copying is explicit**, matching `ObjCRef`:

```mojo
var weak2 = weak.copy()         # an independent registration
```

**There is one small heap allocation per weak reference**, and the reason is
worth understanding. The Objective-C runtime tracks a weak reference *by the
address of the slot holding it*. Mojo values move. If the slot were a struct
field, any move would leave the runtime pointing into a dead stack frame — a
corruption with no diagnostic. So the slot lives on the heap, its address stays
stable for the life of the value, and moving the struct moves only a pointer.
Delegates are few; the allocation is not a problem.

### A rough edge

Assigning into an uninitialised `var` of a type with a `__deinit__` destroys
garbage first and crashes. This is pre-existing and not specific to weak
references, but it bites here because the natural shape —

```mojo
var weak: ObjCWeakRef          # then assign later
```

— is exactly that pattern. Bind it in a helper scope and return it instead.

## Buffers that Cocoa callbacks must reach

This one is not about Objective-C at all, and it will catch you.

Mojo destroys a value at its **last use**, not at the end of scope. So a `List`
whose `.unsafe_ptr()` you stash in a global is freed immediately after that
line, and every stored pointer dangles. The symptom arrives much later as a
corrupted allocator, nowhere near the cause.

When memory has to outlive Mojo's view of it, own it outside Mojo:

```mojo
def alloc_zeroed(count: Int, size: Int) -> Int:
    var sym = _sym["calloc"]()
    var call = Pointer(to=sym).unsafe_bitcast[
        def(Int, Int, /) thin abi("C") -> P
    ]()[]
    return Int(call(count, size))
```

Explicit, unowned, and correct. The alternative — hoping a `List` lives long
enough — is not a smaller amount of unsafety, only a less visible one.

## Where callback state lives

Cocoa callbacks are bare C function pointers. They get no closure and no
context argument you did not arrange yourself. State they need must therefore
live somewhere reachable by name.

```mojo
comptime g_running = named_global["life.running", Int]
comptime g_gen = named_global["life.gen", Int]

# read and write through the pointer
g_running()[] = 1
var generation = g_gen()[]
```

`named_global` gives you one zero-initialised process global per name, shared
across every call site, because KGEN deduplicates the global by name. It is the
plainest possible answer to a real constraint, and it is better than the
alternative of smuggling a pointer through `setRepresentedObject:` and casting
it back.

## A short checklist

Use `adopt=` after `alloc`, `new`, `copy`, `mutableCopy`; `retain=` otherwise.
Use `^` when consuming an `ObjCRef`. Wrap `main` and long loops in
`autoreleasepool`, but not AppKit callbacks. Allocate anything a callback must
reach outside Mojo's ownership, and reach it through `named_global`.
