<!-- Produced by a five-way survey of the build files, then spot-verified. -->

> **Size, corrected.** An earlier note here said the CMake libraries were larger
> than bazel's because they contain all of LLVM. That was wrong on measurement.
> The code is the same size — `__TEXT` 55.9 MB against bazel's 55.3 for LLVM, and
> for MLIR the CMake one is *smaller*, 78.0 against 79.7. The whole difference was
> `__LINKEDIT`: ~347,000 local symbols CMake keeps and nothing needs at run time.
> Stripped on install, the pair is **62.5 MB and 106.2 MB against bazel's 77.7 and
> 159.5** — 20% and 33% smaller. LLVM_ABI annotations are why: 140,426 exported
> MLIR symbols against bazel's 171,846, because bazel has to open everything with
> `-fvisibility=default` to get a usable dylib at all.
>
> **Acted on already.** The `MLIR_USE_FALLBACK_TYPE_IDS` finding in §4 was a real
> defect in `tools/build-llvm-cmake.sh` as first written, confirmed by measuring
> the two libraries: 10,876 `TypeIDResolver` symbols in the bazel `libMLIR.dylib`
> against 5,182 in the CMake one. The flag, `-UNDEBUG`, and `lld` are now in that
> script. Everything else below is unstarted.

# Scoping: a CMake build for the Mojo compiler (MojoCocoa)

**Author's note on confidence.** Five surveys read the build files; I spot-verified the load-bearing claims against the tree (`bazel/api.bzl:61-65`, `bazel/internal/cc-toolchain/args/BUILD.bazel:126-134`, `Support/BUILD.bazel:1092-1101`, `tools/make-ninja.py:29-60`, and the contents of `/Volumes/xc/llvm-cmake/install`). **Nobody has compiled a single first-party `.cpp` outside bazel.** Everything below about the tablegen layer is measured; everything about the 542-file compile-and-link layer is inferred from build files. That asymmetry matters and is called out again in §6.

---

## 1. Verdict

**Do it — but only if the goal is "no bazel anywhere, cold build from a clean checkout." If the goal is faster iteration, this is the wrong purchase.**

Three options, honestly compared:

| | Keeps working today | Cold build without bazel | Cost to reach | Failure mode when wrong |
|---|---|---|---|---|
| **Keep bazel** | yes | no | zero | none — it works |
| **ninja replay** (`tools/make-ninja.py`) | source edits only | **no, and probably never** | already spent | build failures, countable, converging |
| **CMake port** | n/a | yes | 4–7 focused weeks | **runtime silent failures**, few but invisible |

The ninja route is not 90% done — it is done for what it can do, and structurally incapable of the rest. Its own header says why: bazel's execution contract is implicit, 2,558 of 9,851 actions have no command line at all, and "there is no way to know how many remain" (`tools/make-ninja.py:29-60`). That is an *unbounded* tail: the unknowns are discovered only by collision, and the space of things bazel does from internal state is not enumerable from outside.

**The CMake tail is a different shape, and this is the single most important claim in this document.** The CMake port's unknowns are enumerable up front, because CMake is not replaying anything — you are re-deriving the build from source, and the source is bounded: 142 target entries in 7 packages, one 421-line flag file, 105 `.td` files, and a named list of six semantic traps. There is no hidden execution contract to discover.

But it is not free of tail, and the tail is *worse in kind while smaller in size*: **the CMake port trades build-failure risk for runtime-correctness risk.** A wrong `alwayslink`, a wrong `MLIR_USE_FALLBACK_TYPE_IDS`, a missing `-Wl,-u`, a dropped `exports_filter` — every one of those links cleanly and produces a compiler that starts up and then misbehaves in a way that looks like memory corruption or a missing dialect. There are approximately **five** such traps, all named in §4 and §5, all with a specific verification test. Five known silent failures with known tests is a manageable risk. It is *not* the same as forty unknown build failures with no denominator.

Two facts strengthen the case materially:

- **The hard half is already done and worked first try.** LLVM+MLIR: 5,191 actions, zero failures, first configure succeeded without adjustment (`tools/build-llvm-cmake.sh:37-38`). That is the part everyone expects to be painful.
- **The first-party half is smaller than the repo suggests.** Not 690 targets — 690 is what `bazel query` returns, and 198 of those are auto-generated clang-tidy tests. The real number for `mojo` + `libMojoCompiler.dylib` is **142 entries across 7 packages** (`KGEN` 71, `Support` 52, `AsyncRT` 4, `Config` 2, `KGEN/tools/mojo` 2+9, `Cache` 1, `Init` 1).

The case against: you already have a working build. If bazel is merely annoying rather than blocking, 4–7 weeks buys you a second build system to keep in sync, and CMake will not enforce `layering_check`, so the dependency graph starts drifting from day one.

---

## 2. Phases

Ordered so the two decisions that can kill the project are resolved in the first week, not the last.

### Phase 0 — Resolve the ABI decision (**1–2 days**)

**This must be first. It is the only thing in the project that can invalidate a month of work retroactively.**

`bazel/internal/cc-toolchain/args/BUILD.bazel:132-134` applies `-DMLIR_USE_FALLBACK_TYPE_IDS=1` to *every* compile action, including MLIR's own. `tools/build-llvm-cmake.sh:105-106` passes only `-mcpu=apple-m4 -std=c++20`. The header default is `false` (`install/include/mlir/Support/TypeID.h:311-312`). Measured evidence: the bazel `libMLIR.dylib` exports **1** self-owning `TypeIDResolver<T,void>::id` symbol; the CMake one exports **5,181**.

There is no CMake option for this — it is a raw preprocessor switch, so it has to go into `CMAKE_CXX_FLAGS` for the whole LLVM/MLIR build.

Also settle in the same pass: drop `-DLLVM_BUILD_STATIC` (it collapses `LLVM_ABI` to nothing against a dylib-exporting install — `install/include/llvm/Support/Compiler.h:187`), and decide the `NDEBUG` story (this tree needs `-UNDEBUG` in *every* config including release; `CMAKE_BUILD_TYPE=Release` fights you).

**Done looks like:** a written decision, and if the decision is "keep fallback TypeIDs," an LLVM/MLIR install rebuilt with `-DMLIR_USE_FALLBACK_TYPE_IDS=1` in `CMAKE_CXX_FLAGS`.
**Verify:** `nm -gU libMLIR.dylib | grep -c 'TypeIDResolver.*::id'` returns ~1, not ~5181. Then compile a 30-line program that gets a `TypeID` for a builtin type in the main binary and passes it into a dylib, and assert equality.
**Drives effort:** the LLVM rebuild is ~1–2 hours wall clock on an M4 Max, but you may need two attempts.

### Phase 1 — `driver-tblgen` and the whole tablegen layer (**3–5 days**)

This is the second-riskiest unknown and it resolves cheaply, so it goes early. It is also the phase with the most measured evidence behind it.

Build `Support/tools/driver-tblgen` first (it needs only `Error.cpp` + `ErrorOr.cpp` from Support, plus `LLVMTableGen` + `LLVMSupport` — its declared `//Support:Base` dep is a 10x overstatement). Because it returns `llvm::TableGenMain` (`driver-tblgen.cpp:73`), it already accepts `-I`, `-o`, `-d`, `--write-if-changed` — exactly what CMake's generic `tablegen(PROJECT ofn)` macro passes. So: `set(DRIVER_TABLEGEN_EXE ...)`, `tablegen(DRIVER ...)`, no `add_custom_command`.

Then the 8 dialects via `add_mlir_dialect()`, 53 loose `mlir_tablegen()` calls, 3 `-gen-pass-decls`, 9 `driver_option_tablegen` sites. All 20 mlir-tblgen flags used are stock (verified against `mlir-tblgen --help`, 58 generators advertised). Zero `.pdll`, zero `-gen-rewriters`.

**Done looks like:** **131 `.inc` files** on disk, matching the 131 in `bazel-bin/{KGEN,Support}` file-for-file.
**Verify:** `diff -r` the generated tree against `bazel-bin`. They should be byte-identical except for path strings.
**Drives effort:** ~19 `CMakeLists.txt` files under `include/` mirroring the `.td` tree; one wrong include path shows up as a missing `.h.inc` hundreds of files deep. `CO.td` needs its own directory on the path (verified failure, verified fix).

### Phase 2 — Third-party, and the telemetry decision (**2–8 days — huge variance, see below**)

Only six external repos are referenced by first-party BUILD files. Trivial: `sqlite3` (SDK `.tbd`), `xxhash` (exact version match in brew; **do not** define `XXH_INLINE_ALL`), `fmt` (FetchContent 11.2.0 — brew's 12.x is a major ahead), `zlib` (SDK). Crashpad is *not* the hard case people expect: Backtrace's fork ships 12 `CMakeLists.txt` including the Apple MIG codegen, so it is `FetchContent` + `add_subdirectory`.

The variance is entirely **opentelemetry-cpp**. It is pinned at 1.19.0; brew has 1.28.0; the code is built on `opentelemetry::logs::EventLogger` / `EventLoggerProvider`, the Events API upstream removed after 1.19. And it is the *sole* source of protobuf (3,674 symbols), abseil (1,747), boringssl (600), curl and nlohmann in a compiler that `#include`s none of them — verified zero hits for `google/protobuf`, `absl/`, `openssl/` across all six first-party trees.

**Recommendation: stub telemetry in the first cut.** The public surface outside `Support/` is 7 names across 28 references in 7 files. A ~200-line null implementation replaces 1,923 lines and deletes five heavyweight dependencies at a stroke. The repo already has the pattern — `bazel/api.bzl:174-178` replaces `Profiling` and `ProfilerHostGlue` by name with stubs.

**Done looks like:** every third-party target resolves via `find_package` or `FetchContent`, with the telemetry decision recorded.
**Verify:** `otool -L` on a trivial link of `Support:Base` shows no `/opt/homebrew` paths.
**Drives effort:** 2 days if telemetry is stubbed; 5–8 days if it is kept (FetchContent-pinning otel 1.19.0 + protobuf 33.5 + abseil is a long first build and a live ODR hazard when mixed with brew packages).

### Phase 3 — Support, Config, Init, Cache, AsyncRT (**4–6 days**)

60 entries. Straight `add_library` work, plus the one-time chore that cannot be automated: **auditing the include-path contract of every target**. `modular_cc_library` applies `strip_include_prefix="include"` only when `hdrs[0]` starts with `include/` (`bazel/internal/modular_cc_library.bzl:41-50`), and 43 of the 80 closure libraries build `hdrs` with `glob()`. So the include root a target exposes depends on a sorted glob result, not on anything written in the BUILD file. You must read `bazel-bin`, not the BUILD text.

Do not forget `Support:Globals`' `-Wl,-u,__ZN4mlir6detail22FallbackTypeIDResolver22registerImplicitTypeIDEN4llvm9StringRefE` (`Support/BUILD.bazel:1092-1101`) — one line, load-bearing, trivially dropped by accident.

**Done looks like:** all of Support compiles and archives; `Support/tools/build-info` and `system-info` link and run.
**Verify:** compile-and-link only. No behaviour to test yet.

### Phase 4 — KGEN (**5–8 days**)

71 entries, 297 non-test `.cpp`, and the bulk of the 320k lines. Mostly mechanical, with three specifics:

- Preserve the 11 `.headers`/impl splits **verbatim** — they exist to break dependency cycles between KGEN libraries.
- `-DMOJO_CONFIG_SECTION=mojo-max -DMAX_CONFIG_SECTION=max` (hard `#error` guard, `KGEN/lib/Support/Configuration.cpp:22-28`; correct values from `tools/check-dist.sh:127`).
- `_OVERRIDE_DEFINES` (`bazel/api.bzl:61-65`) forces three defines to `0` that the BUILD files write as `1`. Transcribing the BUILD files literally compiles a different program.

**Done looks like:** every KGEN library archives; `kgen` and `mojo-lsp-server` link.
**Verify:** `mojo-lsp-server --version`.
**Drives effort:** volume, plus `-Werror=global-constructors` and the 29-flag warning set surfacing latent warnings the bazel per-target `copts` have been suppressing one site at a time.

### Phase 5 — Link `mojo` and rewrite runfiles (**3–5 days**)

Two hard items here, both real work rather than transcription.

**Runfiles has no CMake equivalent at all.** `Support:BazelRunfiles` links `@rules_cc//cc/runfiles` and calls `Runfiles::Create(execPath, BAZEL_CURRENT_REPOSITORY, nullptr)` (`Support/lib/BazelRunfiles.cpp:101-108`), where `BAZEL_CURRENT_REPOSITORY` is a define injected by rules_cc. `ObjectCompiler` finds `lld` through it (`KGEN/BUILD.bazel:1428-1430`); the driver finds `lldb` through it. **This is a source change, not a build-file change**: rewrite it to resolve tools relative to the executable path. Until it is done, a CMake-built `mojo` builds, links, starts, and fails the instant it tries to emit an object file.

Related, and I verified it: **the CMake LLVM install has no `lld`.** `LLVM_ENABLE_PROJECTS=mlir` only; `install/bin` holds 100 files, none of them `lld`, `FileCheck`, `llvm-lit`, or gtest. Add `lld` to `LLVM_ENABLE_PROJECTS` and install it, or `ObjectCompiler` falls back to a bare `PATH` lookup for `ld64.lld`.

Second item: `cc_shared_library`'s `exports_filter` (`KGEN/BUILD.bazel:1223-1245`) has no analogue. CMake will happily produce two copies of LLVM's `ManagedStatic` registry in one process.

**Done looks like:** `mojo --version` runs; `mojo build` on a hello-world emits an object file and links it.
**Verify:** that hello-world, end to end, with `-I` pointing at `mojo/stdlib` sources.

### Phase 6 — Runtime correctness validation (**3–5 days**)

Not optional, and not folded into Phase 5, because this is where the silent-failure class gets caught. Explicit checks for: every code-generation target registering (`alwayslink`); MLIR TypeIDs agreeing across the dylib boundary; no duplicate `ManagedStatic`; the dialect checksum.

**Done looks like:** `mojo build` and `mojo run` produce byte-comparable behaviour to the bazel-built compiler on the `KGEN/test/mojo-parser` corpus (493 `.mojo` inputs, resolving against the 19-file checked-in mock stdlib — no precompile step needed).
**Verify:** diff the output of both compilers over that corpus.

### Phase 7 — Tests (**5–10 days, deferrable indefinitely**)

`lit` needs `FileCheck` and `llvm-lit`, neither of which the install prefix has. Unit tests need gtest, which a stock LLVM install does not export (`LLVM_INCLUDE_TESTS=OFF` in `build-llvm-cmake.sh:100`). Both are LLVM-configure changes, not CMake-port work.

---

### Totals

| Phase | Days |
|---|---|
| 0 ABI decision | 1–2 |
| 1 tablegen + driver-tblgen | 3–5 |
| 2 third-party | 2–8 |
| 3 Support/Config/Init/Cache/AsyncRT | 4–6 |
| 4 KGEN | 5–8 |
| 5 link + runfiles rewrite | 3–5 |
| 6 runtime validation | 3–5 |
| **Working `mojo`** | **21–39 engineer-days** |
| 7 tests | +5–10 |

**Call it 4–7 focused weeks for one person to a working compiler**, with the spread driven almost entirely by (a) the telemetry decision, (b) how many latent warnings `-Werror=global-constructors` surfaces, and (c) whether Phase 0 goes the way you want.

**Do not read the Mojo stdlib into this estimate.** It is not in scope and not a prerequisite. The bootstrap arrow points one way: `mojo` is the tool `mojo_library` invokes, never a consumer of Mojo output. Verified four ways — the shipped target `//KGEN/tools/mojo:mojo` has no `mojo_deps`; the release output tree contains zero `.mojoc`; `Support`/`Init`/`Config`/`Cache` have zero Mojo references; the distribution ships 1,263 `.mojo` *sources* and zero `.mojopkg`. There are ~2,500 lines of Starlark Mojo rules the port never has to reimplement. (One trap: `tools/make-dist.sh:20` prints `bazel build //KGEN:mojo`, which *is* an alias for `mojo-full` and *does* precompile the stdlib — but line 25 then copies the mojo-free binary. Scope from `rebuild.sh:33`, not from that printed command.)

---

## 3. What can be dropped in a first cut, and what it costs

| Drop | Count | Cost |
|---|---|---|
| **Tests** (`modular_cc_test`, `lit_tests`, benchmarks, examples) | ~159 invocations | You validate against `KGEN/test/mojo-parser` by hand instead. Real, but Phase 6 covers the important part. |
| **Clang-tidy targets** | ~960 generated | **Zero.** Auto-generated; `CMAKE_EXPORT_COMPILE_COMMANDS=ON` + `run-clang-tidy` recovers it whenever you want. |
| **`layering_check` / `parse_headers`** | 28 packages | **No CMake equivalent exists.** First build still links — the graph is provably layered *today*. From then on nothing prevents drift, and any return to bazel gets progressively harder. Also the reason the 422 headers are known self-contained, which is a gift you are spending. |
| **Telemetry** | 1,923 lines, 7 names outside Support | Deletes otel + protobuf + abseil + boringssl + curl + nlohmann. **~2.3 MB (15%) of the shipped binary's `__text` for a feature that is off.** Requires a source change: there is *no* compile-time switch — `MODULAR_TELEMETRY_ENABLED` is a plain runtime config key (`Support/lib/Configuration.cpp:264-274`). |
| **Crash reporting** | 137 lines, 4 entry points | The handler binary isn't even shipped (`find dist -name '*crashpad*'` → nothing), so it cannot succeed today. Drops 5 Apple frameworks + `-lbsm`. |
| **Docs** (`-gen-dialect-doc`, `-gen-pass-doc`, man, markdown) | 35 of 175 tablegen actions | Nothing compiled. **20% of the tablegen work for free.** |
| **`.dwarf` / `.stripped` output groups, runtool, mojo_deps env, `internal_deps`** | ~100 | Zero — all bazel-run plumbing, and `internal_deps` references `//MLRT` and config settings that **do not exist in this repo**. |
| **`mlir_nanobind` / nanobind rules** | 6 | Zero — already `_noop` in `bazel/api.bzl:266-273`. |
| **Tracy** | 7 select sites | Zero — `@tracy` isn't a repo, `//:tracy_enabled` isn't defined, and `Support/internal/Tracy/` doesn't exist on disk. A faithful port would reproduce a select on a flag that doesn't exist and then hunt for missing sources. |

**Keep, do not drop:** `driver-tblgen` (9 driver `.cpp` files `#include` its output — the driver does not compile without it), the dialect checksum (see below), and `alwayslink` (see below).

---

## 4. The three things most likely to go wrong

### 1. `MLIR_USE_FALLBACK_TYPE_IDS` mismatch — silent, total, and retroactive

The flag is toolchain-wide in bazel and absent from the existing CMake LLVM. Measured: **1 self-owning TypeID symbol in the bazel `libMLIR.dylib` vs 5,181 in the CMake one.** The two are different definitions of the same header template specialisation. Mixing them links cleanly and then computes different `TypeID`s than the ones baked into the dylib — dialect, op, attribute, and interface lookups silently miss.

This is first because discovering it in Phase 5 means the LLVM install, and possibly some design assumptions, were wrong for a month. The flag exists specifically so MLIR objects can cross shared-library boundaries — which is precisely what a `libMLIR.dylib` + `libMojoCompiler.dylib` split does.

### 2. The `alwayslink` / force-load class

Four compiler-closure libraries — `TargetTraits`, `KGENToLLVM`, `HostBackend`, `ObjectCompiler` — register code-generation targets through static initialisers and are never referenced by symbol. `KGEN/BUILD.bazel:1447-1450` says so outright: *"TargetBackend implementations self-register via a static initializer and aren't referenced directly, so the linker would drop them."* Same shape as `Support:ProfilerHostGlue` (`Support/BUILD.bazel:487-489`) and the `-Wl,-u` on `Support:Globals`.

**CMake has no `alwayslink` property.** A straightforward `add_library` port produces a compiler that builds, links, starts, and reports no available code-generation targets. Nothing appears in any build log. The fix is per-consumer `$<LINK_LIBRARY:WHOLE_ARCHIVE,...>` or `-Wl,-force_load`, written by hand, five times, correctly.

### 3. `api.bzl` silently rewriting the build

The obvious way to write this port — read the BUILD files, transcribe them — is wrong in seven places, four of them silent:

- `_OVERRIDE_DEFINES` (`bazel/api.bzl:61-65`) flips `MOJO_COMPILER_ACCELERATOR_SUPPORT`, `MODULAR_KGEN_PROFILING_ENABLED`, `MLRT_ACCELERATOR_SUPPORT` from the `1` written in the BUILD files to `0`. Seven source files read these macros. Silent.
- Three targets are replaced **by name** with a `TimeProfiler` stub (`Profiling`, `ProfilerHostGlue`, `MAXProfilerPlugin`). Loud — one of them lists sources that don't exist — which is the good outcome.
- `internal_deps` is captured and dropped, erasing every `//MLRT` dep and 11 `select()` sites.

**Read `bazel/api.bzl` before writing a single line of CMake.** It is 273 lines and it is the difference between porting the build and porting a description of the build.

**Runner-up, and it will bite:** the dialect checksum. `gen_dialect_checksum.py:38` hashes `sorted(args.td_files)` — sorting the literal path strings it was handed — over bazel's *transitive* `td_library` closure, which is **97 files including 33 of MLIR's own `.td`**, not the 64 first-party ones you'd guess. A CMake build will produce a different `MOJO_DIALECT_CHECKSUM` from byte-identical sources. Nothing fails to build; every `.mojoc` from one compiler is simply rejected by the other, with an error message that blames compiler versions (`MojoPrecompiledFile.cpp:43`). Decide deliberately: reproduce the exact value, or accept the artifact-compatibility fork.

---

## 5. What the surveys could not determine

Stated plainly, because this is where a tail would hide.

1. **The entire compile-and-link layer is unexamined.** 542 `.cpp`, ~320k lines, and not one of them has been compiled outside bazel. Every estimate for Phases 3–4 is derived from build files, not from a compiler. **This is the single largest unknown in the project.** The tablegen survey's own author flags it: high confidence there, "do not let that confidence transfer."
2. **How many `-Werror=global-constructors` sites exist.** Three targets already opt out individually, which suggests these have been accreting one at a time. Unknowable until you compile.
3. **Whether Homebrew's opentelemetry-cpp 1.28.0 still ships `api/include/opentelemetry/logs/event_logger.h`.** Explicitly unverified — checked offline only. If it doesn't, `find_package` against brew is a dead end. Verify this before committing to any telemetry path.
4. **Whether the brew otel bottle is built with `WITH_OTLP_HTTP=ON`.** Unverified.
5. **Whether crashpad's CMake build actually configures on macOS.** Read, not run. `util/CMakeLists.txt:374-376` hardcodes `MIG_ARCH` to arm64 when `CMAKE_OSX_ARCHITECTURES` is unset — correct here, wrong for a universal build. Its targets also use bare unnamespaced names (`client`, `util`, `compat`) that can collide.
6. **The actual include-path contract of 43 of the 80 closure libraries.** Derived from sorted `glob()` results; must be read out of `bazel-bin` per target. One-time, but it is 80 manual inspections.
7. **Whether `exports_filter` is load-bearing at runtime.** Nobody tested what happens with two copies of `ManagedStatic` in one process. The BUILD comment implies it matters; that's an implication, not a measurement.
8. **Whether clang 22.1.4 can be swapped.** At least `-Wno-c2y-extensions` is recent enough that Apple clang may reject it, and `-Werror=unused-command-line-argument` is in the same flag set.
9. **Minor survey disagreements**, none load-bearing but worth knowing the numbers are ±10%: non-test `.cpp` 436 vs 441; `modular_cc_test` 58 vs 51; `alwayslink` 9 vs 7.

**Now determined by this pass, and not in the surveys:** the CMake LLVM install prefix has **no `lld`, no `FileCheck`, no `llvm-lit`, and no gtest** (100 binaries in `install/bin`; `LLVM_ENABLE_PROJECTS=mlir` only; `LLVM_INCLUDE_TESTS=OFF`). Phase 5 needs `lld` added; Phase 7 needs the other three. Both are one-line changes to `build-llvm-cmake.sh` plus a rebuild — cheap, but only if done at the same time as the Phase 0 rebuild rather than as a third full LLVM build.

---

## 6. Bottom line

This does **not** have the same tail as the aquery replay. That project's unknowns were unbounded because it was reverse-engineering an implicit execution contract by collision. This one's unknowns are bounded by the source: 142 targets, one flag file, 105 `.td` files, six named traps.

But it has a tail, and it is a *different* tail: **build failures converge and you can count them; the CMake port's residual risk is a handful of silent runtime failures that no build log will ever show you.** Five of them are named above, each with a specific test. Phase 6 exists solely to catch them, and it should not be compressed.

The honest asymmetry in this scoping: the tablegen layer was measured — generators run, 131 `.inc` files verified file-for-file against `bazel-bin` — and it is 3–5 days. The 320k-line compile-and-link layer was only read, and it is 9–14 days. If the estimate breaks, it breaks there, and it breaks by 50%, not by 500%.

**Recommendation: commit to Phase 0 and Phase 1 only — one week, ~5 days.** At the end of that week you will have resolved the ABI question definitively, built `driver-tblgen`, and generated 131 `.inc` files that diff clean against bazel's. That is a real, verifiable checkpoint, and it is enough information to decide whether the remaining 16–34 days are worth spending. If Phase 1 comes in on estimate, the rest is volume, not risk. If it doesn't, you have spent a week instead of a month.