# `let` and keyword selectors: a language design for Cocoa in this fork

Status: DESIGN, 2026-08-26. Nothing here is implemented yet.

**Compatibility stance.** This fork is *cocoa-mojo*, not a compatibility layer
for historical Mojo. Upstream's own churn broke the syntax of the vast
majority of published examples; there is no pristine dialect to defend. We
heal the language where its removals cost us something (`let`, `fn`) — but new
code here is a different dialect, and that is a decision, not an accident.
The migration diagnostics in this document exist to teach, not to promise
compatibility.

## What we have today, and why it is not acceptable

Creating a window in `spikes/playground/p0_window.mojo` currently reads:

```mojo
var NSWindow = ObjCClass.lookup["NSWindow"]()
var win = msg_send[ObjCObject, "NSWindow", "alloc", is_class=True](
    NSWindow.as_object()
)
win = msg_send[
    ObjCObject, "NSWindow", "initWithContentRect:styleMask:backing:defer:",
](win, CGRect(CGPoint(200.0, 200.0), CGSize(420.0, 160.0)),
  Int(15), Int(2), Bool(False))
_ = msg_send[ObjCObject, "NSWindow", "setTitle:"](...)
```

Selector strings are unchecked, argument types are unchecked, `Int(15)` is a
style mask by folklore, and ownership is manual. This is the assembly language
of Cocoa. The design goal is that the same program reads:

```mojo
with autoreleasepool():
    let app = NSApplication.shared()
    let win = NSWindow(
        contentRect=CGRect(CGPoint(200, 200), CGSize(420, 160)),
        styleMask=NSWindowStyleMask.titled | NSWindowStyleMask.closable,
        backing=NSBackingStore.buffered,
        defer=False,
    )
    win.title = "Hello from Mojo"
    win.makeKeyAndOrderFront(None)
```

Anyone who has written Swift AppKit can transliterate. That is the point.

## Facts this design stands on (verified in this tree, 2026-08-26)

1. **`let` is entirely absent from the compiler.** `TokenKinds.def` has no
   `let` token and no removed-keyword diagnostic; nothing in the stdlib,
   kernels or spikes uses `let` as an identifier. Claiming it breaks nothing.
2. **`defer` is not a Mojo keyword**, so NSWindow's infamous `defer:` label
   needs no escaping. For genuine future collisions, a trailing underscore is
   stripped by the mapper (`for_=` -> `for:`), the Python convention.
3. **The ARC object model already exists.** `std/objc/ownership.mojo` has
   `ObjCRef`: +1 on the way in, retains on copy, releases on destroy via ASAP
   destruction, `autoreleasepool` integration. The keyword needs to add
   *syntax and checking*, not semantics.
4. **The language has `**kwargs`** (PythonObject uses it) and **runtime
   `__getattr__`** (`python_object.mojo:440`). It does not, as far as we know,
   have a comptime-parameter `__getattr__[name]`.
5. **The compiler can interrogate the SDK.** `cocoakb_query` is an
   elaborator intrinsic (`IREvaluatorContext.cpp:1139`): comptime code queries
   `CocoaKBDatabase` and receives compile-time constants. The surface already
   answers: selector existence and type encoding
   (`cocoakb_selector_encoding`), argument and return *classes* per selector
   (`cocoakb_selector_arg_classes`, `cocoakb_method_ret_class`), the correct
   msg_send ABI variant (`cocoakb_msgsend_variant` — the stret question),
   class hierarchy (`cocoakb_superclass`), enum values
   (`cocoakb_enum_value`), struct size/align/field offsets, POSIX C signatures
   (`cocoakb_posix_sig`), and a database hash (`cocoakb_db_hash`) for
   reproducibility. **The compiler is already the binding generator.**

## Idea 1: `let` as the Cocoa binding keyword

### The design

`let name = expr` declares an **immutable, scope-bound, owning binding** whose
type must conform to a `Retained` trait (today: `ObjCRef` and the class
wrappers built on it; tomorrow: CoreFoundation handles).

- **Immutable**: reassignment is a compile error. (The *object* is mutable —
  `win.title = ...` is fine. The *binding* is not. Exactly Swift's `let`.)
- **Owning**: +1 at bind; release at scope exit rides the existing ASAP
  destruction. No new lifetime machinery.
- **Trait-gated**: `let x = 5` is an error with a teaching diagnostic:
  *"`let` declares a scope-bound reference-counted binding; for values use
  `var`"*.

### DECISION RECORDED AT IMPLEMENTATION (2026-08-26): general, not trait-gated

The section below argued for gating `let` on a `Retained` trait. When the
keyword was implemented, the opposite was chosen, deliberately:

1. **The machinery decided.** The compiler still contains the complete
   immutable-binding pipeline from the original `let` era —
   `PatternDeclKind::kBind` ("like an 'imm' arg convention"),
   `VarDeclKind::Bind`/`Bound`, and `MBValue` enforcement; the `VarDeclKind`
   enum's own comment still says "declared implicitly by the user via
   non-var/let syntax". `let` maps onto it in a handful of mechanical parser
   changes. A trait gate would have required NEW conformance machinery in the
   elaborator for the sake of rejecting `let n = 42`.
2. **The compatibility stance changed the argument.** Trait-gating was the
   upstream-merge story; this fork has since declared itself cocoa-mojo. With
   that settled, general `let` is the healed language — Swift muscle memory
   included — and `let win = NSWindow(...)` and `let n = 42` both meaning
   "immutable binding" is one rule instead of two.

The ARC behaviour for Cocoa objects is unchanged either way: it lives in
`ObjCRef`, not the keyword. What follows is kept as the original analysis.

### Why trait-gated rather than general (superseded, see above)

Upstream removed general `let` deliberately (two declaration keywords, no
semantic difference). Reintroducing it *generally* re-litigates that decision
and buys only style. Gating it on `Retained` gives the keyword real semantic
content — "this binding manages a foreign reference-counted object" — the same
way `with` is tied to context managers. It is also the honest merge story:
a small, purpose-scoped extension, not a fork of the language's declaration
model.

The cost: Swift users will try `let x = 5` and be told no. The diagnostic must
teach, and if experience shows the restriction is more irritating than
meaningful, widening `let` later is backwards-compatible; narrowing it later
would not be.

### Compiler changes (sized small on purpose)

| # | change | where | size |
|---|---|---|---|
| 1 | `TOK_KEYWORD(let)` | `KGEN/include/KGEN/MojoParser/TokenKinds.def` (beside `TOK_KEYWORD(var)`, line ~157) | 1 line |
| 2 | statement production | `ParserStmts.cpp` — the `Token::kw_var` cases at 119/802/855 gain a sibling that reuses the var path with an `isLet` flag | small |
| 3 | immutability check | decl resolver: reassignment of an `isLet` binding is an error | small |
| 4 | conformance check | elaborator: the declared type must conform to `Retained`, else the teaching diagnostic | small |

`let` **lowers to `var`** plus these checks. No new IR, no new lifetime pass,
no AIR involvement. Keep the productions in one guarded region so upstream
merges conflict in one place.

## Idea 2: Mojo keyword arguments as the selector syntax

### The mapping (Swift's importer, run in reverse)

| Mojo | selector |
|---|---|
| `NSWindow(contentRect=r, styleMask=m, backing=b, defer=d)` | `alloc` + `initWithContentRect:styleMask:backing:defer:` |
| `win.performClose(sender)` | `performClose:` |
| `table.insertRows(at=ix, withAnimation=a)` | `insertRowsAt:withAnimation:` |
| `win.title` / `win.title = v` | `title` / `setTitle:` |

Rules: first keyword is capitalized and prefixed `initWith` for constructors;
subsequent keywords become selector parts verbatim; property get/set by name.
A trailing underscore escapes a Mojo keyword collision and is stripped.

### Where the mapping runs: the library, not the parser

This is the load-bearing decision. The parser should never learn what a
selector is. Two tiers:

**Tier 1 — declared surface, synthesized and VERIFIED bodies (the default).**
No offline generator and no generated files: the wrapper author writes one
declaration line per method with the Mojo-side keyword names —

```mojo
struct NSWindow(ObjCClassWrapper["NSWindow"]):
    def __init__(out self, *, contentRect: CGRect,
                 styleMask: NSWindowStyleMask, backing: NSBackingStore,
                 defer: Bool):
        self = objc_init[
            "initWithContentRect:styleMask:backing:defer:"
        ](contentRect, styleMask, backing, defer)
```

— and everything dangerous in the body is synthesized and checked at comptime
against the cocoakb database:

- the selector is **verified to exist** — a misspelled selector is a compile
  error, not a runtime crash;
- the declared Mojo argument types are checked against
  `cocoakb_selector_arg_classes` and the encoding;
- the msg_send variant is chosen by `cocoakb_msgsend_variant`, which settles
  the struct-return (`frame` -> `CGRect`) hazard mechanically;
- enum arguments come from `cocoakb_enum_value`, so `NSWindowStyleMask.titled`
  is database truth, not a hardcoded `Int(15)`;
- the binary is stamped with `cocoakb_db_hash`, so a result is pinned to the
  SDK snapshot that type-checked it.

The database also carries what a mechanical reverse mapping cannot: Swift maps
`insertRows(at:withAnimation:)` from `insertRowsAtIndexes:withAnimation:` —
renames live in ground truth, and here ground truth is queryable at comptime.
The hand-written part is one line of keyword names per method; the ABI, the
selector, and the types are the compiler's responsibility.

**Tier 2 — dynamic fallback (the long tail).** For selectors with no wrapper:
runtime `__getattr__` (the PythonObject pattern) building the selector string
at run time, object-and-scalar signatures only, struct returns rejected with a
clear error. Exists to keep exploration fluid, not to be the product.

**Phase 3 — and it is already there.** The plan above ended with "a
comptime-parameter `__getattr__[name: StaticString]` hook ... the one
speculative compiler change here. Propose, don't assume."

Checked: **`__getattr_param__` has been in the parser all along**, and it does
exactly this. `ExprNodes.cpp` resolves an attribute reference against
`__getattr_param__` before falling back to `__getattr__`, by the same
mechanism as `__getitem_param__` — which `Tuple` already uses for static
indices. The name arrives as a PARAMETER, so the selector is known at compile
time and everything the database knows about it is available before the
program runs.

The distinction matters and cost an experiment to find. A plain `__getattr__`
takes the name as a runtime `String` (the PythonObject shape), and a runtime
string cannot feed a parameter list — `cocoakb_selector_encoding[name]()`
against it is "cannot use a dynamic value in a parameter list". So the
library route looked closed when the wrong hook was tried, and is wide open
with the right one.

`call_direction_test.mojo` proves the shape end to end:
`Obj["NSString"](...).length()` resolves the selector at compile time, reads
its encoding from the SDK, and sends a real message.

**So the call direction needs no compiler work.** It is library design, which
is where this document always wanted it.

**Return types: the kind, and — after being told to look again — most of the
class too.** Two drafts of this note were wrong in opposite directions. The
first said "return types are not recoverable"; the second corrected that to
"the KIND is recoverable, the CLASS is not, and only the headers have it".

The second was still wrong, and the question that broke it was "the class
returned is returned at runtime as an id, how can we not know the type?"

**The kind** comes from the `@encode` string, and MacModula2 has shipped
exactly this: `q/l/i/s` → INTEGER, `Q/L/I/S` → CARDINAL, `d/f` → REAL,
`B/c/C` → BOOLEAN, structs matched by name to NSRect/NSPoint/NSSize/NSRange.
`method_ret_kind` in CocoaBaseMCP reproduces its answers on every selector
checked.

**The class** is not in a method's encoding — a bare `@`, 48 of 522,170
carry the typed form, and BridgeSupport records only the retvals that are
unusual. That is where both earlier drafts stopped. But it IS in a
**property's** attribute string: `T@"NSTextStorage"`, and a property is read
by a selector, so a getter's return class is simply known. We were ingesting
no properties at all. `rt_properties` (145,196 of them) plus the instancetype
family now answers **88,117 of 160,797** object-returning instance methods,
and `[textView textStorage]` — the example both drafts used to argue it was
impossible — is an `NSTextStorage`.

What remains header-only is the non-property surface:
`stringByAppendingString:`, `objectAtIndex:`. Reading the headers with clang
is the route to those, and it stays a database change rather than a compiler
one.

**That one compiler task is done.** `cocoakb_query` folds at attribute level
now (`KGENAttrs.cpp`), so a database answer is an ordinary compile-time
constant and can choose a type. `method_ret_kind` is derived upstream in
CocoaBaseMCP and reproduces MacModula2's answers exactly, and
`typed_result_test.mojo` types `length` as `Int`, `uppercaseString` as
`ObjCObject` and `isEqualToString:` as `Bool` with no annotation at the call.

One link below the fix mattered and is worth remembering: the class and
selector must reach the query as `!kgen.string` PARAMETERS, taken from
`StringLiteral`'s own parameter. Routed through `_get_kgen_string` instead
they arrive as a `data_to_str` expression, which does not fold at attribute
level and breaks the chain one level under the part that was repaired -- which
is why the first attempt looked like the fix had not worked at all.

What follows was the diagnosis before that, kept because it is the shape of
the problem: A conditional type folds when its condition is a comptime constant --

```mojo
comptime T: AnyType = Bool if 16 == 16 else Int      # folds
comptime T: AnyType = Bool if cocoakb_struct_size["CGSize"]() == 16 else Int
                                                     # does NOT fold
```

-- and does not when the condition is a `cocoakb_query`. The query is a
`#kgen.param.expr` and `ParametricIREvaluator` knows how to evaluate it, but
not early enough to select a type during type checking; the expression stays
symbolic and the error prints the whole unevaluated conditional as the type.
Exposing the queries as aliases rather than `def`s does not help, so it is the
folding and not the wrapper. Until that is fixed, a result's Mojo type has to
be written at the call, which is what `msg_send[Int, "NSString", "length"]`
already does.

So the plan stands, with its two tiers vindicated by a compiler that shipped
them. The receiver's class is DECLARED, never inferred. Object results are
`id` until something says otherwise, and the something is tier 1's typed
surface -- MacModula2 hand-covers 40 classes and lets the rest be `id`, which
is the same bargain this document proposed. Parsing the SDK headers with
clang would recover the classes and make even that unnecessary; it is a
database change rather than a compiler one, and it is the only route to it.

### The same trick covers POSIX

`cocoakb_posix_sig` / `cocoakb_posix_arg_classes` mean `external_call` FFI
declarations can be comptime-verified the same way: a wrapper that declares
`open(path: StringSlice, flags: Int32) -> Int32` and is checked against the
database's C signature turns a silently-wrong FFI prototype — today's classic
crash-later bug — into a compile error. This falls out of the identical
machinery and should ride along in phase 1.

## Idea 3: `fn` as the foreign-callable function

### Where `fn` stands in the compiler (verified 2026-08-26)

Unlike `let`, `fn` was never fully torn out. `TOK_KEYWORD(fn)` is still in
`TokenKinds.def:130`; both the declaration path (`DeclResolution.cpp:1957`)
and the function-type path (`ParserExprs.cpp:1366`) still **parse** it and then
emit "'fn' has been removed; use 'def' instead" with a FixIt — each behind a
"FIXME(26.5): remove entirely". The grammar plumbing is intact. Reviving `fn`
means deleting two error emissions and attaching semantics, which is less work
than `let` needs.

### The problem it solves

Cocoa calls back constantly — target/action, delegates, notification
observers, timers, completion handlers. Today a callback looks like this
(`spikes/playground/p0_window.mojo:67`):

```mojo
def did_finish_launching(self_: P, cmd: P, note: P) abi("C"):
```

Three defects, all silent:

- **Untyped soup.** Every parameter is a raw pointer. `note` is an
  NSNotification and `app` an NSApplication only by comment.
- **The `cmd: P` boilerplate** is the ObjC `_cmd` slot, hand-written into
  every callback and never used.
- **Nothing checks that the Mojo function matches the selector.** The
  *encoding string* handed to `class_addMethod` comes from cocoakb and is
  right; whether the Mojo function actually has that shape is unchecked —
  the function value is cast to a raw pointer. Wrong arity or a raising body
  is a runtime crash, not a diagnostic.

### The design

`fn` declares a **foreign-callable function**: thin (no captures), non-raising,
C ABI, all parameter and return types ABI-classifiable. That is precisely the
contract an ObjC IMP requires, and it is faithful to `fn`'s heritage as the
strict function — narrowed to the boundary where strictness pays.

```mojo
fn did_finish_launching(self: ObjCObject, note: NSNotification):
    print("launched")

var delegate = ObjCClassBuilder["AppDelegate"]()
delegate.method["applicationDidFinishLaunching:"](did_finish_launching)
```

- The `_cmd` slot is not written by the author. Registration wraps the `fn`
  in a comptime-generated thin trampoline that carries `(self, _cmd, args...)`
  and forwards — library-level, no compiler involvement.
- **Registration is verified against the database**: `method[sel](f)` queries
  `cocoakb_method_encoding` for the selector, classifies `f`'s declared
  parameter and return types, and comptime-asserts they match. A misdeclared
  callback is a compile error — the same property the call direction gets.
- Definition-site diagnostics: an `fn` with a capture list, a `raises`, or a
  non-classifiable parameter type errors **at the definition**, not at the
  cast. Today the same mistakes surface as a crash inside Cocoa's event loop.

In type position, `fn(NSNotification) -> None` becomes sugar for today's
`def(...) thin abi("C") -> None` — the `IMP0`/`IMP1` typedefs in
`classes.mojo` read as what they are.

### The `let`/`fn` symmetry

The two revived keywords are the two directions of the same boundary:
**`let` is the foreign object we hold; `fn` is the code the foreign runtime
holds.** Both are trait/contract-gated rather than general, both lower onto
existing machinery (`ObjCRef`; thin `abi("C")` defs), and both put a teaching
diagnostic where a Swift-shaped instinct will first trip.

### Blocks fall out of it

Modern Cocoa wants blocks, and blocks have their own ABI (isa, flags, invoke,
descriptor, copy/dispose helpers). The correspondence that makes this cheap:
**a thin `fn` is exactly a global block** — `_NSConcreteGlobalBlock`, no
captures, so no copy/dispose helpers at all. The library can construct the
static block struct around any `fn` and completion-handler APIs work in phase
1. Capturing closures as heap blocks (with synthesized copy/dispose riding the
existing ClosureEmitter) is real work and explicitly phase 3+.

### Compiler changes for `fn`

| # | change | where | size |
|---|---|---|---|
| 1 | delete the two "removed" errors, attach semantics: thin + `abi("C")` + non-raising | `DeclResolution.cpp:1957`, `ParserExprs.cpp:1366` | small |
| 2 | definition-site diagnostics (capture list, raises, unclassifiable type) | decl resolver | small |
| 3 | migration diagnostic: an `fn` that *would have been* legacy-valid but breaks the new contract gets "fn is foreign-callable; use def", not a bare error | same place | tiny |

Change 3 exists because old-Mojo `fn` was a general strict function; code from
that era (e.g. `fn main() raises`) must get a teaching message, not a
contract violation.

## Phasing

1. **Phase 1 — no compiler change.** Curated one-line-per-method wrappers for
   the demo surface (NSApplication, NSWindow, NSView, NSString, NSTimer…),
   bodies synthesized and verified through cocoakb at comptime; POSIX-checked
   `external_call` and the verified `method[sel](f)` registration path (over
   plain `def ... abi("C")`) ride along. `var` bindings. Proves the object
   model, the keyword mapping, and the callback contract.
2. **Phase 2 — the keywords.** `let` (four small changes) and `fn` (three,
   mostly deleting errors). Demo programs switch over; callbacks lose their
   `cmd: P` boilerplate and gain definition-site checking.
3. **Phase 3 — comptime `__getattr__`** if the long tail justifies it, and
   capturing closures as heap blocks if the API surface demands them.

Ship syntax after the object model is proven, not before.

## Risks, stated plainly

- **Upstream reuses `let` later with different semantics.** Mitigation: our
  `let` is one guarded parser region lowering to `var`; worst case is a
  rename, not an unpick.
- **The reverse mapping is not total** (ObjC renames). Mitigation: tier 1
  declarations carry true selectors, comptime-verified against the database;
  the mechanical rule is only the fallback's guess.
- **The database is a build input.** Its coverage bounds what compiles, and a
  stale database mis-verifies against a newer SDK. `cocoakb_db_hash` in every
  artefact makes the pairing auditable; the check gates already exist in
  `run-cocoa-checks.sh`.
- **Dynamic tier ABI holes** (struct returns, va-args). Mitigation: reject at
  the boundary, loudly.
- **This fork is not the only Mac fork.** MojoMacX64 (Vega II) shares the OS;
  the whole `std.objc` layer plus this design should remain cherry-pickable —
  another reason the parser diff stays minimal and guarded.


## `let` binds; it does not copy

Found while writing the editor's lexer, and worth stating plainly because the
failure is silent.

```mojo
var i = 0
let start = i          # binds to i, not a snapshot of it
while ...:
    i += 1
# start is now whatever i is
```

That is the revived binding behaving exactly as designed -- an immutable
binding to a place, which is what `PatternDeclKind::kBind` means -- and it is a
trap wherever the intent was to remember a value before changing the original.
The lexer's keyword span came out empty because `start` followed `i` to the end
of the word, so `while k < i` never ran and no character was ever marked.
Nothing warned, and the code reads correctly.

Use `var` where a copy is meant. `let` on an expression (`let end = i + 1`) is
a value and has no such hazard; only `let x = <another binding>` aliases.
