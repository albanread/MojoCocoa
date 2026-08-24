//===- AirTargetProfile.h - One coherent Apple target identity -----------===//
//
// The Apple target identity is five separate things that were being carried as
// scattered literals:
//
//   GPU family              apple-m4        hardware, what the runtime reports
//   AIR version             2.8.0           encoded in the triple as _v28
//   Metal language version  4.0.0           air.language_version
//   SDK version             26.0            "SDK Version" module flag
//   minimum deployment OS   26.0.0          the macosx part of the triple
//
// Conflating them is why `metal:4` reads as a Metal language version when it
// actually selects M4 HARDWARE, and why the triple, air.version and
// air.language_version each had their own literal and their own comment
// warning that the other two must be changed to match.
//
// They vary independently. The AIR and Metal versions are properties of the
// installed TOOLCHAIN, not of the chip: this machine's Metal toolchain emits
// 2.8/4.0 for an M1 as readily as an M4. The family selects capabilities.
// So a profile is (family x language profile), and the alias
// `apple-m4-metal4` names the pair rather than a sixth arch.
//
// One disagreement is deliberate and worth stating, because it looks like a
// bug. std/gpu/host/info.mojo maps an unsuffixed `apple-m4` to
// "+metal3_2,+air2_7_0", while this defaults to Metal 4. The backend has
// always stamped 2.8/4.0 regardless of those feature strings, and it has
// always been right to: the installed toolchain emits 2.8/4.0, and the
// conservative-looking choice was tried, produced a module the reader
// rejected, and taught nothing because the error named nothing. The frontend
// feature string selects LANGUAGE features for the stdlib to gate on; what
// gets stamped into the module is a property of the toolchain that will
// package it. Making that explicit here is the point -- it was previously an
// unremarked literal.
//
//===----------------------------------------------------------------------===//

#ifndef KGEN_OBJECTCOMPILER_TARGET_AIR_AIRTARGETPROFILE_H
#define KGEN_OBJECTCOMPILER_TARGET_AIR_AIRTARGETPROFILE_H

#include <optional>
#include <string>

#include "llvm/ADT/StringRef.h"
#include "llvm/Support/FormatVariadic.h"

namespace M::KGEN::Air {

/// A toolchain-level language profile: what the Metal frontend stamps.
struct LanguageProfile {
  llvm::StringRef name;
  unsigned airMajor, airMinor, airPatch;
  unsigned metalMajor, metalMinor, metalPatch;
  unsigned sdkMajor, sdkMinor;
  unsigned osMajor, osMinor, osPatch;
  /// The LLVM bitcode format the AIR reader accepts. Lives here rather than
  /// beside the writer because it is a property of the toolchain, exactly like
  /// the AIR version -- and because it was previously stranded in AirTraits.h,
  /// a different file from every other stamp, which is how it stayed pinned to
  /// a value verified against a Metal toolchain nobody runs any more.
  unsigned bitcodeVersion;
  /// False until someone has actually run `xcrun metal -S -emit-llvm` under
  /// this profile and read the numbers off the result. Selecting an
  /// unverified profile is refused rather than guessed at -- picking the
  /// conservative-looking one without measuring is a mistake this backend has
  /// already made once, and the module was rejected with no useful error.
  bool goldenVerified;
};

/// Measured on this machine: Metal toolchain "Apple metal version 32023.830",
/// `xcrun metal -S -emit-llvm` emits triple air64_v28-apple-macosx26.0.0,
/// air.version 2.8.0, air.language_version Metal 4.0.0.
inline constexpr LanguageProfile kMetal4 = {
    /*name=*/"metal4", /*air=*/2, 8, 0, /*metal=*/4, 0, 0,
    /*sdk=*/26, 0,     /*os=*/26, 0, 0, /*bitcode=*/17,
    /*goldenVerified=*/true};

/// The pairing std/gpu/host/info.mojo carries as "+metal3_2,+air2_7_0".
/// The AIR and Metal numbers come from that table; the SDK and OS numbers do
/// NOT -- nobody has sampled a Metal 3.2 toolchain here. Left unverified on
/// purpose so selecting it fails loudly instead of stamping invented versions.
inline constexpr LanguageProfile kMetal3_2 = {
    /*name=*/"metal3_2", /*air=*/2, 7, 0, /*metal=*/3, 2, 0,
    /*sdk=*/0, 0,        /*os=*/0, 0, 0,  /*bitcode=*/17,
    /*goldenVerified=*/false};

/// Metal feature-set limits. Module metadata, so they belong to the profile
/// even though every Apple family currently agrees on them -- the point of the
/// profile is that a family which does not can say so in one place.
struct ResourceLimits {
  unsigned deviceBuffers = 31;
  unsigned constantBuffers = 31;
  unsigned threadgroupBuffers = 31;
  unsigned textures = 128;
  unsigned readWriteTextures = 8;
  unsigned samplers = 16;
};

struct TargetProfile {
  /// Hardware generation, as the runtime discovers and reports it.
  llvm::StringRef family;
  LanguageProfile lang;
  ResourceLimits limits;

  /// The AIR version is encoded IN the triple (`_v28` == AIR 2.8), which is
  /// why it can never be stamped independently of air.version.
  std::string triple() const {
    return llvm::formatv("air64_v{0}{1}-apple-macosx{2}.{3}.{4}", lang.airMajor,
                         lang.airMinor, lang.osMajor, lang.osMinor,
                         lang.osPatch)
        .str();
  }

  /// AIR has no LLVM codegen target, so the optimisation pipeline runs against
  /// an arm64 TargetMachine. Its OS version is derived here for one reason:
  /// it used to be a literal `arm64-apple-macosx14.2.0` in AirTraits.h,
  /// contradicting the AIR triple's macosx26.0.0 while nobody noticed, because
  /// "the host triple" is not where you look when auditing AIR versions.
  std::string codegenTriple() const {
    return llvm::formatv("arm64-apple-macosx{0}.{1}.{2}", lang.osMajor,
                         lang.osMinor, lang.osPatch)
        .str();
  }

  /// One line, for verbose output and retained-artifact manifests. A failure
  /// report that does not say which profile produced the module is missing the
  /// first thing you would ask.
  std::string describe() const {
    return llvm::formatv(
               "family={0} profile={1} air={2}.{3}.{4} metal={5}.{6}.{7} "
               "sdk={8}.{9} minos={10}.{11}.{12} triple={13}",
               family, lang.name, lang.airMajor, lang.airMinor, lang.airPatch,
               lang.metalMajor, lang.metalMinor, lang.metalPatch,
               lang.sdkMajor, lang.sdkMinor, lang.osMajor, lang.osMinor,
               lang.osPatch, triple())
        .str();
  }
};

/// Resolve the arch string the frontend leaves in `target-cpu`.
///
/// Accepts `apple-m1`..`apple-m5`, optionally suffixed with a language profile
/// (`apple-m4-metal4`). `metal:4` is normalised to `apple-m4` upstream, so it
/// never reaches here. Returns nullopt for an unknown family, and reports an
/// unverified language profile through `unverified` so the caller can refuse
/// it with a real diagnostic rather than silently stamping guessed versions.
inline std::optional<TargetProfile> profileForArch(llvm::StringRef arch,
                                                   bool &unverified) {
  unverified = false;
  llvm::StringRef family = arch;
  LanguageProfile lang = kMetal4;
  if (arch.consume_back("-metal4")) {
    family = arch;
  } else if (arch.consume_back("-metal3_2")) {
    family = arch;
    lang = kMetal3_2;
  }
  if (family != "apple-m1" && family != "apple-m2" && family != "apple-m3" &&
      family != "apple-m4" && family != "apple-m5")
    return std::nullopt;
  unverified = !lang.goldenVerified;
  return TargetProfile{family, lang};
}

} // namespace M::KGEN::Air

#endif // KGEN_OBJECTCOMPILER_TARGET_AIR_AIRTARGETPROFILE_H
