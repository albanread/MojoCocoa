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
./bazelw build --config=build-mojo --config=release //KGEN/tools/mojo:mojo //KGEN:CompilerRT
```

`//KGEN:CompilerRT` is in there because `make-dist.sh` needs that dylib and
building the compiler alone does not produce it.

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

## What the release build actually changed

Measured, one M4 Max:

| | before (dbg, static) | after (release, dynamic LLVM) |
|---|---|---|
| compiler binary | 169.8 MB | **27.9 MB** |
| libLLVM.dylib | — | **77.7 MB**, 37,113 `llvm::` symbols |
| libMLIR.dylib | — | **159.5 MB**, 170,816 `mlir::` symbols |
| distribution | 439 MB | 645 MB (includes LLVM headers) |
| compile a demo | 6.88 s | **5.74 s** |
| LLVM backends built | AArch64, RISCV, X86 | **AArch64** |
| full build | 8,527 actions | 7,999 actions, **882 s** |
| mandelbrot | GPU 0.9 ms, 60 fps | GPU 0.39 ms, 62 fps |

The build is fifteen minutes, not the hour it used to feel like.

## LLVM is a shared library

`//bazel/llvm-shared:LLVM` builds `libLLVM.dylib`, and the compiler links
against it rather than absorbing it. That is what took the binary from 104.8 MB
to 56.5 MB, and it is the point of the exercise: LLVM is built once and stays
built. An out-of-tree tool — an IDE, a language server — links the same dylib
without building LLVM at all.

Three things had to be true, and each failed loudly on the way:

**Every LLVM library in the closure must be listed.** `cc_shared_library`
refuses to guess. The list in `bazel/llvm-shared/BUILD.bazel` is the answer to

```bash
bazel query 'kind("cc_library rule", filter("llvm-project//llvm", deps(//KGEN/tools/mojo:mojo)))'
```

which is 102 targets today. Anything omitted gets linked statically into the
binary *as well*, and two copies of LLVM in one process means two
`ManagedStatic` registries and two sets of `cl::opt`. Bazel catches this at
analysis time rather than letting it fail at startup.

**zlib-ng and zstd come along.** LLVM's Support links them, so they land inside
the dylib and have to be exported from it. They appear in `exports_filter` under
their canonical `@@zlib-ng+` names — the plain `@zlib-ng` form is not visible
from this module.

**Visibility, again.** Covered below; without it the dylib exports 192 symbols
instead of 37,113 and is useless to everything including the compiler.

### Why it is 77.7 MB and not 30

    __TEXT        55.3 MB     code
    __LINKEDIT    21.7 MB     symbol table and export trie
    __DATA         1.2 MB

There is no debug information in it and nothing left for `strip` to remove.
55 MB is what one AArch64-only LLVM costs at `-O2` with default visibility, and
the 21.7 MB is the price of exporting 38,873 symbols — which is the point, since
that is what a consumer links against.

For scale, a distribution `libLLVM` with all sixteen backends runs around
130 MB. Ours is one backend.

The one lever that would shrink it is dropping
`-fno-visibility-inlines-hidden`, which stops LLVM's inline and template members
being emitted and exported. That is precisely the set an IDE needs, so it stays.

### Using it from another project

The distribution carries the headers as well as the dylib, so this is the whole
of it — no bazel, no LLVM source tree:

```bash
clang++ -std=c++17 -fno-rtti mytool.cpp \
  -I dist/CocoaMojo/include \
  -L dist/CocoaMojo/lib -lLLVM \
  -Wl,-rpath,$PWD/dist/CocoaMojo/lib
```

`tools/ide-probe/ide_probe.cpp` is a working example — it builds a module, runs
the verifier and prints the registered targets — and `check-dist.sh` compiles and
runs it on every check, so this path cannot rot quietly.

`dist/CocoaMojo/include` is 2,395 headers, 41 MB, and it is two trees merged in
this order:

1. LLVM's checked-out headers. These reach the build as a symlink farm into the
   `llvm-raw` repo, so they are copied with `cp -RL` rather than rsync.
2. The 43 generated headers on top — `llvm-config.h`, `abi-breaking.h` and the
   `llvm/Config/*.def` files that record which targets this LLVM was built
   with.

The order matters. The source tree ships `.in` templates for those Config
headers, and if they win, a consumer compiles against a `Targets.def` listing
backends that are not in the dylib. The probe catches exactly that: it should
print the AArch64 family and nothing else.

```
registered targets: aarch64_32 aarch64_be aarch64 arm64_32 arm64
```

## One flag explains two different failures

`bazel/internal/cc-toolchain/args/BUILD.bazel:124-125` applies
`-fvisibility=hidden` to the entire toolchain:

```
"-fvisibility-inlines-hidden",
"-fvisibility=hidden",
```

That single setting is behind both of the hard-to-diagnose problems in this
tree, and they looked nothing alike from the outside.

It is why `AsyncRT_DeviceContext_create` and its 124 siblings were missing at
run time: hidden makes them private externs, invisible the moment anything
wants them across a JIT or dylib boundary. `make-dist.sh` works around it by
recompiling those two files with `-fvisibility=default`.

It is also why LLVM cannot currently be a shared library here — see
`bazel/llvm-shared/BUILD.bazel`. Linked with `-all_load`, LLVM comes out with
roughly 13,000 defined text symbols and 192 exported.

If a symbol is defined, links, and then cannot be found at run time, check
visibility before anything else.

## Integrating an editor

Most of what an IDE needs is already in the distribution.

### The language server

`dist/CocoaMojo/bin/mojo-lsp-server` speaks LSP on stdin/stdout. Point an editor
at it and it advertises eleven capabilities:

    codeAction  completion  definition  documentSymbol  hover  inlayHint
    references  rename  resolve  semanticTokens  signatureHelp

That covers completion, diagnostics, jump-to-definition, rename, and semantic
highlighting — an editor does not need to parse Mojo itself. `check-dist.sh`
sends it a real `initialize` request on every check, since an editor's first
move failing is the one bug that makes everything else look broken.

### Build and run

`cocoamojo --build` and `--run`, as above. `cocoamojo format` and
`cocoamojo doc` are subcommands of the same driver.

### Linking LLVM

See "Using it from another project". This is what lets an editor's own
tooling — an indexer, a custom analysis — work on the same IR the compiler
produces, without building LLVM.

### The language server is statically linked, deliberately

It is 60.7 MB rather than 48.8 MB, because it carries its own LLVM instead of
sharing `libLLVM.dylib`. That is not an oversight, and the reason is worth
understanding before anyone "fixes" it.

`Support/BUILD.bazel` builds `libMSupportGlobals.dylib` with a comment that says
what it is for:

```
# NOTE: This library should not have any deps to avoid shared object linking issues
```

It links `llvm:Support` and `mlir:Support` on purpose, to be the single home for
LLVM and MLIR global state shared across shared objects — that is what the
`FallbackTypeIDResolver` note above it is about. It exports 1,699 `llvm::`
symbols, seven of them CommandLine.

`libLLVM.dylib` contains `llvm:Support` too, because every other LLVM library
depends on it. So there are two copies, and there always were: before this work,
`mojo` had LLVM statically linked *and* loaded `libMSupportGlobals.dylib`.
Hidden visibility was quietly keeping them apart — neither copy exported
anything, so each bound to its own.

Turning visibility on for LLVM removed that accidental isolation. The compiler
is fine. The language server is not, because it registers a `-I` option through
`cl::opt` and both copies now reach the same registry:

    : CommandLine Error: Option 'I' registered more than once!
    LLVM ERROR: inconsistency in registered CommandLine options

with `Program arguments:` printed twice, which is the tell — static initializers
running in both copies.

The real fix is for `libLLVM.dylib` to get Support from `libMSupportGlobals.dylib`
rather than carry its own. Bazel cannot currently express that here:
`Support:Globals` is a `modular_shared_library`, which does not produce
`CcSharedLibraryInfo`, so `cc_shared_library`'s `dynamic_deps` will not accept
it. Converting it is a change to Modular's code with cross-SO type-identity
consequences, and it has not been made.

Until then: the compiler shares the dylib, the language server does not, and
`check-dist.sh` fails loudly with `duplicate LLVM CommandLine registry` if that
ever changes by accident.

### MLIR is a shared library too

`//bazel/mlir-shared:MLIR` builds `libMLIR.dylib` — 159.5 MB, 170,816 exported
`mlir::` symbols — and takes `libLLVM.dylib` as a `dynamic_deps` rather than
absorbing a second copy of it. With both shared, the compiler is 27.9 MB.

This is what in-process compilation needs. `cocoamojo --build` shells out and
requires none of it; an editor that wants to compile inside its own process, or
to build and inspect IR directly, links MLIR.

It carried a risk worth recording, because it is subtler than the one that broke
the language server. `libMSupportGlobals.dylib` links `mlir:Support` on purpose,
and the comment above it is specifically about this:

```
# Always link and expose the FallbackTypeIDResolver::registerImplicitTypeID
# function. This is used by downstream libraries to decide whether MLIR types
# in different SOs are the same type or not.
```

MLIR identifies types by `TypeID`, and two shared objects that disagree about
whether `mlir::IntegerType` is the same type do not crash — a `dyn_cast` returns
null and the failure surfaces a long way from its cause. Modular anticipated
MLIR across shared objects, which is why that function is force-linked, but
"anticipated" is not "verified".

So the verification is end-to-end rather than structural. `./spikes/run-cocoa-checks.sh`
compiles and runs 16 checks that assert real values — `cocoakb_query` results,
block ABI layout, weak-reference reloads, NSError bridging, and three that must
fail to compile and still do. All 16 pass against the distribution, with no
bazel involved:

```bash
./spikes/run-cocoa-checks.sh      # uses dist/CocoaMojo when it exists
```

A dylib that links and a demo that renders would not have been evidence of
anything here. Sixteen assertions on values are.

### Embedding the compiler

`libMojoCompiler.dylib` is the front end as a library — 27.5 MB, 20,774 exported
symbols, with LLVM and MLIR as `dynamic_deps` rather than absorbed copies. It
holds four phases: `MojoTooling` (parse and diagnostics), `Elaborator` (comptime
evaluation, `cocoakb_query`), `Pipeline` (lowering) and `ObjectCompiler` (AOT
object emission), plus `Init` for the process context.

Before it, the distribution shipped the parser's *headers* and no parser: the
front end was linked statically inside `cocoamojo` and `mojo-lsp-server`, and
nothing out of tree could call it.

Syntax checking is the cleanest of the phases and the one an editor wants first.
`tools/ide-probe/syntax_probe.cpp` is the whole of it in 60 lines:

```bash
clang++ -std=c++20 -fno-rtti -DLLVM_ON_UNIX=1 \
  -DMODULAR_ASYNCRT_MAX_PROFILING_LEVEL=0000000 \
  -DMAX_CONFIG_SECTION=max -DMOJO_CONFIG_SECTION=mojo-max \
  tools/ide-probe/syntax_probe.cpp \
  -I dist/CocoaMojo/include -L dist/CocoaMojo/lib \
  -lMojoCompiler -lMLIR -lLLVM -Wl,-rpath,$PWD/dist/CocoaMojo/lib \
  -o syntax_probe

./syntax_probe bad.mojo -I dist/CocoaMojo/lib/mojo/stdlib
```

```
bad.mojo:3:4: error: expression must be mutable in assignment
bad.mojo:4:17: error: cannot implicitly convert 'StringLiteral["not an int"]' value to 'Int'
bad.mojo:5:4: error: use of unknown declaration 'undefined_function'
parsed: yes, errors: 3, warnings: 0
```

Every flag there is required. `-std=c++20` because Support's headers use
`std::string::starts_with`; the three defines because KGEN's headers reference
them unconditionally (`bazel/config.bzl`); `LLVM_ON_UNIX` because LLVM's own
headers guard platform members on it.

`M::MojoParserContext` (`KGEN/MojoTooling/ParserDriver.h`) is the seam. It takes
an `llvm::SourceMgr` you own and a `LIT::ParserConfig`, which is
`{MLIRContext*, const CompilationOptions&}` — and `CompilationOptions` is
default-constructible, so there is no target registration, PassManager or
pipeline to stand up. Diagnostics arrive through `SourceMgr::setDiagHandler` as
ordinary `llvm::SMDiagnostic` values with kind, location, message, ranges and
fix-its.

Three orderings are load-bearing, and each is a real bug rather than a style
preference:

1. Add the buffer to the `SourceMgr` **before** constructing
   `MojoParserContext` — its shared state snapshots existing buffers into an
   identifier map used to reuse open buffers during import resolution.
2. Install the diagnostic handler before parsing and clear it before the
   handler's context object dies, or a later operation dereferences a dangling
   pointer.
3. Destroy the `MojoParserContext` before the `MLIRContext` and the
   `SourceMgr`; its destructor finalizes imported bytecode modules.

Use `parseFileForLSP`, not `parseFile`. The first body-resolves only what
descends from the root and signature-resolves the rest; the second body-resolves
the entire transitive stdlib closure. At keystroke rates that is the difference
between usable and not.

**The stdlib has to be there.** There is no cheap tokenize-only mode: the parser
is lazily levelled — unparsed, then signature, then body — and syntax errors
inside function bodies only surface at body resolution. A real syntax check is
already the LSP-level parse, so an embedder inherits the `-I` paths.
`ParserConfig::useBuiltinModule` can be turned off, but then real code produces
nonsense diagnostics.

`KGEN/docs/overviews/LSPParserInteraction.md` documents the parse flow in more
detail, and `mojo-lsp-server` is a complete worked example.

### Cocoa completion

The language server completes Objective-C classes and selectors out of
`cocoa.sqlite` — the same database the compiler answers `cocoakb_query` from at
compile time. 28,814 classes and 522,170 selectors.

Typing inside the string:

```mojo
msg_send[ObjCObject, "NSWindow", "setTit"]
```

offers

    setTitle:                          (ObjCObject) -> None
    setTitlebarHeight:                 (Float64) -> None
    setTitleVisibility:                (Int) -> None
    setTitleWithRepresentedFilename:   (ObjCObject) -> None

Signatures are decoded from the raw `@encode` string into Mojo types, `self` and
`_cmd` dropped, since what a reader wants is the arguments they have to supply.
The raw encoding is kept in the hover documentation.

Three positions are recognised:

| where | what it offers |
|---|---|
| `ObjCClass.lookup["NSWin` | class names, with superclass |
| `msg_send[T, "NSWindow", "setTit` | instance selectors |
| `msg_send[T, "NSWindow", "allo", is_class=True` | class methods |

Selectors include everything inherited: `alloc` and `init` live on `NSObject`,
and a list that omitted them would be useless. The superclass chain is walked in
SQL with a recursive CTE, and the depth it returns doubles as the ranking, so a
selector declared on the class outranks one inherited from six levels up.

`KGEN/lib/CocoaKB/CocoaCompletion.cpp` is a separate reader from the
elaborator's. The elaborator asks the database point questions and gets one
answer; completion asks for everything matching a prefix, ranked and bounded.
Different queries, different indexes, and the language server should not have to
link the elaborator to offer them.

The context detection is textual, deliberately. Elaborating a half-typed
`msg_send` to find the receiver would be the principled approach and would also
make completion depend on the file compiling, which while typing it usually does
not.

`check-dist.sh` probes all three positions on every check. That is not
ceremony — the first version of this shipped a bug the probe caught: the
`is_class=True` lookahead ran a fixed 240 characters and read the *next*
statement's arguments, so completing an instance selector on one line silently
became a class-method lookup because the line below it passed `is_class=True`.
Two of the three positions still worked, which is exactly the kind of failure a
single test would have missed.


## What is not done

- **Elaboration and AOT are linkable but unproven from outside.**
  `libMojoCompiler.dylib` contains `:Elaborator`, `:Pipeline` and
  `:ObjectCompiler` as well as the parser, but only the parse path has a probe
  behind it. The others are believed reachable, not demonstrated.
- **The JIT cannot run GPU programs**, embedded or otherwise. `cocoamojo --run`
  builds and executes instead, which is why it works.
- `mojo run` (the JIT) still cannot run GPU programs. `cocoamojo --run` builds
  instead, which is why it works. The JIT path is filed, not fixed.
- The distribution is not signed or notarized, so it will not run on another Mac
  without the user clearing quarantine.
