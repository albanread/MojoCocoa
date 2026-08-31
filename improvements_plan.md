# AIR backend improvements — plan

Source: the code review of 31 August 2026 over the whole AIR lowering
(`KGEN/lib/Target/Air/`, `KGEN/lib/KGENToLLVM/Target/Air/AirLowering.cpp`,
`KGEN/lib/Compiler/ObjectCompiler/Target/Air/`), cross-checked against
`APPLE_GPU_LOWERING_REVIEW.md` (whose P0/P1 sections already prescribe part of
this) and `STATUS.md`.

The sprints that execute this plan are in
[`improvement_sprints.md`](improvement_sprints.md). Sprint 1 is implemented in
the same change that adds these documents.

## Scope rule

This fork's standing discipline applies to everything here: no transform ships
enabled without a clean sweep behind it, no version stamp is guessed rather
than golden-sampled, and every fix keeps its located diagnostic. Where an item
cannot be verified from this machine (or needs a corpus sweep to promote), the
plan says so and the sprint defines the exit criterion rather than landing the
change blind.

## Findings and dispositions

| ID | Finding | Where | Disposition |
| --- | --- | --- | --- |
| F1 | Capture-pack address spaces: `legalizeKernel` types every still-generic AS0 pointer parameter as device AS1, so a by-pointer capture pack (host bytes) is described as a device buffer and the launch dies with "unknown device address". The fix is signature-level typing plus the already golden-sampled `air.indirect_buffer` / `air.struct_type_info` metadata. | `AirBackend.cpp:612`, `TODO(air-indirect)` at `:559` | Sprint 2 — the keystone. Also unlocks precise residency (runtime `markAllResident()` is O(live allocations) precisely because this metadata is missing). |
| F2 | `APPLEGPU_KEEP_AIR` retained artifacts are misnamed and lost: `pre.ll` and `post.ll` are both written after the downgrade pipeline (identical content), all fixed-name artifacts are overwritten per kernel under `SplitStrategy::PerExported`, and the metallib copy has a fixed name. | `AirBackend.cpp:2164-2178`, `:2256-2272`, `:2303` | Sprint 1 — implement the review doc's P1 shape: `<kernel>.<stage>.ll`, `<kernel>.air`, `<kernel>.metallib`. |
| F3 | `splitI64Shuffle` leaves the old `air.simd_shuffle.*.i64` declaration behind; a dead declare is as fatal as a live call, and `checkExternals` would then fail the build once the transform is enabled — the transform defeats itself. | `AirLegality.cpp:915-953` | Sprint 1 — erase dead declarations, mirroring `renameIntrinsics`. |
| F4 | The alloca-privacy heuristic carries a duplicated comment block and a garbled guard (`st->getValueOperand() != u->getOperand(1)` compares a store's value against its own pointer operand, which is true for nearly every store and cannot detect the store-the-alloca-elsewhere case it exists to skip). `allocaBaseOf`'s `depth` parameter is unused. | `AirLegality.cpp:386-399`, `:409`, `:339` | Sprint 1 — one comment, correct guard via `allocaBaseOf`, drop the dead parameter. Log-only rule, so the blast radius is a cleaner log, not different codegen. |
| F5 | The overload-symbols test's header claims the second kernel proves module-scoped declaration sharing, but `main()` runs two `_compile_code` invocations — two modules. `STATUS.md` is right that a same-module multi-kernel case is untested. | `test_air_overload_symbols.mojo` | Sprint 1 — make the comment state exactly what is covered. Sprint 3 — settle whether the shape is reachable in production (PerExported splits at LLVM level; the MLIR pass runs pre-split on the whole module) and either test it or close the STATUS item with that reasoning. |
| F6 | `emitBitcode` emits the module as it stands — unlike `emitAssembly`/`emitObject` it never legalizes, so `--emit` bitcode paths for the AIR target are pre-legalization views. | `AirBackend.cpp:2017-2023`, dispatcher `ObjectCompiler.cpp:1575-1623` | Sprint 1 — document the intent (a view, not an AIR artifact; the reader-compatible artifact is `emitObject` only). Legalizing here would run `legalizeModule` twice on the same module in the emitObject flow's calling discipline, which is not idempotent (it appends `air.kernel` metadata per run), so the fix is documentation plus a non-idempotence note, not a second legalization call. |
| F7 | Stale comments inherited from the x86-64 Vega fork: the second inlining pass is justified with AMD's buffer-resource constraint; `legalizeKernel` still says "v1 requires kernels whose leading params are all pointers" while the code handles by-value scalars. | `AirBackend.cpp:2079-2081`, `:749-750` | Sprint 1. |
| F8 | `legalizeModule` picks the arch from the first defined function's `target-cpu` and silently compiles every kernel in a mixed-arch module for it. | `AirBackend.cpp:1751-1755` | Sprint 1 — diagnose disagreement instead of guessing. |
| F9 | `emitAssembly`/`emitObject` discard the detailed `llvm::Error` from legalization and return only "AIR legalization failed". | `AirBackend.cpp:2028-2029`, `:2037-2038` | Sprint 1 — propagate `llvm::toString` (review doc P1 item 3). |
| F10 | The `.air` temporary is named `llPath` and the metallib `libPath`; indentation drifted at two blocks. | `AirBackend.cpp:2218`, `:1869-1878`, `:2124-2158` | Sprint 1. |
| F11 | The legality firewall's seven `Fail` rules have no in-tree test firing them; the only verification is the spike scripts. `kgen-llvm-opt -passes=air-legality` already exists and is the natural vehicle. | `AirLegality.h`, `KGEN/tools/kgen-llvm-opt` | Sprint 3. |
| F12 | Runtime-side lifetime bugs found in the same review thread: `destroyBuffer`/`~VRBuffer` free Metal buffers without draining in-flight command buffers; `createStream` does not retain its context; GPU-context `CLOCK_RATE` falls through to the host-CPU answer; raw-copy staging allocations unchecked. | `AsyncRT/lib/MojoBindings/AppleGPU{RT,Metal}.cpp` | Sprint 4 — runtime, separate verification surface (stress test per review doc P0 exit criterion). |
| F13 | Default-off work with strong measured rationale awaiting promotion: `applyAirKernelFnAttributes` (MSL fast-math set, `nosync` withheld from barrier-reaching kernels), `rename-llvm-intrinsics` + `guard-nan-minmax`, `split-i64-shuffle` (unblocked by F3). | `AirBackend.cpp:1841`, `AirLegality.cpp` transforms | Sprint 5 — promote each only behind a clean corpus sweep, per the table's own policy. Measured 31 Aug (oracles `findings/air-quality-2026-08-31.md`): the scalarize-wide-vectors knob neither helps nor hurts fma or the unrolled matmul, so it stays off; `rename-llvm-intrinsics`' scalar half has corpus evidence of reader tolerance, making it polish rather than correctness. New evidence-backed item: unrolling the register matmul helps upstream (3058→3216 at 2048³) and hurts us (3113→2951) — the largest remaining compute-side gap, investigate before any transform work. |
| F14 | Perf candidates: per-kernel `xcrun metallib` subprocess (batchable), `air.read_write` stamped on every device buffer (precision needs golden evidence), linear family/rule lookups (~60 entries — fine until the registry grows). | `AirBackend.cpp:767`, `:2283-2299` | Sprint 5, after measurement; the repo's rule is that performance claims carry benchmarks. |

| F15 | The opt pipeline runs against an arm64 TargetMachine for the air64 target, and it SLP-vectorizes float arithmetic into widths no Apple GPU executes — measured 31 Aug: the unrolled register matmul emits `fmul/fadd <16 x float>` packed by 64 `insertelement` chains where upstream emits 256 scalar mul+add pairs. The Scalarizer knob removes the vector arithmetic but not the packing (module grows 671→805 lines), which is why it measured as a no-op. The fix belongs at SLP width/creation, not at cleanup. | `AirBackend.cpp` opt pipeline; evidence in oracles `findings/air-quality-2026-08-31.md` | Sprint 5 item 5 — the top compute-side gap. |

## Match, then exceed — the Apple Silicon thesis

Parity on the visible artifact is now measured, not hoped: fma peak at
parity, large matmuls at parity or ahead, every probe and bench shape
EXACT against upstream on the same machine, same session. What we cannot
see of theirs — their scheduler internals, their property handling — we
were never going to copy, and do not need to: the thesis is focus. Apple
Silicon is one target among many for upstream and none of their
datacentre-shaped priorities (multi-vendor, multi-node, closed kernels)
buy them anything here. It is *the* accelerator for this fork. Concretely,
"exceed" is available on four fronts where being specialized wins:

1. **Codegen for AGX specifically.** Wide-vector float ops, unroll shapes,
   threadgroup-memory tiling and simdgroup-matrix scheduling decided
   against one GPU family instead of five. F15 is the first instance; the
   probe corpus plus `compare-air.sh` is the scoreboard, refreshed after
   every backend change.
2. **The runtime, which is ours alone.** Precise residency via
   `air.indirect_buffer` (Sprint 2), encoder sharing across compatible
   launches, dispatch cost that does not scale with live allocations —
   upstream's runtime is a shared component serving every vendor; ours
   serves one driver on one OS.
3. **Unified memory, used as unified memory.** A datacentre-shaped stack
   treats the GPU as discrete; on this machine host and device are the
   same RAM. Host-pointer binding with precise residency and zero-copy
   paths for the Cocoa compositing case (a `CAMetalLayer` whose texture a
   Mojo kernel wrote microseconds earlier) is something they have no
   reason to build and we use daily.
4. **The desktop iteration loop.** `cocoamojo --run` JITs GPU code;
   compile latency is a feature here in a way it never is for a
   datacentre build farm.

The match/exceed line is empirical, per the usual rule: the oracles
comparison is re-run after each backend sprint and the tables updated in
place. "Ahead" means the same tables reading below 1.00 where they matter,
not a claim.

## What is deliberately not in this plan

- Re-deriving any AIR version stamp or profile number. Those are
  golden-sampled facts (`AirTargetProfile.h`), and `kMetal3_2` stays
  unverified-refused until someone samples a Metal 3.2 toolchain.
- The `convergent`-at-MLIR-declaration design, the `$<hash>` signature
  uniquing, and the rule/transform split. The review found these correct and
  load-bearing; nothing here touches them.
- Upstream backports. The fork is frozen; nothing here has an upstream
  destination.
