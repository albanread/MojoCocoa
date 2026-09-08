# 7. What to understand

Ten things about this backend are not obvious from watching it work.

## 1. AIR is a reader, not a target

There is no instruction selection on this side of the boundary. The compiler
borrows an arm64 TargetMachine so the optimiser has something to talk to,
rewrites the module until it is Apple-shaped, and serialises it for a frozen
LLVM fork inside the Metal compiler service. Every hard problem in the port —
version skew, silent semantics, unnamed failures — follows from that one
fact. NVPTX and AMDGPU never have it; they consume the optimiser's output
in-process.

## 2. The identity is five numbers, and one is inside the triple

Family, AIR version, Metal language version, SDK version, minimum OS. They
vary independently, the AIR and Metal versions are properties of the
*toolchain* and not the chip, and `_v28` in `air64_v28-apple-macosx26.0.0`
is the AIR version stated a second time. One profile builds all of it, and an
unverified profile is refused rather than guessed at.

## 3. Sample the toolchain, never the table

The stdlib's `+metal3_2,+air2_7_0` pairing describes what the *language*
pairs with; the file describes what the *toolchain* writes. Every probe in
both Apple profiles of the oracle corpus stamps AIR 2.8.0. The conservative
choice was tried once, was rejected, and *taught nothing because the error
named nothing*.

## 4. There is no generic address space, and the failure is silent

> *A kernel whose stores are in `addrspace(1)` and whose loads are in
> `addrspace(0)` writes correctly and reads zero.*

Any `ptr` without an `addrspace` in a finished kernel is a defect unless it
is alloca-derived. The idiom for reaching a raw address is `inttoptr`, not
`addrspacecast`, which Apple never emits and which AMD's backend needed for a
reason that did not survive the port. Shader validation on and off, in one
run, tells non-residency from a generic pointer.

## 5. Inline first, then legalise, then legalise again

Three separate defects were "the code moved after I legalised it". Helpers
are inlined before the first AIR-specific rewrite, and the address-space,
three-way-compare and deviceize passes run a second time after the
post-optimisation inliner, because *on AIR that is not a missed optimisation,
it is a wrong answer*.

## 6. Verify canonical IR; the disassembler lies; the bitstream does not

Gate 1 sits after legalisation and before the typed-pointer downgrade, or it
cries wolf twenty-three times for four findings. `llvm-dis` re-populates
intrinsic attributes on load, so what it prints is not what was written;
dump the module from inside the compiler and read records with
`llvm-bcanalyzer`. And the one typed-pointer rule: a call's explicit type
must equal the pointee type of its callee — for *every* callee, not the one
the fix was first hit on.

## 7. Form is not deployability

Three gates check form. A module can pass all of them and kill the compiler
service at pipeline creation with a message that names nothing — for a dead
`declare`, a vector `llvm.fma`, an `i4`. Gate 4 compiles every function in the
metallib to a pipeline state. It is twenty lines and belongs in CI.

## 8. The best optimisation was turning one off

An Apple lane is scalar. SLP packed a fully unrolled matmul sixteen wide and
Apple's compiler ran it 9% slower than the scalar form. With SLP and
VectorCombine off the port sits at 970 GFLOP/s against the release's 956 and
Apple's 951; device O0 is within 0.3% of the best. Apple's compiler is the
optimiser. The device pipeline's job is to not get in its way — and to unroll
only the loops the source left rolled, behind a gate whose marks are stripped
before the driver sees them.

## 9. Dispatch cost is an encoder boundary

Metal charges 3.5 µs for a fresh compute encoder and 1.0 µs for a dispatch
inside an open one, because a boundary is a GPU-side drain. One encoder per
batch, a ring of four command buffers and a hash-keyed function cache put the
runtime at 0.9–1.0 µs, Metal's own floor, and took STREAM from 81 to 97 GB/s
without touching a kernel. The 150 µs round trip for a host-observed result
is the same for everyone and is the reason the examples batch a frame's
dispatches rather than reading anything back mid-frame.

## 10. A null experiment is a cache hit until proven otherwise

Six knob experiments measured the same number and emitted identical bitcode
because the compile cache had served all six. A silent hit is
indistinguishable from "the knob had no effect", so it produces confident
false refutations — and it can hide a compiler regression from the suites.
Fresh `MODULAR_CACHE_DIR` for anything that exercises the compiler, an
`[air-knobs]` line from every knob, retained artefacts before belief, and the
suites rather than the motivating program before a push.
