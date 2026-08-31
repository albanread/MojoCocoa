# Cocoa improvements — phase two: the surface comes from the data

Status: DESIGN, 2026-08-31. Companion to
[COCOA_LET_DESIGN.md](COCOA_LET_DESIGN.md) (the keywords) and
[COCOA_CLASS_DESIGN.md](COCOA_CLASS_DESIGN.md) (`class`); this document is
the program those two left open — the call surface, the constructor, and the
substrate gaps that keep real programs writing assembly idioms. Written after
the 31 August review of phase one, which measured everything quoted below.

The sprints that execute this plan are in
[`cocoa_improvement_sprints.md`](cocoa_improvement_sprints.md).

**Where this sits.** Phase one redirected `let`, `fn` and `class`, and shipped
`std.objc` with the typed call tier. Phase two makes the language read like
the first example in COCOA_LET_DESIGN.md — keyword arguments, construction,
property writes — **without any class being written down by hand**.

## The principle this phase is bound by

**All Cocoa classes are equal, and the surface is data.**

macOS carries roughly 28,814 Objective-C classes. A surface that hand-covers
NSWindow, NSView and forty friends is the MacModula2 bargain — a privileged
front tier over an assembly-language back tier — and this fork rejects it.
Every class reachable from the database is reached the same way, by the same
machinery, with the same checking. The database is the binding generator
(COCOA_LET_DESIGN.md, fact 5); phase two is the rest of that sentence.

### DECISION RECORDED (2026-08-31): tier 1 is rejected

COCOA_LET_DESIGN.md Idea 2 proposed two tiers: **tier 1**, declared wrapper
structs with keyword-only parameters, hand-written one line per method; and
**tier 2**, the generic parameterised surface. Tier 2 shipped
(`std.objc.typed`: `Obj["NSView"](id).setFrameSize(...)`, selector checked,
result typed). Tier 1 is now **rejected, not deferred**: a wrapper struct for
NSWindow is special treatment for NSWindow, and there is no version of it
that scales to the whole SDK without becoming a generated binding — the thing
this fork's whole design exists to avoid. The `objc_init` intrinsic tier 1's
sketch assumed was never built; nothing depends on the route.

What tier 1 was for — keyword names at the call, verified bodies — phase two
delivers generically, through one compiler hook and the database.

## Where phase one stands (measured 2026-08-31)

Working, verified on the shipped `dist/CocoaMojo` compiler:

- `let` — immutable binding; reassignment rejected; teaching diagnostics for
  wrong scope. The dominant binding form in the IDE (644 `let` vs 186 `var`
  in `ide/roast.mojo`).
- `fn` — foreign-callable contract (C ABI, non-raising, no async) with FixIt
  teaching diagnostics; type-position sugar (`comptime IMP0 = fn(P, P, /) -> None`).
- `class` — declaration, registration, boxes, fields, inheritance, `@objc`,
  `@staticmethod`, dealloc lifecycle. Ten-plus classes across `examples/`;
  `RoastGridView(NSView, NSTextInputClient)` in the IDE.
- The typed tier — every selector the database knows, checked as you type,
  results typed by the SDK, class methods included (`Cls`, arity 0–6 both sides).

Still assembly, by count:

| Symptom | Count | Where |
|---|---|---|
| `msg_send[...]` beside typed calls | 51 | `ide/roast.mojo` (against 377 typed calls) |
| `msg_send`-only example files | 7 of 9 GUI examples | incl. `examples/window` — the showcase |
| state parked in `named_global` | 56 / 48 / 43 / 34 | roast / lsp / gridview / dap |
| a retained `NSDictionary` as an `Int` field | 1 | `roast.mojo` `var _attrs: Int` |
| uses of `ObjCRef`, the owning reference | 0 | across `ide/` and `examples/` |

And the front door teaches the wrong tier: guide chapter 1's first program
and all of `examples/window/main.mojo` are `msg_send` with `Int(15)` folklore
style masks, hand-declared geometry duplicating `std.objc.geometry`, and
`named_global` state.

## Facts this design stands on (verified 2026-08-31)

1. **Call-site keyword arguments already work.** Both of these run on the
   shipped compiler:

   ```mojo
   def make_window(*, contentRect: Int, styleMask: Int) -> Int: ...
   print(make_window(styleMask=11, contentRect=4))   # binds, any order
   ```

   The grammar, the ordering rules, and `*`/`**` unpacking are all in
   `ParserExprs.cpp:1109–1274`. Kwargs bind to **declared parameter names**
   of the callee — that is the whole mechanism, and it is why tier 1 was
   attractive and why it is unnecessary: the only missing piece is letting a
   *generic* callee receive the names.

2. **The parametric hooks are asymmetric.** Reads have one: `__getattr_param__`
   (`ExprNodes.cpp:1889`, the mechanism `Obj`/`Cls` already ride). Writes do
   not: assignment resolves plain `__setattr__` only (`ExprNodes.cpp:1941`),
   and a runtime-string setter cannot reach the database, so `win.title = x`
   has no checked path today. Call keyword names have no parametric route at
   all.

3. **String surgery does not fold; SQL does.** Carried from
   COCOA_LET_DESIGN.md's tier-2 build: a Mojo-side `replace('_', ':')` on a
   parameter leaves result types symbolic and collapses the scheme into
   unevaluated conditionals. The name→selector mapping lives in SQLite
   (`cocoakb_p_selector_for`, keyed on class, mojo name, is_class, arity).
   Everything in this design that turns names into selectors goes to SQL by
   the same rule.

4. **The database has argument types, not argument names.** `bs_method_args`
   carries `type64` per argument but no name column, and only 26,168 rows —
   BridgeSupport records the unusual, not everything. So keyword labels
   cannot come from the SDK's headers today. They don't need to: **the
   selector's own parts are the labels** — `initWithContentRect:styleMask:
   backing:defer:` is called with `contentRect=`, `styleMask=`, `backing=`,
   `defer=` — and the reconstruction is exact and mechanical in both
   directions. (Swift's importer renames because Swift wants prettier labels;
   we are not renaming anything. Header-derived labels are a possible future
   database change, noted under risks, not a dependency.)

5. **The remaining `msg_send`s are backlog, not capability gaps.** The 51 in
   `ide/roast.mojo` classify almost entirely as typed-tier-covered calls
   (`setMessageText:`, `objectAtIndex:`, `count`, `addItem:`, `runModal`,
   `sharedApplication` via `Cls`, `alloc`/`init` chains). The tier's one
   self-documented hole is struct returns it cannot name — and even that
   proviso points you to the escape hatch.

6. **The seam is untyped receivers.** `Obj["NSScreen"](someArrayId)` compiles
   — the class is *declared, never checked*, so any `Int` becomes an id and
   the mistake surfaces as a runtime ObjC exception. Found live while probing
   the tier (the probe wrapped the array, not the screen; nothing complained
   until Cocoa did).

7. **The keywords' diagnostics hold.** Re-probed on the shipped compiler:
   `fn ... raises` → the teaching error with a FixIt to `def`; a typo'd
   `class MyView(NSVeiw)` → `the Objective-C runtime has no class 'NSVeiw'`;
   `let` reassignment → `expression must be mutable in assignment`. And the
   `let` trap is confirmed: `let start = i` followed by `i += 1` leaves
   `start` reading the mutated value, silently — Swift's `let` snapshots, and
   three documented incidents (AGENTS.md) say users will write the Swift
   instinct.

8. **Hygiene debts, small and known.** No parser tests cover `let` at all;
   `fn_def_decls_errors.mojo:248` still asserts `'fn' has been removed`;
   `typed.mojo`'s own docstring spells `Cls["NSColor"].blackColor()`, which
   does not compile — the hook needs an instance, `Cls["NSColor"]()`.

## The design

### 1. The kwargs hook: names as parameters at the call

One compiler change, shaped exactly like `__getattr_param__`. When a call
site carries keyword operands and the callee declares the hook, the keyword
**names** arrive as `StringLiteral` parameters in source order and the
values as runtime operands:

```mojo
struct Bound[cls: StringLiteral, name: StringLiteral]:
    def __call_kw_param__[*Parts: StringLiteral](self, *values): ...
```

Opt-in by declaration, no behaviour change for any callee that does not
declare it — the same containment that let `__getattr_param__` ship without
disturbing anything. This is the load-bearing item of phase two: it is what
makes keyword arguments reach the generic surface, where today they can only
bind to names a human wrote down. (Implemented 2026-08-31, sprint P1. The
hook is agnostic to the callee's parameter shape; `std.objc.typed` declares
its overloads with one named `StringLiteral` parameter per label rather than
a `*Parts` pack, which the subscript binding handles without pack indexing.
And the guard is narrower than this sketch: only a struct instance whose
type declares the hook redirects — plain functions, parametric functions
mid-binding, and constructors keep the ordinary path, a distinction the
stdlib's own `_format_int[radix=16](value, prefix=p)` forced.)

### 2. Selector derivation, in SQL, by concatenation

The kwargs analogue of `cocoakb_p_selector_for`: a query keyed on
**(class, the capitalised concatenation of the parts, is_class, arity)**.
The method name is the selector's first part; the kwargs are the rest. The
concatenation happens in SQLite — fact 3 — and the answer is the selector,
its existence, its argument classes, and its typed result, exactly as the
positional tier receives today.

Because the labels *are* the parts, **no rename table ever exists**. A
misspelled label fails the existence check and the diagnostic quotes the
class, the name it built, and near misses from the database — the
"does not exist cannot reach code generation" property, extended to the
keyword spelling. Deliberately absent: Swift-style renaming. The escape for
anything the mechanical rule cannot say is the existing positional
underscore form, which keeps working. `defer` is not a Mojo keyword
(verified in phase one) and the trailing-underscore escape (`for_=` → `for:`)
carries forward unchanged.

### 3. Construction: `alloc` + the init family, generically

(Implemented 2026-08-31, sprint P2. The kwargs `__init__` this section
sketched became a static `__init_kw_param__` on `Obj` — construction has no
self yet, and a static leaves the ordinary `__init__` entirely alone, so
the overload question never arose and the `.make` fallback went unused. A
second constructor form exists beside the initialiser family and the labels
decide between them: a FACTORY is a class method whose selector parts are
the labels verbatim (`NSButton(buttonWithTitle=…)`, one send), checked
before the init form; existence rides `rt_methods` rather than the `@self`
marker, which the ingest records on subclasses more often than on the
defining class.)

`Obj["NSWindow"]` gains a kwargs `__init__` (distinct from the id-taking one
by the presence of keywords): it consults the database's instancetype family
for the initialiser whose parts match the given labels, sends `alloc`, then
that `init...`. The plain spelling is one user-written alias, not library
privilege:

```mojo
comptime NSWindow = Obj["NSWindow"]
let win = NSWindow(
    contentRect=CGRect(CGPoint(200, 200), CGSize(420, 160)),
    styleMask=NSWindowStyleMask.titled | NSWindowStyleMask.closable,
    backing=NSBackingStore.buffered,
    defer=False,
)
```

Every class gets this by the same three lines of machinery; none is written
down anywhere. If overload resolution between the id-`__init__` and the
kwargs-`__init__` proves unpleasant, the fallback spelling is a uniform
`Obj["NSWindow"].make(...)` — decision point inside the sprint, not before
it.

### 4. Property writes: `__setattr_param__`

The symmetric hook fact 2 says is missing. `win.title = "Hello"` looks up
the setter by (class, name, setter-direction) in SQL — `setTitle:` — checks
its argument class, and sends it. Reads already work through
`__getattr_param__`; this closes the pair. What is explicitly **not** offered
is KVC: `win.anything = x` is a selector send the database vouched for or a
compile error, never a stringly-typed runtime lookup.

### 5. Bridging by argument class

The generic call path already knows each argument's ABI class from the
database; it should accept the Mojo value and do the crossing itself:

- `@` arguments accept `String` (the `nsstring(...).ptr()` happens inside);
- `:` arguments accept `StaticString`/`StringLiteral` (the `sel[...]` inside);
- BOOL maps to `Bool`, scalars pass through.

This deletes the `.ptr()` noise that makes even the friendly tier read
pointer-flavoured — uniformly, for every selector, because it is driven by
the same per-argument metadata the checking already consults.

### 6. The `let` aliasing warning

Refined 2026-08-31 after review: a bind-site warning (fire on every
place-shaped right-hand side) would flag many benign bindings — the corpus
has hundreds of `let`s and three incidents. **Warn at the mutation site,
naming the live alias.** A `let` whose right-hand side is a place records
its root (the local, the `self` field, the list the subscript rides on, the
`named_global` behind a generated accessor); an assignment or `__setitem__`
through that root while the binding is in scope warns:

    warning: this write changes what 'start' reads — 'let start' aliases
    'i' from line 14; for a snapshot use `var start = i`

This fires exactly when both ingredients of the trap are present (an alias,
and a later write through its root) and stays silent on every binding whose
source is never touched — the "few issues" property, made structural. All
four documented incidents are caught at the line that causes the surprise,
the write nobody thought of as a write. Known limits, stated: method-based
mutation (`append`) does not fire for slot aliases (it moves no slot);
cross-module global accessors may not resolve to a root and fall uncovered;
scope-visibility stands in for true liveness, refined by "is the binding
used after this point" if that proves noisy. The bind-site warning remains
the fallback if root-tracking proves expensive.

The break-glass end state, only if a release cycle of the warning shows a
deliberate-aliasing population of ~zero: `let x = y` becomes an immutable
**value** under `var`'s existing `ImplicitlyCopyable` gate — scalars and
`String` snapshot for free, a `List` refuses with "use `.copy()` or
`let ref`" — and today's binding semantics survive behind an explicit
`let ref x = y` spelling (the `ref` pattern already works as a statement;
probed 2026-08-31; `let ref` composition is probe-first). That ladder —
`let` value, `let ref` place, `var`, `ref` — is complete and one-way; it
is not taken on speculation. A type-dependent hybrid — copy when
implicitly copyable, bind otherwise — is rejected outright: inside generic
code, `let x = y` would mean different things per instantiation.

### 7. What stays untouched

`msg_send` — the escape hatch, forever, and the ABI escape for struct
returns the tier cannot name. The positional underscore tier — the reach
layer and the machinery the kwargs path delegates to. Class design sprint 6
(ownership: retain/release on class references, nil as a first-class state,
owning fields) — unchanged, referenced, still on the critical path: it is
what retires `var _attrs: Int` and the `named_global` idiom, and no call
surface makes those friendly on its own.

## Migration and enforcement

The pattern that got us here is right for spikes and wrong for the front
door: new work starts at `msg_send` because it is the flexible tier, and the
"raise the level" pass is the one that always slips. Phase two makes the
destination cheap and the regression visible:

1. **The front door migrates first**: `examples/window` and guide chapter 1
   onto the kwargs surface, as the proof and the teaching surface.
2. **A ratchet**: `msg_send` counts under `examples/` and `ide/` recorded in
   the check scripts, failing on growth. Mechanical, heuristic, immediate.
3. **Then the exact lint**: once the kwargs surface covers a selector, the
   compiler can flag a `msg_send` it covers, because both tiers ask the same
   database — the check is exact by construction, not heuristic. This is the
   end state: the escape hatch stays available and the compiler says so out
   loud when you use it where you needn't.

## The sprints

Sizes relative to the `let` revival (= small). Each lands alone and leaves
the tree green (`check-ide.sh`, `check-dist.sh`, `spikes/run-cocoa-checks.sh`).

| # | sprint | size | verified by |
|---|---|---|---|
| P1 | The kwargs hook: `__call_kw_param__` in the elaborator, opt-in by declaration; kwargs overloads on `Obj`/`Cls`/`Bound`; the SQL concatenation query | M | probe programs: a kwargs call round-trips a real selector, a misspelled label is a compile error quoting the class; parser tests for the hook's presence and absence |
| P2 | Construction: kwargs `__init__` on `Obj` (or `.make`), instancetype lookup, `alloc`+`init` | S–M | `NSWindow(contentRect=…)` probe against a live window; second class proves it is not NSWindow-shaped |
| P3 | `__setattr_param__` and the setter query | S | property round-trip: read, write, read back through the runtime |
| P4 | Bridging by argument class: `String`→`@`, `StaticString`→`:`, BOOL | S | the existing tier tests re-run with bridged spellings; `.ptr()` count in examples drops |
| P5 | The `let` aliasing warning; `let` parser tests; fix `fn_def_decls_errors.mojo:248`; fix the `typed.mojo` docstring spelling | S | the AGENTS.md traps each warn; parser suite green |
| P6 | Front-door migration: `examples/window`, guide ch. 1 and 4; the ratchet in the check scripts | S | the ratchet holds; the guide's first program contains no `msg_send` |
| P7 | Class sprint 6, unchanged (parallel track) | S–M | per COCOA_CLASS_DESIGN.md |
| P8 | Optional, last: an `Id`-carrying type so wrong-provenance receivers stop compiling (fact 6) | M | the array-as-screen probe becomes a compile error |

P1 is the gate: everything else is library work on top of it, and if its
overload-resolution proves harder than sized, P2's `.make` fallback keeps
the surface while it is worked.

## Risks, named

- **The hook is the one genuinely new compiler mechanism.** Scoped like
  `__getattr_param__` — opt-in, no global behaviour change — and sized M
  for that reason. The elaborator's call-operand binding is more travelled
  code than attribute lookup; the sprint says probe first.
- **Folding must be tested first, not last.** The conditional-type probe
  pattern (`16 == 16` folds, a query must too) is the canary; if the
  concatenation query does not fold at parameter level, nothing above it
  works, and it is a day-one check in P1, not a P1 exit surprise.
- **No renames is a choice, not an oversight.** The mechanical labels are
  the selector's own parts — exact, queryable, and uglier than Swift's in
  places (`insertRowsAtIndexes(indexes=…)` not `insertRows(at:…)`). The
  positional tier and `msg_send` remain the escape. Header-derived prettier
  labels are a future database change (clang pass over the headers), never a
  compiler one.
- **Construction overload resolution** may prefer adding `.make` over
  fighting `__init__` ambiguity with the id-taking form; the sprint decides
  on evidence.
- **Sprint 6 slipping keeps the `Int`-global idiom idiomatic.** The ratchet
  counts `named_global` alongside `msg_send` for exactly this reason.
- **The database is a build input**, as ever: a class newer than the dump
  will not compile against it. `cocoakb_db_hash` stamping and the
  reinstall-after-OS-update story already carry this; nothing here adds to
  the exposure.

## What this is not

Not per-class wrappers — rejected above, permanently, on the all-equal
principle. Not generated bindings — there is nothing to regenerate when the
SDK moves, because `Obj["NSView"]` is a parameter. Not a deprecation of
`msg_send` or the positional tier — escape hatches, kept. Not KVC. Not the
GPU program — [`improvements_plan.md`](improvements_plan.md) is that. And
not a substitute for class sprint 6: friendly syntax over unowned objects
is friendly spelling on an unfriendly base, and both halves are owed.
