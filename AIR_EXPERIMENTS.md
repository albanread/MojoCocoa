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

The immediate next implementation should now be item 1: make barrier semantics
survive the shared optimiser, using the AIR verifier as the fail-closed oracle
and sweeping the non-Apple GPU targets before enabling the change generally.
