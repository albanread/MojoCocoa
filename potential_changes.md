# Potential changes

Language and compiler ideas that are worth doing but are **not** being done
now, each with enough evidence to pick it up cold and enough context to know
why it was put down.

A thing lands here rather than in COCOA_CLASS_DESIGN.md when it is a real
proposal that has been costed, not a sketch — and when the reason for waiting
is a judgement about ordering rather than a doubt about the idea.

---

## `global` as a keyword

**Status:** filed, not scheduled. Counter to the current direction — see
"Why not now".

### The idea

`global` is a reserved word cocoa-mojo does not use. `TokenKinds.def:135`
declares it; the only reference in the whole compiler is `Lexer.cpp:89`, where
it sits in a list of statement keywords and is never consumed. Meanwhile a
module-level `var` is rejected with

> global variables are not supported; move this into a function body or use
> 'comptime'

so the slot is empty and the need is already admitted in a diagnostic.

Today a process-wide variable is spelled:

```mojo
comptime g_caret = named_global["roast.caret", Int]
...
g_caret()[] = offset_at_point(local.x, local.y)
```

The proposal is:

```mojo
global caret: Int
...
caret = offset_at_point(local.x, local.y)
```

`global x: T` at module scope would desugar to exactly what `named_global`
emits now — a KGEN global, zero-initialised, deduped by symbol name — so the
semantics are already built and tested. This is parser work plus one decision
about symbol naming.

### The evidence

Counted across `ide/` at the time of filing:

| | |
|---|---|
| declarations | 88 |
| touch sites (`g_x()[]`) | 538 |
| globals shared between two sites by string | **0** |

The `()[]` is a call plus a subscript to touch a variable, 538 times. The name
is written twice — once as the alias, once as the string key — and the two
must be kept in sync by hand.

The string key earns nothing. Its only purpose is letting two sites share one
storage location by agreeing on a name, and no string is declared twice
anywhere in `ide/` or `examples/`. So it is ceremony carrying a silent-wrong
failure mode in both directions: two globals that accidentally agree on a
string quietly become one variable, and a typo quietly makes two.

### Why not now

**It is comfortable in exactly the wrong place.** Class fields work now — the
box, its initializers, and its destruction all landed — and the direction of
travel is state moving OUT of process globals and INTO the objects that own
it. `gridview.mojo` alone has 36 globals, and most of them are editor state
(caret, selection, buffer, font metrics) that belongs on `RoastGridView`. The
tab-bar migration showed the shape of it.

Making the current pattern pleasant is a good way to ensure nobody ever leaves
it. The 538 call sites are an argument for the keyword and equally an argument
that this state is in the wrong place: a field would remove the ceremony too,
and remove the global.

### If it is picked up

Scope it narrowly: the genuinely process-wide singletons — one app, one
window, one shared action target — and leave per-object state migrating to
fields. If it also makes the remaining `Int` globals pleasant, that is a
bonus, not the goal.

Design notes that were settled while costing it:

- **It is not Python's `global`.** In Python, `global x` inside a function
  declares intent to rebind a module-level binding; here it would be a
  DEFINITION at module scope. The divergence is unavoidable rather than
  chosen: Mojo has no module-level variables at all, so Python's meaning has
  nothing to refer to. The word is free in practice, not only in the token
  table. Same trade already made with `class`.
- **No initializers in v1.** `global x: Int = 5` needs a run-once initializer,
  which is a separate problem (the same one field initializers had, at process
  scope). Refusing it keeps the semantics identical to `named_global` and
  honest about it.
- **Zero must remain a valid value.** 25 of the 88 hold a `List[...]`:
  zero-initialised, never destroyed. That is the rule the box's ground state
  used to carry, and it would carry over unchanged — it belongs in the
  keyword's documentation rather than in folklore.
- **Sharing becomes an import** rather than a matching string, and the symbol
  should be module-qualified and derived, so a collision becomes impossible
  instead of silent. Nothing currently depends on the string-matching route.
- **Threading is unchanged**: no locking, exactly as today.

### Related

- The other free Python keywords noted at the same time: `del`, `match`,
  `case`, `nonlocal`, `yield`. `class` was the first one spent, on
  COCOA_CLASS_DESIGN.md.
- The field migration this defers to: COCOA_CLASS_DESIGN.md, "the box".
