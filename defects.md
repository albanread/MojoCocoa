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
