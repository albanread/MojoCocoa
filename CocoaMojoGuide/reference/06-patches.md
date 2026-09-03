# 6. Patches applied to the compiler

[Deviations](05-deviations.md) says what this fork changed about the language
and why. This document covers the work inside the compiler that made those
changes real, and the defects fixed along the way.

Ninety-three commits touch the compiler, the backend, the GPU runtime or the
standard library, between 23 and 31 August 2026. They divide as:
<!-- doccrate:keep-together:start -->


| Area | Commits | What it is |
|:---|---:|:---|
| `[Air]` / `[AIR]` | 36 | The Metal/AIR backend: lowering, legality, object emission |
| `[KGEN]` | 30 | The frontend: the class model, `cocoakb`, and frontend defects |
| `[AppleGPU]` | 10 | Kernel launch, argument binding, capability reporting |
| `[AsyncRT]` | 7 | The Metal runtime: residency, batching, async launch |
| `[stdlib]` | 7 | Standard-library fixes, mostly around `class` and `String` |
| `[Kernels]`, `[Support]` | 3 | Example corpus repair, debug annotation |

<!-- doccrate:keep-together:end -->

The rest of this document explains the ones worth understanding. To list them
all: `git log --oneline --grep='^\[\(KGEN\|Air\|AppleGPU\|AsyncRT\|stdlib\)\]'`.
<!-- doccrate:keep-together:start -->


## Building the class model

Forty-one commits mention the class model in some form, which makes it the
largest single body of work in the fork. It landed as numbered sprints and each
one is a self-contained claim:

<!-- doccrate:keep-together:end -->
<!-- doccrate:keep-together:start -->


| Sprint | What it established |
|:---|:---|
| 1 | The parser accepts `class` |
| 2 | Classes resolve to types; each method's selector is derived |
| 2b | Protocols, registration, the method walk, trampolines |
| 3 | Fields live in the box, proven at runtime, and emptied when the object dies |
| 4 | The SDK answers, and the parser can ask it |

<!-- doccrate:keep-together:end -->

Two of these are worth drawing out.

**Trampolines and the ABI oracle.** A method Cocoa calls arrives through the
Objective-C dispatch machinery, which means the compiler must emit a function
with exactly the shape the runtime expects — receiver, `_cmd`, then arguments,
in the right register file. Getting that wrong does not produce a diagnostic;
it produces a corrupted call. The approach taken was to make **clang the ABI
oracle**: rather than reason about classification rules, ask the toolchain that
already implements them, and make a refusal speak (*"Trampoline refusals speak;
clang becomes the ABI oracle"*).

**A class travels in a register, and still retains.** A class value has to be
passable like any other Mojo value while remaining a reference-counted
Objective-C object. Getting both at once — register-passable *and* correctly
retained — is the commit that makes `class` usable as an ordinary type rather
than a special case you must handle carefully.

Frontend defects fixed while building this:

- **`@staticmethod` crashed the compiler.** It is now a `+` method, which is
  what it always meant in Objective-C terms.
- **Fields were constructed into the local, not the box** — so the object the
  runtime held and the object your code wrote to were different memory.
- **A returned class could not parameterise a type**, and the fix required the
  compiler to query the *returned* class, which turned out to be knowable at
  compile time.
- **`cocoakb_query` folded too late**, so the SDK could not choose a type.
  Folding it early is what lets a database answer participate in elaboration
  rather than merely be checked afterwards.
- **`box_ref`: nil is a state, not a hazard** — reading a field of a nil class
  reference should be a defined outcome, not a trap.
<!-- doccrate:keep-together:start -->


## The AIR backend

This is the largest area by commit count and the one with the most instructive
failures. The theme running through all of it:

<!-- doccrate:keep-together:end -->

> LLVM's verifier is target-agnostic by construction, so it cannot see any of
> AIR's rules. Every defect this backend shipped was **legal LLVM IR that was
> illegal for the target**, and each was found one crash at a time, days apart,
> from an error naming nothing.

That sentence is why the backend has a **data-driven legality firewall** rather
than a pile of `if`s: a table of rules, each carrying its own action
(permit / log / fail) and its own evidence for why it exists. A rule added as
`fail` on day one is a rule that stops the build on its first false positive,
and a gate that cries wolf gets switched off — so rules start at `log` and are
promoted once a full sweep is clean.

Representative fixes, each a distinct failure mode:

**Address spaces.** AIR has no generic address space, so a kernel left with its
stores in `addrspace(1)` and its loads in `addrspace(0)` *writes correctly and
reads zero* — an output buffer full of zeroes, no diagnostic, and nothing any
verifier objects to. Hence: deviceize **every** captured pointer rather than
the one the frontend unpacked first; follow pointers whose descriptor arrives
through a `select` or `phi`; reach captured pointers with `inttoptr` rather
than `addrspacecast`; re-legalise after inlining, because whatever the inliner
just pulled in from a callee has never been through it; and drop no-op
`addrspacecast`s, which make `metallib` reject the whole module.

**Barriers.** A workgroup barrier is one dynamic rendezvous for the whole
threadgroup, so selecting or skipping it per thread can silently expose
partially written threadgroup memory. Divergent barriers are now rejected, and
barriers are marked convergent **at declaration creation, before the optimiser
runs** — marking them later is too late, because the optimiser has already
moved them. A kernel that reaches a barrier no longer claims `nosync`.

**Missing instructions.** AIR has no three-way compare, and InstCombine
synthesises `llvm.scmp` out of ordinary comparison code — so a kernel acquires
one without the author writing anything unusual, and it surfaces at the reader
as `Undefined symbols: llvm.scmp.i32.i32`. These are now expanded into selects
during legalisation, with a rule that fails closed on any that survive. The
same shape recurs: `llvm.vector.reduce.*` and vector interleave were lowered,
int↔float casts routed through `air.convert`, and `llvm.stepvector` folded.

**Symbols and types.** AIR declarations need an exact type key, and the symbol
stems must match what Apple's reader expects — including refusing to guess
integer signedness rather than picking one. The `simdgroup_matrix` family
needed mangling, and per-signature tags had to be stripped from symbol names.

**Three defects that only surface when the metallib becomes a pipeline.** The
most expensive class: the module verifies, `metallib` accepts it, `air-opt`
accepts it, and the failure appears only when the driver builds a compute
pipeline — which is why the backend now retains artifacts per kernel and keeps
diagnostics attached to their cause.
<!-- doccrate:keep-together:start -->


## The Apple GPU runtime

**Precise residency, and a selector that was never active.** Metal needs to be
told which allocations a dispatch may touch. The original approach declared
every live root buffer to every compute encoder — one `useResource` per buffer
per dispatch, under the registry lock. Correct, and linear in live allocations.
An `MTLResidencySet` inverts that: one set per device, attached to each command
queue, edited when an allocation is created or destroyed, with nothing left on
the dispatch path.

<!-- doccrate:keep-together:end -->

The instructive part is the follow-up. **The selector was wrong, so the
optimisation had never executed.** The code asked for
`makeResidencySetWithDescriptor:error:` where `MTLDevice` exposes
`newResidencySetWithDescriptor:error:`. `respondsToSelector:` answered no, the
set was never created, and every launch fell back to the walk.

The results stayed correct throughout, which is exactly what hid it: *the
fallback is the old code, and the old code works.* Every measurement of
"precise residency" before that fix, in both repositories, was the walk timed
against itself, and the ~25% improvement recorded for it was noise between two
runs of identical code.

Measured properly afterwards, in µs per dispatch:
<!-- doccrate:keep-together:start -->


| Live buffers | Walk | Residency set |
|---:|---:|---:|
| 256 | 18.56 | 3.46 |
| 1,024 | 73.35 | 3.25 |
| 4,096 | 289.53 | 3.37 |

<!-- doccrate:keep-together:end -->

Linear against flat, and −99% at the top end.

**Launch and batching.** Metal launches now default to queued execution,
asynchronous launch is safe to leave on, and queued dispatches are batched into
command buffers. The measured effect is clearest on `examples/fluid`, whose
step is about 35 dependent dispatches: launch overhead, not arithmetic, is what
such a step is made of.

**Binding.** Captured device pointers are bound as buffers rather than bytes,
and bound **from the kernel's argument contract rather than from the value** —
the value does not always know what the kernel expects. Reflection is
authoritative for compiler-generated kernels, copies are routed by host/device
rather than by `MTLBuffer` handle, and oversized threadgroup storage is
rejected up front rather than failing later.

**Capability reporting.** The ABI capability table is generated from the source
and checked, so what the runtime claims and what it implements cannot drift
apart. `MULTIPROCESSOR_COUNT` is answered from measured cores.
<!-- doccrate:keep-together:start -->


## Standard library

Two `String` fixes worth naming because both are the kind that survive review:

<!-- doccrate:keep-together:end -->

- **`String._realloc_mutable` asked the allocator for zero.** A zero-size
  allocation is permitted to return null or a pointer you must not use, and
  either answer is a fault later, somewhere else.
- **`String` doubled when copying rather than when growing**, which is the
  wrong side of the operation and turns append-heavy code quadratic.

The rest are the class model reaching the library: `std.objc.typed` for calling
Cocoa as calls, `box_ref` reaching a class's fields from outside a method, and
the runtime half of class registration, made provable on its own.
<!-- doccrate:keep-together:start -->


## What this history is good for

Two things, beyond the record.

<!-- doccrate:keep-together:end -->

First, the failure modes repeat. Address spaces, convergence, and
optimiser-synthesised intrinsics account for most of the AIR defects, and each
was found the same way — a program that ran and produced the wrong answer,
rather than one that failed. If you are extending the backend, those three are
where to look first.

Second, several entries above are corrections of *earlier entries*. The
residency selector invalidated its own measurements; a legality rule was
recorded as counter-evidence against a theory that turned out to be wrong
(*"unmapped vector intrinsics are not the defect"*); a status note was
corrected for overstating what a gate proved. That is the shape of honest work
on a backend reconstructed black-box, and the commit history is kept in that
shape on purpose.
