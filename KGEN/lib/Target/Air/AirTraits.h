//===----------------------------------------------------------------------===//
// TargetTraits for Apple AIR (air64) — the Metal GPU target.
//
// Fills the shape the upstream hooks were built for (codegenTriple,
// forcedBitcodeVersion). Ported from the x86-64 MacVegaFork, where the same
// backend drove a Radeon Pro Vega II; the AIR pipeline itself is Apple's and
// is not vendor-specific — the driver lowers AIR to GCN on a Vega and to AGX
// on Apple Silicon from the same bitcode. See AIR_APPLE_SILICON.md.
//===----------------------------------------------------------------------===//

#ifndef KGEN_TARGET_AIR_AIRTRAITS_H
#define KGEN_TARGET_AIR_AIRTRAITS_H

#include "Target/TargetTraits.h"

#include "Target/Air/AirTargetProfile.h"

#include "llvm/TargetParser/Triple.h"

namespace M::KGEN {

struct AirTraits final : TargetTraits {
  llvm::StringRef name() const override { return "air"; }
  bool matches(const llvm::Triple &triple) const override {
    return triple.str().starts_with("air64");
  }
  bool isGPU() const override { return true; }
  llvm::StringRef getAsmExtension() const override { return ".air.ll"; }
  llvm::StringRef getLLVMExtension() const override { return ".air-in.ll"; }
  llvm::StringRef getObjectExtension() const override { return ".metallib"; }

  /// AIR has no LLVM codegen target; the TargetMachine (used for the opt
  /// pipeline only) is built for arm64, matching upstream's "Metal GPU
  /// targets use ARM64 during compilation" convention. The bazel-built LLVM
  /// carries the AArch64 backend.
  std::string codegenTriple(llvm::StringRef triple) const override {
    // Derived from the default language profile, not written out again. The
    // literal that used to sit here said macosx14.2.0 -- left over from the
    // x86-64 fork's pinned Xcode 15.2, and quietly contradicting the AIR
    // triple's macosx26.0.0 for as long as both existed.
    return Air::TargetProfile{"apple-m4", Air::kMetal4}.codegenTriple();
  }

  /// The hardware-verified AIR profile is LLVM-17-encoded bitcode. Verified
  /// against Xcode 15.2 on the x86-64 fork; re-verify against the Xcode in use
  /// here before trusting it (AIR_APPLE_SILICON.md §5).
  unsigned forcedBitcodeVersion() const override {
    return Air::kMetal4.bitcodeVersion;
  }

  llvm::StringRef acceleratorSectionTitle() const override {
    return "Apple Metal";
  }

  /// The arch names upstream already knows: std/gpu/host/info.mojo defines
  /// apple-m1..apple-m5 against triple air64-apple-macosx, and sys/info.mojo
  /// accepts either the bare form ("apple-m4") or the vendor-prefixed one
  /// ("metal:4"). Both must classify as APPLE_GPU in the stdlib's
  /// _vendor_from_arch, which substring-matches -- a name containing "amd",
  /// "gfx" or "mi" would misroute device codegen to the HIP paths.
  ///
  /// Every Apple GPU family here is 32-lane (upstream AppleMetalFamily:
  /// warp_size=32, max_thread_block_size=1024, 32KB threadgroup memory),
  /// unlike the Vega's wave64.
  llvm::ArrayRef<AcceleratorArch> supportedAcceleratorArchs() const override {
    static const AcceleratorArch archs[] = {
        {"apple-m1", "Apple M1 GPU through Metal (SIMD32)"},
        {"apple-m2", "Apple M2 GPU through Metal (SIMD32)"},
        {"apple-m3", "Apple M3 GPU through Metal (SIMD32)"},
        {"apple-m4", "Apple M4 GPU through Metal (SIMD32)"},
        {"apple-m5", "Apple M5 GPU through Metal (SIMD32)"},
    };
    return archs;
  }

  static const AirTraits &get();

protected:
  bool isBaseTarget() const override { return false; }
};

} // namespace M::KGEN

#endif // KGEN_TARGET_AIR_AIRTRAITS_H
