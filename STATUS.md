# Where this port stands — pick up here

Status snapshot: 24 August 2026, commit
`48d88ec32638c3178531525085fd94a0b2d72f33`, Apple M4.

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
| AppleGPURT pipeline and launch | Working vertical slice | Pipeline reflection, argument binding, coarse residency, and dispatch pass with Metal debug and shader validation enabled. Launch is synchronous by default; `APPLEGPU_ASYNC_LAUNCH=1` defers the wait to `synchronize()` and is worth +29% on a 1-chain FMA kernel (exactly upstream's rate) falling to +2.9% at 64 chains. Same corpus failure set under both. Still opt-in: the per-dispatch command buffer is not yet batched, which is where the remaining 13-17% at 2-8 chains lives. |
| Numerical smoke | Passing | Rebuilt Mandelbrot: CPU 95.214 ms, GPU 0.849 ms, 100% exact on the latest verification run. Timing is a smoke observation, not a stable benchmark. |
| Apple MMA | Passing on the 8x8 path only | `test_apple_mma_8x8`: 19 sub-tests PASS, 0 SKIP, after signature-specific declaration uniquing. `test_tensor_core_apple` also reports PASS but is **vacuous here** — all 18 sub-tests print `SKIP: requires Apple M5 + Metal 4`, and its FileCheck pattern `{{PASS|SKIP}}` accepts a skip. It is not evidence for this machine. |
| AIR overload regression | Passing in current uncommitted worktree | New compile-only `test_air_overload_symbols`: 1/1 pass across mixed dtype signatures; its two kernels are separate `_compile_code` invocations, so a same-module multi-function pass test is still needed. |
| Broad MAX GPU surface | In triage | 740-target census: 79 pass, 21 build failure, 17 runtime failure, 623 skip. The census includes foreign-target and missing-package noise and is not an acceptance score. |

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
- One MHA case still causes `XPC_ERROR_CONNECTION_INTERRUPTED` at Metal
  pipeline creation and needs reduction from retained AIR artifacts.
- Metal printing references undefined `__mojo_metal_os_log_64`.
- Target selection is inconsistent: runtime hardware discovery reports
  `apple-m4`, stdlib associates that with Metal 3.2/AIR 2.7, while the backend
  stamps Metal 4.0/AIR 2.8/SDK 26. Target features also produce ignored-feature
  warnings in the temporary arm64 optimization path.

### Runtime ABI

- `DeviceAttribute.MULTIPROCESSOR_COUNT` (attribute 16) is unimplemented and
  blocks current attention/KV-cache tests.
- `AsyncRT_DeviceContext_enqueueHostFunctionRange` is unimplemented.
- Compiler-generated metallib reflection is currently best-effort; the
  fallback classifies some arguments from their values.
- Captured pointers use `markAllResident()`, an `O(all live allocations)`
  correctness fallback until `air.indirect_buffer` metadata enables precise
  residency.
- Dispatch waits for every command buffer, so the runtime does not yet provide
  meaningful asynchronous execution.

### Numerical/runtime correctness

- Known failures include SRAM matmul, depthwise grouped convolution, index
  tensor, layer norm, and RMS norm.
- `test_gather` fails with an unknown device address, which points first to the
  runtime argument/lifetime contract rather than arithmetic lowering.

### Test taxonomy

- Many NVPTX/AMDGCN-only tests fail to build instead of being marked
  incompatible with Apple.
- Some targets depend on the absent `Kernels/lib/attn_res` package.
- 623 targets skip in the broad census, and M5 runtime capability cannot be
  validated on the M4.

## Immediate priorities

1. Complete the in-progress ownership cleanup: keep `AirLowering` as the only
   declaration creator, move the attempted backend verifier to a real
   post-global-lowering boundary, and retain a clean non-AIR target diagnostic.
2. Land the rebuilt exact-function-type declaration key and its passing
   compile-only regression test; extend the test to scalar/vector shims and an
   injected hash-collision diagnostic.
3. Fail before `metallib` on unresolved external `llvm.*` declarations and
   lower vector interleave/deinterleave operations.
4. Introduce one explicit Apple target profile from which triple, Metal/AIR
   versions, SDK, and deployment target are derived.
5. Publish and test the AsyncRT capability matrix; implement the device
   attributes and host function range reached by current tests.
6. Require complete reflection for compiler-generated metallibs and make
   allocation resolution/residency lifetime-safe.
7. Create a layered Apple-only acceptance suite and constrain foreign-target
   tests correctly.
8. Reduce the remaining numerical failures only after each case is assigned to
   compiler emission, driver acceptance, runtime ABI, binding/lifetime, or
   arithmetic correctness.

The detailed rationale and exit criteria for each item are in
[`APPLE_GPU_LOWERING_REVIEW.md`](APPLE_GPU_LOWERING_REVIEW.md).

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
