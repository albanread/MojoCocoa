# 8. Concurrency and blocks

Grand Central Dispatch is the concurrency story for a Cocoa app: UI work
belongs to the main queue and everything else hops between queues. It is a C
API in libSystem, so there is nothing to link.

The reason it lands cleanly here is a coincidence of contracts. Every GCD
operation exists in two forms — a block form, and an `_f` form taking a bare C
function pointer plus a context word — and **the `_f` form is exactly the
revived `fn`**: thin, non-raising, C ABI. So most of `std.objc.dispatch` is
direct calls with no adaptation layer at all.

```mojo
from std.objc.dispatch import (
    Semaphore, async_f, global_queue, main_queue, sync_f, with_block,
)
```

## Queues

```mojo
var q = global_queue()      # the default-priority concurrent queue
var m = main_queue()        # where UI work belongs
```

`main_queue()` is worth a note: the main queue is not a function in C but a
global, `_dispatch_main_q`, and the `dispatch_get_main_queue()` macro takes its
address. The library references it the same way it references the `msg_send`
stubs — as a link-time symbol.

## Dispatching an `fn`

```mojo
fn set_flag(ctx: P) -> None:
    named_global["app.flag", Int]()[] = 42

sync_f(q, ctx, set_flag)     # runs before returning
async_f(q, ctx, set_flag)    # returns immediately
```

The context word is how you get data to the work function, because an `fn` has
no closure. In practice you will often reach for `named_global` instead, the
same way Cocoa callbacks do — see
[Where callback state lives](05-ownership.md#where-callback-state-lives).

`Pointer` is non-nullable, so when the work function ignores its context you
still have to hand it a real address rather than null. Any stable one will do.

## Waiting: `Semaphore`

```mojo
var sem = Semaphore()
var ctx = P(unsafe_from_address=sem._sem)

async_f(q, ctx, add_and_signal)
async_f(q, ctx, add_and_signal)
sem.wait()
sem.wait()
```

One `wait()` per expected signal. This is the rendezvous the dispatch spike
uses to prove three concurrent `async_f` calls all ran.

## Blocks

Plenty of modern Cocoa is block-only, and blocks have their own ABI — isa,
flags, invoke pointer, descriptor, copy and dispose helpers. That sounds like a
lot of machinery to build.

It is not, because of the correspondence the design turns on: **a thin `fn` is
exactly a global block.** No captures means `_NSConcreteGlobalBlock` and no
copy/dispose helpers at all, so the library can build the 32-byte block literal
around any `fn` on the stack.

```mojo
fn block_work() -> None:
    var n = named_global["app.count", Int]()
    n[] = n[] + 1

with_block[block_work](q, wait=True)     # sync: no copy needed
with_block[block_work](q, wait=False)    # async: the runtime Block_copy's it
```

The `wait=True` path never escapes the frame, so the stack literal is enough.
The `wait=False` path does escape, and dispatch's own `Block_copy` memmoves the
32 bytes off your frame — safe precisely because there are no captures to
deep-copy and the descriptor is immortal.

## What is not here yet

**Capturing closures as heap blocks.** That needs synthesized copy and dispose
helpers riding the existing closure emitter, and it is explicitly a later
phase. If an API demands a block that captures, you are outside what the
library covers today.

The practical consequence is the one you have already met everywhere else in
this guide: state that a callback needs must live somewhere reachable without a
closure. `named_global` is the answer here too.
