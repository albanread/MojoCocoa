# AIR backend improvements — sprints

Execution order for [`improvements_plan.md`](improvements_plan.md). Each sprint
carries its own verification; nothing is promoted without the sweep the plan's
scope rule requires.

## Sprint 1 — mechanical fixes and diagnostic hygiene (IMPLEMENTED)

All compiler-side, all verifiable from this machine. Implemented together with
these two documents.

1. **Retained artifacts, per kernel and per stage (F2, F10).**
   `APPLEGPU_KEEP_AIR=<dir>` now writes `<kernel>.pre.ll` (canonical IR after
   legalization, before the downgrade pipeline), `<kernel>.post.ll` (after
   `LLVMIRDowngradePass` + `PointerRewriter` + the post-inlining re-legalization),
   `<kernel>.air` (the bitcode as packaged), `<kernel>.metallib`, and on a gate
   rejection `<kernel>.rejected.ll`. The kernel stem is the module name,
   sanitized; the previous fixed names meant the last kernel of a multi-kernel
   build silently overwrote every earlier one, and `pre`/`post` were identical
   because both dumps sat after the pipeline.
2. **Legalization errors keep their cause (F9).** `emitAssembly` and
   `emitObject` propagate `llvm::toString(std::move(err))` instead of
   collapsing to "AIR legalization failed".
3. `splitI64Shuffle` erases the declarations it emptied (F3), mirroring
   `renameIntrinsics`; without this, enabling the transform fails every build
   at `checkExternals` on its own dead declaration.
4. **Alloca-privacy heuristic cleanup (F4).** One copy of the comment; the
   store-into-slot test is `allocaBaseOf(store->getPointerOperand()) == base`
   instead of the self-comparing operand check; `allocaBaseOf` drops its unused
   `depth` parameter. `generic-deref` stays Log-only.
5. **Mixed-arch modules are diagnosed, not guessed at (F8).**
   `legalizeModule` collects every defined function's `target-cpu` and refuses
   the module if they disagree, naming both values.
6. **Comment truth (F5, F6, F7).** The second inlining block cites the Apple
   invariant (re-legalize what inlining pulls in; Metal fully inlines kernels)
   rather than AMD's; `legalizeKernel`'s per-argument metadata comment
   describes scalar handling instead of the stale "v1 requires all pointers";
   `emitBitcode` documents that it is deliberately a pre-legalization view;
   the overload test's header states exactly what its two `_compile_code`
   invocations do and do not cover.

Verification: `./bazelw test //max/kernels/test/gpu/compile:test_air_overload_symbols.mojo.test
//max/kernels/test/gpu/compile:test_air_target_profile.mojo.test
--nocache_test_results --test_output=errors`, plus an `APPLEGPU_KEEP_AIR`
retention check through `emitAssembly` and a syntax build of the two Air
libraries. Exit: green, and a KEEP_AIR run of a two-kernel file leaves four
distinct per-kernel artifacts.

## Sprint 2 — the keystone: capture-pack address spaces (F1)

**Status 31 Aug: part one landed.** Single-aggregate capture packs (the
TileTensor shape of nn/index_tensor) now type constant: AirLowering stamps
exported kernels and enables the byval kernel-argument hook upstream built
for exactly this, and `legalizeKernel` types a byval-of-struct pointer
parameter as constant AS(2) with constant metadata sized to match the
launcher's packing. `test_index_tensor`: FAIL → PASS; full GPU-tree sweep
shows zero new failures against the committed corpus baseline (the two
`fail`s outside the baseline — differential and gated_group_rmsnorm — fail
identically on the unmodified compiler at current HEAD; the fp8_gemv
regression was this sprint's own reroute flip, reverted). The runtime needed
no change: reflection-driven setBytes already existed.

**The remaining sub-case is now precisely understood (31 Aug, evening).**
The component-build loop (private dist + `cocoamojo`, AIR swapped by
replacing `bin/cocoamojo-compiler` — the driver carries the compiler
statically; `libMojoCompiler.dylib` is the embedder's copy and never
affects it) plus three standalone reproducers established, by
intervention:

1. **Pointer captures are device BY DESIGN.** The launcher packs the
   address as the slot's bytes; the runtime resolves it in the allocation
   registry and binds the real buffer with setBuffer. Typing such a slot
   constant (tried: `kgen.offload.capture` marker → byval([N x i8]))
   BREAKS it — the kernel then reads constant space at a stack address.
   Reverted; agg_caps.mojo is the standing reproducer for the correct
   behavior.
2. **The rms_norm blocker is not a typing problem at all.** Its adapter
   captures by REFERENCE: the slot's bytes are a pointer to HOST memory
   (`0x16f3…` stack addresses in every failure log), which no AIR address
   space can make readable. The pointee must be copied into the pack at
   marshaling time — a change to the capture ABI (`_to_device_type` for
   by-ref captures on GPU targets, Mojo/kernels side), not to the AIR
   backend. pack_struct.mojo reproduces the class in miniature and fails
   identically on the pre- and post-fix compilers, as it should: it is
   the unsupported pattern itself.
3. byval reaches ReadReg pointer captures but as `byval({})` — the KGEN
   pointee is opaque by LowerKGENToLLVM — so the convention path can
   never carry a pack type. Any future marker must originate in
   ResolveCompilerPromises, where the type still exists (the marker
   chain built and worked mechanically before being reverted for (1)).

The reroute stays off with its note updated to name reference-capture
marshaling as the blocker.

1. ✅ Plumb the pack/constant distinction to `legalizeKernel` via the
   byval hook (done, single-aggregate case; see F16 for why this lives at
   the MLIR boundary).
2. Param packs (above) — then flip `reroute_gpu_to_rms_norm_gpu`; the gate
   is `test_cpu_gpu_differential` green at every width.
3. Emit `air.indirect_buffer` / `air.struct_type_info` argument metadata
   for capture-struct parameters, so residency narrows from
   `markAllResident()` to the reachable set. The golden-sampled target
   shape, including the flat per-field tuple and the nested
   `location_index` namespace, is recorded in the comment at
   `AirBackend.cpp` (the TODO(air-indirect) block); re-sample under the
   current toolchain before trusting it. Unchanged from the original plan.
4. Runtime half, after the metadata exists: residency narrows; keep
   `APPLEGPU_COARSE_RESIDENCY=1` as the fallback switch and re-measure
   dispatch overhead against unrelated allocation count (review doc P0
   exit criterion). The runtime's constant-binding path already works —
   part one needed zero runtime changes.

Verification so far: `test_index_tensor` passes; the AIR compile tests,
`test_apple_mma_8x8` and `compute_smoke` all green; the full
`//max/kernels/test/gpu/...` sweep's failure set matches the committed
baseline. `test_gather` is the next expected conversion once param packs
land (same "unknown device address" signature).

1. Locate where a kernel's parameter list is classified before LLVM types
   exist (the MLIR signature), and plumb "this parameter is a capture pack"
   down to `legalizeKernel`, so the AS0→AS1 default at `AirBackend.cpp:612`
   becomes a typed decision rather than a guess. The review doc's P0 and
   `STATUS.md` priority 1 agree the fix belongs at IR typing. Architecturally
   this is F16, not just the keystone: address-space and capture-pack typing
   belongs in the MLIR LLVM dialect — pointers still typed, rewriter
   invariants intact — rather than on opaque-pointer IR after the fact;
   `propagatePointerAS`, its sibling-reconciliation cases and
   `rebuildMismatchedSignatures` are the incident scars of the after-the-fact
   approach, and this is the move that retires that class.
2. Emit `air.indirect_buffer` / `air.struct_type_info` argument metadata for
   capture-struct parameters. The golden-sampled target shape, including the
   flat per-field tuple and the nested `location_index` namespace, is already
   recorded in the comment at `AirBackend.cpp:574-601`; re-sample under the
   current toolchain before trusting it.
3. Runtime half, after the metadata exists: residency narrows from
   `markAllResident()` to the reachable set; keep `APPLEGPU_COARSE_RESIDENCY=1`
   as the fallback switch and re-measure dispatch overhead against unrelated
   allocation count (review doc P0 exit criterion).

Verification: `test_index_tensor` passes; the `reroute_gpu_to_rms_norm_gpu`
flip in `nn/normalization.mojo` launches; `test_cpu_gpu_differential` green at
every width; the MHA XPC-crash reduction is re-checked in case it shares the
root cause. Do not batch this sprint with Sprint 4's runtime changes — one
variable at a time.

## Sprint 3 — legality test infrastructure (F5, F11)

1. Lit/FileCheck tests in `KGEN` firing each of the seven `Fail` rules
   (`mask-bitcast`, `three-way-compare`, `native-int-float-cast`,
   `vector-fp-cast`, `vector-llvm-fma`, `unknown-air-symbol`,
   `divergent-barrier`) through `kgen-llvm-opt -passes=air-legality`, which
   already exists for exactly this. A rule's diagnostic text is an interface;
   lock it.
2. Settle the same-module multi-kernel question (F5): the MLIR-level
   `LowerGlobalPOPToLLVM` runs pre-split over the whole module, while
   `SplitStrategy::PerExported` gives the object backend one kernel per
   module. Either find a compile path that produces a two-kernel MLIR module
   and test it, or close the `STATUS.md` item by documenting that the split
   makes the shape unreachable in production. Correct the STATUS wording
   either way.

Verification: `./bazelw test` over the new lit suite;
`APPLEGPU_AIR_RULES=list` output unchanged.

## Sprint 4 — runtime lifetime repairs (F12)

AppleGPURT, from the same review thread. In order of blast radius:

1. `destroyBuffer` / `~VRBuffer` drain (or retain-against) in-flight command
   buffers before releasing a Metal buffer; `residencyRemove` takes the same
   discipline. Today a free racing an async dispatch is a use-after-free the
   Metal validation layers may not catch.
2. `createStream` retains its context.
3. GPU-context `CLOCK_RATE` stops falling through to the host-CPU switch
   (returning a Xeon literal for an Apple GPU contradicts the backend's own
   refuse-to-invent comment); unchecked staging allocations in the raw-copy
   paths get the legible-nil-check treatment the sibling path already has.

Verification: a stress test that allocates and frees on one host thread while
dispatching on another, under `MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1`; the
existing `compute_smoke` and example corpus unchanged.

## Sprint 5 — promotions and measurement (F13, F14)

Behind a clean corpus sweep, per the transforms' own policy:

1. `applyAirKernelFnAttributes` (MSL fast-math semantics; `nosync` already
   correctly withheld from barrier-reaching kernels).
2. `rename-llvm-intrinsics` + `guard-nan-minmax` as a pair, never separately.
   Measured 31 Aug: the scalar `llvm.maxnum/minnum.f32` forms are tolerated
   by Apple's reader (probe 05 runs clean both spellings), so this is
   naming consistency, not correctness.
3. `split-i64-shuffle`, unblocked by Sprint 1's F3 fix.
4. ~~`APPLEGPU_AIR_SCALARIZE_WIDE_VECTORS` on perf grounds~~ — measured 31
   Aug against upstream on fma_peak and the unrolled register matmul: no
   effect beyond noise, slightly negative on the matmul, correctness EXACT.
   Stays off; see oracles `findings/air-quality-2026-08-31.md`.
5. **The unrolled-matmul gap (F15) — cause still open, two attributions
   refuted.** NOT SLP (the source authors `SIMD[16]`; we preserve its
   width into AIR, upstream eliminates it) and NOT vector width at all:
   scalarize@128 gives 2937, scalarize@32 verifiably reproduces theirs'
   256-scalar arithmetic shape and gives 2955, default 2951 — theirs
   3216 GFLOP/s at 2048³. The next step is diagnostic, not a transform:
   body-level diff of the tile-load/GEP pattern (ours 16 `<4 x float>`
   threadgroup loads + 109 GEPs vs theirs 132 scalar loads + 148 GEPs)
   and the index-convert mix (`u.i32` vs `s.i64`). Both scalarize knobs
   stay off; neither width helped. Full record with both refutations:
   oracles findings/air-quality-2026-08-31.md.
6. Small-shape matmul (512³, ragged-513) at 15-17% behind upstream is
   consistent with per-dispatch overhead on short kernels — that is
   STATUS item 5 (runtime profiling), not codegen.
7. Measure before building: per-kernel `xcrun metallib` subprocess cost in
   a large build (F17 — if it is visible in compile latency, batch kernels
   per metallib; the format carries multiple functions and PerExported is
   the only reason we do not); `air.read` vs `air.read_write` precision only
   with a golden sample showing Apple distinguishing them for device buffers.

Each promotion is its own commit with the sweep result recorded, so a
regression bisects to one knob.

Also recorded 31 Aug: fma peak is at parity with upstream (9525 vs 9539
GFLOP/s at 64 chains; we win at 1 chain) — the 25 Aug 1.35-1.43x launch-tax
gap is closed by async launch + batching. The refreshed tables live in the
oracles repo beside the 25 Aug ones.

## Standing verification commands

```bash
# Compiler-side acceptance (Sprint 1's gate)
./bazelw test \
  //max/kernels/test/gpu/compile:test_air_overload_symbols.mojo.test \
  //max/kernels/test/gpu/compile:test_air_target_profile.mojo.test \
  --nocache_test_results --test_output=errors

# Runtime acceptance (Sprints 2 and 4)
MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 ./bazel-bin/spikes/compute_smoke
MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 ./bazelw test \
  //max/kernels/test/gpu/layout:test_apple_mma_8x8.mojo.test \
  --nocache_test_results --test_output=errors

# Legality rules, outside any bazel action
APPLEGPU_AIR_RULES=list kgen-llvm-opt -passes=air-legality <file>.ll
```
