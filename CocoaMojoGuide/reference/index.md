# CocoaMojo Reference Manual

Look-up material, organised by what you are trying to find. If you are learning
rather than checking, start with the [Programmer's Guide](../guide/).
<!-- doccrate:keep-together:start -->


| Section | Contents |
|:---|:---|
| [1. Language reference](01-language.md) | The dialect this frozen compiler accepts: keywords, conventions, declarations, and a complete list of what was removed |
| [2. `std.objc`](02-std-objc.md) | Every exported type and function, with signatures |
| [3. `cocoakb` queries](03-cocoakb.md) | Every compile-time metadata query, its parameters and its result |
| [4. Diagnostics](04-diagnostics.md) | The compile errors this layer produces, what each means, and how to fix it |
| [5. Deviations from Modular's compiler](05-deviations.md) | Every way this fork changes the language, the argument for each, and what it costs — plus what is upstream's churn rather than ours |
| [6. Patches applied to the compiler](06-patches.md) | The work inside the compiler that made those changes real, and the defects fixed on the way |

<!-- doccrate:keep-together:end -->
<!-- doccrate:keep-together:start -->


## Version

Everything here describes the compiler at the fork point of
[MojoCocoa](https://github.com/albanread/MojoCocoa), Mojo 1.1.0. The fork does
not track upstream, so this reference does not go stale in the usual way — it
describes one compiler that does not change.

<!-- doccrate:keep-together:end -->

Facts were taken from the source tree: `mojo/stdlib/std/objc/`,
`mojo/stdlib/std/sys/_cocoakb.mojo`, `KGEN/lib/MojoParser/`, and the
verification spikes under `spikes/`.
<!-- doccrate:keep-together:start -->


## Notation

Parameters appear in square brackets and are resolved at compile time.
Arguments appear in parentheses. A parameter with `= value` is defaulted.

<!-- doccrate:keep-together:end -->
<!-- doccrate:keep-together:start -->


```mojo
def msg_send[
    R: AnyType,
    cls: StaticString,
    selector: StaticString,
    is_class: Bool = False,
    *Ts: AnyType,
](obj: ObjCObject, *args: *Ts) -> R
```

<!-- doccrate:keep-together:end -->

Throughout, `P` abbreviates `OpaquePointer[MutUntrackedOrigin]`, following the
convention used in the standard library itself.
