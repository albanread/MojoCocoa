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
equal the number of arguments after `self`; mismatch is a parse-adjacent
diagnostic naming both counts. A method with no underscore and no arguments is
a nullary selector (`isFlipped`).

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
pointer to a synthesized Mojo struct containing every field. Consequences,
each deliberate:

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
| 2 | **Register it, and resolve the body.** Classes get their own signature/body path — no comptime params, bases resolved against the runtime rather than as traits, no injected value-type conformances — then registration + per-method trampolines: selector derivation, encoding derivation, protocol adoption, raise-catch boundary, `ClassName()`. | L | an execution test class round-trips through `msg_send`; **RoastTabBar rewritten** (`drawRect:` exercises struct encodings); `check-ide.sh` green |
| 3 | **Give it state.** `class_addIvar`, the box, synthesized init/dealloc, `self.field`. | M | a test class whose field's `deinit` flips a flag proves teardown; tab-bar and `RoastActions` globals become fields; `check-ide.sh` green |
| 4 | **Check it against the SDK.** Encoding cross-check on inherited selectors via `cocoakb_selector_encoding`; `@objc` honored; BOOL spelling settled from the database; teaching diagnostics. | S–M | negative tests: a wrong `drawRect:` signature is a compile error quoting the database's encoding |
| 5 | **Dogfood.** Migrate the remaining IDE delegates and subclasses (app delegate, outline data source, GridView + NSTextInputClient — the big one); delete migrated `named_global`s and the then-unused IMP shapes. | M–L | all suites green; the counts fall and are asserted: `encoding=` in `ide/` → 0, `named_global` 84 → the survivors are genuinely process-global; the 61-warning chip mostly closes as a side effect |
| 6 | **Owning fields.** `ObjCRef` integration: fields that retain on store and release in `dealloc`; nil-aware reference types begin here and grow into their own design. | M | retain-count round-trip tests; the manual `objc_retain` count in `ide/` falls toward zero |

After sprint 5 the next *program* — typed member calls against the database,
COCOA_LET_DESIGN.md Idea 2 — gets its own design document, written with the
benefit of a compiler that already derives and checks encodings.

## Risks, named

- **The deferred-body parser is shared machinery.** Riding `StructDeclOp`
  risks class-isms leaking into struct paths; a new op risks re-implementing
  resolution. Sprint 1's investigation decides with code, not taste, and the
  struct/trait test suites are the tripwire.
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
  the arbiter.
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
