# Building and shipping CocoaMojo

This describes how `dist/CocoaMojo` is produced: a self-contained toolchain that
compiles and runs Mojo for Cocoa on Apple silicon, with no bazel daemon standing
between you and your program.

    dist/CocoaMojo/bin/cocoamojo --run   spikes/mandelbrot/mandelbrot.mojo
    dist/CocoaMojo/bin/cocoamojo --build spikes/life/life.mojo      # -> ./life

## The whole thing, from a clean checkout

```bash
./tools/release.sh
```

That runs the two steps below and prints what it produced. Everything after this
section is why each step is the way it is.

## Step 1 — build the compiler (bazel, once)

```bash
./bazelw build --config=build-mojo --config=release //KGEN/tools/mojo:mojo
```

Bazel builds the compiler. That is the only job it has here, and after this
command it has no further part to play.

`--config=release` is defined in `.bazelrc` and differs from the default build in
three ways, each of which changes the action key — which is why it gets its own
output tree, `darwin_arm64-opt`, and why a failure leaves the existing `dbg`
toolchain exactly where it was.

**`--compilation_mode=opt`.** The repository default is
`--compilation_mode=dbg`. A debug LLVM is why the compiler was 169 MB with a
49 MB symbol table, and why it was slower than it needed to be at the one job it
has. Nothing in this fork requires a debug LLVM.

**`-mcpu=apple-m4`**, on both target and host compiles. There is exactly one
machine this runs on and we know what it is, so LLVM is compiled to schedule for
the M-series pipeline rather than for a conservative baseline arm64.

**`--dynamic_mode=default` and `--features=supports_dynamic_linker`.**
`bazel/internal/common.bazelrc` disables dynamic linking globally, with a note
about circular dependency linking issues. Those bite the full Modular graph,
which this fork does not build. Turning it back on inside this config lets LLVM
and MLIR link as shared libraries instead of being folded into every binary, so
a change to one backend source relinks a delta rather than 169 MB.

### One backend

`bazel/public-patches/llvm_project.bzl` configures LLVM's backends. It used to
read `["AArch64", "RISCV", "X86"]`; it now reads `["AArch64"]`.

X86 and RISCV were 57 MB of objects and several thousand compile actions for
code this machine will never execute. Removing them required deleting nothing:
`InitializeAllTargets()` expands from LLVM's generated `Targets.def`, so it now
registers AArch64 alone and every call site in `KGEN/tools` compiles unchanged.

AArch64 covers both halves of the job — the arm64 the compiler emits for the
host, and the MC layer underneath. The Apple GPU path is unaffected: AIR is
emitted as bitcode against an `air64` triple, not through a registered LLVM
target.

To add a backend back, use the `extra_targets` tag on the module extension, or
append to `BACKENDS` if it should be unconditional.

## Step 2 — assemble the distribution (no bazel)

```bash
./tools/make-dist.sh
```

This copies the compiler and its runtime dylibs, stages the Mojo packages and
the Cocoa database, and builds one library from source. The result:

    dist/CocoaMojo/
      bin/cocoamojo               the driver -- this is the interface
      bin/cocoamojo-compiler      the compiler bazel built
      lib/libKGENCompilerRTShared.dylib
      lib/libAsyncRTRuntimeGlobals.dylib
      lib/libMSupportGlobals.dylib
      lib/libCocoaMojoGPU.dylib   Metal/AsyncRT device runtime -- see below
      lib/mojo/{stdlib,max,kernels}
      share/cocoa.sqlite          the SDK database the elaborator reads

### Why libCocoaMojoGPU is compiled here rather than copied

Bazel compiles `AppleGPURT.cpp` and `AppleGPUMetal.cpp` with
`-fvisibility=hidden`, which makes every `AsyncRT_DeviceContext_*` entry point a
*private* extern. Linked statically into a single binary that is invisible. The
moment anything wants those symbols from a JIT or across a dylib boundary they
are simply absent — which is what

    JIT session error: Symbols not found: [_AsyncRT_DeviceContext_create, ...]

had been reporting all along, and why GPU programs could be compiled but never
run. `-force_load`, `-keep_private_externs` and `ld -r` cannot un-hide a symbol.
Recompiling the two files with default visibility can: 125 exported symbols
instead of none.

`make-dist.sh` checks the count and fails the build if it ever drops back,
because the failure mode is silent until someone tries to run a kernel.

`AppleGPUMetal.cpp` is compiled with ARC off — it does its own retain/release
and calls `dispatch_release`, which ARC forbids.

### Why sources rather than precompiled packages

`lib/mojo` holds `.mojo` sources, not `.mojoc`. A precompiled Mojo package
records the compiler version that produced it, and this tree's compiler rejects
packages built by a different one:

    Precompiled file `attn_res.mojoc` version 1.1.0.dev0 is newer than
    compiler version 1.1.0.dev0

Shipping sources costs 35 MB and removes that whole class of failure.

## The driver

`tools/cocoamojo` is the interface. It supplies what the bare compiler needs and
otherwise stays out of the way:

| | |
|---|---|
| `MODULAR_MOJO_MAX_COCOAKB_PATH` | the SDK database the elaborator queries |
| `MODULAR_MOJO_MAX_COMPILERRT_PATH` | the Mojo runtime |
| `MODULAR_CRASH_REPORTING_ENABLED=false` | no crashpad handler ships here |
| `COCOAMOJO_ROOT` | so a program can find the toolchain that built it |
| `-I` paths | stdlib, max, kernels |
| link flags | `-lobjc`, Foundation, AppKit, Metal, QuartzCore, `-lCocoaMojoGPU` |

Cocoa is not a library you opt into here, it is the platform, so every build
gets the frameworks and the GPU runtime. A program that uses none of them pays
one load command.

Binaries from `--build` carry an rpath into the distribution's `lib/`, so they
run with an empty environment:

```bash
env -i ./mandelbrot     # opens its window and renders
```

`--run` builds to a temporary binary and executes it. It does not use `mojo run`,
because that JITs, and the JIT cannot resolve the GPU runtime.

### Why the environment variables matter more than they look

Handing a bazel action a single environment variable via `--action_env` enters
the key of **every** action in the graph. One boolean rebuilt all 3,610 actions
here, LLVM included. That is the reason this distribution exists: the compiler
reads these variables directly at run time, so pointing it at a different
`cocoa.sqlite` costs nothing.

## The playground

`spikes/playground/playground.mojo` is an editor whose Run key shells out to the
toolchain. It launches `cocoamojo --run`, not the bare compiler — pointing
`NSTask` at the raw binary is what produced `unable to locate module 'std'` in
the output pane.

It finds the driver through `COCOAMOJO_ROOT`, so a playground started with
`cocoamojo --run` runs your buffer with the same toolchain it came from.
`MOJOCOCOA_MOJO` overrides that outright.

## Verifying a release

```bash
./tools/check-dist.sh
```

Builds every demo, runs the two that answer in finite time, and checks the GPU
runtime's exports. What it should print:

    OK   mandelbrot        GPU 0.4 ms vs CPU 102 ms, 60 fps
    OK   window_smoke      WINDOW-SMOKE: PASS
    OK   playground
    OK   p0_window
    OK   life
    OK   libCocoaMojoGPU   125 AsyncRT symbols exported

## What is not done

- LLVM is a shared library within the distribution, but the compiler is still a
  single tool: there is no `llvm-config`, and nothing outside this tree links
  against it.
- `mojo run` (the JIT) still cannot run GPU programs. `cocoamojo --run` builds
  instead, which is why it works. The JIT path is filed, not fixed.
- The distribution is not signed or notarized, so it will not run on another Mac
  without the user clearing quarantine.
