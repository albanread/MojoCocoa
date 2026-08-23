> # ⚠️ INCOMPLETE — WORK IN PROGRESS
>
> This is an active port, not a released thing. The Cocoa support works and is
> verified (9/9 spikes, example apps build). The **Apple Silicon GPU stack has
> never been compiled** — it is ported source, nothing more. Expect breakage,
> expect the API to move, and read `STATUS.md` before relying on anything here.

# MojoCocoa

**Mojo as a first-class local language on the Mac.**

A fork of [modular/modular](https://github.com/modular/modular) that teaches the
Mojo compiler about Cocoa, so writing a native macOS application in Mojo is an
ordinary thing to do rather than an exercise in hand-transcribing Objective-C
metadata.

Nothing here is a binding layer. The compiler reads the macOS SDK itself, at
compile time, and checks what you wrote against it:

```mojo
comptime assert size_of[CGRect]() == cocoakb_struct_size["CGRect"]()
comptime assert offset_of[CGRect, "size"]() == cocoakb_field_offset["CGRect", "size"]()

var s = msg_send[ObjCObject, "NSString", "stringWithUTF8String:", is_class=True](cls, p)
```

A struct that drifts from the SDK fails to build. A selector typo is a compile
error at the line that asked. An argument passed in the wrong register file is
a compile error. None of that is a runtime surprise, and none of it was
hand-written.

## Why

The Mac deserves better than being a place where you *can* run a language. The
aim is Mojo that opens an `NSWindow`, draws through a `CAMetalLayer`, handles
mouse and key events from Mojo functions on a class defined at runtime, and
does all of it with the compiler checking every selector against the SDK on the
machine you are building on.

`spikes/` has the evidence: Conway's Life with mouse drawing and age-coloured
cells, a Metal mandelbrot, and a Mojo editor-and-runner written in Mojo.

## ⚠️ No support — and don't bother Modular

This fork is **unsupported by Modular Inc.** and unaffiliated with them. It is
one person's port, running on one machine.

- Do **not** file issues, discussions, pull requests or support requests with
  Modular, or on the upstream repo, for anything you build or break here.
  Nothing in this tree is theirs to answer for. The AIR backend and the GPU
  runtime in particular are **ours, not Modular's** — if they misbehave, that
  is this fork's doing.
- No support is offered here either. Everything is **as-is**, with no
  compatibility promises and no undertaking to fix anything.

If you want supported Mojo on supported platforms, use the real thing:
[modular/modular](https://github.com/modular/modular) and
[docs.modular.com](https://docs.modular.com).

Upstream's contributor process does not apply here — this fork carries no
contributing guide, no code of conduct and no CLA, because contributions go
nowhere upstream. Those files were removed rather than left lying around
pointing at Modular's issue trackers and review teams.

## Fixed at this release, forever

This fork never rebases on, merges, or tracks upstream. The fork point is the
whole point: a known-good snapshot of the open-sourced compiler, tuned for this
hardware until the machine stops working. Hardcoding for arm64 Darwin and the
M-series GPU is a feature, not a bug.

## Where this sits

This is the Mojo member of a family of ports that share one idea: **a compiler
should read the OS, not be told about it.** A single SQLite mirror of the macOS
Objective-C surface — [CocoaBaseMCP](https://github.com/albanread/CocoaBaseMCP),
built from the live runtime and BridgeSupport — backs all of them:

| project | language |
|---|---|
| **MojoCocoa** | Mojo |
| MacModula2 | Modula-2 |
| MacBCPL | BCPL |
| MF66 / MF67 | Forth |
| MacNCL, MRASM, MACVM | NCL, assembler, a research VM |

Each one gets struct layouts, enum values, selector existence, method
encodings, and ABI classification from the same database, so a fact learned
once is available to all of them. Adding a capability is a `SELECT`, not a new
generator.

Direct ancestor: [MojoMacX64](https://github.com/albanread/MojoMacX64), the same
work on an Intel Mac Pro driving a Radeon Pro Vega II. MojoCocoa is that port
retargeted to Apple Silicon — see `AIR_APPLE_SILICON.md` for what that involved
and why some of it got *simpler*.

## Status

| | |
|---|---|
| Cocoa compiler hook (`cocoakb`) | working — 9/9 spikes |
| `std.objc` — dispatch, ownership, runtime class definition | working |
| Cocoa example apps | building |
| Apple Silicon GPU stack (AIR + runtime) | ported, not yet compiled |

`STATUS.md` is the honest, current picture. `COCOA_ARM64.md` and
`AIR_APPLE_SILICON.md` are the design notes.

## The GPU part, and why it exists

Modular open-sourced a great deal — the frontend, elaborator, MLIR dialects and
the host backend are all here and genuinely buildable, which is the only reason
the Cocoa hook was possible at all. What they did not publish is GPU lowering:
only `Host` exists under the three `Target/` directories, and the wheels ship no
backend library.

So a compiler you build yourself cannot emit GPU code, however good Modular's
own is. `AIR_APPLE_SILICON.md` records the evidence and the plan: our own AIR
backend and our own runtime against the open `AsyncRT` C ABI, replacing
`libmax`/`libMGPRT` with code we can read.

## Thank you, Mojo developers

This fork exists only because Modular open-sourced the entire Mojo compiler —
parser, elaborator, code generator, JIT, LSP — along with the standard library,
the GPU kernel library, and the AIR bitcode machinery, all under Apache 2.0
with LLVM Exceptions. That is a rare and generous act.

It is worth being precise about how much it bought. The Cocoa work above is a
compiler hook: it was possible only because the elaborator and the comptime
machinery were right there to hook into. The GPU work is our own AIR backend,
but it drops into `TargetTraits` / `TargetBackend` extension points that
upstream deliberately left public and documented for out-of-tree use — the
`plugin_consumers` package group in `KGEN/BUILD.bazel` is an invitation. None
of this would be a weekend's work against a closed compiler; most of it would
not be possible at all.

Thank you to everyone who built Mojo and then gave it away. 🔥

## Building

Bazel, via the bundled wrapper — no toolchain install needed.

```bash
python3 ../CocoaBaseMCP/build.py        # the SDK database, ~12s
./bazelw build //spikes:life
./spikes/run-cocoa-checks.sh            # the 9 verification spikes
```

`local.bazelrc` selects `--config=build-mojo` and points the compiler at
`cocoa.sqlite`. Rebuild the database after a macOS update;
`cocoakb_query<"db_hash">` makes drift visible.

Requires Apple Silicon, macOS 15+, and Xcode 16+.

## Licence and provenance

Forked from `modular/modular` at `577b6b8`, Apache 2.0 with LLVM exceptions.
Upstream's own README is kept as `UPSTREAM-README.md`. Everything added here
carries the same licence.

[LICENSE](LICENSE) and [Licenses/](Licenses/) stay exactly as upstream has
them, and are the one part of Modular's paperwork this fork keeps deliberately.
Almost every file here is still their Apache-2.0 code; §4(a) requires a
derivative work to ship the licence with it, and the same grant is what puts
this fork's own additions on a clear footing. The contributor process was
dropped because it routes to Modular. The licence is not process.
