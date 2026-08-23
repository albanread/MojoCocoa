# Where this port stands — pick up here

Two things live in this tree, both ported from the x86-64
[MojoMacX64](https://github.com/albanread/MojoMacX64) fork to Apple Silicon:

1. **Cocoa support** (`cocoakb`) — DONE and validated.
2. **Apple Silicon GPU stack** (AIR lowering + runtime) — ported, NOT yet compiled.

See `COCOA_ARM64.md` and `AIR_APPLE_SILICON.md` for the design notes.

## 1. Cocoa — done

9/9 spikes pass. `./spikes/run-cocoa-checks.sh` runs them.

    export MODULAR_MOJO_MAX_COCOAKB_PATH="$PWD/../CocoaBaseMCP/cocoa.sqlite"
    ./spikes/run-cocoa-checks.sh

Compiler: `bazel-bin/KGEN/tools/mojo/mojo-full` (Mojo 1.1.0.dev0). The raw
binary cannot find `std.mojoc` on its own — run Mojo through
`./bazelw run //KGEN:mojo -- run <abs-path>`, which supplies the stdlib.

Database: rebuilt from the live runtime with `python3 ../CocoaBaseMCP/build.py`
(12s, 236MB, 28,814 classes / 522,170 methods). Re-run after any macOS update.

## 2. AIR / GPU — ported, uncompiled

**Nothing in this section has been through a compiler yet.** That is the first
job in the morning.

Files added:

    KGEN/lib/Target/Air/AirTraits.{h,cpp}
    KGEN/lib/KGENToLLVM/Target/Air/AirLowering.cpp        <-- NOT yet reviewed
    KGEN/lib/Compiler/ObjectCompiler/Target/Air/AirBackend.cpp
    AsyncRT/lib/MojoBindings/AppleGPU{RT,Metal,Internal}.*

Changes made, all unverified:

- `AirTraits` — arch list is now `apple-m1`..`apple-m5` (upstream's own names).
- `AirBackend` — retargeted to the profile Apple's toolchain actually emits,
  read off a golden sample rather than guessed:
  `air64_v28-apple-macosx26.0.0`, `air.version 2.8.0`, `Metal 4.0.0`, SDK 26.0.
- `AirBackend` — **capture hoisting removed**. It burned one of 31 buffer slots
  per captured pointer, and existed only because AMD needs a bound resource.
  `deviceizeCapturedPointers` was extended to cover the `extractvalue` case it
  used to handle.
- `AppleGPUMetal` — unified memory: every buffer `storageModeShared`, HtoD/DtoH
  are plain `memcpy`, staging blits gone (kept behind `kUnifiedMemory` +
  `hostVisible`). `WARP_SIZE` 64 -> 32. `archForName` reads the M-series digit.
  `CLOCK_RATE` no longer answered (was Vega 20's 1.7GHz; Metal exposes none).
- Whole Vega naming sweep -> AppleGPU, including the `__vega_cap_` ->
  `__applegpu_cap_` handshake, which is now moot since hoisting is gone.

### Two known gaps, both marked in the source

- `TODO(air-indirect)` in `AirBackend.cpp` — Apple describes capture structs as
  `air.indirect_buffer` + `air.struct_type_info` with nested
  `air.indirect_argument` records. We do not emit that yet. One buffer slot for
  the whole blob, however many captured pointers.
- `TODO(air-residency)` in `AppleGPUMetal.cpp` — **the one that will bite.** A
  pointer dereferenced by GPU address rather than through a bound argument
  still needs its allocation resident for the dispatch; Metal will not infer
  that from a raw address. Hoisting used to give this for free. The registry
  `resolveAddress()` walks knows every live buffer, so the coarse fix is
  `useResource:usage:` across all of them on the encoder.

`AirLowering.cpp` has NOT been looked at yet. It mangles `air.simd_shuffle_*`
by payload type; the thing to check is anything assuming wave64, since Apple
SIMD groups are 32 lanes. `mojo/stdlib/std/gpu/primitives/warp.mojo` already
carries an Apple path — read it first.

## Build discipline (learned the hard way)

Only **toolchain or sysroot** changes invalidate LLVM+MLIR — that is a ~35-50
minute rebuild. Source changes are KGEN-only: the `LowerPOPToLLVM` fix was 24
seconds / 9 actions. Do not edit `local.bazelrc` or
`bazel/internal/cc-toolchain/macos_sysroot_repository.bzl` casually; the
`--action_env` line and the framework list are both settled and paid for.

## Golden-sample technique

The way to check anything about AIR, rather than guessing from tables:

    xcrun metal -S -emit-llvm k.metal -o k.ll     # Apple's own IR + metadata
    xcrun metal -x ir -c k.ll -o k.air            # round-trip our IR back in

Xcode ships a full LLVM-style AIR toolchain (`air-objdump`, `air-readobj`,
`air-nm`, `air-opt`, `air-link`). Samples from tonight are in /tmp/goldenair
(not preserved across reboot — regenerate, it takes seconds).

## Reference numbers on this machine (Apple M4, 10 GPU cores)

From **Modular's own wheel compiler**, which has the closed Metal backend —
this is the target to match once our stack runs:

    spikes/mandelbrot/compute_smoke.mojo
      CPU: 219.284 ms   GPU: 6.205 ms   35.34x   100% exact agreement

    maxBufferLength 8.88 GiB, recommendedMaxWorkingSet 11.84 GiB, unified YES
