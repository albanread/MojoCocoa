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

## Findings (2026-08-28): the spike PASSED

Run end to end in an afternoon. The answer to the question the brief opens
with: the debugger's second half is **days, not a month** — it already works.

    (lldb) frame variable
    (__mlir_type.`!kgen.scalar<index>`) a = 0
    (__mlir_type.`!kgen.scalar<index>`) b = 0
    (__mlir_type.`!kgen.scalar<index>`) sum = 0

And over DAP — the IDE's actual path, `initCommands: ["plugin load ..."]`,
then `setBreakpoints` → verified, `stopped`, `stackTrace` naming
`main::add(...)`, `scopes`/`variables` with names and values, `disconnect`
clean. The backtrace demangles the whole Mojo stack down to
`__wrap_and_execute_main`, with arguments (`add(a=0, b=0)`).

Per step, with the surprises:

- **Step 0.** Exports patch reached the build: liblldb exports
  `lldb_private::`. But `libMojoLLDB` links **no shared libLLVM** — Bazel
  statically absorbed LLVM/MLIR/KGEN into it (98.6 MB), and liblldb
  (139.6 MB) embeds its own static LLVM too. The stipulation about linking
  the shared libLLVM did not happen and turned out **not to be required**.
- **Steps 1–3.** Everything built first try — 1987 actions, no source
  changes. `plugin load` resolved and initialized. The predicted
  duplicate-`ManagedStatic` abort never fired: two static LLVM copies
  coexist under macOS two-level namespace…
- **…except for one symbol, and it was the crash.** The TargetRegistry's
  list head unifies across the images, so lldb's own target initialization
  and the plugin's `InitializeAllTargets` both append to ONE registry, and
  the next lookup dies with `Cannot choose between targets "aarch64" and
  "aarch64"`. That surfaced as a null `TargetInfoAttr` silently kept by
  `MojoTypeSystem::Impl` and a segfault in `GetPointerByteSize` at
  `breakpoint set` — three frames from the cause, nothing naming it. Two
  fixes, both in tree now: the silent failure is loud
  (`MojoTypeSystem.cpp`), and target registration is idempotent — ask the
  registry before initializing (`Plugin.cpp`), which is right in both
  worlds: inside lldb the registry is already populated and the block must
  not run; embedded standalone (MojoJupyter) it is empty and it must.
- **Step 4.** Passes, CLI and DAP. One extra artefact: `run` shells out to
  **`lldb-argdumper`**, which must be built and shipped beside the binaries
  (`@llvm-project//lldb:lldb-argdumper`); DAP launches do not need it, but
  the CLI does.
- **Step 5.** The increment as-built is **~240 MB** (liblldb 139.6 +
  plugin 98.6 + lldb-dap 1.2 + driver and argdumper), on a 921 MB
  distribution. Bigger than the brief hoped, because the shared-libLLVM
  diet never happened. Re-pointing both at `libLLVM.dylib`/
  `libMojoCompiler.dylib` is now an optimization, not a blocker.

What v2 polish looks like, seen in the output: types print as
`__mlir_type.`!kgen.scalar<index>`` rather than `Int`, and DAP value
strings carry raw hex beside the decimal. Both are formatter-layer work in
`Language/Formatters/`, on a debugger that now runs.

**Follow-through:** the IDE side landed on the `ide-debugger` branch the
same day — the distribution ships the debugger, `dap_adapter()` prefers it,
the plugin loads via `initCommands`, the stopped frame's locals render into
the console, `Break on Raise` is a Debug-menu toggle, and `dap_test`
requires variables whenever the plugin ships. The branch's log carries the
details.

### Findings, second day: expressions

`expr` looked like a crash and was nothing of the kind. Batch lldb stops on
a command error and exits 1; the error was EMPTY, so nothing printed and the
exit read as a die. Two causes, both fixed on main:

- **No search paths.** An expression is real Mojo compiled by the type
  system's own parser, and it could not find the stdlib. The plugin now
  self-locates via `dladdr` — `<root>/lib/libMojoLLDB.dylib` beside
  `<root>/lib/mojo` — with `COCOAMOJO_ROOT` as the override.
- **Diagnostics erased on exit.** `MojoUserExpression::Parse` broadcast its
  DiagnosticManager to the expression logger's listeners and then CLEARED
  it, unconditionally. Jupyter listens; lldb and lldb-dap do not, so every
  expression error left as an empty string. The hand-off is now conditional
  on a listener existing.

What works now: pure expressions JIT and run in the debuggee from the CLI
(`String("hi ") + String(42)` allocates and executes there); a frame
variable evaluates over DAP; and a failure arrives with words. What does
not, named precisely for whoever picks it up: **frame locals are not
injected into the JIT** (the plugin materializes only REPL-persistent
variables, so `total + 41` is "unknown declaration"), and **statement-
wrapped expressions produce no result over DAP** (the CLI's fix-it turns
`1 + 1` into `_ = 1 + 1`, which runs and answers nothing). Those two are
the debugger's next plugin features, in that order.

### Frame locals: the state, and the contract that has to exist first

On `frame-locals-spike`, off by default behind `MOJO_LLDB_FRAME_LOCALS=1`.
Collection works — the frame's variables reach the REPL wrapper as arguments,
which nothing had ever wired up: the wrapper could always take variables (a
notebook's `a` between cells), but the only source connected to it was the
persistent-variable state, and a debugger stopped in someone else's function
has nothing in that.

The frontier moved twice while proving it. `total + 41` first failed at name
resolution; with collection on it fails at TYPE CHECKING —
`'!kgen.scalar<index>' does not implement '__add__'` — so the name binds and
a type flows, but the wrapper receives the DWARF's scalar type rather than
Mojo's `Int`.

**Why this is a correctness boundary rather than finishing work: the JIT
resolves a name it cannot safely read.** Two independently ordered lists are
pretending to be one contract.

    persistent variable:  context -> reference cell -> T     (two derefs)
    frame local:          context -> T                       (one deref)

`AddVariable` puts ONE pointer-sized slot in the context holding the
variable's address; a persistent variable has an extra allocated cell. A
`(name, type)` pair cannot carry that difference. And the ordering: wrapper
fields are emitted persistent-first, materializer entities are registered
frame-first (during parsing) then persistent (in `prepareForExecution`), and
the offset `AddVariable` returns is discarded rather than checked. Once both
kinds coexist the offsets simply will not line up.

The fix is one ordered binding list carrying the capture kind —
`{name, type, PersistentIndirect | FrameAddress, VariableSP}` — used to
generate the field and its dereference depth, to register entities in exactly
that order after compilation, and to assert each returned offset equals the
field it belongs to. Extend the persistent path; do not change notebook
behaviour underneath it.

Two more things the code now says out loud rather than getting wrong
silently. `Materializer::AddVariable` **validates nothing** — it inserts an
entity and never touches the `Status` — so its success is not proof a value
is readable; `GetValueObjectForFrameVariable(..., eNoDynamicValues)` and its
error is the honest preflight. And shadowing currently resolves the wrong
way: persistent variables seed the seen-set first, so they win, where the
frame should.

The gate stays until `total + 41` answers **42** — not until it compiles, not
until it executes. Result materialization is part of the feature. Before
that: reads of locals and arguments, nested shadowing, frame-versus-
persistent name collisions, unavailable locals failing with words, repeated
evaluations and fix-it retries, and both scalar and nontrivial values.

### Why `total + 41` cannot work yet: two erasures, not one

The type-check failure above is not a plugin defect. It is the visible end of
something that happens in the compiler, and it is worth stating precisely
because two plausible-looking fixes are both wrong.

There are **two** erasures, and they are independent:

1. **Representation erasure** — `Meters` becomes the storage it lowers to,
   `index`.
2. **Declaration erasure** — the tie to the real `Meters` *declaration* (its
   fields, its methods, its module) is gone.

Repairing only the first buys nothing. A name attached to a scalar DIE is not
a semantic Mojo type.

**What is still intact, and where.** Instrumenting
`createDebugVariableForVarDecl` (`KGEN/lib/LowerLIT/CheckLifetimes.cpp:103`),
where the debug variable is built, shows full source identity at that point:

    dist : lit.struct<@types::@Meters>
    p    : !lit.struct<@types::@Point>
    n    : !kgen.param<:meta<!lit.struct<@std::@builtin::@simd::@SIMD<
             {:dtype index}, SIMDLength{1}>>>
           sugar_alias(*"Int`0x1", @std::@builtin::@simd::@SIMD<...>)>

Two things fall out of that third line. `Int` **is not a struct**: it is
`SIMD[DType.index, 1]`, which is why its DWARF DIE is a one-element
`DW_TAG_array_type` — that part was never a bug. And its surface name
survives only as a `SugarAttr` (`SugarKind::Alias`), which the debug path
discards: `MojoParser/DebugInfo.cpp:179` wraps `getCanonicalType(type)`.

**Where it goes.** `LowerLITTypes.cpp:211`:

    if (decl.isSingleElement())
      return replacer.replace(fieldTypes.front(), LowerLITReplacer::AsType);

This is the **type** domain, not a debug-info decision, and that is the whole
difficulty: one replacement serves both codegen and debug info, so erasing
for the value representation necessarily erases for the source type. Debug
types are deferred by design — *"Use unresolved types now for simplicity,
these will get resolved during compilation"* — so `DIUnresolvedMLIRType`
resolves through the very replacer that performed the erasure and inherits
it. `Int` and a user's own one-field struct converge on one shared DIE:

    total  0x230  array_type      '!kgen.scalar<index>'
    dist   0x230  array_type      '!kgen.scalar<index>'   <- Meters
    sum    0x230  array_type      '!kgen.scalar<index>'
    p      0x4f6  structure_type  'module types::struct Point'
    label  0x514  structure_type  '...::struct String'

`dist` does not merely share a *name* with the `Int`s. It has no DIE of its
own. Check the `DW_AT_type` reference, not the presence of a name string: an
unused `Meters` DIE elsewhere would read as a false positive.

**Where the surviving names actually come from**, because this cost real
time: not `LowerLITTypes.cpp`. Its `debugTypeConverter` never runs in this
pipeline — both entry points instrumented, marker strings confirmed present
in the staged binary, zero hits. `Point` is named at
`KGENToLLVM/DebugInfoTypeConverter.cpp:293`,
`DIStructType::get(type.getName(), memberTypes)`, where `StructInstanceType`
still carries source identity. `Meters` never reaches it.

**The approach to avoid.** Emitting a `DIBasicType` carrying `Meters`'
encoded `SourceName` produces a `DW_TAG_base_type`, and
`MojoDWARFParser.cpp:397` assumes every base type is a builtin scalar: it
tries the name as a dtype, then as an MLIR type, fails both, and yields no
`CompilerType` at all. Guessing surface types from scalar names is worse than
incomplete — it is ambiguous, since a user's one-field wrapper lowers to the
same scalar as `Int`, and it loses identity again for a one-field *pointer*
wrapper.

The model to hold instead:

    source type:   Meters, with declaration identity and members
    storage type:  index, describing how the bits are located and read

- **Short term** — a named derived source type (`Meters -> index`), lowered
  as `DW_TAG_typedef` or a dedicated annotated derived type, with
  MojoDWARFParser decoding its `SourceName` while reading storage through the
  underlying type. Cost worth knowing before choosing: **the DebugInfo
  dialect has no derived/typedef type**. It has `DIArray`, `DIBasic`,
  `DIMember`, `DIPointer`, `DIStruct`, `DISubroutine`,
  `TargetIndependentPointer`, `DIUnresolvedMLIR`, `DIUnspecified`,
  `DIVariant`, `DIVector` — so this means a new tablegen type plus bytecode,
  LLVM lowering and parser support, not a small patch. (`DIVectorType` has an
  optional name, the nearest existing hook, but it is vector-shaped and does
  not cover the pointer wrapper.)
- **Long term** — keep `DIStructType(Meters, members)` and describe
  scalarization through the variable's location expression and fragments.
  Type metadata describes the source program; location metadata describes
  optimized storage. The flattening site already says so:
  `TODO(#23914): Track this optimization with DWARF expressions.`
- **Separately** — expression compilation must resolve that source name to
  the *real* declaration. `getOrCreateStructDecl` (`MojoTypeSystem.cpp:1249`)
  creates an empty synthetic decl, and `CompleteStructureTypeFromDWARF`
  (`MojoDWARFParser.cpp:548`) adds `DW_TAG_member` fields only. Layout can be
  restored that way; **methods never can**. User types need the module
  declaration surface imported, not reconstructed from DWARF members. Expect
  `Int` and a user type to diverge here: `lookupSingleMember` returns early
  on an existing decl, so `Int` may bind to the real prelude declaration
  while `Meters` gets only a skeleton — a partial success that reads like
  progress and is not.

**Acceptance has to distinguish all three**, or a fix to one will be mistaken
for a fix to the others:

    frame variable sum    -> Meters, and a readable value
    expr sum.value        -> field / layout reconstruction
    expr sum.method()     -> real declaration and method resolution

Today all three fail at the same upstream point, so none of them
discriminates yet.

### The gate is not merely inert: it poisons unrelated expressions

Measured with an expression that mentions no locals at all:

    MOJO_LLDB_FRAME_LOCALS=0   expr 1 + 41   -> evaluates
    MOJO_LLDB_FRAME_LOCALS=1   expr 1 + 41   -> fails

With collection on, *every* frame local goes into the wrapper, so `Point` and
`String` arrive as `Pointer[T]` with `AnyType` / `AnyStruct[Point]`
mismatches and take the whole expression down with them. So "collection
works" was true and incomplete: it works by breaking everything else. Frame
locals need a type filter before they need anything else, and that is a
stronger reason for the default-off gate than the one recorded above. A
separate defect surfaced alongside it: `unable to locate module 'types'` —
the expression parser cannot find the user's own module.

### Provenance, since a stale artifact will happily confirm anything

`tools/make-dist.sh` used to warn and continue when the debugger had not been
built. `DIST_DIR` is normally reused, so that left the *previous*
`libMojoLLDB.dylib` in place and every later test silently exercised a stale
plugin. It now fails with the missing path named (`NO_DEBUGGER=1` to opt out)
and prints the sha256 prefix of each staged binary. Stage into a fresh
directory and compare hashes against `bazel-bin` before believing any
negative result; build the fixture `-g -O0` and confirm zero
`DW_AT_APPLE_optimized` DIEs, or an optimized-away local will look like a
finding.

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
