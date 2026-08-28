# Spike: MojoLLDB as a shipped dylib

**For whoever owns the build.** This is a brief, not a design: the point is
to find out in a day whether the debugger's second half is a week or a
month, and the answer is decided almost entirely by shared-library state,
not by any code we would write.

Nothing here is IDE work. The IDE side is done and shipped — Roast has a
working debugger against Xcode's `lldb-dap`: breakpoints bind, the program
stops, the editor follows. What it cannot do is show you a variable, and
this brief is about why and what it would take.

## The problem, precisely

Variables do not inspect, and it is **not** missing symbols. Measured on a
five-line program built with `--debug-level full --no-optimization`:

    37  DW_TAG_variable
   172  DW_TAG_formal_parameter
    43  DW_TAG_structure_type
   ...  DW_AT_name ("total"), DW_AT_name ("sum")

The DWARF is rich and the locals are named. What stops LLDB is one
attribute on every compile unit:

    DW_AT_language (DW_LANG_Mojo)

LLDB resolves a **TypeSystem plugin** by that tag. Xcode's LLDB has none for
Mojo, so it declines to interpret any variable in those units — including
ones that are plainly `Int` — and says so:

    warning: This version of LLDB has no plugin for the language "mojo".
    Inspection of frame variables will be limited.

`KGEN/lib/MojoLLDB` is that plugin. It is in this tree, 52 files, 540 KB of
C++, and nothing builds it.

## What it would buy

Read from the source rather than the README:

- **`TypeSystem/`** — `MojoTypeSystem` (MLIR → LLDB entities) and
  `MojoDWARFParser` (DWARF → MLIR). This is the blocker removed.
- **`Language/Formatters/`** — real providers for `List`, `Dict`, `Variant`
  (with a mangled-storage-name parser), `PythonObject`, and a
  decorator-driven path for synthetic types. So a `List[Rope]` shows
  elements rather than `_capacity` and a pointer.
- **`ExpressionParser/`** — `JITUserExpression` + `JITExecutionUnit` compile
  a Mojo expression to machine code and run it **in the target process**.
  That is a watch pane and DAP's `evaluate` request, with real Mojo syntax
  calling real methods.
- **`Language/MojoLanguageRuntime`** — `CreateExceptionResolver`, driving
  `mojo break-on-raise`: stop where an error is RAISED rather than where it
  is caught. Hard to get any other way.
- **`REPL/`** — what powers `mojo repl`, and a plausible IDE scratchpad
  later, free once the plugin loads.

## Why it has to be our own lldb

Three independent reasons, any one sufficient.

**ABI.** `Plugin.cpp` exports `PluginInitialize(SBDebugger)` — LLDB's
standard runtime plugin entry point — and the target is a
`modular_shared_library`, so `plugin load` is the intended mechanism. But
the deps name `@llvm-project//lldb:lldb24.0.0git`, and Xcode ships
`lldb-1703.0.236.103`, Apple's own fork. An LLDB plugin links the host's C++
ABI; upstream 24 into Apple 1703 fails to load at best.

**Symbol visibility, which is subtler.** A TypeSystem/Language/
LanguageRuntime plugin is written against `lldb_private` — not the SB API —
and a stock `liblldb` does not export those symbols at all. So even a
perfectly ABI-matched dylib would fail to resolve at load. This is the
silent killer of the "just build against some lldb" idea, and it is why the
tree carries `bazel/public-patches/llvm-lldb-exports.patch`: 99 selective
`LLDB_PRIVATE_EXPORT` annotations, exactly the `lldb_private` surface the
plugin uses, applied to the overlay by `llvm_source.bzl`. Somebody already
fought this fight; the patch is the trophy.

**Global state, which is the loudest.** `RELEASE.md` already has a section
titled "LLVM is a shared library", and `check-dist.sh` already fails with
`duplicate LLVM CommandLine registry`, because two copies of LLVM in one
process means two `ManagedStatic` registries and two sets of `cl::opt`.
Apple's `lldb` has its own LLVM inside it. Loading a `libMojoLLDB` that
pulls OUR `libLLVM` into that process is that abort by construction.

So the shortcut — drop a dylib next to Xcode's lldb — is dead three ways.
We ship our own `lldb-dap` or we do not have this feature.

## The shape it takes here, which is the encouraging part

`MojoLLDB`'s deps are almost entirely libraries the distribution already
ships:

| MojoLLDB needs | already in `dist/CocoaMojo/lib/` |
|---|---|
| `ExecutionEngine`, `KGENDialect`, `MojoTooling`, `ObjectCompiler`, `TransformUtils` | `libMojoCompiler.dylib` (17,481 such symbols exported) |
| `Support:Base/Context/Globals/CrashReporting`, `Init` | `libMSupportGlobals.dylib` |
| `AsyncRT:RuntimeGlobals` | `libAsyncRTRuntimeGlobals.dylib` |
| `llvm:ExecutionEngine` | `libLLVM.dylib` |
| MLIR | `libMLIR.dylib` |
| **`lldb:liblldb`** | **nothing — the only new library** |

`libMojoCompiler` already links `@rpath/libLLVM`, `@rpath/libMLIR`,
`@rpath/libMSupportGlobals`, `@rpath/libAsyncRTRuntimeGlobals`. So
`libMojoLLDB.dylib` is the same shape as something we already build: one
more consumer of the same set, exactly as `mojo-lsp-server` "shares
libLLVM.dylib with the compiler rather than carrying a second copy".

The stipulation that follows, now with the overlay's actual shape:

> **`liblldb` must link the same shared `libLLVM`/`libMLIR` the distribution
> ships — and today it does not.** In the overlay, `lldb24.0.0git` is a
> `cc_binary(linkshared = True)` over the overlay's **static** LLVM
> libraries, and `liblldb.wrapper` is nothing but a `cc_import` of that
> dylib. Built naively, `lldb-dap` embeds a private LLVM inside `liblldb`,
> and loading `libMojoLLDB` (which pulls `@rpath/libLLVM`) into it is the
> two-registry abort again — this time entirely from our own build. Making
> liblldb a consumer of `//bazel/llvm-shared:LLVM` is the same trick
> `RELEASE.md` documents for the compiler, and the export list in
> `bazel/llvm-shared/BUILD.bazel` is where a missing-symbol failure gets
> fixed.

The targets the spike needs all exist in the overlay: `lldb` (line 1025),
`lldb-dap` (1258), `liblldb.wrapper` (1003). And
`bazel/public-patches/llvm-fix-lldb-dap-console.patch` is already applied to
`lldb-dap`'s sources — evidence that building it from this tree was already
contemplated, or done, by whoever left the patch.

## If `plugin load` misbehaves: the embedding fallback

`Plugin.cpp` states it plainly: *"LLDB has two different types of plugin
initialization, we support them both."* Alongside
`PluginInitialize(SBDebugger)` there is a C-callable
`MODULAR_EXPORT bool LLDBPluginInitialize()`, and **MojoJupyter is shipped
prior art for it** — `KGEN/lib/MojoJupyter/Kernel.cpp` includes the
plugin's headers directly and links `:MojoLLDB` and `liblldb` into one
process, no `dlopen` anywhere. So the worst plausible outcome of the spike
is not "no feature"; it is "link the plugin into our `lldb-dap` instead of
loading it", which trades a JSON key in the IDE for a one-target build
change.

## The spike

Time-boxed to a day. Stop at the first thing that does not work and write
down what it was — a negative answer here is worth as much as a positive
one, because it decides whether the IDE's debugger stays at v1 permanently.

0. **Two probes before any real work, seconds each.**

       nm -gU bazel-bin/.../liblldb*.dylib | grep -m1 DumpDataExtractor
       otool -L bazel-bin/KGEN/libMojoLLDB.dylib | grep libLLVM

   The first proves the exports patch reached the build (pick any symbol
   the patch annotates). The second shows whether `libMojoLLDB` links the
   shared LLVM — which side of the two-registry problem we are on.

1. **Build the three artefacts.**

       ./bazelw build --config=release //KGEN:MojoLLDB
       ./bazelw build --config=release @llvm-project//lldb:lldb-dap

   The interesting failure is at link: if `liblldb` brings its own LLVM,
   this is where it shows.

2. **Prove there is one LLVM.** The probe `check-dist.sh` already runs for
   `mojo-lsp-server` — start it, watch for `duplicate LLVM CommandLine
   registry`. If it aborts, apply the `bazel/llvm-shared` pattern to
   liblldb before going further; the rest of the spike is moot until there
   is one LLVM in the process.

3. **Load the plugin.** With `lldb-dap` from step 1:

       plugin load .../libMojoLLDB.dylib

   In DAP this is a `launch` field, `initCommands`, so the IDE side is one
   JSON key and needs no new plumbing. If load fails here with the build
   otherwise healthy, switch to the embedding fallback above rather than
   debugging `dlopen`.

4. **Ask it the question that started this.** Build the program below with
   `--debug-level full --no-optimization`, break on line 9, and run
   `frame variable`. Today it prints nothing. Success is `total` and `sum`
   with values.

       def add(a: Int, b: Int) -> Int:
           var sum = a + b
           return sum


       def main():
           var total = 0
           for i in range(5):
               total = add(total, i)
           print("total:", total)

   When it answers, this becomes a `check-ide.sh` check the same day — a
   working `frame variable` is exactly the kind of thing that regresses
   silently.

5. **Measure the size.** Xcode's `lldb-dap` is 67 MB, but ours links the
   shared LLVM rather than embedding it, so the increment should be far
   smaller. The distribution is 921 MB and the disk image 162 MB; this
   number decides whether the app ships it or fetches it.

## The risk worth watching

`MojoLLDB` deps include `//AsyncRT:RuntimeGlobals` and, under
`hal_device_context_enabled`, `//MLRT:Driver/CompilationDeviceImpl` — the
GPU runtime, inside the debugger's process. `Plugin.cpp` releases AsyncRT on
`SBDebugger::Destroy`, so somebody has already thought about this, but it is
this fork's own AIR/Metal code meeting a process with strong opinions about
global state. If the spike dies anywhere unpatched, expect it here.

## What lands on the IDE side afterwards

Small, and already scaffolded — recorded so the estimate is honest:

- `dap_adapter()` in `ide/roast.mojo` is already a ladder (setting → env →
  Xcode). Prefer `$COCOAMOJO_ROOT/bin/lldb-dap`: one line.
- `initCommands` on `launch` in `ide/dap.mojo`: one JSON key.
- A variables pane: `scopes` then `variables` requests, both plain DAP, and
  the client's request/response machinery already exists.
- Hover and a watch row are the `evaluate` request against the same
  machinery — but they run Mojo code **in the debuggee**, so they arrive
  as explicit gestures, not as something that fires on every mouse move.
- `mojo break-on-raise` as a Debug-menu toggle: an `initCommands` entry.

And one that is ours alone, noted here so it is not forgotten: a `class`
keeps its fields in a single `__mojo_box_<Name>` ivar
(COCOA_CLASS_DESIGN.md). To stock formatters that is an opaque blob on an
`id`. The decorator-driven synthetic path in `Language/Formatters/` is where
a provider goes so that `self` at a breakpoint inside a `RoastGridView`
method shows `caret` and `anchor` — the compiler that invented the box and
the debugger that displays it are in the same tree, which is the whole
argument for shipping our own.

## Notes from building v1, which cost time and might cost yours

- **Debug info is not in the binary.** `--debug-level full` emits a `.dSYM`
  BESIDE the executable. `dwarfdump` on the executable finds nothing and it
  looks broken.
- **`--no-optimization` is not optional.** With optimisation on, `total` and
  `sum` are not in the DWARF at all — eliminated before debug info could
  describe them — and breakpoints slide to whatever line survived.
- **Developer mode gates everything.** With it off, `lldb` does not fail on
  `run`; it HANGS waiting for an authorization dialog no headless process
  can answer. `sudo DevToolsSecurity -enable`. `check-ide.sh` now reads the
  status and skips with the fix printed.
- **Killing an adapter strands its debuggee.** It stays stopped forever with
  nobody to resume it, and `SIGTERM` cannot reap a `SIGSTOP`ped process. DAP
  `disconnect` with `terminateDebuggee` is the answer; `ide/dap.mojo` does
  this now.
