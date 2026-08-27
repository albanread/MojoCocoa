# 4. Diagnostics

The compile errors this layer produces, what each one means, and what to do.
Messages are quoted from the source that emits them.

## Language-level

### `'fn' declares a foreign-callable (C ABI, non-raising) function in cocoa-mojo and may not be marked 'raises'; use 'def' for an ordinary Mojo function`

`fn` is the foreign-callable function. The C boundary has no error channel, so
a raising `fn` cannot exist. Comes with a FixIt replacing `fn` with `def`.

This is also the migration message: code from the era when `fn` was a general
strict function (`fn main() raises`) gets told what changed rather than a bare
contract violation.

### `'fn' declares a foreign-callable function and cannot be 'async'; use 'def'`

Same contract, same remedy.

### `unknown tokens at the end of a declaration`, on a class field

A field initializer. `var x: Int = 3` is not accepted in this version; declare
`var x: Int` and let it take its default. See
[chapter 6](../guide/06-callbacks.md#the-rules-v1).

### `expression must be mutable for in-place operator destination`, in a class method

The method needs `mut self` to write a field, exactly as a struct method would.

### `'let' declares an immutable binding inside a function body; use 'var' for a field or module value`

`let` has no field or file-scope form. Use `var` there.

### Reassigning a `let`

Rebinding a `let` is a compile error. The object remains mutable — this is
about the binding, not the value. See
[the language chapter](../guide/02-the-language.md#let-is-back--as-the-immutable-binding).

### `'alias' is deprecated; use 'comptime'`

A warning, not an error. `alias` still parses.

### `'__new__' is not supported on structs; use '__init__' instead`

### `the 'register_passable' function effect is no longer supported`

### `the 'escaping' function effect is no longer supported`

### `implicit deletion. '@explicit_destroy' is no longer required.`

Remove the decorator; implicit deletion is now the default.

## `std.objc` compile-time assertions

These come from `comptime assert` inside `msg_send`, `send` and
`ObjCClassBuilder`, so they fire during elaboration and name the problem
precisely.

### Unknown or unmodelable signature

```text
std.objc: 'SELECTOR' on CLASS has an @encode signature the ABI classifier
could not model, so std.objc cannot pick a dispatch stub for it. Call it by
hand with a checked external_call if you know the layout.
```

`cocoakb_msgsend_variant` answered `"?"`. Rare, and the escape hatch is the one
the message names: call it yourself with `external_call`, having worked out the
layout.

### Wrong argument count

```text
std.objc: 'SELECTOR' on CLASS takes N argument(s), but M were passed.
```

Count the colons in the selector. `stringWithUTF8String:` takes one;
`initWithContentRect:styleMask:backing:defer:` takes four. This is the check
that prevents reading an unset argument register.

### Wrong register file — float where an integer is expected

```text
std.objc: argument I of 'SELECTOR' on CLASS is a float, but the ABI expects an
integer/pointer register here. Check the argument type.
```

### Wrong register file — integer where a float is expected

```text
std.objc: argument I of 'SELECTOR' on CLASS is an integer, but the ABI expects
a float register here. Pass a Float32/Float64.
```

The usual cause is an integer literal where a `CGFloat` is wanted. Write
`Float64(0)` rather than `0`. These checks fire only where the classification
is certain, so an absence of error is not proof of correctness for struct
arguments.

### Selector implemented by nothing

```text
std.objc: no class in the metadata implements selector 'SELECTOR', so its
dispatch ABI is unknown. Check the selector spelling.
```

From `send`. Either the selector is misspelled, or the framework declaring it
was not scanned when the database was built.

### Unknown selector encoding when defining a class

Raised by `ObjCClassBuilder.add_method` when `encoding` is omitted and the SDK
does not know the selector. Supply it:

```mojo
b.add_method["myCustomAction:", encoding="v@:@"](handler)
```

## `cocoakb` query failures

A name the database does not contain fails the query itself. The
`must_fail.mojo` spike is exactly this:

```mojo
comptime bogus = cocoakb_struct_size["NSDefinitelyNotAStruct"]()
```

The build fails. It does not return zero, and it does not return a plausible
size.

If a name you believe is real fails, work through these in order.

**Is the database built?** `python3 ../CocoaBaseMCP/build.py`.

**Is the compiler pointed at it?** `MODULAR_MOJO_MAX_COCOAKB_PATH` must name
an existing `cocoa.sqlite`.

**Is it stale?** Rebuild after a macOS update. `cocoakb_db_hash()` tells you
which revision a compilation used.

**Is the spelling the runtime's?** The database is built from the live
Objective-C runtime and BridgeSupport, so it holds the runtime's names, not a
header's typedef.

## Runtime failures the compiler cannot catch

Three things remain yours.

**A nil class.** `ObjCClass.lookup` returns nil when the framework is not
loaded. Every subsequent message to it does nothing, silently. Check
`is_nil()` once at startup.

**Use after the pool drains.** An object handed to a pool by `autorelease()` is
valid only until that pool exits. Nothing checks this.

**An object released while Cocoa still holds it.** Typically an `ObjCRef` that
went out of scope, or a `new_instance` result never retained, where Cocoa keeps
a bare pointer. The symptom is a crash inside `objc_msgSend` with a
plausible-looking receiver.

## Symptoms with no error at all

| Symptom | Cause |
|:---|:---|
| Window appears but ignores the keyboard | `acceptsFirstResponder` missing or returning `False` |
| Window cannot be focused, no Dock icon | `setActivationPolicy:` not called with `0` |
| Callback never fires | Selector added under a different spelling, or `register()` never ran |
| `respondsToSelector:` returns `False` | Same as above; check the selector string character by character |
| Allocator corruption far from any Cocoa call | A `List` pointer stashed after its last use; allocate outside Mojo instead |
| `autorelease pool page corrupted` | A pool token popped twice |
| A class field written from Mojo is not visible to Cocoa | `ClassName()` returns a copy of the box plus the `id`; mutating through it writes the copy. Write fields from methods the runtime dispatches to |
| A class field owning memory never frees | `dealloc` is not hooked yet, so a field's `deinit` does not run |
| Windowed app starts and exits with no window and no message | `load_framework["AppKit"]()` was not called; every message to the nil class silently no-ops |
| A crash when assigning into a `var` declared but not initialised | Pre-existing: assigning into an uninitialised `var` of a type with `__deinit__` destroys garbage first. Bind in a helper scope and return instead |
