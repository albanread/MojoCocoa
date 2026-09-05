# Patches to the standard library

Every change this fork makes to Modular's standard library, so that a future
sync knows what to carry forward and why. A patch that only exists as a diff
is a patch someone re-applies blindly or drops silently.

**Write an entry when you change anything under `mojo/stdlib/`.** Say what
was wrong, not just what changed — the reasoning is the part a merge conflict
destroys.

The staged copies are downstream of this tree and are not edited by hand:

    mojo/stdlib/std/…                      the source of truth
    dist/CocoaMojo/lib/mojo/stdlib/…       staged by tools/make-dist.sh
    ~/Library/Application Support/Roast/…  the editable copy Roast installs

Changing one of the copies and not this tree means the next `make-dist.sh`
throws the change away.

---

## 2026-08-31 — the keyword-argument call surface (`std.objc.typed`, `std.sys._cocoakb`)

**Files:** `std/objc/typed.mojo`, `std/sys/_cocoakb.mojo`

**What and why.** Sprints P1, P2 and P4 of
`cocoa_improvements_design.md`: the call direction grew its keyword form,
for calls and for construction, and its argument-kind guard.
`win.setFrame(aRect, display=True)` now means `setFrame:display:`, and
`NSWindow(contentRect=..., styleMask=...)` constructs a window — the labels
are the selector's trailing parts (or, for construction, name an initialiser
or a factory class method), assembled into selectors INSIDE the SQL
(`?2 || ':' || ?4 || ':'`; `'initWith' || upper(substr(?2,1,1)) ||
substr(?2,2) || ...`), because joining them in Mojo would be string surgery,
which does not fold, and a result type conditioned on it would stay
symbolic. Three queries per label count for calls (selector, kind, class)
and two for construction (form, selector), five label counts, mirroring the
name-keyed tier; `Bound`/`BoundClass` gained `__call_kw_param__` overloads
and `Obj` gained static `__init_kw_param__` overloads, both re-dispatched to
by the compiler's new call hooks (names as StringLiteral parameters, values
positional). Verified by `spikes/s5-cocoakb/kwargs_call_test.mojo` and
`kwargs_init_test.mojo` (fold canary, instance/class/two-label calls,
init-form and factory-form construction against live objects) plus
`must_fail_kwarg_label.mojo`, `must_fail_kwarg_init.mojo` and
`must_fail_kwarg_string.mojo` (a bad label of either kind, or a String
argument where the selector's `@encode` kind says it cannot cross, is a
compile error naming the class and the labels).

Sprint P3 added property writes (`__setattr_param__` on `Obj`: the setter
a plain name means, assembled and verified in SQL; a read-only property is
a compile error). Sprint P4 added the argument kinds: the compiler parses each method's
`@encode` string (in `CocoaKBDatabase.cpp`, beside the SQL, because Mojo
cannot -- string surgery does not fold) and packs one kind character per
argument into an integer, seven bits each, so comptime shifts decompose
them. A `String` argument is refused where it cannot legally cross — and where
the selector DOES take an object, the keyword hooks bridge it
compiler-side (`__bridge_string` in typed.mojo, resolved from the hooks'
own module scope), so bare Strings cross on the keyword and construction
surface without the narrowing the language does not yet have.

**Carry forward:** yes — this is the fork's own surface, like the rest of
`std.objc`. On an upstream sync, the whole file moves aside rather than
merging.

---

## 2026-08-30 — `String._realloc_mutable` doubled on every copy-on-write

**File:** `std/collections/string/string.mojo`

**Symptom.** Roast died stepping the debugger:

    ABORT: std/memory/alloc.mojo: alloc failed: returned a null pointer

with the process's memory **flat** the whole way — 118 MB, never climbing.

**Cause.** `_realloc_mutable` grew with `max(capacity, capacity_bytes() * 2)`.
Doubling is an *append* heuristic: it buys amortised O(1) growth for a
string being built up. But this function is also how a **shared** string is
made unique — `_unsafe_mutable_ptr` calls it with the capacity the string
already has whenever `_is_unique()` is false:

```mojo
var new_cap = max(self.capacity_bytes(), capacity)
elif not self._is_unique() or new_cap > self.capacity_bytes():
    self._realloc_mutable(new_cap)
```

So every copy-on-write doubled a buffer that did not need to grow. The
diagnostic, with the content length beside it:

    want= 18874368   capacity= 9437184    cap_bytes= 9437184    byte_len= 4288
    want= 37748736   capacity= 18874368   cap_bytes= 18874368   byte_len= 4998
    want= 75497472   capacity= 37748736   cap_bytes= 37748736   byte_len= 5025
    want= 603979776  capacity= 301989888  cap_bytes= 301989888  byte_len= 6457

Five kilobytes of content, a capacity walking to 600 MB. Memory stayed flat
because each step frees the buffer before it, which is why this looked like
one absurd request rather than a runaway — it was the last doubling in a
chain.

**Patch.** Double only when the request actually exceeds the current
capacity. Otherwise honour it as given: a copy needs the size it has.

**Carry forward:** yes, and check upstream first — if this is fixed there,
take theirs.

---

## 2026-08-30 — `String._realloc_mutable` asked the allocator for zero bytes

**File:** `std/collections/string/string.mojo`

**Symptom.** A trap with a message that names the wrong culprit:

    alloc: `Layout.count()` must be > 0

**Cause.** The growth arithmetic was

```mojo
var new_capacity = (max(capacity, self.capacity_bytes() * 2) + 7) >> 3
var new_ptr = self._alloc(new_capacity << 3)
```

An empty inline `String` has `capacity_bytes() == 0`, so growing one by
nothing computes `(0 + 7) >> 3 == 0` and asks `alloc` for a zero-sized
layout. The allocator refuses — correctly — but the message describes the
allocator rather than the `String` that asked it for nothing.

**Patch.** Two changes, and deliberately not one:

- `new_capacity` is clamped to at least one unit, so the benign zero case
  allocates the smallest thing worth owning instead of trapping.
- A capacity that cannot hold the live length still aborts, now with a
  message that says the caller passed something that is not a size.

The second half is why this is not a blind clamp. Clamping a bad size would
allocate something small and then `memcpy` the old length into it, turning a
loud trap into silent heap corruption. A benign zero deserves a buffer; a
nonsense size deserves an abort that names itself.

**Carry forward:** yes. Neither half depends on anything else in this fork.

---

## 2026-09-01 — the property-write bridge and the shared `__bridge_string`

**Files:** `std/objc/typed.mojo` (unchanged this time — the change is the
compiler's, but the effect is stdlib surface): bare Strings now cross in
positional calls (`win.setTitle("Hello")`) and property writes
(`win.title = "Hello"`), not only keyword calls and constructions. The
`__bridge_string` helper in typed.mojo is now consulted by all three call
arms and the assign arm; the guard in the positional tier is unchanged and
still refuses a String where the selector takes a non-object.

**Carry forward:** yes, with the rest of `std.objc`.

---

## 2026-09-01 — `nsenum`: enum values by their SDK names

**Files:** `std/objc/foundation.mojo`, `std/objc/__init__.mojo`

**What and why.** Sprint P6: the folklore integer leaves the examples.
`nsenum["NSWindowStyleMaskTitled"]()` answers 1 from BridgeSupport, a name
the metadata does not know is a compile error naming it -- the same
property every other call into the database has. The query
(`cocoakb_enum_value`) already existed; this is the public wrapper, and the
function-local import keeps `std.sys._cocoakb` out of foundation's header
surface.

**Carry forward:** yes, with the rest of `std.objc`.

---

## Prior stdlib work, from the history

Most changes under `mojo/stdlib/` in this fork are not bug patches against
Modular's code — they are this fork's own surface (`std.objc`, `class`
support, the Cocoa database bridge) which happens to live in the stdlib tree.
They are listed here so an entry is never mistaken for a missing one, and
they are indexed rather than described: their reasoning is in the commits.

| Commit | What it is |
|---|---|
| `d3ce7c8a` | `std.objc.typed`: calling Cocoa as calls |
| `9c606281`, `1ffa4ce8` | `box_ref`: reaching a class's fields; nil as a state |
| `8666a03a`, `5d599de4`, `1e1217a0` | a returned class parameterises a type; the SDK chooses it |
| `bc422335`, `43121d47`, `ec26184f`, `ef6a68a6` | class fields live in the box |
| `fc991d41`, `3dfe3e02` | `class B(A)`; `@staticmethod` |
| `320832b2` | struct returns, and the IDE becomes entirely `class` |
| `e22ab603` | every `msg_send` in the IDE becomes a call |
| `5390d3b3` | fix-list entries 1–5, 7, 9 |
| `e8dd6790` | the stdlib README's fork notice |

This table was seeded from `git log -- mojo/stdlib` and is an index, not an
audit: nobody has gone back through those commits to separate a fix to
Modular's code from an addition of our own. If you touch one of them, write
it a proper entry above and delete its row here.
