# Embedding the Mojo compiler

A map of the compiler's phases as they look from outside, for building an editor
that embeds them rather than shelling out to `cocoamojo`.

Everything here was read out of this tree. Claims are marked **verified** where
something was actually built and run, and **mapped** where the code says so but
nothing has exercised it yet. The distinction matters: the parse path turned up
three ordering constraints that no amount of reading the headers would have
predicted, and the other phases have not had that treatment.

## The shape of it

There is no library call that compiles a file, and there is no library call that
runs one. `build()` (`KGEN/tools/mojo/Build/mojo-build.cpp:889`) and `run()`
(`KGEN/tools/mojo/Run/mojo-run.cpp:346`) are both file-static, take a driver
`State` wrapping `argv`, and reference some forty-five TableGen'd `options::OPT_*`
IDs. They are not a layer you can call into.

**The layer immediately below them is clean** — no `cl::opt`, no `ArgList`, no
`State` — and it is four calls:

| phase | call | header |
|---|---|---|
| parse | `LIT::importMojoFile()` | `KGEN/MojoParser/EntryPoint.h:114` |
| elaborate | `KGENCompiler::runKGENPipeline()` | `KGEN/Compiler/KGENCompiler.h:44` |
| emit | `ObjectCompiler::create()` / `emitArchive()` | `KGEN/Compiler/ObjectCompiler.h:55,62` |
| JIT | `initializeExecutionEngine()` | `KGEN/Compiler/KGENCompiler.h:81` |

Two in-tree programs already drive that layer with their own option handling
rather than the driver's: `KGEN/tools/kgen/kgen.cpp:733-767` and the language
server. They are worth reading before writing anything.

## What to link

```
dist/CocoaMojo/lib/libMojoCompiler.dylib    the front end -- all four phases
dist/CocoaMojo/lib/libMLIR.dylib
dist/CocoaMojo/lib/libLLVM.dylib
dist/CocoaMojo/include/                     llvm, llvm-c, mlir, mlir-c, KGEN,
                                            Support, Init, Config, Cache, AsyncRT
```

Compile flags, every one of them required, and each a silent failure if omitted:

```bash
-std=c++20                                    # Support's headers use std::string::starts_with
-fno-rtti
-DLLVM_ON_UNIX=1                              # LLVM headers guard platform members on it
-DMODULAR_ASYNCRT_MAX_PROFILING_LEVEL=0000000 # bazel/config.bzl:30
-DMAX_CONFIG_SECTION=max                      # bazel/config.bzl:34
-DMOJO_CONFIG_SECTION=mojo-max                # bazel/config.bzl:35
```

`MOJO_CONFIG_SECTION` is the one that looks harmless and is not: it is what turns
the config key `mojo-max.import_path` into the environment variable
`MODULAR_MOJO_MAX_IMPORT_PATH`. Get it wrong and configuration silently stops
being read.

One more flag is set globally by the toolchain and is worth knowing about:
`-DMLIR_USE_FALLBACK_TYPE_IDS=1` (`bazel/internal/cc-toolchain/args/BUILD.bazel:133-135`).
`mlir/Support/TypeID.h` defaults it to false, so an embedder that omits it
computes MLIR TypeIDs a different way from the libraries it is linking against.
This is the cross-shared-object type identity that `libMSupportGlobals.dylib`
exists to keep consistent. **Mapped, not verified** — the probe compiles without
it, which may mean it does not matter for parsing, or may mean the failure is
somewhere we have not looked.

## Phase 1: parse and diagnostics — **verified**

`tools/ide-probe/syntax_probe.cpp` is a complete working example.
`check-dist.sh` compiles and runs it on every check.

`M::MojoParserContext` (`KGEN/MojoTooling/ParserDriver.h:99`) is the handle. It
takes an `llvm::SourceMgr` you own and a `LIT::ParserConfig`, which is
`{MLIRContext*, const CompilationOptions&}` plus flags. `CompilationOptions` is
default-constructible: no target registration, no PassManager, no pipeline.

Diagnostics arrive through `llvm::SourceMgr::setDiagHandler` as ordinary
`SMDiagnostic` values carrying kind, location, message, ranges and fix-its.
`Support/lib/Compiler/Diags.cpp:512-515` short-circuits to that handler when one
is installed, so there is no MLIR diagnostic engine to stand up.

```
bad.mojo:3:4: error: expression must be mutable in assignment
bad.mojo:5:4: error: use of unknown declaration 'undefined_function'
parsed: yes, errors: 3, warnings: 0
```

Use `parseFileForLSP` (`:129`), not `parseFile` (`:124`). The first
body-resolves only what descends from the root and signature-resolves the rest;
the second body-resolves the whole transitive stdlib closure. At keystroke rates
that is the difference between usable and not.

### Three orderings, each a real bug

1. **Add the buffer to the `SourceMgr` before constructing `MojoParserContext`.**
   `SharedState`'s constructor snapshots the existing buffers into an
   identifier→id map (`KGEN/lib/MojoParser/SharedState.cpp:513-518`) used to reuse
   already-open buffers during import resolution.
2. **Clear the diagnostic handler before its context object dies.** The handler
   holds a raw `void*`; the LSP uses `llvm::scope_exit` and comments on the
   dangling-pointer hazard (`MojoServer.cpp:838-844`).
3. **Destroy the `MojoParserContext` before the `MLIRContext` and the
   `SourceMgr`.** Its destructor finalizes imported bytecode modules
   (`ParserDriver.cpp:74-78`).

### The stdlib is not optional

There is no lex-only or syntax-only mode. Resolution is lazy and levelled —
unparsed, then signature, then body — and syntax errors inside function bodies
only appear at body resolution. A real syntax check is already the LSP-level
parse, so an embedder inherits the `-I` paths.

`ParserConfig::useBuiltinModule = false` exists (`EntryPoint.h:92`) but produces
nonsense diagnostics for real code. `SharedState.cpp` hard-errors with
*"'std' is required for all normal mojo compiles"*.

Related, and surprising: on this fork imports must be `std.`-qualified.
`from std.collections import Dict` parses clean; `from collections import Dict`
fails with *"unable to locate module 'collections'"*.

### Threading

The parser is single-threaded and there is no incremental reparse. The LSP gets
concurrency by giving each open document its own `MLIRContext` — and pays for it
by re-parsing the stdlib per document, which it has a TODO about
(`MojoServer.cpp:2685-2700`). An editor will meet the same wall.

## Phase 2: elaboration — **mapped**

`runKGENPipeline(ModuleOp, TargetInfoAttr)` (`KGEN/Compiler/KGENCompiler.h:44`)
does comptime evaluation, type checking and post-elaboration lowering in place.
`runElaborationPipeline` (`:58`) is the narrower one and takes an
`AsyncRT::CPUDevice&`.

This is where the Cocoa knowledge lives, and it brings a hard dependency the
parse path does not have: `cocoakb_query` opens `cocoa.sqlite` and fails loudly
without it — *"no Cocoa metadata database is configured; set
MODULAR_MOJO_MAX_COCOAKB_PATH"* (`KGEN/lib/Elaborator/IREvaluatorContext.cpp:1005`).

## Phase 3: object emission — **mapped**

`ObjectCompiler::create(...)` then `emitArchive()` returns a `BufferRef` holding
a static archive, in process.

**Producing an executable is not in the library.** `linkOutput`
(`mojo-build.cpp:646`) is file-static and runs `cc` through
`llvm::sys::ExecuteAndWait`; `generateDSYM` (`:616`) shells out to `xcrun
dsymutil`; `ObjectCompiler` itself resolves `ld64.lld` and executes it. An
embedder gets objects and archives in-process and links by spawning a linker,
exactly as the driver does.

## Phase 4: JIT — **verified, and the known limitation was wrong**

This was documented in this repo as broken:

```
JIT session error: Symbols not found: [_AsyncRT_DeviceContext_create, ...]
```

That was never a limitation of the JIT. `ExecutionEngineOptions::libraryPaths`
(`KGEN/ExecutionEngine/ExecutionEngine.h:58`) feeds an ORC
`EPCDynamicLibrarySearchGenerator`, and `-Xlinker -L` / `-l` reach it. The
symbols were missing because nothing exported them until `libCocoaMojoGPU.dylib`
existed — the same hidden-visibility problem as everything else in this tree.

Handed that dylib, the JIT runs GPU kernels and opens windows:

```
CPU: 81.759 ms
GPU: 0.413 ms
speedup: 197.96 x
exact agreement: 100.0 % ( 0 boundary-band pixels differ)
COMPUTE-SMOKE: PASS
```

`cocoamojo --run` now JITs rather than building to a temporary binary.

Three things to know before embedding it:

- **Only `-L`, `-l`, `-rpath` and absolute dylib paths reach the JIT.**
  Everything else — framework flags especially — is dropped with a warning
  (`XlinkerResolution.cpp`). Frameworks are `dlopen`'d at run time, so windowed
  programs work anyway.
- **`libraryPaths` is `SmallVector<StringRef>`, not of `std::string`.** The
  strings must outlive the engine. `mojo-run.cpp` is correct only incidentally.
- **JIT'd user code runs in your address space.** `executeMain`
  (`mojo-run.cpp:235`) calls it under an `llvm::CrashRecoveryContext`, so a
  segfault is caught — but a call to `exit()` is not, and takes the editor with
  it. This is the strongest argument for keeping execution in a subprocess even
  though the JIT works.

## What will bite

**One compiler per process, and some of it does not reset.**
`Init::createContext` is process-wide and `report_fatal_error`s on a second call
(`Init/lib/Init.cpp:100-104`); use `getOrCreateContext`, which itself
fatal-errors if the requested `Options` differ from the existing context's
(`:120-126`). `llvm::InitializeAllTargets` and friends are global. Four KGEN
targets are `alwayslink` and self-register into `llvm::ManagedStatic`
registries: `TargetTraits`, `KGENToLLVM`, `HostBackend`, and one more.

**Two copies of anything with a registry is fatal, and this tree has already
proved it.** `libMSupportGlobals.dylib` deliberately links `llvm:Support` and
`mlir:Support` to be the single cross-shared-object home for MLIR TypeID
identity. `libLLVM.dylib` carries `llvm:Support` too. Under the toolchain's
default hidden visibility those two copies never saw each other; with visibility
on they do, and the language server died at startup with *"Option 'I' registered
more than once"*. It ships statically linked for that reason. See RELEASE.md.

**Configuration is ambient and global.** `Config::open()` caches the parsed
`modular.cfg` in a function-local static behind `std::call_once`. A stray
`~/.modular/modular.cfg` or `MODULAR_MOJO_MAX_IMPORT_PATH` silently changes what
the embedded compiler does. Without a discoverable config,
`collectDefaultImportPaths` returns no paths *silently*
(`SharedState.cpp:86-90`) and every parse floods with unresolved imports — a
configuration error that presents as a source error.

**The API is C++ and not stable.** Every entry point traffics in
`mlir::ModuleOp`, `llvm::SourceMgr`, `ErrorOr<T>`, `ArrayRef`. An embedder must
be C++ built with the same toolchain against the same
`libMSupportGlobals.dylib`. If the editor is written in anything else, the LSP
over stdin/stdout is the boundary to use, not this.

**Bazel visibility, if the IDE lives in this repo.** `//KGEN:*` targets are
behind `package_group(name = "consumers")` (`KGEN/BUILD.bazel:29-46`), which does
not list a new top-level package — this is why `//KGEN:MojoCompilerShared` is
defined inside `KGEN/BUILD.bazel` rather than under `//bazel`. Several targets an
embedder may want are `//visibility:private` and would need widening:
`ToolCommon.headers`, `KGENDialect.headers`, `POPDialect.headers`,
`ObjectCompiler.headers`.

**No reusable diagnostic-to-editor conversion.**
`buildLspDiagnosticFromSMDiagnostic`, `getRangeFromDiag` and
`buildCodeActionFromSMDiag` all live inside the `mojo-lsp-server` binary, not a
library. Copy them.

**`mojo-lsp-server` is the wrong linkage template.** It is the right *API*
template — it does everything an editor needs — but it links LLVM statically
(68 MB) for the registry reason above, where `cocoamojo` is 30 MB and links
`@rpath/libLLVM.dylib` and `@rpath/libMLIR.dylib`. Copy the code, not the BUILD
file.

## Where to start

Read `KGEN/docs/overviews/LSPParserInteraction.md` — it covers the parse flow,
the two parse paths, diagnostics and threading with line-anchored quotes. Then
`tools/ide-probe/syntax_probe.cpp`, which is sixty lines and runs.
