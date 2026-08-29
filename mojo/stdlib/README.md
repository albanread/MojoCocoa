# The Mojo standard library

Upstream's standard library, as carried by this unofficial fork — plus
`std/objc`, which is this fork's own.

## Your copy

When Roast is installed as an application this tree is copied to
`Application Support/Roast/Standard Library`, because an app's own
Resources are sealed by its signature and "read the source" is a poor
answer to "change the source". Builds compile against the copy, the
language server indexes it, and Go to Definition lands in it. Nothing here
is precompiled: an edit takes effect on the next ⌘B, and a mistake breaks
every build until it is fixed or File ▸ Reset Standard Library & Examples…
restores the shipped originals.

## Cocoa is here

    std/objc/       the Cocoa layer — the reason this fork exists

Cocoa is not a library you opt into here, it is the platform: every build
links `libobjc` and the frameworks whether or not a program uses them. So
it sits in `std`, not in a package of its own.

    runtime.mojo      ObjCClass, ObjCObject, msg_send — the bottom layer
    classes.mojo      ObjCClassBuilder and class_addMethod: what the
                      compiler's `class` keyword lowers onto
    typed.mojo        Obj["NSWindow"](…) and Cls[…] — the typed call
                      surface, checked against the Cocoa database
    error.mojo        NSError out-parameters, bridged to `raises`
    ownership.mojo    retain, release, autoreleasepool
    foundation.mojo   nsstring, ns_to_string, extern_object
    dispatch.mojo     Grand Central Dispatch
    geometry.mojo     CGRect, CGPoint, CGSize, NSRange

A `class` declaration in Mojo *is* an Objective-C class: the compiler
derives each selector from the method name, takes its type encoding from
the SDK, and registers the lot on first use. `gridview.mojo` in the IDE
source (File ▸ Open IDE Source) is the largest worked example — twenty-one
selectors, including the whole of NSTextInputClient.

## The rest, roughly by what you reach for

    builtin/        Int, String, SIMD, Bool — no import needed
    collections/    List, Dict, Set, Optional, String internals
    memory/         Pointer, allocation, span
    math/ bit/ complex/ random/                     numbers
    io/ os/ pathlib/ tempfile/ stat/ subprocess/    the world outside
    time/ benchmark/ testing/                       measuring and proving
    sys/            target facts: CompilationTarget, sizeof, env
    ffi/            C interop, external_call
    python/         the CPython bridge — Python.import_module
    gpu/            kernels; DeviceContext lives in `max`, not here
    algorithm/ iter/ itertools/                     functional pieces
    format/ hashlib/ base64/ logger/                text and bytes
    reflection/ traits/ origin/ compile/    the type system's own tools

## Vision and roadmap

The principles behind upstream's decisions about features and priorities:

- The [Vision document](https://www.mojolang.org/docs/vision)
- The [Roadmap](https://www.mojolang.org/docs/roadmap/)

## Contributing

This tree is part of an unofficial fork and **does not accept
contributions**. See the [repository README](../../README.md) for what this
fork is and is not.

The Mojo standard library is developed at
[modular/modular](https://github.com/modular/modular), which is where
contributions to it belong. `std/objc` is this fork's own and has no
upstream to send changes to.

## Getting started

- [Mojo standard library development](./docs/development.md)
- [FAQ](./docs/faq.md)

## License

Apache License v2.0 with LLVM Exceptions. See the license file in the
repository for more details.

## Support

This fork is unsupported and carries no warranty. Bugs in the Mojo standard
library itself belong upstream at
[modular/modular](https://github.com/modular/modular).
