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

### D4 — By-reference struct captures typed device — fix built, verifying
A closure capturing a struct by reference (TileTensors in the rms_norm
adapter) becomes a pointer kernel parameter whose pointee is erased by
LowerKGENToLLVM; typed device, the runtime reads the struct's first 8
bytes as an address and binds the wrong buffer or refuses the launch
("unknown device address", the `0x16f3…` stack addresses). Fix: a
`kgen.offload.capture` marker in ResolveCompilerPromises (struct-pointee
pointer captures only, size from the pointee) → `byval([N x i8])` in
AirLowering → constant AS(2) in the backend; scalar-pointee pointer
captures stay device per D3. Repro: `spikes/capture-abi/pack_struct.mojo`.
Gates re-verification in flight at the time of this note.

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
