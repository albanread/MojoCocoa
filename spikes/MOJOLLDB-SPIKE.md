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

Two independent reasons, either one sufficient.

**ABI.** `Plugin.cpp` exports `PluginInitialize(SBDebugger)` — LLDB's
standard runtime plugin entry point — and the target is a
`modular_shared_library`, so `plugin load` is the intended mechanism. But
the deps name `@llvm-project//lldb:lldb24.0.0git`, and Xcode ships
`lldb-1703.0.236.103`, Apple's own fork. An LLDB plugin links the host's C++
ABI; upstream 24 into Apple 1703 fails to load at best.

**Global state, which is the real one.** `RELEASE.md` already has a section
titled "LLVM is a shared library", and `check-dist.sh` already fails with
`duplicate LLVM CommandLine registry`, because two copies of LLVM in one
process means two `ManagedStatic` registries and two sets of `cl::opt`.
Apple's `lldb` has its own LLVM inside it. Loading a `libMojoLLDB` that
pulls OUR `libLLVM` into that process is that abort by construction.

So the shortcut — drop a dylib next to Xcode's lldb — is dead on both
counts. We ship our own `lldb-dap` or we do not have this feature.

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

The stipulation that follows:

> **`liblldb` must link the same shared `libLLVM`/`libMLIR` the distribution
> ships.** `--config=release` already links both as shared libraries, and
> the `@llvm-project//lldb:liblldb.wrapper` in the deps suggests the wrapper
> exists for exactly this. Confirm rather than assume.

Bazel already exposes what is needed:

    @llvm-project//lldb:lldb
    @llvm-project//lldb:lldb-dap

## The spike

Time-boxed to a day. Stop at the first thing that does not work and write
down what it was — a negative answer here is worth as much as a positive
one, because it decides whether the IDE's debugger stays at v1 permanently.

1. **Build the three artefacts.**

       ./bazelw build --config=release //KGEN:MojoLLDB
       ./bazelw build --config=release @llvm-project//lldb:lldb-dap

   The interesting failure is at link: if `liblldb` brings its own LLVM,
   this is where it shows.

2. **Prove there is one LLVM.** The probe `check-dist.sh` already runs for
   `mojo-lsp-server` — start it, watch for `duplicate LLVM CommandLine
   registry`. If it aborts, the rest of the spike is moot until the wrapper
   is doing its job.

3. **Load the plugin.** With `lldb-dap` from step 1:

       plugin load .../libMojoLLDB.dylib

   In DAP this is a `launch` field, `initCommands`, so the IDE side is one
   JSON key and needs no new plumbing.

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
global state. If the spike dies anywhere, expect it here.

## What lands on the IDE side afterwards

Small, and already scaffolded — recorded so the estimate is honest:

- `dap_adapter()` in `ide/roast.mojo` is already a ladder (setting → env →
  Xcode). Prefer `$COCOAMOJO_ROOT/bin/lldb-dap`: one line.
- `initCommands` on `launch` in `ide/dap.mojo`: one JSON key.
- A variables pane: `scopes` then `variables` requests, both plain DAP, and
  the client's request/response machinery already exists.
- `mojo break-on-raise` as a Debug-menu toggle: an `initCommands` entry.

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
