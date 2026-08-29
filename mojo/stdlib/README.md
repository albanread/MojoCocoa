# The standard library

Your copy. This tree lives in `Application Support/Roast/Standard Library`
so that it is *editable* — an installed app's own Resources are sealed by
its signature, and "read the source" is a poor answer to "change the
source". Builds compile against this copy, the language server indexes it,
and Go to Definition lands in it. File ▸ Reset Standard Library & Examples…
restores the shipped originals if an experiment goes badly.

`std/` is the library. Everything below is under it.

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
the SDK, and registers the lot on first use. `ide/gridview.mojo` in the IDE
source (File ▸ Open IDE Source) is the largest worked example — twenty-one
selectors including the whole of NSTextInputClient.

## The rest, roughly by what you reach for

    builtin/        Int, String, SIMD, Bool — no import needed
    collections/    List, Dict, Set, Optional, String internals
    memory/         Pointer, UnsafePointer, allocation, span
    math/ bit/ complex/ random/     numbers
    io/ os/ pathlib/ tempfile/ stat/ subprocess/    the world outside
    time/ benchmark/ testing/       measuring and proving
    sys/            target facts: CompilationTarget, sizeof, env
    ffi/            C interop, external_call
    python/         the CPython bridge — Python.import_module
    gpu/            kernels, DeviceContext lives in `max` rather than here
    algorithm/ iter/ itertools/ functional pieces
    format/ hashlib/ base64/ logger/  text and bytes
    reflection/ traits/ origin/ compile/   the type system's own tools

## Editing it

Nothing here is precompiled: the toolchain reads these sources on every
build, so an edit takes effect the next time you press ⌘B. That also means
a mistake here breaks every build until it is fixed or reset.
