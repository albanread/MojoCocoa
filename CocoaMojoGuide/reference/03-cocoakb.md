# 3. `cocoakb` queries

Compile-time queries against `cocoa.sqlite`. Every one resolves to a constant
before code generation, so a name the metadata does not know is a compile error
rather than a wrong answer.

```mojo
from std.sys._cocoakb import cocoakb_struct_size, cocoakb_field_offset
```

The module is underscore-prefixed because it is compiler-adjacent, not because
it is off limits — the verification spikes import it directly.

## Layout

### `cocoakb_struct_size`

```mojo
def cocoakb_struct_size[name: StaticString]() -> Int
```

Size in bytes of a Cocoa struct. `name` is spelled as the runtime spells it,
for example `"CGRect"`.

### `cocoakb_struct_align`

```mojo
def cocoakb_struct_align[name: StaticString]() -> Int
```

Alignment in bytes.

### `cocoakb_field_offset`

```mojo
def cocoakb_field_offset[type_name: StaticString, field: StaticString]() -> Int
```

Byte offset of a field within a struct. This is what makes a declaration
checkable rather than merely plausible.

```mojo
comptime assert size_of[CGRect]() == cocoakb_struct_size["CGRect"]()
comptime assert cocoakb_field_offset["CGRect", "size"]() == 16
```

## Constants

### `cocoakb_enum_value`

```mojo
def cocoakb_enum_value[name: StaticString]() -> Int
```

The value of an enum member, from BridgeSupport. Signed, so a value that must
sign-extend as a pointer does behaves correctly, and a flag mask narrowed by
the caller keeps its bits either way.

```mojo
comptime assert cocoakb_enum_value["NSUTF8StringEncoding"]() == 4
```

### `cocoakb_constant_type`

```mojo
def cocoakb_constant_type[name: StaticString]() -> StaticString
```

The declared type encoding of an extern-symbol constant, for example `"@"` for
an object. Constants like `NSFontAttributeName` are runtime addresses, not
compile-time values; this reports the type, and `extern_object` fetches the
value.

## Classes and methods

### `cocoakb_superclass`

```mojo
def cocoakb_superclass[name: StaticString]() -> StaticString
```

### `cocoakb_method_encoding`

```mojo
def cocoakb_method_encoding[
    cls: StaticString, selector: StaticString, is_class: Bool = False
]() -> StaticString
```

The verbatim `@encode` signature, inheritance-resolved: the lookup walks the
superclass chain, so asking `NSMutableString` about `length` finds `NSString`'s
definition. Returns the raw form including frame offsets, for example
`"Q16@0:8"`.

### `cocoakb_msgsend_variant`

```mojo
def cocoakb_msgsend_variant[
    cls: StaticString, selector: StaticString, is_class: Bool = False
]() -> StaticString
```

Which `objc_msgSend` entry point the send must use. Returns `"objc_msgSend"`,
`"objc_msgSend_stret"`, or `"objc_msgSend_fpret"`; `"?"` marks a signature the
ABI classifier could not model, and callers assert against it.

On arm64 the answer is always `"objc_msgSend"`. AAPCS64 has neither `_stret`
nor `_fpret` — an aggregate return travels in `x0`–`x1`, in `v0`–`v3` when it
is a homogeneous float aggregate, or through the `x8` indirect-result register.
The query is retained because its other job — rejecting unmodelable
signatures — still matters.

### `cocoakb_method_ret_class`

```mojo
def cocoakb_method_ret_class[
    cls: StaticString, selector: StaticString, is_class: Bool = False
]() -> StaticString
```

The AAPCS64 return classification, in the token vocabulary below.

### `cocoakb_method_arg_classes`

```mojo
def cocoakb_method_arg_classes[
    cls: StaticString, selector: StaticString, is_class: Bool = False
]() -> StaticString
```

Comma-joined classifications of the arguments beyond `self` and `_cmd`. An
empty string means the selector takes none; `"g"` means one; `"g,g"` two.

## Selector-keyed queries

For protocol-typed receivers whose concrete class is unknown at compile time.

### `cocoakb_selector_variant`

```mojo
def cocoakb_selector_variant[selector: StaticString]() -> StaticString
```

The dispatch variant, taken from any class implementing the selector. An empty
result or `"?"` means no class in the metadata implements it.

### `cocoakb_selector_arg_classes`

```mojo
def cocoakb_selector_arg_classes[selector: StaticString]() -> StaticString
```

### `cocoakb_selector_encoding`

```mojo
def cocoakb_selector_encoding[selector: StaticString]() -> StaticString
```

The `@encode` signature by majority across implementing classes, for example
`"v24@0:8@16"`. Used by `ObjCClassBuilder` to type a Mojo method when defining
a class at run time.

## POSIX

The same database describes the C library.

| Query | Returns |
|:---|:---|
| `cocoakb_posix_sig[name]()` | The full C type as clang reports it, e.g. `"int (const char *, int, ...)"` |
| `cocoakb_posix_ret_class[name]()` | AAPCS64 return classification |
| `cocoakb_posix_arg_classes[name]()` | AAPCS64 argument classifications |

## Provenance

### `cocoakb_db_hash`

```mojo
def cocoakb_db_hash() -> StaticString
```

The SHA-256, lowercase hex, of the database this compilation consulted. A
binary can record exactly which metadata revision produced it, which is the
reproducibility pin and also how you notice a stale database after a macOS
update.

## The AAPCS64 token vocabulary

These tokens come from `derive_method_abi.py` in CocoaBaseMCP. They are **not**
the SysV eightbyte vocabulary, and reading them as if they were puts a
homogeneous float aggregate in the wrong register file.

| Token | Meaning | Register file |
|:---|:---|:---|
| `v` | void | — |
| `g` | general-purpose register | integer |
| `f` | scalar float | float, `v0`–`v7` |
| `h2`, `h3`, `h4` | homogeneous float aggregate of k members | float, k consecutive `v` registers |
| `i1`, `i2` | small integer struct | integer |
| `b` | by-value pointer | integer |
| `x` | indirect result via `x8` | — |
| `s` | struct | integer |
| `m` | memory | — |
| `?` | unmodelable; a compile error | — |

A value goes in a `v` register when it is a scalar float or a homogeneous float
aggregate. Everything else goes in the integer file. Testing whether every byte
of a token is `f` would be the SysV reading and would misclassify an HFA.

Worked examples from the verification spike:

| Query | Result |
|:---|:---|
| `cocoakb_method_ret_class["NSString", "length"]()` | `"g"` — one GPR |
| `cocoakb_method_ret_class["NSValue", "rectValue"]()` | `"h4"` — `CGRect` in `v0`–`v3` |
| `cocoakb_method_encoding["NSMutableString", "length"]()` | `"Q16@0:8"` |
