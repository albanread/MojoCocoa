# Where this port stands — pick up here

Status snapshot: 25 August 2026, commit
`d07673ce7202d19ab17d6cad41dfb2538c82e87b`, Apple M4.

Two systems live in this tree:

1. **Cocoa support** (`cocoakb`) — working and validated.
2. **Apple Silicon GPU support** (Mojo/MAX lowering to AIR plus AppleGPURT) —
   working end to end for validated smoke and Apple MMA coverage, with
   substantial compiler, runtime ABI, and numerical coverage still open.

The high-level design, systemic findings, and prioritized adjustments are in
[`APPLE_GPU_LOWERING_REVIEW.md`](APPLE_GPU_LOWERING_REVIEW.md). The older
[`AIR_APPLE_SILICON.md`](AIR_APPLE_SILICON.md) records the original porting
plan and should now be read as history rather than current status.

## Current summary

| Area | Status | Evidence / limitation |
| --- | --- | --- |
| Cocoa compiler hook and `std.objc` | Working | `./spikes/run-cocoa-checks.sh`: 9 passed, 0 failed. |
| Mojo/MAX → AIR → metallib | Working vertical slice | The source-built compiler emits metallibs accepted by the current Xcode toolchain. |
| AppleGPURT pipeline and launch | Working vertical slice | Pipeline reflection, argument binding, coarse residency, and dispatch pass with Metal debug and shader validation enabled. Launch is asynchronous and command-buffer-batched by default; `APPLEGPU_SYNC_LAUNCH=1` restores the bring-up mode, while `APPLEGPU_BATCH_DISPATCHES=0` isolates batching. Each dispatch retains a separate compute encoder; batches flush on errors and drain at synchronization, host observation, teardown, or the 64-dispatch bound. Rejected post-command-buffer launches commit an empty buffer so later queue entries cannot stall behind an abandoned predecessor. On the M4 Max, batching reduces the 35-dispatch fluid median from about 1.06 to 0.93 ms/step with identical diagnostics, on top of the earlier 3.5x-3.7x asynchronous-over-synchronous gain. |
| Numerical smoke | Passing | Rebuilt Mandelbrot: CPU 95.214 ms, GPU 0.849 ms, 100% exact on the latest verification run. Timing is a smoke observation, not a stable benchmark. |
| Example kernels | 10 of 11 pass on M4 Max | Every generic example now compiles and passes its numerical oracle under Metal validation. Stale exclusions were removed from integer matmul and double-buffer GEMM; scatterND was repaired and promoted from manual. The remaining back-to-back matmul is NVIDIA `mma` code. See `max/kernels/test/gpu/examples/APPLE_STATUS.md`. |
| Apple MMA | Passing on the 8x8 path only | `test_apple_mma_8x8`: 19 sub-tests PASS, 0 SKIP, after signature-specific declaration uniquing. `test_tensor_core_apple` also reports PASS but is **vacuous here** — all 18 sub-tests print `SKIP: requires Apple M5 + Metal 4`, and its FileCheck pattern `{{PASS|SKIP}}` accepts a skip. It is not evidence for this machine. |
| AIR overload regression | Passing in current uncommitted worktree | New compile-only `test_air_overload_symbols`: 1/1 pass across mixed dtype signatures; its two kernels are separate `_compile_code` invocations, so a same-module multi-function pass test is still needed. |
| Broad MAX GPU surface | Measured | **96 of 119 in-scope targets pass** (confirming sweep, 25 Aug; `tools/corpus/CORPUS.md`). This replaces the 740-target census, which counted other vendors' tests, closed-dep packages, and vacuous skips. The 25 Aug tooling fixes (a real `blocked` class, `--keep_going` on every batched bazel query, the stale-testlog guard, bucket precedence) change how the not-run remainder splits, so the backlog needs one re-baseline sweep before its size is quoted. |

## What cannot be tested here, and why

Three separate reasons a target may be untestable in this fork. None of them
is a defect, and all three have been mistaken for one:

1. **No source.** `max/kernels/src/graph_compiler` depends on
   `Kernels/lib/{attn_res,matmul_rs,msa}` and `Kernels/src/mega_ffn`, which
   have no source directories at all — they ship as precompiled `.mojoc` in
   the prebuilt wheel and our from-source compiler rejects them on a version
   mismatch. There is no open-source graph compiler; when this project writes
   one it will be in Mojo. `builtin_kernels` therefore fails with 29 errors
   that are nothing to do with us. Out of scope, encoded in
   `tools/corpus/scope.py` as `CLOSED_DEP_PATHS`.

2. **No hardware.** The M5 paths — 16x16 `simdgroup_matrix` — compile here and
   the metallib loads; the driver refuses the pipeline at creation with
   "supported by GPUFamily10 and later". This M4 Max is Family9. Those kernels
   are exercised as far as codegen and no further.

3. **Another vendor's.** NVIDIA, AMD and Qualcomm targets each have their own
   fork. A failure there is not this fork's concern.

The rule underneath all three: **we cannot test what does not yet exist.**
Before spending time on a red target, establish which of the three it is —
`tools/corpus/report.py` separates them, and `ls` on a BUILD dependency with
no `.mojo` files settles the first case in seconds.

## Verification commands

```bash
./spikes/run-cocoa-checks.sh

MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 \
  ./bazel-bin/spikes/compute_smoke

MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 \
  ./bazelw test \
    //max/kernels/test/gpu/layout:test_apple_mma_8x8.mojo.test \
    //max/kernels/test/gpu/layout:test_tensor_core_apple.mojo.test \
    --nocache_test_results --test_output=errors

./bazelw test \
  //max/kernels/test/gpu/compile:test_air_overload_symbols.mojo.test \
  --nocache_test_results --test_output=errors
```

The `compute_smoke` target is a runnable binary, not a Bazel test target.
Build it first with `./bazelw build //spikes:compute_smoke` when necessary.

## What is working in the Apple GPU path

- `AirTraits` registers `air64` and Apple M1-M5 hardware names.
- MAX/Mojo Apple operations use semantic `llvm.air.*` shims.
- Target-owned `AirLowering` converts those POP operations in the
  module-scoped global lowering pass and creates signature-specific
  declarations without symbol-table races.
- `AirBackend` inlines helpers, creates the final AIR ABI names and metadata,
  legalizes address spaces and kernel arguments, writes LLVM-17 AIR bitcode,
  and packages it with `xcrun metallib`.
- AppleGPURT allocates shared-memory Metal buffers, loads MSL or metallib,
  reflects argument slots, binds buffers/constants, marks captured-pointer
  resources resident, dispatches, and reports Metal errors.
- Metal debug and shader validation are usable as part of acceptance testing.

Commit `48d88ec` closes the observed `Calling a function with a bad signature!`
compiler-assertion class for overloaded AIR shims. The fix is at the
module-declaration site rather than enumerated at individual Mojo call sites.

## Known failure classes

These are separate work streams, not one GPU defect:

### Compiler/AIR legality

- `llvm.vector.interleave2` can remain unresolved until `metallib`; unsupported
  external LLVM declarations need a fail-closed pre-driver gate.
  (`llvm.vector.reduce.*` lowering landed 24 Aug; `spikes/air-gates.sh`
  sketches the gate.)
- One MHA case still causes `XPC_ERROR_CONNECTION_INTERRUPTED` at Metal
  pipeline creation and needs reduction from retained AIR artifacts.
- Metal printing references undefined `__mojo_metal_os_log_64`.
- Target features still produce ignored-feature warnings in the temporary
  arm64 optimization path. (The triple/version inconsistency itself is
  resolved: one target profile now drives the triple and every version stamp.)

### Runtime ABI

- Reflection is now authoritative for compiler-generated kernels
  (`MULTIPROCESSOR_COUNT`, the ranged host function, and
  `compute_capability` all landed 24-25 Aug). The open defect is UPSTREAM of
  reflection: `legalizeKernel` types any still-generic pointer parameter as
  device, so a by-pointer capture pack — host bytes — is described as a
  device buffer and the launch dies with "unknown device address".
  Priority 1 below.
- Captured pointers use `markAllResident()`, an `O(all live allocations)`
  correctness fallback until `air.indirect_buffer` metadata enables precise
  residency.
- Asynchronous launch is the default. Every read path and teardown drain, state
  is locked, and `APPLEGPU_SYNC_LAUNCH=1` provides the synchronous debug mode.
  Consecutive dispatches share one command buffer by default, with separate
  compute encoders and `APPLEGPU_BATCH_DISPATCHES=0` as the isolation switch.

### Numerical/runtime correctness

- Known failures include SRAM matmul, depthwise grouped convolution, and
  layer norm. Index tensor and RMS norm are now DIAGNOSED rather than open
  mysteries: the capture-pack address-space typing (priority 1) and the
  `rowwise` GPU path it blocks the reroute of (priority 2), with
  `test_cpu_gpu_differential` as the gate.
- `test_gather` fails with an unknown device address, which points first to the
  runtime argument/lifetime contract rather than arithmetic lowering.

### Test taxonomy

- Many NVPTX/AMDGCN-only tests fail to build instead of being marked
  incompatible with Apple.
- Some targets depend on the absent `Kernels/lib/attn_res` package.
- 623 targets skip in the broad census, and M5 runtime capability cannot be
  validated on the M4.

## Immediate priorities

Rewritten 25 August after the review pass and the corpus re-measurement. Of
the previous list, items 3-7 landed in the meantime (vector.reduce lowering,
the single target profile, the capability matrix with `MULTIPROCESSOR_COUNT`
and the ranged host function, authoritative reflection, and the corpus tooling
that replaced the census); the earlier list is in git history.

Standing policy, decided 25 Aug: this fork is FROZEN against upstream. Only
security fixes get backported (`git log --grep -iE 'cve|security'` against the
upstream remote), nothing else. The object-oriented story is the platform's —
Cocoa here, COM on Windows — not whatever upstream adds later.

1. **Capture-pack address spaces — the keystone.** `legalizeKernel` defaults
   any still-generic pointer parameter to device (the `as ? as : 1`), so a
   capture pack passed by pointer — host bytes — is typed as a device buffer
   and the launch fails with "unknown device address". Binding it constant at
   the runtime instead is already refuted: the kernel body dereferences
   `addrspace(1)` and returns zeros. The fix is at IR typing, from the
   signature rather than a guess at the LLVM type. Whether a pack goes by
   value (works) or by pointer (fails) depends on closure nesting depth, which
   is why direct closures work and adapter layers do not.
   *Exit: `test_index_tensor` passes; the rms_norm reroute launches.*

2. **RMS norm correct on GPU.** Flip `reroute_gpu_to_rms_norm_gpu` in
   `nn/normalization.mojo` the moment 1 lands.
   *Exit: `test_cpu_gpu_differential` green at every width.*
   Then two root causes, separately: the `rowwise` GPU body itself (ten files
   build on that surface — softmax, grouped_matmul, fp8_quantization — so the
   reroute fixes one symptom, not the defect), and the differential harness's
   own host-side fault above ~4096 elements (documented in the test; host
   side, not the backend).

3. **Re-baseline the corpus with the fixed tooling.** The committed reports
   are wrong in known directions: the backlog was undercounted by the
   multi-GPU override, `other-vendor` inflated by a catch-all bucket, and
   bazel refusals scored as build failures. One clean sweep; regenerate
   `CORPUS.md` and `apple-exclusions`; commit as the baseline. First fix the
   runner's un-killable timeout — a GPU-wedged test outlived
   `subprocess.run(timeout=900)` by an hour (recorded: 4267s, ended only by
   an external SIGKILL); run each test in its own process group and kill the
   group on expiry.

4. **Burn down the re-measured backlog.** Keep the old item-8 discipline:
   assign every red target to compiler emission / driver acceptance / runtime
   ABI / binding-lifetime / arithmetic BEFORE touching code. Known clusters
   going in: comptime `llvm.ctlz`, `llvm.masked.gather`, MOCO-2405 printf and
   capture-trait, KERN-2651 threadgroup memory over 32 KB, and the MHA XPC
   crash reduction.

5. **Profile the post-batching runtime.** Command-buffer batching is now the
   default and retains separate encoders for state isolation. The next known
   scaling cost is `markAllResident()`: every dispatch walks every live
   allocation. Implement `air.indirect_buffer` metadata, measure launch cost
   against unrelated allocation count, and only then consider sharing one
   encoder across compatible launches.

6. **Snapshot the oracle while it still is one.** The correctness comparisons
   against upstream's release depend on the two kernel libraries still
   describing the same kernels, and freezing means that window only closes.
   Archive the exact wheel with a checksum beside `oracles/`; widen the
   upstream-vs-ours numerical tables (matmul, attention, softmax) now; re-run
   every sub-millisecond benchmark post-async — the recorded STREAM numbers
   carry the 0.4 ms launch tax and are flagged suspect in the findings doc.

7. **Fluid follow-ups (fun-sized).** Move `spikes/fluid` to `[NSApp run]` +
   `NSTimer` so Apple Events actually deliver (`fluidctl` already sends
   correctly; the hand-rolled pump is what never receives — the README
   records the diagnosis). Strip the AE-chase debug prints
   (`fluid.mojo` `[ae] received`, `fluidctl.mojo` `target nil?`). Print fps
   to stdout, not only the title bar.

8. **Strategic track, unscheduled.** Objective Mojo as a LIBRARY, no parser
   changes on a frozen tree: typed receivers (`Id["NSWindow"]`) so the class
   stops being typed by hand, keyword-argument selector resolution from
   `cocoa_data` (Mojo's keyword arguments are the native spelling of ObjC's
   keyword selectors), retain/release through `__copyinit__`/`__del__` so the
   scattered bare `objc_retain`s get matching releases by construction. An
   `air-cc` extraction spike — standalone `.ll` → `.metallib` tool — so
   MacModula2, MacBCPL, and friends can emit graphics kernels against this
   backend; it also fuzzes the backend with a second producer's IR shapes.

## Build discipline

Only toolchain or sysroot changes invalidate LLVM+MLIR and trigger the long
rebuild. Source changes should remain KGEN- or runtime-scoped. Avoid casual
changes to `local.bazelrc` or
`bazel/internal/cc-toolchain/macos_sysroot_repository.bzl`.

Run runtime acceptance with `--nocache_test_results` after rebuilding the
compiler. Record the KGEN commit, target profile, hardware, macOS, and Xcode
version with any reported census.

## Golden-sample technique

Check AIR facts against Apple's own compiler rather than inferred tables:

```bash
xcrun metal -S -emit-llvm k.metal -o k.ll
xcrun metal -x ir -c k.ll -o k.air
```

Use the shipped AIR tools (`air-objdump`, `air-readobj`, `air-nm`, `air-opt`,
and `air-link`) to inspect the result. Retained failure artifacts should be
unique per kernel and include the complete target profile.
