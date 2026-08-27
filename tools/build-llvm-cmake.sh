#!/usr/bin/env bash
# Build LLVM and MLIR as shared libraries with CMake -- no bazel.
#
#   ./tools/build-llvm-cmake.sh [build-dir]
#
# This is the supported way to get a libLLVM.dylib. Upstream builds one with
# -DLLVM_BUILD_LLVM_DYLIB=ON, which also switches on LLVM_ENABLE_LLVM_EXPORT_ANNOTATIONS
# so the library exports through LLVM's own LLVM_ABI attributes rather than the
# blanket -fvisibility=default this repo has to use to coax one out of bazel.
#
# The flags below match what bazel compiles LLVM with in --config=release, so
# the result is ABI-compatible with the rest of this tree. The ones that matter,
# and are silent failures if wrong:
#
#   fallback TypeIDs   -DMLIR_USE_FALLBACK_TYPE_IDS=1. This is the one that is
#                      silent, total and retroactive if wrong. bazel applies it
#                      to every compile action including MLIR's own
#                      (bazel/internal/cc-toolchain/args/BUILD.bazel:134); the
#                      header defaults it to false. It exists so MLIR objects can
#                      cross a shared-library boundary, which is exactly what a
#                      libMLIR.dylib plus a separate compiler library does.
#
#                      Without it the two libraries hold different definitions of
#                      the same header template, link cleanly, and then compute
#                      different TypeIDs than the ones baked into the dylib --
#                      dialect, op, attribute and interface lookups quietly miss.
#                      Measured here: 10,876 TypeIDResolver symbols in the bazel
#                      libMLIR against 5,182 in a build without the flag.
#
#                      There is no CMake option for it. It goes in CMAKE_CXX_FLAGS
#                      for the whole build or it is not applied at all.
#
#   assertions ON      bazel passes -UNDEBUG, so LLVM here has assertions
#                      enabled even in an optimised build. Assertions change
#                      LLVM's ABI, so a Release-without-assertions library
#                      cannot be mixed with this tree's compiler.
#   no RTTI, no EH     -fno-rtti -fno-exceptions
#   C++20, libc++
#   AArch64 only       matches bazel/public-patches/llvm_project.bzl
#   lld                KGEN's ObjectCompiler resolves ld64.lld to link what it
#                      emits. An mlir-only install has no lld and the compiler
#                      falls back to hunting PATH.
#   -mcpu=apple-m4
#
# One divergence to know about: bazel compiles zstd from source, this links
# Homebrew's static libzstd.a. Same C ABI, so it holds, but Homebrew builds it
# for a newer deployment target than the 11.0 used here and the linker says so.
# The warning is harmless; the alternative is building zstd too.
#   zstd ON, static     bazel compiles zstd from source and enables it, so a
#                       library built without it cannot read what this tree
#                       writes. Linked statically on purpose: the shared one
#                       lives under /opt/homebrew and a distribution that
#                       depends on that path does not run on a Mac without it.
#
# Source defaults to the tree bazel already fetched and patched, so this builds
# the same LLVM the compiler was built against, patches included. Override with
# LLVM_SRC to point somewhere else.
# RESULT, measured on an M4 Max: 5,191 actions, zero failures, first configure
# succeeded without adjustment.
#
#   libLLVM.dylib    62.5 MB    37,493 exported symbols   (bazel's: 77.7 MB)
#   libMLIR.dylib   106.2 MB   140,426 exported symbols   (bazel's: 159.5 MB)
#
# Smaller than the bazel-built pair, which is not what you would guess. The code
# is the same size either way -- __TEXT is 55.9 MB against bazel's 55.3 for LLVM,
# and for MLIR ours is actually less, 78.0 against 79.7. Every megabyte of the
# difference is __LINKEDIT: the symbol table and export trie.
#
# Two things account for it. CMake keeps ~347,000 local symbols that nothing
# needs at run time, so the install step strips them -- unstripped these are
# 107.5 MB and 238.8 MB, and `strip -x` is the whole of the difference. And the
# export surface is smaller because LLVM_ABI annotations export deliberately:
# 140,426 MLIR symbols against bazel's 171,846, where bazel has to open
# everything with -fvisibility=default to get a usable dylib at all.
#
# The build tree keeps its symbols; only the install tree is stripped. Debug
# there, ship from here.
#
# libMLIR takes @rpath/libLLVM.24.0git.dylib rather than absorbing a second copy,
# and neither has any reference to /opt/homebrew -- verify with otool -L before
# shipping either, since a Homebrew path in there means the distribution only
# runs on a machine that has Homebrew.
#
# tools/ide-probe/{ide_probe,mlir_probe}.cpp compile and run against the install
# tree alone, with no bazel, no build directory and no LLVM source present.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

BUILD="${1:-/Volumes/xc/llvm-cmake/build}"
INSTALL="${LLVM_INSTALL:-/Volumes/xc/llvm-cmake/install}"

# The patched source bazel fetched. It reaches the workspace through a symlink
# into the repository cache; -L resolves it.
if [ -z "${LLVM_SRC:-}" ]; then
  OB="$(readlink bazel-bin 2>/dev/null | sed 's|/execroot/.*||')"
  LLVM_SRC="$(cd -P "$OB"/external/*llvm_source*llvm-raw 2>/dev/null && pwd)" || true
fi
[ -f "${LLVM_SRC:-}/llvm/CMakeLists.txt" ] || {
  echo "no LLVM source at ${LLVM_SRC:-<unset>}"
  echo "Set LLVM_SRC to an llvm-project checkout, or run a bazel build once so"
  echo "the patched source is fetched into the repository cache."
  exit 1
}
echo "source:  $LLVM_SRC"
echo "build:   $BUILD"
echo "install: $INSTALL"
echo

command -v cmake >/dev/null || { echo "cmake not installed"; exit 1; }
command -v ninja >/dev/null || { echo "ninja not installed"; exit 1; }

cmake -G Ninja -S "$LLVM_SRC/llvm" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$INSTALL" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
  -DLLVM_ENABLE_PROJECTS="mlir;lld" \
  -DLLVM_TARGETS_TO_BUILD=AArch64 \
  -DLLVM_BUILD_LLVM_DYLIB=ON \
  -DLLVM_LINK_LLVM_DYLIB=ON \
  -DLLVM_ENABLE_ASSERTIONS=ON \
  -DLLVM_ENABLE_RTTI=OFF \
  -DLLVM_ENABLE_EH=OFF \
  -DLLVM_ENABLE_ZLIB=ON \
  -DLLVM_ENABLE_ZSTD=ON \
  -DLLVM_USE_STATIC_ZSTD=TRUE \
  -DLLVM_ENABLE_LIBXML2=OFF \
  -DLLVM_ENABLE_TERMINFO=OFF \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_DOCS=OFF \
  -DMLIR_INCLUDE_TESTS=OFF \
  -DMLIR_INCLUDE_INTEGRATION_TESTS=OFF \
  -DCMAKE_C_FLAGS="-mcpu=apple-m4" \
  -DCMAKE_CXX_FLAGS="-mcpu=apple-m4 -std=c++20 -DMLIR_USE_FALLBACK_TYPE_IDS=1 -UNDEBUG"

echo
echo "== building (this is the long one) =="
ninja -C "$BUILD"

echo
echo "== installing =="
ninja -C "$BUILD" install

# Strip local symbols from the installed libraries. They are ~45 MB of libLLVM
# and ~130 MB of libMLIR, they are not exports, and nothing loads them at run
# time. The build tree is left alone so a debugger still has them.
echo
echo "== stripping the install tree =="
for lib in "$INSTALL"/lib/*.dylib; do
  [ -f "$lib" ] || continue
  before=$(stat -f%z "$lib")
  strip -x "$lib" 2>/dev/null || true
  after=$(stat -f%z "$lib")
  [ "$before" -ne "$after" ] && \
    printf "   %-18s %.1f -> %.1f MB\n" "$(basename "$lib")" \
      "$(echo "$before/1048576" | bc -l)" "$(echo "$after/1048576" | bc -l)"
done

echo
for lib in libLLVM.dylib libMLIR.dylib; do
  f="$INSTALL/lib/$lib"
  if [ -f "$f" ]; then
    n=$(nm -gU "$f" 2>/dev/null | wc -l | tr -d ' ')
    printf "  %-16s %s, %s exported symbols\n" "$lib" "$(du -h "$f" | cut -f1)" "$n"
  else
    printf "  %-16s NOT BUILT\n" "$lib"
  fi
done
