#!/usr/bin/env bash
# Build libCocoaMojoGPU -- the Metal/AsyncRT device runtime -- into a dist.
#
#   ./tools/make-gpu-runtime.sh              -> dist/CocoaMojo/lib
#   ./tools/make-gpu-runtime.sh /some/dist   -> there
#
# Two lines of clang++ and no bazel, so this is also the loop to use while
# working on the runtime: edit AppleGPU*.cpp, run this, run the test. It was
# inline in make-dist.sh, which needs bazel for everything else -- meaning
# the only way to pick up a C++ change was a full distribution build, and
# the way people actually avoid that is to skip the rebuild and then debug a
# stale dylib. That happened on 2026-09-05: a two-parameter accessor called
# against a three-parameter build, for an hour.
#
# NEVER copy the result into an installed /Applications/Roast. That bundle is
# notarized; dyld rejects a replacement dylib whatever it is signed with, and
# restoring the original bytes does not undo it. Development uses dist/.
#
# -fvisibility=default is not optional: the sources carry no visibility
# attributes, and the default build hides every symbol, so the runtime links
# and then resolves nothing. ARC is off for AppleGPUMetal.cpp, which does its
# own retain/release and calls dispatch_release.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
D="${1:-$ROOT/dist/CocoaMojo}"
M="$ROOT/AsyncRT/lib/MojoBindings"
[ -d "$D/lib" ] || { echo "no distribution at $D -- run ./tools/release.sh first" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
clang++ -std=c++17 -O2 -arch arm64 -fvisibility=default -x objective-c++ \
        -fobjc-arc    -c "$M/AppleGPURT.cpp"    -o "$TMP/AppleGPURT.o"
clang++ -std=c++17 -O2 -arch arm64 -fvisibility=default -x objective-c++ \
        -fno-objc-arc -c "$M/AppleGPUMetal.cpp" -o "$TMP/AppleGPUMetal.o"
clang++ -dynamiclib -arch arm64 -install_name '@rpath/libCocoaMojoGPU.dylib' \
        -o "$D/lib/libCocoaMojoGPU.dylib" "$TMP/AppleGPURT.o" "$TMP/AppleGPUMetal.o" \
        -framework Metal -framework Foundation -framework CoreGraphics \
        -framework IOKit -lobjc
n=$(nm -gU "$D/lib/libCocoaMojoGPU.dylib" | grep -c 'AsyncRT') || true
[ "$n" -gt 100 ] || { echo "GPU runtime exported only $n AsyncRT symbols -- visibility regression" >&2; exit 1; }
echo "   $n AsyncRT symbols exported -> $D/lib/libCocoaMojoGPU.dylib"
