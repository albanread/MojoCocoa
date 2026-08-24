# An Apple Silicon GPU stack for Mojo — no Modular binaries

> [!NOTE]
> This is the original porting plan. The stack has since compiled and run end
> to end. For the current evidence, architecture review, systemic findings,
> and recommended adjustments, see
> [`APPLE_GPU_LOWERING_REVIEW.md`](APPLE_GPU_LOWERING_REVIEW.md) and
> [`STATUS.md`](STATUS.md).

Scoping notes for porting the MacVegaFork GPU stack from the Radeon Pro Vega II
to Apple Silicon, so one from-source compiler has **both** the Cocoa support
(`cocoakb`, see `COCOA_ARM64.md`) and GPU codegen — using only our own code.

## 1. The gap, and where it sits

    max  (Mojo, open source)
      |   calls AsyncRT_* C symbols
      v
    AsyncRT_* C ABI  ....................... the seam
      |
      v
    [ GPU runtime ]  <-- Modular ships libmax.dylib + libMGPRT.dylib (closed)
      |                  MacVegaFork ships VegaRT.cpp + VegaRTMetal.cpp (ours)
      v
    Apple Metal drivers

    KGEN (open source)
      |   TargetTraits / TargetBackend virtuals ... the other seam
      v
    [ AIR lowering ]  <-- Modular's is a closed out-of-tree plugin
      |                   MacVegaFork ships AirTraits/AirLowering/AirBackend (ours)
      v
    .metallib

Both seams are open; both implementations behind them are closed. We already
have our own implementation of each, written for a harder target.

## 2. Why not just link Modular's

Established by inspection, so nobody re-derives it:

- `KGEN/lib/{Target,KGENToLLVM/Target,Compiler/ObjectCompiler/Target}/` contain
  **only `Host`** upstream.
- The macOS wheels ship no backend library: `mojo_compiler` has
  `bin/{lld,mojo,modular-crashpad-handler}` + three runtime dylibs; `max_core`
  has `libmax`, `libMGPRT`, `libAsyncRTMojoBindings`. That is all of them.
- `libNVPTX.so` is shipped separately but is Linux-only and is a `cc_import`
  dep of `max_lib` (the runtime), not of `mojo_common` (the compiler).
- Registration is link-time (`TargetTraitsRegistry`, `KGEN/lib/Target/
  TargetTraits.h:165`). There is no `dlopen` in the compiler.
- The wheel's `mojo` carries `air64-apple-macosx` (x1) and `metallib` (x8);
  the from-source `mojo-full` carries zero of each. (Both carry `amdgcn` /
  `nvptx64` strings — that is LLVM's own target list, not Modular lowering.)

## 3. What upstream leaves open

The extension surface is fully public and plainly meant for out-of-tree use:

- `KGEN/lib/Target/TargetTraits.h` — `matches`, `isGPU`, `codegenTriple`,
  `forcedBitcodeVersion`, the three extension getters, `acceleratorSectionTitle`,
  `supportedAcceleratorArchs`, `emitsOffloadObjectFile`.
- `KGEN/include/KGEN/Compiler/Target/TargetBackend.h` — ~20 virtuals including
  `finalizeModuleForTarget`, `emitBitcode`, `buildLLVMPipeline`,
  `sharedMemoryAddressSpace`, `requiresOriginalFunctionOrder`.
- `KGEN/BUILD.bazel` has a `plugin_consumers` package group exporting
  `TargetBackend.headers`, commented *"Narrow to the plugin repo once Bazel
  supports external repo refs"* — their own backends are a plugin against
  these very headers.
- The `AsyncRT_*` C ABI is recovered in `MojoBindings/ABI-NOTES.md` (~130
  symbols), taken from the call-site comments in the open Mojo source.

## 4. What we already have — 2,964 lines

| layer | file | lines |
|---|---|---:|
| compiler | `KGEN/lib/Target/Air/AirTraits.{h,cpp}` | 77 |
| compiler | `KGEN/lib/KGENToLLVM/Target/Air/AirLowering.cpp` | 177 |
| compiler | `KGEN/lib/Compiler/ObjectCompiler/Target/Air/AirBackend.cpp` | 991 |
| runtime | `AsyncRT/lib/MojoBindings/VegaRT.cpp` | 960 |
| runtime | `AsyncRT/lib/MojoBindings/VegaRTMetal.cpp` | 759 |
| runtime | `VegaRTInternal.h`, `BUILD.bazel`, `vegart_metal_smoke.c` | 228 |

The codegen path — LLVM IR -> air64 bitcode (LLVM-17 encoding) -> `metal`
frontend -> `.metallib` — is Apple's standard pipeline, not AMD-specific. The
driver lowers AIR -> GCN on a Vega and AIR -> AGX on Apple Silicon; same input.
`__vega_cap_<param>_<offset>` is a private handshake between our own AirBackend
and our own VegaRT, so it stays internally consistent and needs no rework.

## 5. The Apple Silicon deltas

**5.1 Unified memory — the big one, and it simplifies.** `VegaRTMetal.cpp`
says: *"Discrete-GPU semantics throughout: device buffers are
storageModePrivate in HBM2; host buffers are storageModeShared; every HtoD/DtoH
goes through a staging blit."* On Apple Silicon there is one pool. Device
buffers become `storageModeShared`, and the HtoD/DtoH staging blits collapse to
`memcpy` or disappear. Less code, and faster — the frame never crosses PCIe.

**5.2 SIMD width, 64 -> 32.** `VegaRTMetal.cpp` returns `WARP_SIZE = 64`
("wave64, verified in S1"). Apple SIMD groups are 32 lanes. Every shuffle mask,
ballot width and reduction that assumed 64 must be re-derived — in the runtime
attribute *and* in `AirLowering`'s `air.simd_shuffle_*` handling. Upstream's
`mojo/stdlib/std/gpu/primitives/warp.mojo` already carries an Apple path; read
it before writing a new one.

**5.3 Arch naming.** `archForName()` matches `"Vega II"` -> `metal-vega2` and
`"580X"` -> `metal-polaris`. Needs the M-series. The existing comment is the
constraint worth preserving: the string must classify as APPLE_GPU in the
stdlib's `_vendor_from_arch`, which substring-matches — `"amd"`/`"gfx"`/`"mi"`
would misroute codegen to HIP. `info.mojo:676` accepts `"metal"` or `"apple"`,
and upstream already names `apple-m1`..`apple-m4` with `+metal3_2,+air2_7_0`.
This machine reports `metal:4` (Apple M4, 10 GPU cores).

**5.4 Clock rate / occupancy constants.** `CLOCK_RATE` is hardcoded to Vega 20's
1.7 GHz; `MAX_THREADS_PER_BLOCK` 1024 is plausible on Apple but should be
queried rather than assumed.

**5.5 Naming.** `VEGA_KEEP_AIR`, `vega-kernel.*` temp files, "MacVegaFork AIR
backend" producer metadata. Cosmetic, but worth doing at port time rather than
living with a Vega-named Apple stack.

## 6. What did NOT need porting

`AirBackend` needs the `lib/Compiler/ObjectCompiler/LLVM/Bitcode/17/*.h` glob in
`KGEN/BUILD.bazel` — recorded in `COCOA_ARM64.md` as deliberately skipped during
the Cocoa port, since it was the AMD-side dependency then. It comes back now.

## 7. Suggested order

1. Wire the three `Air` directories + the Bitcode/17 glob into `KGEN/BUILD.bazel`;
   port `AirTraits` with M-series archs. Get `--target-accelerator=metal:4` to
   stop erroring with *"target 'air64-apple-macosx' is not supported"*.
2. Port `VegaRT`/`VegaRTMetal` with unified-memory storage modes and
   `WARP_SIZE = 32`. `vegart_metal_smoke.c` is the existing bring-up harness.
3. One trivial kernel end to end.
4. Re-derive the wave64 assumptions in `AirLowering`.
5. Validate with `spikes/mandelbrot/compute_smoke.mojo` — it already
   cross-checks GPU against CPU bit-exactly.

Reference numbers from Modular's own wheel compiler on this M4, for comparison
once ours runs: **CPU 219.284 ms, GPU 6.205 ms, 35.34x, 100% agreement.**
