# `class`: Objective-C classes as a language feature

Status: DESIGN, 2026-08-27. Decisions below are recorded and approved;
nothing is implemented yet. Companion to [COCOA_LET_DESIGN.md](COCOA_LET_DESIGN.md),
which this document assumes.

**Where this sits.** The revived keywords are a program, and each one is a
direction across the same boundary:

- `let` — the foreign **objects we hold** (implemented, general).
- `fn` — the **code the foreign runtime holds** (designed in COCOA_LET_DESIGN.md).
- `class` — the **types we give the foreign runtime**. This document.

In cocoa-mojo, **`class` declares an Objective-C class**. Not a second value
type, not Python semantics, not a general reference type — `struct` stays the
value world, and the reference world on this platform *is* the ObjC runtime.
A pure-Mojo shared reference is `ArcPointer[T]` and needs no keyword.

## Decisions recorded (2026-08-27)

1. **`class` always means Objective-C class.** The keyword is spent on the
   fork's identity. There is no "plain Mojo class" variant and none is
   reserved for later; if one is ever wanted, it will have to argue against
   this paragraph.
2. **Selectors are derived by underscore mapping, with `@objc` as the
   override.** Every `_` in a method name becomes `:` — `roastBuild_` is
   `roastBuild:`, `outlineView_child_ofItem_` is `outlineView:child:ofItem:`.
   The PyObjC convention, mechanical and twenty years proven. The keyword-
   argument mapping from COCOA_LET_DESIGN.md Idea 2 remains the plan for the
   *call* direction and is explicitly not this document's problem.

## DECISION RECORDED AT SPRINT 1 (2026-08-27): attributed StructDeclOp

Sprint 1's first task was to choose between attributing `StructDeclOp` and
introducing a `ClassDeclOp`. The tree decided it:

1. **`StructDeclOp` is load-bearing far outside the parser.** 241 references
   across more than twenty files — the type system, LLDB's `MojoTypeSystem`
   and data layout, code completion, `PublicASTDecl`, signature printing,
   `ClosureEmitter`, `ParamBindings`. A new op would have to be taught to
   every one of them before a class could do anything at all, and each of
   those is a place to get it silently wrong.
2. **The op is already a variant carrier.** Its argument list holds
   `synthetic`, `definesClosure`, `decorators`, `convention`,
   `registerPassableConstraint` and a dozen optional attributes; a `class`
   flag is the shape the op already has, not a new idea imposed on it. And
   because the assembly format ends in `attr-dict-with-keyword`, the new
   attributes print and parse with no printer change.

So `class` lowers onto `StructDeclOp` carrying two new attributes:
`UnitAttr:$objcClass`, and `OptionalAttr<StrArrayAttr>:$objcBases` holding the
base names in source order — superclass first, protocols after. They are
strings, deliberately: these names are resolved against the Objective-C
runtime, not against Mojo's trait system, so nothing here is a
`TraitSymbolAttr`.

### What sprint 1 actually lands, and why the line is there

The **header** is parsed eagerly in `parseClassStmt`, unlike a struct's, which
is re-parsed lazily from a recorded source extent. A class header is a small
fixed grammar — name, optional base list, colon — with no comptime parameters
and no `where` clauses, so parsing it on sight costs nothing and gives
immediate diagnostics.

The **body** is not resolved. `resolveSignature(StructDeclOp)` refuses at the
top when `objcClass` is set, before anything else runs, and the reason is the
sprint boundary: everything below that point is the *value-type* pipeline —
comptime parameters, a conformance list read as Mojo traits, and the
unconditional injection of `AnyType`, `Deinitable` and `Movable`. None of it
describes a reference type whose layout belongs to the Objective-C runtime.
Sprint 2 gives classes their own path rather than teaching that function to be
two things, and a class body cannot be resolved sensibly before then anyway:
`self`'s type is the registered class, and registration is sprint 2.

The practical consequence, and it is the honest one: **every class declaration
reports `class lowering is not implemented yet`**, because whole-module
translation resolves every top-level decl, so declaring is using. Syntax
errors fire *instead of* that refusal rather than alongside it — a header that
does not parse never reaches signature resolution — which is the property
`class_decl_errors.mojo` exists to pin.

One behaviour deliberately better than `struct`'s: a malformed class header
**recovers** by skipping the body and continuing the file, where a malformed
struct header abandons the rest of the module. The header's extent is
unambiguous, so one bad class need not hide every diagnostic after it. This is
not a nicety — it is what makes the diagnostics testable. Without it the first
bad class in a file swallows every expectation after it, and a test file can
assert exactly one syntax error. (The recovery has to consume a token before
skipping when the current one already sits at the declaration's indentation:
`skipUntilIndentation` stops on the *current* token, so the statement loop
would otherwise make no progress. The codebase already knows this hazard —
`ParserStmts.cpp:680` comments on it.)

The refusal carries a **note naming the parsed superclass and protocols**.
Partly courtesy, mostly necessity: resolution fails, so no IR is printed, and
the note is the only window onto what the header was understood to mean. It is
what `class_decl.mojo` asserts to prove the base list was captured rather than
merely tolerated.

### DECISION REVISED AT SPRINT 2 (2026-08-27): one pipeline, three branches

Sprint 1 said classes would get their own signature path rather than teaching
`resolveSignature` to be two things. Reading the whole function rather than its
first forty lines reversed that, and the design's own refinement is why.

If a class type genuinely *is* a register-passable struct of one pointer — the
conclusion recorded above — then almost all of the value-type pipeline is
already describing it correctly. The injected `AnyType`, `Deinitable` and
`Movable` are true of a reference. `computeSelfTypeForStruct` gives the right
`self`. The canonical trait, the source name, the signature remap: all correct
as they stand. Exactly three things differ, and each is one line:

1. the keyword the re-parse expects (`kw_class`);
2. the parenthesised list — Objective-C names already captured at parse time,
   stepped over by `skipObjCBaseList` rather than resolved as Mojo traits,
   which would report `NSView` as an undefined trait and be a lie about a
   correct line;
3. `TypeConvention::RegisterPassable` instead of `MemoryOnly`.

A parallel path would have duplicated sixty lines to change three. The lesson
is the same one sprint 1 learned about the op: where the design says a class
resembles a struct, the implementation should let it *be* one and mark the
differences, rather than build a second thing that drifts.

**Fields are diagnosed, not deferred.** A class field would resolve without
complaint as an ordinary `StructFieldOp` — and that is the danger, because it
would silently join the *reference's* layout, making `class C: var n: Int` an
Int rather than something pointing at one. Rejecting it until sprint 3 builds
the box costs a diagnostic and prevents a wrong program from compiling.

### DISCOVERED AT SPRINT 2 (2026-08-27): encodings are looked up, not derived — and that reorders the sprints

The design said sprint 2 derives a method's type encoding from its Mojo
signature, and sprint 4 later cross-checks that against the database. Trying it
showed both halves of that to be backwards.

**Derivation cannot work by inspecting Mojo types.** `Int` is not a struct
named `Int`; it is `Scalar[DType.int]`, a SIMD parameterisation, and `Float64`
and the rest are the same. There is no name to match on, the parser layer has
no `DType` plumbing at all, and a mapping written here would be a guess about
exactly the trivia this document says never to guess. The attempt failed on the
most common type in the language, which is a good place to be stopped.

**The database already has the answer, keyed by selector:**

    drawRect:                 v48@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16
    isFlipped                 B16@0:8
    mouseDown:                v24@0:8@16
    outlineView:child:ofItem: @40@0:8@16q24@32
    roastBuild:               <not in database>

Every selector a class overrides or adopts is already there, complete with
argument offsets and the struct expansion nobody wants to write by hand. Only
`roastBuild:` is missing — because we invented it. That is the real shape of
the problem: **overrides and protocol methods are a lookup; novel selectors are
the rare case**, and they are also the easy case, being target/action shapes
like `v@:@`.

So the rule is: look the encoding up by selector; derive only when the database
has never heard of it, and then only from types that have an encoding. That
also relocates the check — there is nothing to cross-check when the database is
the source rather than a second opinion. What sprint 4 keeps is the *live
runtime* as the second opinion, per **Two oracles**.

**This makes sprint 4 a prerequisite of sprint 2, not a follow-on.**
Registration needs encodings, encodings need `cocoakb_selector_encoding`, so
the database work has to land before a class can be registered at all. The
sprint table below is ordered as originally planned; the dependency is the
correction. Selector derivation — which is genuine string work with a real
diagnostic, and needs no database — landed and stands.

### SPRINT 4 (2026-08-27): the SDK answers, and the parser can ask it

The database was already a compile-time oracle, but only for the elaborator:
`CocoaKBDatabase` lived in an anonymous namespace inside
`IREvaluatorContext.cpp`, with a query surface — `selector_encoding`,
`method_encoding`, `superclass`, struct sizes, enum values, POSIX signatures —
whose own comment says `selector_encoding` exists "to type a Mojo-implemented
method when defining an ObjC class at runtime". The intent was there; nothing
could reach it.

It now lives in `KGEN/lib/CocoaKB` beside `CocoaCompletion`, and both the
elaborator and the parser depend on it. Three readers of one file would have
been silly; two are deliberate, and the header says why — one answers point
questions for the compiler, the other prefix questions for the language server,
and they share the file and the configured path, nothing else.

What a class now gets at declaration time:

- **Encodings, looked up.** `method_encoding` walks the superclass chain, so an
  override gets what its superclass actually declares — `drawRect:` comes back
  `v48@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16`, which is the string
  `ide/roast.mojo` writes out by hand today, offsets included.
  `selector_encoding` catches protocol methods. Derivation runs only for a
  selector the SDK has never heard of, meaning we invented it, and then only
  from types with an unambiguous encoding.
- **Framework attribution**, from `bs_classes`, added as a `class_framework`
  query. `class GridView(NSView, …)` records `objcFrameworks = ["AppKit"]`, so
  registration can load AppKit before `objc_getClass("NSView")` returns nil and
  `objc_allocateClassPair` silently builds a root class.
- **A typo catcher.** A superclass the runtime has never heard of is an error at
  the declaration. `class Typo(NSVeiw)` does not fail at runtime; it produces a
  root class and a window that never appears.
- **Disagreement with the SDK.** Where a declared type has an unambiguous
  encoding, it is compared against the SDK's: declaring `tag(self) -> Bool`
  when the SDK says `q`, or `mouseDown_(self, event: Bool)` when it says `@`,
  is a compile error quoting both. Partial on purpose — Mojo's scalars cannot
  be encoded here — and honest about being partial.

**A class no longer compiles without the database**, which is the "declaring is
using" consequence arriving on schedule. The first attempt got this wrong in a
way worth recording: with no database every base came back unknown, so every
class reported `the Objective-C runtime has no class 'NSView'` — blaming
correct code for a configuration problem, which is precisely the shape of the
language server's old "unable to locate module 'std'". `availability()` now
separates "the SDK has no such class" from "there is no SDK metadata here", and
the diagnostic names the path it tried.

### DECISION AT SPRINT 2B (2026-08-27): a class travels in a register, and still retains

The trampoline work stalled on something the design had not noticed, and the
way out was to change the compiler rather than the design.

Objective-C hands a method its receiver by value in x0. Mojo puts a
register-passable type in a register only when it is *trivially* so; a
non-trivial one is passed by reference. A class reference retains on copy, so
it is not trivial, so `self` arrived as `!lit.ref<!TabBar> read_mem` -- and a
trampoline receiving that would read a pointer to the pointer.

The obvious escape was to declare classes trivially register-passable and give
up retain-on-copy. That is what `ObjCObject` already does ("a borrowed id;
ownership arrives in P3"), so it would not have been unprecedented. It would
also have thrown away sprint 6 to buy an afternoon.

Reading the rule showed it was not an ABI rule at all:

    // We can pass trivial register borrowed arguments in a register. We cannot
    // pass non-trivial ones because we cannot diagnose ownership and have
    // other lifetime issues.

The restriction is about **lifetime tracking**, with a FIXME above it saying
borrows of non-trivial register-passable values have no origins. It conflates
two questions that are separate: how a value travels, and what copying it
costs. For a borrowed Objective-C receiver the lifetime concern does not
arise -- the runtime guarantees the receiver outlives the message send, by
construction.

`Signatures.cpp` briefly granted that exception, and porting the IDE revoked
it. With `self` arriving as a register borrow, `self.__objc_id` — a field
projection, which needs an address — hit the same emitter assertion from the
other side: a register borrow of a non-trivial type cannot produce one. The
resolution is the rule MacModula2's cocoa-send notes arrive at from the ABI
end: **registers at the boundary, memory inside**. The C ABI's registers-only
view exists at exactly one place, the synthesized trampoline, which receives
everything by value — the receiver in x0, a CGRect spread over v0–v3 — and
stores each non-trivial value into a local before calling in. The store is the
conversion between the two calling conventions. Inside Mojo, a borrowed class
travels by memory like any non-trivial type, so field projection just works.
`spikes/s5-cocoakb/struct_arg_test.mojo` proves the round trip: a `drawRect:`
sent with `{7, 9, 321, 87}` is seen by the method as exactly those numbers.

Struct **returns** turned out to need no compiler work at all — the fix was a
type declaration. AAPCS returns NSRange in x0/x1 and CGRect (a four-double
HFA) in v0–v3; a Mojo `TrivialRegisterPassable` struct of the same fields
lowers to exactly that, and the trampoline's existing register-result path is
then correct as it stands. What made these look impossible was that every
file declared its own geometry as `Copyable, Movable` — memory-only, a by-ref
result slot, the wrong ABI. Thirteen files did so. `std.objc.geometry` is now
the one copy, declared the way the ABI sees the types, and
`struct_ret_test.mojo` proves both shapes at register level: `selectedRange`
answers `{41, 1759}` and a rect method answers `{11, 22, 1280, 720}`, exactly.
The memory-only-result gate stays, for shapes that genuinely need x8.

One leniency landed with it: the SDK-disagreement check compares ABI classes,
not spellings — `characterIndexForPoint:` returns `Q` where Mojo's `Int` says
`q`, and signedness is a reinterpretation the register file cannot see.

**Sprint 5 is done.** The IDE has no `ObjCClassBuilder`, no `add_method`, no
hand-written encoding, and no `self_: P, cmd: P` anywhere: five classes —
the app delegate, the actions-and-data-source object, the tab bar, the grid
view with the whole NSTextInputClient, and the completion popup — are
declarations, fifty-one selectors, every encoding from the SDK or derived.
The toolbar's item factory is the nice proof of the callback round trip: a
method on a class builds the five toolbar items AppKit asks for, and the
smoke test counts them. What sprint 5 could not yet do is delete the
`named_global` state — fields are sprint 3, the box — or the stdlib's IMP
shapes, which the spikes still use.

A class also gained the one thing it is: a single `__objc_id` field. Until
sprint 2b it was an empty struct -- a type with methods and nowhere for `self`
to live, which is fine while nothing runs and impossible the moment something
does. Author-declared fields still go in the box behind it (sprint 3).

### SPRINT 2B COMPLETE (2026-08-27): a class registers, instantiates and answers

`spikes/s5-cocoakb/class_test.mojo` declares a class, makes one, and lets the
Objective-C runtime dispatch to it. No `ObjCClassBuilder`, no encoding string,
no IMP, no `cmd: P` slot:

```mojo
class Probe(NSObject):
    def isProxy(self) -> Bool:
        return True

    def isEqual_(self, other: Int) -> Bool:
        return other == 0
```

Instantiating it registers the class; `msg_send` reaches both methods; a second
instance finds the class already there. Compare that with the ten
`ObjCClassBuilder` sites and forty-nine hand-written encodings the IDE carries
today.

What the compiler synthesizes per class: an `__init__` that drives
`ObjCClassRegistrar` -- construct with name, superclass and frameworks, adopt
each protocol, add each method, register, instantiate, keep the `id` -- and a
C-ABI trampoline per method that drops the `_cmd` slot and forwards the rest.

Three things learned finishing it, each of which cost something:

- **Synthesizing into a scope you are walking invalidates the walk**, and it
  presents as a segfault rather than a diagnostic. Methods are collected in
  full before any trampoline is built.
- **A trampoline must not be `always_inline`.** It is registered by address, so
  it has to have one. Copying that flag from `synthesizeEmptyDtor` was a
  reflex, and the wrong one.
- **`__init__` returns `out self` by reference, not in a register.** A class is
  register-passable but not *trivially* so, and loading one into an SSA
  register is refused -- correctly, because that load is exactly where a retain
  will have to happen when class references own what they point at.

Registration is idempotent: the registrar looks the class up before building
it, so the second instance costs one `objc_getClass`. Methods whose arguments
Mojo passes in memory are still refused rather than registered wrongly --
Objective-C passes arguments by value, and forwarding a reference would hand
the method a pointer where it expects a value.

### SPRINT 3 (2026-08-27): the box, and why it needs no attribute interception

The runtime half is done and proved: `ObjCClassRegistrar.add_box(size)`
reserves one instance variable, `box_offset(cls)` reads back where the runtime
put it, and `spikes/s5-cocoakb/box_test.mojo` hangs a Mojo struct off two
instances and checks they do not share. One ivar, not one per field, so a
field can be any Mojo type rather than only what Objective-C ivar layout can
describe.

The design question that looked hardest turned out to answer itself. If
author fields live in a box, `self.count` has to resolve to *something*, and
intercepting attribute resolution in `ExprNodes.cpp` is a deep and unpleasant
change. It is not needed. A Mojo method already receives `self` as a **memory
borrow** — `!lit.ref<Class> read_mem`, which is a pointer to storage — so if
the class's `StructDeclOp` simply *holds* the author fields and the trampoline
hands the method a pointer to the box, field access resolves natively. The
class type becomes memory-only, which is what a struct with real fields is
anyway.

So the shape is:

- **The class `StructDeclOp` is the box**: `{__objc_id, …author fields}`,
  memory-only. Methods take a borrow of it and `self.count` and
  `self.__objc_id` both work with no new machinery.
- **The box lives inline in the object.** `class_addIvar` reserves
  `sizeof(Self)` bytes; the box is at `id + offset`, so there is no second
  allocation and nothing to free. The trampoline's conversion is an add, not
  a load.
- **The offset is cached per class** in a `pop.global_alloc` global written by
  `__init__` after registration — the runtime settles the offset when the pair
  is registered, and it does not move.
- **The size is a comptime parameter expression**,
  `#kgen.param.expr<get_sizeof, #kgen.type<Self>>`, which the elaborator
  resolves after layout — the compiler does not need to know the size when it
  synthesizes `__init__`.

Two of the three synthesis steps are written and compile; the third is
blocked on one specific thing, and it is worth recording precisely so the next
attempt starts from knowledge rather than from where this one did.

**Step 2 (caching the offset) and step 3 (the trampoline's conversion) work
out.** The ops needed all exist: `pop.global_alloc` for the per-class slot,
and `lit.ref.to_pointer` → `pop.pointer.bitcast` → `pop.offset` →
`lit.ref.from_pointer` for "this reference, moved along by N bytes". Step 3
also settles the trampoline's receiver: when a class has fields it must take
`self` as a **reference** (`ArgConvention::ReadMem`), because the C ABI passes
a pointer in x0 and that pointer is the `id` — taking it by value would copy a
struct Objective-C never sent.

**Step 1 (`add_box(sizeof(Self))`) is where it stops.** The size has to reach
the runtime as `#kgen.param.expr<get_sizeof, …>`, a comptime expression the
elaborator resolves after layout, and constructing that attribute correctly
from C++ is the open question. What does *not* work, each established by
trying it: `TypeAttr` is not a `TypedAttr`, so `cast`ing one into a
`ParamOperatorAttr` operand asserts; `LITStructAttr` will not wrap an
unresolved parameter expression, so the size cannot be boxed into a Mojo `Int`
that way; and declaring the Mojo side to take a raw `__mlir_type.index`
sidesteps the wrapping but not the attribute construction. The next attempt
should read the elaborator's own `GetSizeOf` handling and copy how it builds
its operands, rather than inferring the shape from call sites as this one did.

Until step 1 lands, class fields stay diagnosed rather than half-working, and
the IDE's state stays in `named_global`. The runtime half is committed and
tested regardless, so the next attempt starts from a proven mechanism and one
attribute.

One wart is already visible and worth stating before it surprises anyone:
`TabBar()` returns the class value, and with the class being the box that is a
*copy* of the freshly constructed state. Reading `.__objc_id` from it is
correct, which is all the IDE does with it; mutating a field through it would
write the copy, not the object. A distinct handle type is what fixes that, and
it belongs with sprint 6's reference work rather than here.

### The test harness had to be built too

`./bazelw test //KGEN/test/mojo-parser:all` cannot build in this tree. All 357
targets depend on `//bazel/mlir-shared:MLIR`, and that dylib does not link:
the toolchain-wide `-fvisibility=hidden` leaves MLIR's C API referencing LLVM
symbols hidden out of the library — the same root cause catalogued in
RELEASE.md, and nothing to do with the parser.

Rather than land compiler changes with no coverage, `tools/check-parser.sh`
reads each test's own RUN line and runs it, substituting what `lit.cfg.py`
substitutes, against `kgen-translate`, `kgen-opt` and `FileCheck` — all of
which build fine. A test whose RUN line still holds an unsubstituted lit
variable is counted as skipped, not passed.

At the end of sprint 1: **331 pass, 1 fail, 25 skipped.** The single failure is
`decls/fn_def_decls_errors.mojo`, which asserts `'fn' has been removed; use
'def' instead` — a diagnostic commit `a694adc` deleted when this fork revived
`fn`. It has been stale since then and is not this sprint's to fix.

## The evidence

The IDE is the fork's first real program: 7,389 lines across `ide/` and
`examples/`. The pure-Mojo files (`rope.mojo`, `png.mojo`, `ifs.mojo`) read
cleanly. Everything else is measurable ceremony at the ObjC boundary:

| pattern | count | of which `class` deletes |
|---|---|---|
| `msg_send[...]` | 379 | the call direction — not this doc |
| `named_global[...]` | 84 | most: state moves into instances |
| `encoding="..."` by hand | 49 | all — derived from signatures |
| `ObjCClassBuilder` rituals | 10 sites | all |
| `comptime IMP*` shapes in the stdlib | 11 | all — trampolines are synthesized |
| dead `try`/unreachable `except` warnings | 50 of 61 | all — method bodies may raise |

And the bugs actually hit while building the IDE map onto the same table: the
outline-view crash was manual autorelease-pool management; the
destructor-on-garbage bug is *why* every global is an `Int` address instead of
an owning reference; the tab bar drew nothing on day one because its state had
to be poked into globals rather than living on the view that draws it.

The connective fact: `ObjCRef` (`std/objc/ownership.mojo:42`) already exists
with a releasing `deinit` — and the IDE could not use it, because the only
place an app-lifetime value can live today is a `named_global`, and globals
are zero-initialised in a way that runs destructors on garbage (the parked
chip). **State needs somewhere to live. Instances are that place.** Cocoa has
been saying so since 1988.

## Two oracles: the dump and the live runtime

Cocoa is not only a database here. It is also a live runtime on the machine
doing the compiling, and — because this fork is Apple-silicon-only and does not
cross-compile — **the compile host is the target**. Whatever the program will
ask `objc_msgSend` at run time can, in principle, be asked right now. Most
compilers see their target platform only through headers; this one has three
views of it, and the design should say which view answers which question.

`cocoa.sqlite` already is this idea, half-executed. Its schema is two sources
side by side: `bs_*` tables from Apple's BridgeSupport XML (the headers as
data) and `rt_*` tables from a dump of a live runtime. They are not redundant,
and the overlap is not the interesting part:

| | knows | count here |
|---|---|---|
| runtime only | class clusters, private and internal classes — why `NSConcreteAttributedString` is findable | **27,764** classes absent from BridgeSupport |
| BridgeSupport only | classes in frameworks that were not loaded when the dump ran | **951** classes absent from the runtime dump |
| BridgeSupport only | enum and constant values — `NSWindowStyleMaskClosable = 2` | **48,775** rows the runtime cannot produce at all |

That middle row is the whole limitation of runtime introspection, made
countable. **The runtime only knows what is loaded.** And the third row is the
limitation that no amount of loading fixes: enum values, C function
signatures, argument names, availability and struct field names are
compile-time facts from headers. `objc_getClass` will never tell anyone that
`Int(15)` means titled|closable|miniaturizable|resizable.

So the rule is an asymmetry, not a hierarchy: **the runtime knows what *is*;
BridgeSupport knows what things *mean*.** Neither is a superset, and they
compose in one particular direction — `bs_classes` carries framework
attribution (`AppKit|NSView`), which is exactly what you need before the
runtime can be asked anything at all. The dump tells you where to look; the
runtime tells you what is there.

### What that changes

**Sprint 2 must load the base's framework before registering.** `class
GridView(NSView)` registers by looking up `objc_getClass("NSView")`, which
returns nil unless AppKit is in the process — and `objc_allocateClassPair`
with a nil superclass cheerfully builds a *root* class that then silently does
nothing. `load_framework`'s own docstring in `std/objc/runtime.mojo` documents
this failure shape and notes it "cost real time". Registration therefore
resolves each base's framework from `bs_classes` and loads it first. This is a
bug we would otherwise have found by watching a window not appear.

**Sprint 4 gets a second, independent arbiter.** The compile-time check stays
the database: hermetic, deterministic, and it fails the build early. But a
debug-build assertion at registration can ask the live runtime the same
question — `class_getInstanceMethod` on the superclass, then
`method_getTypeEncoding` — and catch the one thing the database cannot: that
the dump is stale relative to *this* machine. Two cheap checks that fail
differently.

**The compiler itself should not query the live runtime.** Loading AppKit into
the compiler process runs Apple's `+load` and `+initialize` code inside the
compiler, reaches for the window server, and installs main-thread assertions;
and a build that consults the live runtime stops being reproducible across OS
point releases. The live runtime is an **oracle for validating the dump**, not
a build input — the same posture this fork already takes toward the vendor GPU
kernels it keeps as reference. A `check-cocoakb` that walks the database
against the running system after an OS update is the right shape.

**Roast is a running Cocoa app, and that is worth more than it sounds.** Its
own process has the runtime, and it has already loaded AppKit. Completion can
merge the dump with what is live — catching categories, and classes newer than
the dump. More usefully for the sprints ahead: once sprint 2 registers classes,
Roast can introspect what `objc_allocateClassPair` actually produced — method
list, encodings, protocol conformance — and show it. That is the missing
verification surface for sprints 2 through 5, which otherwise have no visible
artefact at all, because resolution failure means there is no IR to print.

## What it looks like

Today, the tab bar (`ide/roast.mojo`, condensed but real):

```mojo
comptime g_tab_attrs = named_global["roast.tab.attrs", Int]
comptime g_tab_dim = named_global["roast.tab.dim", Int]

fn draw_tabs(self_: P, cmd: P):
    ...
fn tabs_is_flipped(self_: P, cmd: P) -> Bool:
    return True

var tabbuilder = ObjCClassBuilder["NSView"]("RoastTabBar")
tabbuilder.add_method[
    "drawRect:", encoding="v@:{CGRect={CGPoint=dd}{CGSize=dd}}"
](draw_tabs)
tabbuilder.add_method["isFlipped"](tabs_is_flipped)
tabbuilder.add_method["mouseDown:", encoding="v@:@"](tabs_mouse_down)
let tabcls = tabbuilder^.register()
```

Proposed:

```mojo
class RoastTabBar(NSView):
    var attrs: ObjCObject          # was named_global["roast.tab.attrs", Int]
    var dim: ObjCObject            # was named_global["roast.tab.dim", Int]

    def isFlipped(self) -> Bool:
        return True

    def drawRect_(self, dirty: CGRect):
        # encoding v@:{CGRect={CGPoint=dd}{CGSize=dd}} is DERIVED from this
        # signature and CHECKED against what NSView declares in cocoa.sqlite.
        ...

    def mouseDown_(self, event: ObjCObject):
        ...
```

No encoding strings, no `cmd: P`, no IMP shape added to the stdlib, no
globals, and a body that may raise without wrapping itself in a dead `try`.

## The design

### Grammar

```
class Name(Superclass, Protocol, ...):        # bases optional; default NSObject
    var field: Type = initializer             # any Mojo type
    def method_(self, arg: T) -> R: ...       # may raise
    fn strict_(self, arg: T): ...             # fn's contract, unchanged
    @objc("real:selector:")
    def renamed(self, a: T, b: U): ...        # override the derived selector
```

- The **first base names the superclass**: an ObjC class the database knows,
  or another Mojo `class`. Omitted bases mean `NSObject`.
- **Remaining bases are protocols**, adopted via `class_addProtocol` — real
  conformance, because AppKit asks (`conformsToProtocol:` cost us a day on
  NSTextInputClient before this was understood).
- `@objc("...")` on a method overrides the selector spelling; on the class it
  overrides the registered runtime name (collision escape hatch).
- Nested classes, class-level `comptime` parameters, and Mojo-trait
  conformances are **not** in v1. A class is not a struct.

### Selector and encoding derivation

The selector is the method name with `_` → `:`. The number of colons must
equal the number of arguments after `self`; mismatch is a diagnostic naming
both counts. A method with no underscore and no arguments is a nullary
selector (`isFlipped`).

**A leading underscore means the method is Mojo's own and never reaches the
runtime.** This rule was added during sprint 2 and it is doing real work.
Without it, every snake_case helper in a class — and Mojo is a snake_case
language — derives a nonsense selector like `my:helper` and is then rejected
for having a colon it never wanted, which would make a Cocoa class a hostile
place to put a private method. With it, `_tab_width` is simply private, which
is what Mojo and Python already take a leading underscore to mean, and the
dunders come along for free.

What the mismatch diagnostic is really for is the other direction. Writing
`drawRect` where `drawRect_` was meant derives a nullary selector, registers
cleanly, and then never receives a single draw — the framework goes on sending
`drawRect:` to a class that answers `drawRect`. Nothing crashes and nothing
appears. That is a compile error now.

The type encoding is derived from the Mojo signature — the mapping the IMP zoo
encodes by hand today (`ObjCObject`/class refs → `@`, `SEL` slot → `:`,
`Int` → `q`, `Bool` → ObjC BOOL, `Float64` → `d`, structs by member
expansion: `CGRect` → `{CGRect={CGPoint=dd}{CGSize=dd}}`). BOOL's arm64
spelling is verified against the database rather than assumed — the dump is
ground truth for exactly this class of trivia.

**When the selector already exists on the superclass chain** — an override
like `drawRect:` — the elaborator queries `cocoakb_selector_encoding` (the
intrinsic surface catalogued in COCOA_LET_DESIGN.md, `IREvaluator.cpp:190`)
and a mismatch is a **compile error quoting the database's encoding**. A
selector the chain does not know registers with the derived encoding — new
selectors are the point of delegates.

### Fields: one ivar, a boxed Mojo struct

Fields do not become individual ObjC ivars. The class gets **one** hidden ivar
(`class_addIvar`, new to this path — the builder never needed it) holding a
pointer to a synthesized Mojo struct containing every field.

Sprint 1 sharpened what that means in the IR, and the answer is better than
expected. A class is **two** `StructDeclOp`s:

- **the class type** — one field, the `id` pointer; register-passable
  `convention`; `copyInit` retains and the destructor releases. That is not a
  workaround for riding `StructDeclOp`, it is what an Objective-C reference
  *is*, and it is the shape `ObjCRef` (`std/objc/ownership.mojo:42`) already
  has. The representation chosen for parser convenience turns out to be
  semantically right.
- **the box** — a synthesized, memory-only struct holding the declared fields,
  heap-allocated in `init` and destroyed from `dealloc`.

Consequences, each deliberate:

- **Any Mojo type is a field** — `List`, `Rope`, an LSP client — because the
  box is ordinary Mojo memory, not ObjC ivar layout.
- **Real construction and destruction**: a synthesized `init` override
  allocates the box and runs field initializers; a synthesized `dealloc`
  runs `deinit` on the box and frees it, then calls super. Observable,
  testable teardown — the thing `named_global` can never give.
- Every field needs an initializer expression or a `Defaultable` type, the
  same rule surface a struct's synthesized init has.
- `self.field` in a method body loads the box pointer and projects the field.

### Methods and the boundary

- Bodies are `def` and **may raise**. The synthesized trampoline catches at
  the ObjC boundary — unwinding into `objc_msgSend` is undefined behaviour,
  so the boundary reports (hook function; default: NSLog and continue) and
  returns zero-value. This deletes the IDE's 35 dead `try` wrappers and 15
  unreachable `except`s structurally, not by silencing warnings.
- `fn` methods keep `fn`'s strict contract and skip the catch machinery.
- `_cmd` is never written by the author; the trampoline owns that slot.
- `self` is typed as the class. Method calls on `self` dispatch **through the
  runtime** (selector send), not directly — subclassing and KVO stay honest.
  Direct dispatch is a later optimization for provably-final classes, not a
  v1 semantic.
- `ClassName()` registers the class if needed, then `alloc`/`init`. Instances
  convert to `ObjCObject` implicitly — they are one.

### Lowering

Registration lowers to exactly what `ObjCClassBuilder` does today
(`std/objc/classes.mojo:103,114,199,205`): `objc_allocateClassPair`,
`class_addMethod` per method, `class_addProtocol` per protocol,
`objc_registerClassPair` — plus `class_addIvar` for the box, wrapped in a
once-guard and run lazily at first use. The builder itself **stays**, as the
user-level dynamic path; the compiler just stops making people be the builder.

Parser-side, the architecture is already decided by `struct`: declarations
are lazy shells (`parseStructStmt`, `ParserStmts.cpp:3931` — name + recorded
source extent, body deferred until referenced). `parseClassStmt`
(`ParserStmts.cpp:4076`) currently consumes `kw_class`
(`TokenKinds.def:121`), errors, and skips — the shell replaces that error,
and the divergences live in the deferred body path and the elaborator.

### Non-breaking, verified

`class` — and for the record `del`, `global`, `match`, `case`, `nonlocal`,
`yield` — are hard-reserved: using any of them as an identifier is a parse
error in today's compiler (probed 2026-08-27). No program that compiles
contains them, so claiming `class` cannot change the meaning of any existing
code. Within cocoa-mojo, nothing existing is deprecated by v1: `msg_send`,
`ObjCClassBuilder`, and the IMP shapes keep working; the shapes are deleted
only when their last user migrates (sprint 5).

## The sprints

Each lands alone, each is verifiable, each leaves the tree green
(`check-ide.sh`, `check-dist.sh`). Sizes are relative to the `let` revival
(= small).

| # | sprint | size | verified by |
|---|---|---|---|
| 1 | **done** — real grammar behind `parseClassStmt`: name, base list, nesting and parameter diagnostics, recorded on an attributed `StructDeclOp`; elaboration refuses cleanly with a note naming what it parsed. Body resolution deferred to sprint 2 with the registration it depends on. | S–M | `class_decl.mojo` + `class_decl_errors.mojo`; `tools/check-parser.sh` 331 pass / 1 known-stale fail; `structs.mojo` and `traits.mojo` green |
| 2 | **done** — classes resolve to types and register with the runtime: an `__init__` driving `ObjCClassRegistrar`, a C-ABI trampoline per method, selector and SDK encoding per method, protocols adopted. | L | `spikes/s5-cocoakb/class_test.mojo` — declare, instantiate, and let the runtime dispatch to both a nullary and a one-argument method |
| 3 | **Give it state.** `class_addIvar`, the box, synthesized init/dealloc, `self.field`. | M | a test class whose field's `deinit` flips a flag proves teardown; tab-bar and `RoastActions` globals become fields; `check-ide.sh` green |
| 4 | **done** — `CocoaKBDatabase` extracted to `KGEN/lib/CocoaKB` so the parser can ask it; encodings looked up by selector (chain-walking for overrides); framework attribution from `bs_classes`; unknown-superclass typo catcher; SDK-disagreement diagnostic; derivation only for selectors the SDK has never heard of. | M | `class_decl.mojo` checks the SDK's own `drawRect:` encoding and `objcFrameworks = ["AppKit"]`; `class_decl_errors.mojo` covers both disagreement directions and the typo |
| 5 | **done** — every IDE class is a declaration: 51 selectors across five classes, zero builders/encodings/`cmd` slots; the geometry types centralised in `std.objc.geometry` as the ABI sees them; struct args and returns proven at register level. `named_global` state remains until sprint 3's box; the stdlib IMP shapes remain for the spikes. | M–L | `check-ide.sh` 21 checks (toolbar items counted from the factory method); `struct_arg_test` + `struct_ret_test`; 20 cocoa checks |
| 6 | **Nil-aware references.** Smaller than first scoped: once the box is plain Mojo memory (sprint 3) an `ObjCRef` field retains and releases through its own copy/deinit with no special handling, and the class type's own retain/release is sprint 2's `copyInit`. What is left is genuinely new — nil as a first-class state in the pointer's niche, `NSTextView?`, and the zero-init-destructor hazard that currently forces every app-lifetime global to be an `Int`. | S–M | retain-count round-trip tests; the manual `objc_retain` count in `ide/` falls toward zero |

Sprint 1 also settled how the later ones get verified, and it is not cheap.
There is no IR to `FileCheck` until lowering works, so from sprint 2 the
evidence is execution: build the compiler with bazel, run `make-dist.sh`, and
exercise the result through `dist/CocoaMojo` the way `check-ide.sh` already
does. `tools/check-parser.sh` covers the parser half and nothing past it.
Sprint 2 has no partial credit — a half-registered class proves nothing — which
is the real reason it is the large one.

After sprint 5 the next *program* — typed member calls against the database,
COCOA_LET_DESIGN.md Idea 2 — gets its own design document, written with the
benefit of a compiler that already derives and checks encodings.

## Risks, named

- **Struct-isms leaking into classes** — the inverse of the risk this entry
  originally named, and the likelier one. The fear was class-isms escaping into
  struct paths; sprint 1 shipped with `structs.mojo` and `traits.mojo` green, so
  that direction is guarded. The other direction is not: because a class *is* a
  `StructDeclOp`, every consumer that pattern-matches one — LLDB's data layout,
  code completion, signature printing, `PublicASTDecl` — treats a class as a
  value type until told otherwise, silently and plausibly. Each sprint should
  ask which of those it has just made reachable. The `objcClass` flag makes the
  question answerable; nothing makes it automatic.
- **Declaring is using.** Whole-module translation resolves every top-level
  decl, so there is no declared-but-unused state and no lazy escape hatch: from
  sprint 4 on, a class naming a superclass the database does not know is a
  compile error even if nothing ever instantiates it. That is the right
  behaviour — but the database check cannot be opt-in, and a class written
  against an SDK newer than the dump will not compile at all.
- **Class names are process-global.** Registering a name the runtime already
  has fails at runtime; two Mojo files defining the same class collide.
  Diagnose at registration with a message that names the loser; `@objc` on
  the class is the escape.
- **`dealloc` ordering.** The box's `deinit` runs before `[super dealloc]`;
  fields holding ObjC references (sprint 6) release during it. Weak
  references and KVO observers during teardown are the classic haunted house
  — the sprint-3 teardown test exists to walk through it deliberately.
- **BOOL and the long tail of encoding trivia.** Never guess: the database is
  a dump of the actual SDK on the actual architecture, and sprint 4 makes it
  the arbiter — with the live runtime available as the second opinion that
  catches a stale dump. See **Two oracles**.
- **`+initialize`/`+load` are not synthesized** and class methods are absent
  from v1. Both are real; neither is needed by any line of the IDE today.
  They arrive when a user exists, as an extension of sprint 2's machinery.
- **Upstream someday implements `class` differently.** Same stance as `let`:
  this fork's dialect is deliberate; the parser diff is one guarded region,
  and the worst case is a merge conflict in one place, not an unpick.

## What this is not

Not Python classes (no dynamic attributes, no metaclasses, no multiple
implementation inheritance). Not a general reference type (`ArcPointer`
exists). Not the call-syntax program (Idea 2, separate document to come). Not
blocks (`fn`-as-global-block per COCOA_LET_DESIGN.md, capturing blocks later).
