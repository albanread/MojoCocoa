# Defect ledger

Working notes on GPU-path defects as they are discovered: what the symptom
is, what the actual mechanism turned out to be, and where the reproducer
lives. Status vocabulary: **open**, **fixed** (commit named), **refuted**
(a hypothesis tested and disproved — kept so it is not re-tried), and
**blocked** (understood, waiting on a named prerequisite). Reproducers live
under `spikes/capture-abi/` and run on the component loop (private dist +
`cocoamojo --run`, AIR swapped by replacing `bin/cocoamojo-compiler`).

Started 31 August 2026, during Sprint 2 of
[`improvement_sprints.md`](improvement_sprints.md).

## Capture-packs and the launch ABI

### D1 — Single-aggregate capture packs typed device — FIXED
`legalizeKernel` typed every still-generic pointer parameter device AS(1),
so a marshaled capture pack (host bytes the launcher binds with setBytes)
was described to Metal as a device buffer; reflection is the runtime's
contract, so the launch bound a stack address as a device buffer.
`test_index_tensor` read garbage (`left: 0, right: 1`). Fixed by the byval
hook (`582ae833`): byval of a non-empty struct pointee types the parameter
constant AS(2). Repro: the `nn/index_tensor` getitem kernel.

### D2 — byval({}) would mistype opaque device buffers — FIXED
An opaque pointer's pointee converts to the empty struct `{}`; a mutable
device buffer arrives exactly that shape, so a byval from the convention
path could have typed every opaque device buffer constant. Nothing in the
corpus produces one (why the sweep was clean); guarded anyway (`fb7bd1de`).
The empty struct means "pointee unknown" — device, the opposite of a pack.

### D3 — "Type all pointer captures constant" — REFUTED
A pointer capture travels as its ADDRESS in the slot bytes; the runtime
resolves that address in the allocation registry and binds the real buffer.
Typing such a slot constant makes the kernel read constant space at a
stack address — measured: `agg_caps.mojo` went OK → wrong numbers → OK
across marker-on/marker-off. Pointer captures are device BY DESIGN.
Repro: `spikes/capture-abi/agg_caps.mojo`.

### D4 — By-reference struct captures cannot cross the launch ABI — OPEN, mechanism complete
A closure capturing a struct by reference (TileTensors in the rms_norm
adapter, `{var src_tt}` in the tests) becomes a pointer kernel parameter,
and the slot bytes are a HOST address. Three fixes were built and refuted
by intervention, each teaching the next:

1. *Convention byval* — byval attaches but as `byval({})`: the KGEN
   pointee is already opaque at LowerKGENToLLVM (traced).
2. *A compiler-side capture marker* — `kgen.offload.capture` in
   ResolveCompilerPromises, keyed on the pointee being a struct: the
   device-side capture's pointee is ALREADY `!kgen.none` there too
   (traced with `KGEN_TRACE_CAPTURE_MARK`); the device-boundary type
   conversion erases it before any compiler pass runs. The type the rule
   needs does not exist on the compiler side.
3. *Runtime staging* — copy the slot bytes to a device buffer and bind
   that, keeping the kernel's AS(1) reads valid as compiled: built and
   working mechanically, but the slot bytes for a pointer capture are the
   ADDRESS, not the struct, so the kernel reads address bits as fields —
   silently wrong, strictly worse than the loud
   "unknown device address". Reverted; the error stays.

What actually works is already in the tree: an aggregate captured BY
VALUE marshals as bytes through the constant path — `gamma` in the traced
`rms_norm_gpu_warp_tiling` kernel is exactly that shape
(`arg 1 { ptr, {…} }`, reads correctly). The fix is at the Mojo source:
the reroute chain's closures must copy-capture the TileTensors (they
today capture `{var …}` by reference), which requires the captured type
to be `DevicePassable` — TileTensor already is. Where that change lives:
the reroute's adapter closures in `nn/normalization.mojo` and the
`{var}` capture forms in the tests that drive them. Until then the
reroute stays off and `test_cpu_gpu_differential` keeps failing on the
rowwise path (see D6/D7). Repro: `spikes/capture-abi/pack_struct.mojo`
(pointer capture — the unsupported pattern, fails loudly by design);
`rms_repro.mojo` (the real dispatcher path).

### D5 — Rerouted kernel argument order/sizes disagree with the launcher — OPEN
With D4's typing in place, Metal validation names the next defect exactly:
`argument [0] … length(8) has space for 8 bytes, but argument has a
length(32)` — the rerouted `rms_norm_gpu_warp_tiling*` kernel's parameter
list (captures appearing ahead of the leading argument, sizes that do not
match the launcher's slot sizes) disagrees with what
`call_with_pack_metal` binds by index. Pre-dates the marker (the earlier
reroute flip failed at arg 4 the same way, differently masked). This, not
typing, is what now blocks the rms_norm reroute and
`test_cpu_gpu_differential`. Repro: `spikes/capture-abi/rms_repro.mojo`
with the reroute flipped on in the dist's kernels package.

### D6 — A rowwise subkernel variant kills the Metal compiler service — OPEN
`rms_repro.mojo` on the UN-rerouted (rowwise) path crashes at pipeline
creation with XPC_ERROR_CONNECTION_INTERRUPTED, on both the pre- and
post-keystone compilers — a pre-existing rowwise variant defect, distinct
from the known wrong-numbers rowwise failures (which is what the
unflipped differential test actually shows). Not yet reduced to a kernel;
the retained-AIR artifacts from the repro run are the starting point.

## Carried from the review (see improvement_plan.md for detail)

### D7 — Unrolled register matmul ~9% behind upstream — OPEN
Two attributions refuted by intervention (not SLP — the source authors
`SIMD[16]`; not vector width — scalarize@32 reproduces upstream's exact
256-scalar shape and moves nothing). Surviving differences: load/GEP
pattern, index-convert mix. Evidence: oracles
`findings/air-quality-2026-08-31.md`.

### D8 — Runtime lifetime repairs — OPEN
`destroyBuffer`/`~VRBuffer` free Metal buffers without draining in-flight
command buffers; `createStream` does not retain its context; GPU-context
CLOCK_RATE falls through to the host-CPU answer (a Xeon literal on an
Apple GPU); raw-copy staging allocations unchecked. Sprint 4.

### D9 — Small-shape dispatch overhead — OPEN
15-17% behind upstream at 512³/ragged-513 matmul, at parity from 1024³ —
dispatch-shaped, not codegen. Sprint 5 / STATUS item 5 (residency).

### D8 — By-value capture crossing — FIXED FOR COPY-CAPTURES (096a5f52); {var} chain remains
The MOCO-4045 gate in ClosureEmitter dropped a whole closure's DevicePassable
conformance whenever its storage struct was memory-passable, which any
capture of a pointer-containing type forces. Removed: encodability is
per-capture, encode_closure_state has no register-passability assumption,
and the device_type struct is consumed as bytes. A copy-captured TileTensor
now crosses BY VALUE and reads correctly (spikes/capture-abi/tile_caps.mojo,
the regression probe). Pointer captures, scalar captures and
non-DevicePassable captures are unchanged.

REMAINING for the rms_norm reroute: the API chain requires register-passable
closures end to end — rms_norm's InputFn/OutputFn and the rowwise
body-closure trait all carry `& RegisterPassable`, which {var} closures
satisfy (their payload is references) and copy-captured TileTensor closures
never can. Widening rms_norm's constraints binds fine (verified in the dist);
the failure moves into rowwise's `AnyTrait[def[...](Coord, mut Context) ->
None & RegisterPassable & ImplicitlyCopyable]`, and widening THAT trips D10.
So the unblock is: drop RegisterPassable through the rowwise closure layers
(rowwise.mojo, rowwise_types.mojo, the gpu impls), fix D10, copy-capture in
the reroute's adapters, then flip with test_cpu_gpu_differential as the gate.

### D8b — Latent divergent barriers in three basics kernels — FIXED (228f57d2)
test_sum's block_sum_kernel, test_barrier's kernel and test_prefix_sum's
block variant all returned early on `tid >= size` before block collectives,
putting workgroup barriers under thread-varying conditionals. They passed by
optimization luck until the MOCO-4045 change reshaped their bodies; the
divergent-barrier rule then correctly refused the builds. Rewritten to reach
the collective uniformly (clamped load, guarded store). The rule's second
real catch — the first was the original matmul_1_sram incident.
Refined 31 Aug (evening) by experiment: the marshaling machinery is CORRECT
BY DESIGN and mostly exists. ClosureEmitter's `isByReferenceCapture` honors
copy/move conventions; `getDeviceType` resolves `DevicePassable.device_type`
by witness and a whole `__device_type` conversion exists for capture state.
Measured end to end:

- scalar capture (probe 06) — by value, works.
- struct PARAMETER (`gamma`) — by value, works.
- copy-captured struct that is `TrivialRegisterPassable` — by value, WORKS
  (proven with a two-float struct; `copycap_struct.mojo` + the trait).
- copy-captured struct that is merely `ImplicitlyCopyable` (memory-passable)
  — boxed THIN, arrives as a pointer to host memory: `unknown device
  address`. The upstream parser even says so at the capture site —
  DeclResolution.cpp's applyCopyOrMoveCapture carries upstream's own
  `// HACK: This only has the intended effect of "immortalizing" a
  register-passable value` and a TODO error gated on `isTrivial`, which lets
  trivial-but-not-register-passable types through SILENTLY thin.
- `{var}` captures — by reference by convention (their semantics).

So the compiler change for the copy-capture half is precise: the capture
materialization should route a copy-captured `DevicePassable` type through
its `device_type` instead of the MRValue box — the by-value crossing
machinery is sitting right there. The `{var}` half is API-shaped:
`rms_norm`'s `InputFn` requires the `{var}` closure form, which funnels
every caller to by-reference captures; the rowwise path evidently repacks
them (its kernels receive by-value aggregates) — that repack site, and
whether `InputFn` can accept copy-captured closures, are the remaining
questions for the reroute.

### D9/D10 — Widened-closure compiler crashes — BOTH FIXED (be118d91)
Pushing `RegisterPassable` closure constraints through the rowwise layers
crashed the compiler twice, both without diagnostics, both fixed:

- ParamMatcher.cpp:760 — `conversion is double checked` assert when the
  pre-check and the emitter disagreed on a memory-passable closure value
  against a widened closure-trait parameter. Now trusts the emitter and
  falls through to the next candidate.
- sortValueUses (EntryPoint.cpp) — the bytecode-determinism pass seeded
  its ID map for operand-bearing ops only, then `.at()`ed every use owner,
  and the walk does not cover every owner. This was the previously
  "unreproduced D9" crash all along: it needed the widened closure shapes
  to produce the IR that trips it. Now inserts on miss.

### D12 — SCCP lattice assertion — FIXED (2c2d93b2)
The region-order constant-propagation visitor asserted every operand
lattice was initialized when read, but it reaches operations ahead of
their operands' definitions whenever the emitted region order is not a
topological order for every use — which the widened closure traits
produce. Uninitialized is the lattice BOTTOM (reading it folds garbage);
now returns the unknown (top) constant, so the operation simply does not
fold. Gates 7/7, full sweep identical.

### D13 — Widened-closure call mismatch: instref vs genref — ROOT-CAUSED (31844c7f), fix located
With D9/D10/D12 fixed, the widened rms_norm repro gets a genuine verifier
diagnostic: a `kgen.call` whose argument struct and callee-expected
struct print identically but compare unequal. Chased through three
layers of printer elision (struct isMemoryOnly, param_list element
resolution, TypeParamAttr's second type field) with a new env-gated
programmatic differ (KGEN_DUMP_CALL_TYPES=1, committed), which found the
difference:

    expected: #kgen.instref<SIMD,dtype=si64,length=1>
    actual:   #kgen.genref<SIMD<:dtype si64, 1>>

The SAME resolved type as a concrete instantiation reference on one side
and a parametric generator reference on the other. The closure-storage
struct's element type expressions are built through two paths that
canonicalize differently, and comparison is structural.

Fix status: rebinding via ParameterEvaluator::getReboundAttribute at the
capture-field construction is a NO-OP (replace() substitutes parameter
bindings; the genref's inner bindings need full evaluation), tried and
reverted. The fold that produces instref lives on the signature side —
ParametricElaborator.cpp ~480-498 constructs TypeInstanceRefAttr when
bindings resolve, and ParserEvaluationContext::getAndFold does the same
at attr-construction time (but only for attrs implementing
ContextuallyEvaluatedAttrInterface, and only when built through it).
THE FIX (sharpened twice more): concretizeSymbolsWithin only folds
SymbolConstantAttr — it lets TypeGeneratorRefAttr pass through unfolded,
and Elaborator::getConcreteStructTypeReference is the existing
genref→instref fold nothing calls from there. Tried adding that case
(Elaborator.cpp concretizeSymbolsWithin; the fold is replacer-safe since
it returns the instance ref immediately): BUILDS, but does not fire on
this path — the differing type is the closure literal's RESULT type, set
at parse time (liftClosure bindReference), which never passes through
constant concretization at all. The fold must therefore hook where
elaboration finalizes op RESULT TYPES (or where the offload call's
operand types are settled) — Elaborator-side, in the processing of the
closure-literal op (the storage-struct VarDeclOp from emitInitializerCall
/ liftClosure's bindReference). THREE candidate fixes are now eliminated
by measurement, so a fourth (verifier-side isEqualCanon) is not attempted
in vain: the canonicalizer strips type sugar, not parametric form —
isEqualCanon answers 0 on this pair (the differ now reports that verdict
whenever it fires, f61e8d8b). The remaining fix is the emission-side fold at elaborated-type
finalization. Five structured attempts (budgeted ten) narrowed it to
this: (1) lldb proved the elaborator's ParameterEvaluator folds genrefs
via IREvaluator::evaluateContextSpecific, while the parser's context
does not — and the closure storage struct is non-parametric, so its
field attrs are never rebound; (2) the failing argument is always a
kgen.param.constant holding the capture pack (loc(unknown)), created at
IREmitter.cpp:452 with the parse-time type; (3)+(4) adding a result-type
fold to BOTH processParamConstantOp twins builds cleanly but NEVER RUNS
on this path (zero folds traced) — the constants are not processed there
before verification fails, i.e. the call is verified against the
un-folded type, an ordering problem; (5) the next probe (stack trace at
the verifying pass) was staged but not run when the attempt budget
closed. NEXT: instrument verifyCallOperands' caller to name the
verifying pass; if verification runs before operand-defining constants
are processed, the fold belongs at the clone/verify boundary or the call
processing must process its operand constants first. A second symptom in the same repro
('value defined outside the region') may be separate; re-check after.
Repro: rms_crash.mojo against the widened dist kernels.


## Campaign status: the widened-closure work is PAUSED (backed out), 31 Aug night

Decision after five structured attempts on D13 (of a budgeted ten): the fix
is an ordering change in the elaborator's verify-vs-process sequence — core
machinery surgery with real regression surface — and the work is backed out
rather than risked further. Nothing speculative was left in the tree: every
failed attempt (the rebind, both processParamConstantOp type folds, the
instrumentation scaffolding) was reverted before commit.

What STANDS from the campaign, each verified on its own:

- `096a5f52` MOCO-4045 — copy-captured DevicePassable types cross the device
  boundary by value. tile_caps.mojo is the regression probe; full sweep was
  zero-regression, +3 tests.
- `228f57d2` — three latent divergent-barrier kernels made sound.
- `be118d91`, `2c2d93b2` — four crash-to-correct-behavior hardening fixes
  (matchParams, sortValueUses ×D9, SCCP lattice ×D12). These fired only on
  widened shapes but are independently sound; sweeps after each were
  identical to HEAD.
- `31844c7f`/`f61e8d8b` — the call-types differ (KGEN_DUMP_CALL_TYPES=1),
  a permanent diagnostic for any print-identical/compare-unequal pair.

What is UNDONE and stays undone: the RegisterPassable widening itself (it
lives only in the disposable /tmp/aircmp dist), the reroute flip (repo's
normalization.mojo remains reroute=False with accurate notes), and D13's
fold. The reroute stays blocked on D13; test_cpu_gpu_differential stays on
the rowwise path.

Resume point: the staged-but-unrun probe is a one-shot stack trace at the
first DIFFERS in the differ (built once, reverted) naming the verifying
pass; if it shows verification preceding operand-constant processing, the
fold belongs at the clone/verify boundary.


### Runtime lifetime repairs — FIXED (ed3a5302)
destroyBuffer drains in-flight dispatch before release (was a
use-after-free under the async default; test_gated_group_rmsnorm
recovered fail->pass, sweep +2/zero regressions);
createStream retains its context; CLOCK_RATE refuses on Metal contexts
instead of returning a Xeon literal; raw-copy staging allocations
report legible failures. Standing stress:
spikes/capture-abi/lifetime_stress.c.
