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
#   dist/CocoaMojo/bin/cocoamojo --run examples/mandelbrot/main.mojo
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
B="$(readlink bazel-bin || echo bazel-bin)"
# Where the distribution goes. Overridable, and that is not a convenience:
# rewriting dist/CocoaMojo pulls the binaries and the stdlib out from under a
# running Roast, which is a genuinely unpleasant thing to do to someone who is
# using the IDE at the time. Compiler work that only needs something to test
# against should point this somewhere private:
#   DIST_DIR=/tmp/mine ./tools/make-dist.sh
D="${DIST_DIR:-$ROOT/dist/CocoaMojo}"
KB="${COCOAKB:-$ROOT/../CocoaBaseMCP/cocoa.sqlite}"

[ -x "$B/KGEN/tools/mojo/mojo" ] || { echo "build the compiler first:"; \
  echo "  ./bazelw build --config=build-mojo //KGEN:mojo"; exit 1; }

mkdir -p "$D"/{bin,lib,share}

echo "== compiler =="
cp -f "$B/KGEN/tools/mojo/mojo" "$D/bin/cocoamojo-compiler"
cp -f "$ROOT/tools/cocoamojo" "$D/bin/cocoamojo"; chmod +x "$D/bin/cocoamojo"

# The language server, for editors. It speaks LSP on stdin/stdout and shares
# libLLVM.dylib with the compiler rather than carrying a second copy.
if [ -f "$B/KGEN/tools/mojo-lsp-server/mojo-lsp-server" ]; then
  cp -f "$B/KGEN/tools/mojo-lsp-server/mojo-lsp-server" "$D/bin/"
  echo "   mojo-lsp-server"
else
  echo "   no mojo-lsp-server (build //KGEN/tools/mojo-lsp-server:mojo-lsp-server)"
fi

# The debugger: our lldb-dap with the MojoLLDB plugin beside it, which is
# what turns "breakpoints bind and the editor follows" into "frame variable
# answers" (spikes/MOJOLLDB-SPIKE.md records the whole story). The layout is
# load-bearing and free: liblldb's install name is @rpath/... and the
# binaries already carry @loader_path/../lib as their first rpath, so
# bin/ + lib/ resolves everything with no install_name_tool and no
# re-signing. lldb-argdumper goes in lib/ because LLDB's support-executable
# directory is the directory liblldb lives in -- the CLI's `run` shells out
# to it; DAP launches do not.
echo "== debugger =="
LLDB_B="$B/external/+llvm_configure+llvm-project/lldb"
# Warning and carrying on is not an option here: DIST_DIR is usually reused,
# so a missing build would leave the PREVIOUS libMojoLLDB.dylib in place and
# every subsequent test would silently exercise a stale plugin. That produces
# confident, wrong answers -- the exact failure this script must not enable.
# Set NO_DEBUGGER=1 to deliberately build a toolchain without one.
if [ "${NO_DEBUGGER:-0}" = 1 ]; then
  echo "   skipped (NO_DEBUGGER=1)"
  rm -f "$D/bin/lldb" "$D/bin/lldb-dap" "$D/lib/libMojoLLDB.dylib" \
        "$D/lib/liblldb24.0.0git.dylib" "$D/lib/lldb-argdumper"
else
  for f in "$LLDB_B/lldb-dap" "$LLDB_B/lldb" "$LLDB_B/liblldb24.0.0git.dylib" \
           "$LLDB_B/lldb-argdumper" "$B/KGEN/libMojoLLDB.dylib"; do
    [ -f "$f" ] || { echo "   MISSING: $f"; \
      echo "   build //KGEN:MojoLLDB @llvm-project//lldb:{lldb,lldb-dap,lldb-argdumper}"; \
      echo "   (refusing to leave a stale debugger in $D; NO_DEBUGGER=1 to skip)"; \
      exit 1; }
  done
  cp -f "$LLDB_B/lldb-dap" "$LLDB_B/lldb" "$D/bin/"
  cp -f "$LLDB_B/liblldb24.0.0git.dylib" "$D/lib/"
  cp -f "$LLDB_B/lldb-argdumper" "$D/lib/"
  cp -f "$B/KGEN/libMojoLLDB.dylib" "$D/lib/"
  # Prove what landed, so a stale-artifact claim can be checked, not asserted.
  for f in "$D/bin/lldb-dap" "$D/bin/lldb" "$D/lib/libMojoLLDB.dylib"; do
    printf "   %s  %s\n" "$(shasum -a 256 "$f" | cut -c1-12)" "$(basename "$f")"
  done
fi

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
MLIRLIB="$(find "$B" -name 'libMLIR.dylib' -type f 2>/dev/null | head -1)"
# The external repo holding LLVM's sources. It sits beside execroot/ in the
# output base, not inside it, and the +llvm_configure+ prefix is bzlmod's and can
# change -- so cut the path at /execroot/ and glob for the repo.
LLVMSRC="$(echo "${B%%/execroot/*}"/external/*llvm_configure*llvm-project)"
[ -n "$LLVMLIB" ] || { echo "   no libLLVM.dylib -- build //bazel/llvm-shared:LLVM"; exit 1; }
cp -f "$LLVMLIB" "$D/lib/"
nexp=$(nm -gU "$D/lib/libLLVM.dylib" | grep -c '4llvm') || true
# Under the toolchain's default -fvisibility=hidden this lands near 200 rather
# than tens of thousands, and the dylib is useless to anything outside. That is
# a silent failure, so it is checked rather than assumed.
[ "$nexp" -gt 10000 ] || { echo "   libLLVM.dylib exports only $nexp llvm:: symbols -- visibility regression"; exit 1; }
echo "   $(du -h "$D/lib/libLLVM.dylib" | cut -f1), $nexp llvm:: symbols exported"

# MLIR, on top of LLVM. The compiler links both; an in-process consumer that
# wants to build IR rather than shell out needs this one too.
[ -n "$MLIRLIB" ] || { echo "   no libMLIR.dylib -- build //bazel/mlir-shared:MLIR"; exit 1; }
cp -f "$MLIRLIB" "$D/lib/"
mexp=$(nm -gU "$D/lib/libMLIR.dylib" | grep -c '4mlir') || true
[ "$mexp" -gt 10000 ] || { echo "   libMLIR.dylib exports only $mexp mlir:: symbols -- visibility regression"; exit 1; }
echo "   $(du -h "$D/lib/libMLIR.dylib" | cut -f1), $mexp mlir:: symbols exported"

# The Mojo front end. Without this the distribution shipped the parser's headers
# and no parser -- it was statically linked inside the binaries and nothing
# out-of-tree could call it.
echo "== Mojo front end =="
FE="$B/KGEN/libMojoCompiler.dylib"
[ -f "$FE" ] || { echo "   no libMojoCompiler.dylib -- build //KGEN:MojoCompilerShared"; exit 1; }
cp -f "$FE" "$D/lib/"
fexp=$(nm -gU "$D/lib/libMojoCompiler.dylib" | grep -c 'MojoParserContext') || true
[ "$fexp" -gt 10 ] || { echo "   exports only $fexp MojoParserContext symbols -- visibility regression"; exit 1; }
echo "   $(du -h "$D/lib/libMojoCompiler.dylib" | cut -f1), parser API exported"

# LLVM headers, so the dylib is something another project can actually compile
# against. Two trees have to be merged, and the order matters:
#
#   1. the checked-out headers, which reach the build as a symlink farm into the
#      llvm-raw repo -- hence 'cp -RL' rather than rsync, to follow them
#   2. the generated ones on top: llvm-config.h, abi-breaking.h and the Config
#      .def files that record which targets this LLVM was built with. The source
#      tree carries .in templates for these; the generated versions must win, or
#      a consumer gets a Targets.def listing backends that are not in the dylib.
echo "== LLVM headers =="
rm -rf "$D/include"
mkdir -p "$D/include"
cp -RL "$LLVMSRC/llvm/include/llvm" "$LLVMSRC/llvm/include/llvm-c" "$D/include/" 2>/dev/null
GEN="$B/external/+llvm_configure+llvm-project/llvm/include"
[ -d "$GEN" ] && cp -RL "$GEN/llvm" "$D/include/" 2>/dev/null
nhdr=$(find "$D/include" -type f | wc -l | tr -d ' ')

# MLIR headers, same two-tree merge. The generated half is much larger here --
# MLIR's dialects are tablegen'd, so .inc files carry the actual declarations
# and a consumer cannot compile without them.
cp -RL "$LLVMSRC/mlir/include/mlir" "$LLVMSRC/mlir/include/mlir-c" "$D/include/" 2>/dev/null
MGEN="$B/external/+llvm_configure+llvm-project/mlir/include"
[ -d "$MGEN" ] && cp -RL "$MGEN/mlir" "$D/include/" 2>/dev/null

# The compiler's own headers: the phases an embedder calls into. Support, Init
# and Config come too -- KGEN's public headers include them, so an embedder
# needs them whether or not it names them.
cp -RL "$ROOT/KGEN/include/KGEN" "$D/include/" 2>/dev/null
for tree in Support Init Config Cache AsyncRT; do
  [ -d "$ROOT/$tree/include" ] && cp -RL "$ROOT/$tree/include/." "$D/include/" 2>/dev/null
done
# ...and their generated halves. KGEN and Support are tablegen'd the same way
# MLIR is: the .h.inc files carry real declarations, and MTypes.h includes
# MTypes.h.inc unconditionally, so nothing compiles without them.
for tree in KGEN Support Init Config Cache AsyncRT; do
  [ -d "$B/$tree/include" ] && cp -RL "$B/$tree/include/." "$D/include/" 2>/dev/null
done

nhdr=$(find "$D/include" -type f | wc -l | tr -d ' ')
echo "   $nhdr headers ($(du -sh "$D/include" | cut -f1))"
# The generated Config headers are the ones a consumer cannot do without.
for f in llvm/Config/llvm-config.h llvm/Config/abi-breaking.h llvm/Config/Targets.def; do
  [ -f "$D/include/$f" ] || { echo "   missing $f -- consumers will not compile"; exit 1; }
done

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

echo "== examples =="
# Shipped with the toolchain because they are the answer to "what does a
# project look like" -- each folder is one, with its main.mojo, and Roast
# opens them as they are. Copied without build/ or anything a previous run
# left behind, so a fresh distribution is sources only.
# --delete-excluded as well as --delete: without it rsync protects excluded
# files that are already in the destination, so a build/ from an earlier run
# would survive every rebuild of the distribution.
rsync -a --delete --delete-excluded \
      --exclude 'build/' --exclude '*.png' --exclude '.DS_Store' \
      "$ROOT/examples/" "$D/share/examples/"
echo "   $(find "$D/share/examples" -name '*.mojo' | wc -l | tr -d ' ') files in $(ls "$D/share/examples" | grep -vc README) projects"

echo "== the IDE =="
# Roast, built with the compiler this distribution just assembled -- the same
# toolchain someone opening it will compile with. It ships because
# share/examples ships: the Examples menu resolves them through
# COCOAMOJO_ROOT, which only points somewhere real for a Roast that lives
# here. Built rather than copied, because a hand-placed binary is stale the
# moment the IDE changes, which is exactly what it was.
# A failure here fails the distribution, the same bargain as the debugger
# above: a dist that says "ready" without its IDE is a lie that scrolls past
# in a release log. NO_IDE=1 skips it for compiler-only work.
if [ "${NO_IDE:-0}" = 1 ]; then
  echo "   skipped (NO_IDE=1)"
  rm -f "$D/bin/roast"
elif COCOAMOJO_ROOT="$D" "$D/bin/cocoamojo" --build "$ROOT/ide/roast.mojo" \
     -o "$D/bin/roast" >"$D/bin/.roast.log" 2>&1; then
  rm -f "$D/bin/.roast.log"
  echo "   roast ($(stat -f%z "$D/bin/roast" | awk '{printf "%.0f KB", $1/1024}'))"
else
  echo "   FAILED -- roast did not build:"
  grep -m3 'error' "$D/bin/.roast.log" | sed 's/^/     /'
  echo "   full log: $D/bin/.roast.log  (NO_IDE=1 to build a dist without the IDE)"
  rm -f "$D/bin/roast"
  exit 1
fi

echo "== cocoa database =="
if [ -f "$KB" ]; then cp -f "$KB" "$D/share/cocoa.sqlite"
else echo "   WARNING: no cocoa.sqlite at $KB -- set COCOAKB=..."; fi

echo
echo "$D ready ($(du -sh "$D" | cut -f1))"
echo "  dist/CocoaMojo/bin/cocoamojo --run examples/mandelbrot/main.mojo"
