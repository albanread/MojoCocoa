#!/usr/bin/env bash
# Build dist/CocoaMojo -- a self-contained CocoaMojo toolchain with no bazel in it.
#
# Bazel builds the compiler. It has no business being in the way afterwards, and
# it was: handing a build action one environment variable via --action_env re-keys
# every action in the graph, so changing where the SDK database lives rebuilt LLVM.
# That is what this script removes. Run it once after a compiler build; from then
# on `cocoamojo --build` and `--run` are the whole interface.
#
#   ./tools/make-dist.sh
#   dist/CocoaMojo/bin/cocoamojo --run spikes/mandelbrot/mandelbrot.mojo
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
B="$(readlink bazel-bin || echo bazel-bin)"
D="$ROOT/dist/CocoaMojo"
KB="${COCOAKB:-$ROOT/../CocoaBaseMCP/cocoa.sqlite}"

[ -x "$B/KGEN/tools/mojo/mojo" ] || { echo "build the compiler first:"; \
  echo "  ./bazelw build --config=build-mojo //KGEN:mojo"; exit 1; }

mkdir -p "$D"/{bin,lib,share}

echo "== compiler =="
cp -f "$B/KGEN/tools/mojo/mojo" "$D/bin/cocoamojo-compiler"
cp -f "$ROOT/tools/cocoamojo" "$D/bin/cocoamojo"; chmod +x "$D/bin/cocoamojo"

echo "== runtime dylibs =="
for l in KGEN/libKGENCompilerRTShared.dylib \
         AsyncRT/libAsyncRTRuntimeGlobals.dylib \
         Support/libMSupportGlobals.dylib; do
  cp -f "$B/$l" "$D/lib/"
done

# LLVM. The compiler links against this rather than absorbing it, and it is here
# to be linked against by other things too -- an IDE or language server can use
# it without building LLVM at all. bazel puts the real file under _solib_*, so
# find it rather than guessing the path.
echo "== LLVM =="
LLVMLIB="$(find "$B" -name 'libLLVM.dylib' -type f 2>/dev/null | head -1)"
[ -n "$LLVMLIB" ] || { echo "   no libLLVM.dylib -- build //bazel/llvm-shared:LLVM"; exit 1; }
cp -f "$LLVMLIB" "$D/lib/"
nexp=$(nm -gU "$D/lib/libLLVM.dylib" | grep -c '4llvm') || true
# Under the toolchain's default -fvisibility=hidden this lands near 200 rather
# than tens of thousands, and the dylib is useless to anything outside. That is
# a silent failure, so it is checked rather than assumed.
[ "$nexp" -gt 10000 ] || { echo "   libLLVM.dylib exports only $nexp llvm:: symbols -- visibility regression"; exit 1; }
echo "   $(du -h "$D/lib/libLLVM.dylib" | cut -f1), $nexp llvm:: symbols exported"

# The GPU runtime, built here rather than taken from bazel-out on purpose.
#
# Bazel compiles these two files with -fvisibility=hidden, so every
# AsyncRT_DeviceContext_* entry point lands in the object as a *private* extern.
# Statically linked into one binary that is invisible; the moment you want them
# from a JIT or a dylib they are simply not there, which is why `mojo run` on a
# GPU program failed with "Symbols not found: [_AsyncRT_DeviceContext_create...]"
# and why -force_load and `ld -r -keep_private_externs` could not rescue it --
# none of them can un-hide a symbol. Recompiling with default visibility can, and
# does: 125 exported symbols instead of none.
#
# ARC is off for AppleGPUMetal.cpp: it does its own retain/release and calls
# dispatch_release, which ARC forbids.
echo "== GPU runtime (libCocoaMojoGPU) =="
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
M="$ROOT/AsyncRT/lib/MojoBindings"
clang++ -std=c++17 -O2 -arch arm64 -fvisibility=default -x objective-c++ \
        -fobjc-arc    -c "$M/AppleGPURT.cpp"    -o "$TMP/AppleGPURT.o"
clang++ -std=c++17 -O2 -arch arm64 -fvisibility=default -x objective-c++ \
        -fno-objc-arc -c "$M/AppleGPUMetal.cpp" -o "$TMP/AppleGPUMetal.o"
clang++ -dynamiclib -arch arm64 -install_name '@rpath/libCocoaMojoGPU.dylib' \
        -o "$D/lib/libCocoaMojoGPU.dylib" "$TMP/AppleGPURT.o" "$TMP/AppleGPUMetal.o" \
        -framework Metal -framework Foundation -framework CoreGraphics \
        -framework IOKit -lobjc
n=$(nm -gU "$D/lib/libCocoaMojoGPU.dylib" | grep -c 'AsyncRT') || true
[ "$n" -gt 100 ] || { echo "GPU runtime exported only $n AsyncRT symbols -- visibility regression"; exit 1; }
echo "   $n AsyncRT symbols exported"

echo "== packages =="
# Sources, not .mojoc: a precompiled package records a compiler version and this
# tree's compiler rejects packages built by a different one.
mkdir -p "$D/lib/mojo"
rsync -a --delete "$ROOT/mojo/stdlib/"      "$D/lib/mojo/stdlib/"
rsync -a --delete "$ROOT/max/mojo/"         "$D/lib/mojo/max/"
rsync -a --delete "$ROOT/max/kernels/src/"  "$D/lib/mojo/kernels/"

echo "== cocoa database =="
if [ -f "$KB" ]; then cp -f "$KB" "$D/share/cocoa.sqlite"
else echo "   WARNING: no cocoa.sqlite at $KB -- set COCOAKB=..."; fi

echo
echo "dist/CocoaMojo ready ($(du -sh "$D" | cut -f1))"
echo "  dist/CocoaMojo/bin/cocoamojo --run spikes/mandelbrot/mandelbrot.mojo"
