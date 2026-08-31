# Apple AIR lowering experiments

This repository is an isolated experiment tree copied from CocoaMojo source
commit `4dbdea45d80fdfa5923a6d5c670a659d02572490`.  Its Git baseline is
`ad6ee08`; the working CocoaMojo repository is not used for builds or edits.

The experiment keeps one lowering implementation for Apple silicon.  M4 and
M5 differences belong in explicit target capability/profile data, not in
separate compiler pipelines or duplicated builtin spelling rules.

## Landed experiment slices

### Central AIR builtin policy

`AirBuiltinRegistry.h` is the shared source of truth for AIR builtin families,
signature classes, payload domains, convergence, and type suffixes.  Both the
KGEN-to-LLVM lowering and final AIR backend use it.

Important deliberate cases:

- `air.simd_ballot.i32` is a pre-mangled ABI name.  Its operand is `i1` and its
  result is `i32`, so deriving its suffix from operand zero is wrong.
- SIMD payloads are limited to the scalar domains supported by the current
  Metal/AIR path.  The previous backend-only `.u.i64` spelling is no longer
  silently manufactured.
- Barrier convergence classification is shared rather than repeated in two
  lowering layers.

### Fail-closed AIR declaration validation

Final AIR legality now validates registered families, suffix/payload agreement,
arity, and LLVM signatures.  It also handles the currently emitted conversion,
barrier, ballot, matrix-MMA, and fast floating-math forms.

An unknown `air.*` declaration is a failure by default.  A non-AIR unresolved
external remains log-only: captured modules currently contain
`llvm.vector.reduce.fadd` declarations, and AIR packaging alone is not evidence
that every such declaration survives pipeline-state creation.

The policy is intentional: known AIR ABI mistakes must fail before reaching the
driver, while non-AIR intrinsics should be promoted to failure only after the
backend has either lowered them or proven them legal at the PSO boundary.

### Divergent workgroup barrier rejection

The final AIR legality gate now treats kernel arguments tagged by
`!air.kernel` as the authoritative thread-identity sources.  It follows their
SSA data dependencies into conditional branches and uses dominator plus
post-dominator analysis to distinguish two cases:

- a lane-dependent branch that reconverges before one shared barrier is legal;
- a barrier selected, skipped, or iterated by a lane/thread/simdgroup-dependent
  condition fails under the `divergent-barrier` rule.

Threadgroup position and launch-size arguments remain uniform at workgroup
scope and do not taint a branch.  The analysis intentionally does not claim to
recover dependencies hidden through arbitrary memory: the final pipeline
inlines helpers and promotes ordinary scalar temporaries, but a future lowering
that spills thread identity through unknown memory will need explicit
uniformity metadata or a MemorySSA extension.

The rule defaults to `Fail` and can be downgraded independently through
`APPLEGPU_AIR_RULES`.  Implementing the test exposed and fixed a pre-existing
configuration parser defect that silently rejected valid rule actions and
transform settings.

## Validation performed

- `//KGEN/tools/kgen-llvm-opt:kgen-llvm-opt` builds successfully from the clean
  experiment tree.  The first build completed 8,365 actions.
- `//KGEN/test/kgen:air-legality/externals.ll.test` passes.  It covers valid and
  invalid builtin names, suffixes, signatures, conversion declarations,
  barriers, ballot, and matrix MMA.
- `//KGEN/test/kgen:air-legality/barrier-divergence.ll.test` passes.  It covers
  reconvergence, workgroup-uniform conditions, lane-guarded barriers, and a
  simdgroup-dependent barrier loop; it also verifies the firewall rule parser.
- A sweep of the captured `/private/tmp/out_*.air.ll` corpus reports no unknown
  AIR declarations.  Three non-AIR vector-reduction declarations remain logged.
- A second sweep examined 59 captured AIR modules.  Thirty-six contain a
  workgroup barrier, and none is rejected by the divergence verifier.
- The SRAM dimension matrix was run on an M4 Max with the known-good CocoaMojo
  distribution.  All eight aligned/ragged combinations passed after converting
  the mapped output scalar to `Float32` before comparison.  The retained old log
  printed exact expected values while counting every cell as bad, so that result
  was a host-oracle defect rather than a kernel failure.

The SRAM run validates the corrected oracle and existing runtime.  It does not
yet qualify a distribution built from the new compiler commits.

### Example-kernel corpus is 10/11 on Apple

The complete `max/kernels/test/gpu/examples` package was reviewed and run on
the M4 Max. Ten of eleven examples now compile, create pipelines, execute under
Metal API and shader validation, and pass a real numerical oracle. Integer
matmul and double-buffer GEMM had stale Apple exclusions, while scatterND was
still manual because its source had drifted from current Mojo APIs. All three
now run in the default Apple set. The only remaining exclusion is the
NVIDIA-only back-to-back matmul, which reaches its explicit unsupported `mma`
capability check.

The review also exposed non-monotonic static-storage accounting: both working
BK=8 variants report exactly twice their declared shared arrays, while the
original double-buffer BK=16 tile is rejected at its declared 33,280 bytes.
Apple-specific tile choices restore both kernels today, but explaining that
discontinuity is the next direct opportunity to regain K-stage depth and
performance. The exact matrix, fixes, measurements, and recommendations are
recorded in
[`max/kernels/test/gpu/examples/APPLE_STATUS.md`](max/kernels/test/gpu/examples/APPLE_STATUS.md).

### Asynchronous dispatch is now the runtime default

The runtime's already-implemented deferred launch path is now the default
AsyncRT behavior. `APPLEGPU_SYNC_LAUNCH=1` restores one-wait-per-dispatch for
debugging, and `APPLEGPU_ASYNC_LAUNCH=0` remains a compatibility override.
The launch smoke now queues three dependent SAXPY kernels and relies on DtoH to
drain them, directly checking queue order and the host-observation boundary.

Measured with a freshly rebuilt 125-symbol runtime dylib on the M4 Max:

- the 35-dispatch fluid solver produced identical dye, velocity, divergence,
  and rendered-pixel diagnostics in both modes; warm steps were 1.06 ms by
  default versus 3.70-3.90 ms synchronous, a 3.5x-3.7x improvement;
- the checked FMA oracle's warm 32-dispatch samples improved from 12.44 to
  8.64 ms at four chains, 15.10 to 11.04 ms at eight, and 22.20 to 16.61 ms
  at sixteen, with identical checksums.

This removes an implicit CPU-GPU round trip from the normal launch contract.

Command-buffer batching is now layered on top. Each dispatch retains its own
compute encoder, but consecutive encoders share one command buffer until a
drain or the 64-dispatch backpressure limit. The runtime smoke covers three
dependent kernels, 130 launches crossing backpressure twice, an invalid launch
after valid queued work, 65 repeated partial-batch rejections, an oversized
pre-encoder rejection, and an unsynchronized teardown after function and buffer
release. Default-batched, async-unbatched, and synchronous modes all pass under
Metal API and GPU validation. Generated-AIR fluid and all eight aligned/ragged
SRAM matmul shapes also pass with batching and validation.

The repeated-rejection stress also exposed an older unbatched sequencing bug:
the validation path ended its encoder but abandoned the command buffer without
committing it. Because Metal preserves command-buffer creation order, a later
committed launch could wait forever behind that predecessor. Every error after
command-buffer creation now commits an empty/partial buffer; batching likewise
flushes prior valid work before returning the immediate validation error.

Across ten alternating fluid A/B rounds, the warm median fell from about 1.06
ms/step unbatched to 0.93 ms/step batched, roughly 12% lower latency. The FMA
oracle was neutral at four and eight chains and about 1% faster at sixteen,
which is the expected shape: batching removes submission overhead, not kernel
work. `APPLEGPU_BATCH_DISPATCHES=0` isolates the unbatched asynchronous path.

### Wide-vector scalarization was not promoted

`spikes/air_perf/fma_peak_bench.mojo` makes the LLVM scalarizer experiment
repeatable. Float4 fragmentation (`ScalarizeMinBits=128`) and full scalarization
(`=32`) produced no stable throughput improvement at widths 4, 8, or 16.
Explicit width 32 reaches metallib successfully but terminates Apple's pipeline
compiler connection on this M4 Max, with the scalarizer on or off. The pass is
therefore still opt-in. The next compiler capability slice should reduce that
PSO failure and split wide per-thread values before the failure-inducing form,
not enable a late LLVM pass solely because the printed IR looks more scalar.

## Current infrastructure blocker

The fresh-tree Bazel target
`//max/kernels/test/gpu/examples:test_matmul_sram_dims.mojo.test` currently
fails while linking `bazel/mlir-shared/libMLIR.dylib`, before the test runs,
with unresolved LLVM C++ symbols.  This is a build-graph/toolchain issue rather
than an AIR diagnostic or kernel failure.  Compiler-unit validation therefore
uses `kgen-llvm-opt`, while the existing distribution provides the independent
Metal runtime check.

## Recommended next slices

1. **Represent barrier semantics before loop unswitching.**  With the final
   verifier and fixtures in place, make convergence and non-duplication
   explicit in the earliest KGEN/MLIR form that the optimiser sees.  Then run
   NVPTX and AMDGPU regression tests because this is shared lowering policy,
   not an Apple-only change.
2. **Make hardware variation data-driven.**  Introduce an Apple target profile
   containing AIR/Metal versions, SIMD width, threadgroup limits, supported
   payload domains, and matrix shapes.  Select a profile for M4/M5; do not fork
   builtin generation or optimisation passes by chip name.
3. **Remove late address-space inference.**  Carry logical storage class and
   resource binding through typed IR, then lower it once to AIR address spaces.
   Late pointer-shape inference is too fragile for alias analysis and ABI checks.
4. **Validate the complete kernel ABI.**  Add structural checks for buffer and
   constant argument order, sizes, alignment, address spaces, resource metadata,
   and threadgroup allocations before serialization.  Do not infer semantic
   padding from anonymous byte arrays.
5. **Add a real driver acceptance gate.**  Compile a small representative
   kernel matrix through AIR, metallib, pipeline-state creation, and execution.
   This is where remaining unresolved LLVM intrinsics can be classified safely.
6. **Replace coarse residency with compiler-described reachability.**  Batching
   has landed. The next runtime scaling defect is `markAllResident()`, whose
   dispatch cost grows with every unrelated live allocation. Emit and consume
   `air.indirect_buffer` / `air.struct_type_info`, retain a precise resource
   snapshot for the batch, and benchmark against allocation count.

   *Runtime half landed, 30 August 2026; corrected 30 August 2026.* An
   `MTLResidencySet` per device, attached to each command queue and mirrored
   from the address registry: membership edits at allocation and free, nothing
   on the dispatch path. `APPLEGPU_COARSE_RESIDENCY=1` restores the walk, and
   `applegpu_residency_bench` measures both in one binary.

   The first landing used the wrong factory selector -- `make...` where MTLDevice
   exposes `newResidencySetWithDescriptor:error:` -- so `respondsToSelector:`
   answered no, the set was never created, and every launch silently ran the
   walk. Correct results the whole time, which is what hid it: the measurements
   that reported a ~25% win were the fallback walk timing against itself, i.e.
   noise. Only re-measuring on the product tree, where the set was verified
   absent by a runtime probe, surfaced the bug.

   With the set actually active, M4 Max, 9-pass medians, us/dispatch walk vs
   set: 6.66 -> 3.77 at 64 live buffers (-43%), 18.56 -> 3.46 at 256 (-81%),
   73.35 -> 3.25 at 1024 (-96%), 289.53 -> 3.37 at 4096 (-99%). The set is flat
   in the allocation count -- ~3.4us at every size -- while the walk is linear,
   which is the whole claim, now true instead of asserted. Below ~16 buffers
   the set's fixed setup makes it ~0.4us slower in absolute terms; irrelevant
   once a workload has allocations. requestResidency after commit was tried and
   hurt, so it is not here. What remains is the compiler half -- reachability
   metadata so the set can hold fewer than every live allocation.
7. **Reduce the explicit-SIMD width-32 PSO failure.**  Keep the reduced FMA
   source and emitted AIR together. Determine whether the failure is caused by
   vector reconstruction, register pressure, or a specific instruction shape,
   then lower wide per-thread values earlier than final LLVM scalarization.
8. **Explain static threadgroup storage accounting.**  Two BK=8 tiled matmuls
   produce a Metal static-storage count exactly twice their declared shared
   arrays, but the original double-buffer BK=16 tile is rejected at its declared
   size rather than twice it. Reduce this with retained pre/post AIR, identify
   the allocation-liveness or metadata discontinuity, and restore deeper Apple
   K tiles if the emitted footprint can be reduced.

For performance, the immediate next implementation is item 6, precise
residency. For compiler capability, it is item 7, the width-32 PSO reduction.
Item 1 remains the next shared-optimizer correctness change and still requires
the non-Apple GPU sweep before it is enabled generally.


## Full Apple/AIR benchmark sweep, HEAD `3d9daff5`, 30 August 2026

M4 Max, macOS 26.5.1, quiet machine (no build running -- launch timing is
sensitive to CPU load, as the residency bug taught). Run through the shipped
CocoaMojo distribution.

**1. Metal smoke** -- correctness gate, all launch modes: ALL PASS in default,
sync (`APPLEGPU_SYNC_LAUNCH=1`) and coarse (`APPLEGPU_COARSE_RESIDENCY=1`).

**2. FMA compute oracle** -- async vs sync, warm median of 5:

| chains | sync ms | async ms | speedup | recorded prev |
|---|---|---|---|---|
| 4 | 12.48 | 8.67 | 1.44x | 1.44x |
| 8 | 15.11 | 11.03 | 1.37x | 1.37x |
| 16 | 22.48 | 16.59 | 1.35x | 1.34x |

Reproduces the baseline. Compute schedule unchanged by the latest work.

**3. Residency bench** -- per-dispatch us, walk vs set, median of 7:

| live buffers | walk | set | reduction |
|---|---|---|---|
| 0 | 3.22 | 3.97 | +23% (fixed setup, 0.75us absolute) |
| 16 | 3.96 | 3.95 | 0% |
| 64 | 6.70 | 3.92 | -42% |
| 256 | 18.18 | 3.86 | -79% |
| 1024 | 70.40 | 3.34 | -95% |
| 4096 | 275.28 | 3.22 | -99% |

Flat where the walk is linear. Below 16 buffers the set's fixed cost makes it
fractionally slower in absolute terms; irrelevant once a workload allocates.

**4. Fluid workload** -- 35 dependent dispatches per step, 60 steps:

| launch path | ms/step | total |
|---|---|---|
| queued + batched (default) | 1.49 | 89.2 ms |
| synchronous (`APPLEGPU_SYNC_LAUNCH=1`) | 3.87 | 232.4 ms |

2.6x over the fully-synchronous bring-up path, divergence checksums identical.
This is the whole async+batched launch path against sync, a different and
larger comparison than the ~12% recorded earlier for command-buffer batching
alone (batched vs unbatched, both already async). Both hold: batching adds
~12% on top of async, and the full path is 2.6x over sync. A 35-dispatch
dependent workload is dispatch-bound, which is exactly where this shows.

**5. Apple simdgroup matmul** (`bench_apple_gpu_matmul`) -- self-skips with
"SKIP: Apple GPU required": it gates on a specific accelerator arch (it is the
M5 simdgroup-tiled kernel bench) that this dist's Metal path does not present.
Not run here; the FMA oracle is the compute-throughput measurement that does.
GPU kernel correctness is covered separately by the Apple example corpus,
`max/kernels/test/gpu/examples/APPLE_STATUS.md` (ten of eleven pass; the
eleventh is NVIDIA-only mma).
