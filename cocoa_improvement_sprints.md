# Cocoa improvements — sprints

Execution order for [`cocoa_improvements_design.md`](cocoa_improvements_design.md).
Each sprint carries its own verification; nothing lands without the checks it
names. Numbering is P1–P8, matching the design doc, so it can never collide
with `COCOA_CLASS_DESIGN.md`'s own sprint numbers (its sprint 6 is P7 here).

**Ordering.** P1 is the gate for the surface sprints (P2–P4 are library and
SQL work on top of its hook). P3 touches a different resolution path and can
run beside P1 if there are two pairs of hands. P5 is independent of all of
it and can land any time. P6 wants P1–P4 done. P7 is the parallel track the
class design already owns. P8 is last and optional.

**The loop for compiler-touching sprints** (P1, P3, P5), per
COCOA_CLASS_DESIGN.md: build the compiler with `./bazelw`, stage with
`tools/make-dist.sh`, and probe through `dist/CocoaMojo` — a probe that runs
against the previous compiler proves nothing. Parser-level changes also ride
`tools/check-parser.sh`, which substitutes what `lit.cfg.py` would.

## Sprint P1 — the kwargs hook (IMPLEMENTED 2026-08-31)

The load-bearing compiler change: call-site keyword names arriving as
parameters, so a *generic* callee can know them. Everything else in the
surface program is library work above this.

**Status.** Landed end to end. `win.setFrame(aRect, display=True)` sends
`setFrame:display:` through the real runtime to a real window; the class
side (`+dictionaryWithObject:forKey:`) and two labels
(`initWithTitle:action:keyEquivalent:`) both work; a misspelled label is a
compile error naming the class, the method and the label. The folding canary
passed first, exactly as ordered: a type chosen by a keyword-form query
folds (`Bool`), so the whole scheme above the SQL was worth building.
Verification: `kwargs_call_test.mojo` and `must_fail_kwarg_label.mojo` in
`spikes/run-cocoa-checks.sh` (34 passed, 0 failed);
`KGEN/test/mojo-parser/exprs/call_kw_param_hook.mojo` pins the language
mechanism DB-free (`tools/check-parser.sh` 332 pass / 1 known-stale fail);
`tools/check-ide.sh` green except two DAP checks that failed the same way
before this change (debugger variables timing out; a flake, not a
regression — nothing here touches the DAP path).

Three things the implementation taught, recorded so the next sprints start
from them:

1. **The hook's guard is narrower than the design sketch.** Only a struct
   INSTANCE whose type declares `__call_kw_param__` redirects. A plain
   function, a parametric function mid-binding
   (`_format_int[radix=16](value, prefix=p)`), and a constructor must keep
   the ordinary path — the first full-dist build caught the loose version
   breaking stdlib formatting, because a keyword-carrying call onto a
   parameter-bound function is everywhere in the stdlib and all of it is
   legitimate.
2. **The diagnostic is the selector query's refusal**, not the kind assert:
   `the Cocoa metadata has no 'selector_for_parts_1' for NSWindow,
   setFrame, 0, diplay` — the same failure shape the positional tier has,
   with the label in the sentence. The kind asserts stay as belt-and-braces.
3. **The first selector part is the method name and its argument is
   positional, decided.** A PyObjC-style first-part keyword would have no
   meaning in this scheme — the query keys on `name || ':' || parts`, so
   there is nothing a first label could match. The sprint's open question is
   closed by the shape of the query.

One process note that cost a confusing hour: building
`//KGEN/tools/mojo:mojo` does not rebuild `kgen-translate`/`kgen-opt`, and a
stale `kgen-translate` silently lacks new elaborator behaviour — build the
test tools too before believing `check-parser.sh` against a compiler change.

The original task list, for the record:

1. **The SQL query first, because it is cheap and it can kill the sprint.**
   The kwargs analogue of `cocoakb_p_selector_for`, keyed on (class, the
   capitalised concatenation of the parts, is_class, arity). Concatenation
   happens in SQLite — string surgery does not fold (design fact 3). The
   query also feeds the misspelling diagnostic, so it should answer near
   misses, not just existence.
2. **The folding canary, day one, not at exit.** The conditional-type probe
   pattern: a type chosen by `Bool if <kwargs query> == <expected> else Int`
   must fold at parameter level, exactly where `16 == 16` folds. The
   positional tier's build history says the failure mode here is a chain
   that looks repaired one level under where it broke. If the query does not
   fold, stop and fix the query before building the hook.
3. **The hook in the elaborator.** When a call site carries keyword operands
   and the callee declares `__call_kw_param__`, the names arrive as
   `StringLiteral` parameters in source order and the values as runtime
   operands. Opt-in by declaration, zero behaviour change for any callee
   that does not declare it — the containment that let `__getattr_param__`
   (`ExprNodes.cpp:1889`) ship without disturbing anything. Probe the
   elaborator's call-operand binding before committing to the shape; it is
   more travelled code than attribute lookup.
4. **The stdlib half.** Kwargs overloads on `Obj`/`Cls`/`Bound` in
   `std.objc.typed`, mirroring the arity 0–6 pattern of the positional tier,
   with the same diagnostic voice: a misspelled label names the class, the
   selector it built, and the near misses. Decide in-sprint whether the
   first selector part may also be passed as a keyword (PyObjC allows it;
   symmetric is the recommendation, and the query keys on the concatenation
   either way).
5. **Parser tests for the hook**, present and absent — a callee without the
   hook and kwargs in the call is today's error, unchanged.

## Sprint P2 — construction (NOT STARTED, size S–M)

1. Kwargs `__init__` on `Obj`, distinct from the id-taking form by the
   presence of keywords: consult the instancetype family for the
   initialiser whose parts match the given labels, send `alloc`, then that
   `init...`. If overload resolution between the two `__init__`s proves
   unpleasant, take the `.make(...)` fallback spelling and record why — the
   decision is evidence's, made inside the sprint, not before it.
2. The plain spelling is a user-written alias, not library privilege:
   `comptime NSWindow = Obj["NSWindow"]` then
   `NSWindow(contentRect=…, styleMask=…, …)`. Document it in the guide the
   moment it works; it is three lines any user can write for any class.
3. The negative case: labels that match no initialiser in the family are a
   compile error naming what was tried and what the class does declare.

Verification: the `NSWindow(contentRect=…)` probe produces a live window;
**a second class** — `NSButton(buttonWithTitle=…, target=…, action=…)` or
`NSTextField(labelWithString=…)` — proves the machinery is not
NSWindow-shaped; the no-match error fires on a deliberately wrong label.

## Sprint P3 — `__setattr_param__`, property writes (NOT STARTED, size S)

1. The hook, symmetric with `__getattr_param__`: assignment resolution
   (`ExprNodes.cpp:1941`) consults a parametric setter so the name reaches
   the database as a parameter. Without it `win.title = x` has no checked
   path — a runtime-string `__setattr__` cannot reach `cocoakb`.
2. The setter query: by (class, name, setter-direction) — `title` →
   `setTitle:` — with the argument class checked exactly as calls are.
3. **No KVC, ever, in this path**: `win.anything = x` is a selector the
   database vouched for or a compile error. The design says so; a test pins
   it — an unknown name must not fall back to a stringly-typed runtime
   lookup.

Verification: a property round-trip (read, write, read back) through the
runtime, in the `spikes/s5-cocoakb` style; an unknown property name is a
compile error; reads keep working unchanged through `__getattr_param__`.

## Sprint P4 — bridging by argument class (NOT STARTED, size S)

1. The generic call path already knows each argument's ABI class from the
   database; it should accept the Mojo value and do the crossing itself:
   `@` arguments accept `String` (the `nsstring(...).ptr()` happens inside),
   `:` arguments accept `StaticString`/`StringLiteral` (the `sel[...]`
   inside), BOOL maps to `Bool`, scalars pass through.
2. Explicit `ObjCObject`/`Obj[...]` passing stays untouched — bridging is an
   additional accepted shape, not a replacement.
3. Bridging is driven by the DB argument class, never by sniffing the Mojo
   type: a `String` offered where the database says `q` remains a type
   error.

Verification: the existing tier tests re-run with bridged spellings; the
`nsstring(` and `.ptr()` counts under `examples/` and `ide/` drop (the
ratchet in P6 starts counting after this lands); the `String`-where-`q`
error fires.

## Sprint P5 — the `let` warning, and hygiene (NOT STARTED, size S)

1. **Root-place tracking at bind.** A `let` whose right-hand side is a place
   records its root: the local, the `self` field, the list a subscript rides
   on, the `named_global` behind a generated accessor. A value right-hand
   side records nothing. The root pointer lives on the `kBind` decl — no
   semantics change anywhere, so none of the copy route's blast radius on
   `for`-loop induction variables (`ParserStmts.cpp:1746`) and destructuring.
2. **The warning at the mutation site, naming the live alias.** An
   assignment or `__setitem__` through a matched root while the binding is
   in scope warns: "this write changes what 'start' reads — 'let start'
   aliases 'i' from line N; for a snapshot use `var start = i`". Fires only
   when both ingredients of the trap are present (an alias, and a later
   write through its root); every binding whose source is never touched
   stays silent.
3. Accepted limits, documented in the diagnostic's own tests: `append` does
   not fire for slot aliases (it moves no slot); cross-module global
   accessors may not resolve to a root; scope-visibility stands in for
   liveness — refine by "is the binding used after this point" if noisy.
4. **`let` parser tests** — none exist today; the keyword's entire coverage
   gap.
5. Fix `fn_def_decls_errors.mojo:248,252` — still asserting
   `'fn' has been removed`, stale since the revival.
6. Fix the `typed.mojo` docstring: `Cls["NSColor"].blackColor()` does not
   compile; the hook needs an instance, `Cls["NSColor"]()`.

Verification: each of the four documented traps (flag, status line, Othello's
mouse, insertion sort) warns at the write, as four small test files;
benign shapes — `let win = NSWindow(...)`, `let n = i + 1`, an unmutated
source — stay silent; `tools/check-parser.sh` green.

## Sprint P6 — the front door (NOT STARTED, size S)

1. `examples/window` onto the kwargs surface: the folklore `Int(15)` style
   mask replaced by database-backed names, the hand-declared geometry
   replaced by `std.objc.geometry` (which exists to be the one copy), the
   calls in the kwargs spelling. State that P7 would let move into fields
   stays in globals until P7 permits it — the migration is the call surface,
   not the lifecycle.
2. Guide chapters 1 and 4 rewritten onto the same surface: the first Cocoa
   program a user reads contains no `msg_send`.
3. **The ratchet**: `msg_send` and `named_global` counts under `examples/`
   and `ide/` baselined into `tools/check-ide.sh` / `tools/check-dist.sh`,
   failing on growth. Heuristic until the exact lint exists; it exists to
   make regression visible, not to be clever.

Verification: the ratchet holds on a clean tree and trips on a deliberately
added `msg_send`; `tools/check-ide.sh` green with the migrated example; the
guide's first program builds and runs as written.

## Sprint P7 — ownership, class design sprint 6 (PARALLEL, per COCOA_CLASS_DESIGN.md)

Unchanged, and still the critical path for "friendly": retain/release on
class references (copy-init retains, deinit releases), nil as a first-class
state, owning fields. It is what retires `roast.mojo`'s
`var _attrs: Int # a retained NSDictionary` and the `named_global`
integer-address idiom, and no call surface makes those friendly on its own.
Verified per that document: retain-count round-trips, the manual
`objc_retain` count in `ide/` falling toward zero, the dealloc measurement
(200k objects created and released, `maxrss` flat).

## Sprint P8 — id provenance (OPTIONAL, LAST, size M)

The 31 August probe is the test: `Obj["NSScreen"](screens.addr())` — an
array id wrapped as a screen — compiles today and dies in the runtime's
exception handler. An id-carrying type at the `Obj[...]` boundary makes the
wrong-provenance receiver a compile error while `msg_send` (the escape
hatch) stays deliberately raw. Sized last because the wrapper surface built
by P1–P4 determines what the type needs to carry.

Verification: the probe above rejected at compile time; every legitimate id
flow in `ide/` and `examples/` (`box_ref`, trampolines, `.addr()` handoffs)
still compiles.

## Standing verification commands

```bash
./spikes/run-cocoa-checks.sh        # the cocoa surface (9 checks at last count)
tools/check-parser.sh               # parser suite; 331-pass class-era baseline
tools/check-ide.sh                  # the IDE's own checks
tools/check-dist.sh                 # staged dist coherence
tools/make-dist.sh                  # stage before probing any compiler change

# probes, after make-dist:
dist/CocoaMojo/bin/cocoamojo --run <probe>.mojo
```
