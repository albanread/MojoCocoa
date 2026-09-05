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
# Our own cache of built components, so a release does not depend on bazel
# having kept its scratch tree. See tools/components.sh.
. "$ROOT/tools/components.sh"
HEAD_COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
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
LSP_B="$B/KGEN/tools/mojo-lsp-server/mojo-lsp-server"
if [ -f "$LSP_B" ]; then
  cp -f "$LSP_B" "$D/bin/"
  components_store lsp "$HEAD_COMMIT" "$LSP_B:bin" \
    || echo "   (could not write the component cache)"
  echo "   mojo-lsp-server"
elif components_have lsp && ! components_stale lsp KGEN; then
  components_restore lsp "$D" \
    && echo "   mojo-lsp-server (cached, built $(components_built lsp))" \
    || echo "   no mojo-lsp-server (cache unreadable)"
elif components_have lsp; then
  echo "   no mojo-lsp-server: the cached one is from $(components_commit lsp)"
  echo "   and KGEN has changed since -- build //KGEN/tools/mojo-lsp-server:mojo-lsp-server"
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
  have_built=1
  for f in "$LLDB_B/lldb-dap" "$LLDB_B/lldb" "$LLDB_B/liblldb24.0.0git.dylib" \
           "$LLDB_B/lldb-argdumper" "$B/KGEN/libMojoLLDB.dylib"; do
    [ -f "$f" ] || have_built=0
  done

  if [ "$have_built" = 1 ]; then
    cp -f "$LLDB_B/lldb-dap" "$LLDB_B/lldb" "$D/bin/"
    cp -f "$LLDB_B/liblldb24.0.0git.dylib" "$D/lib/"
    cp -f "$LLDB_B/lldb-argdumper" "$D/lib/"
    cp -f "$B/KGEN/libMojoLLDB.dylib" "$D/lib/"
    # Keep a copy, so the next release does not depend on bazel having kept
    # one. KGEN and bazel/ are what feed these: the plugin is built against
    # compiler internals, and bazel/ is where the llvm revision is pinned.
    components_store debugger "$HEAD_COMMIT" \
      "$LLDB_B/lldb-dap:bin" "$LLDB_B/lldb:bin" \
      "$LLDB_B/liblldb24.0.0git.dylib:lib" "$LLDB_B/lldb-argdumper:lib" \
      "$B/KGEN/libMojoLLDB.dylib:lib" \
      || echo "   (could not write the component cache)"
  elif components_have debugger && ! components_stale debugger KGEN bazel; then
    # Not built, but nothing that feeds it has changed since it was. A
    # component that is dynamically loaded and byte-identical to the one that
    # would be produced is the same component.
    components_restore debugger "$D" \
      || { echo "   MISSING: the component cache is unreadable"; exit 1; }
    echo "   from the component cache, built $(components_built debugger)"
    echo "   at $(components_commit debugger); KGEN and bazel/ unchanged since"
  else
    echo "   MISSING: $LLDB_B/lldb-dap and friends are not built"
    if components_have debugger; then
      echo "   the cached debugger is from $(components_commit debugger), and"
      echo "   KGEN or bazel/ has changed since -- it would be a stale plugin"
    fi
    echo "   build //KGEN:MojoLLDB @llvm-project//lldb:{lldb,lldb-dap,lldb-argdumper}"
    echo "   (refusing to leave a stale debugger in $D; NO_DEBUGGER=1 to skip)"
    exit 1
  fi
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

# How many symbols of a given namespace a dylib actually exports. Under the
# toolchain's default -fvisibility=hidden this lands in the low hundreds rather
# than the tens of thousands, and the dylib is useless to anything outside --
# a silent failure, so it is measured rather than assumed.
lib_symbols() { nm -gU "$1" 2>/dev/null | grep -c "$2" || true; }

# The order is: a bazel output that PASSES its check, then the cache, then
# fail. Validating before caching is the point -- a stub that exports nothing
# must never be stored as though it were the real library, or the cache
# becomes a way to ship the regression forever.
if [ -n "$LLVMLIB" ] && [ "$(lib_symbols "$LLVMLIB" '4llvm')" -gt 10000 ]; then
  cp -f "$LLVMLIB" "$D/lib/"
  components_store llvm "$HEAD_COMMIT" "$LLVMLIB:lib" \
    || echo "   (could not write the component cache)"
  echo "   $(du -h "$D/lib/libLLVM.dylib" | cut -f1), $(lib_symbols "$D/lib/libLLVM.dylib" '4llvm') llvm:: symbols exported"
elif components_have llvm && ! components_stale llvm bazel; then
  components_restore llvm "$D" || { echo "   component cache unreadable"; exit 1; }
  echo "   from the component cache ($(components_source llvm), $(components_built llvm))"
else
  if [ -n "$LLVMLIB" ]; then
    echo "   libLLVM.dylib in bazel-out exports only $(lib_symbols "$LLVMLIB" '4llvm') llvm:: symbols"
    echo "   (a visibility regression, and nothing in the cache to fall back to)"
  else
    echo "   no libLLVM.dylib"
  fi
  echo "   build --config=build-mojo //bazel/llvm-shared:LLVM"
  exit 1
fi

# MLIR, on top of LLVM. The compiler links both; an in-process consumer that
# wants to build IR rather than shell out needs this one too.
if [ -n "$MLIRLIB" ] && [ "$(lib_symbols "$MLIRLIB" '4mlir')" -gt 10000 ]; then
  cp -f "$MLIRLIB" "$D/lib/"
  components_store mlir "$HEAD_COMMIT" "$MLIRLIB:lib" \
    || echo "   (could not write the component cache)"
  echo "   $(du -h "$D/lib/libMLIR.dylib" | cut -f1), $(lib_symbols "$D/lib/libMLIR.dylib" '4mlir') mlir:: symbols exported"
elif components_have mlir && ! components_stale mlir bazel; then
  components_restore mlir "$D" || { echo "   component cache unreadable"; exit 1; }
  echo "   from the component cache ($(components_source mlir), $(components_built mlir))"
else
  echo "   no usable libMLIR.dylib -- build --config=build-mojo //bazel/mlir-shared:MLIR"
  exit 1
fi

# The Mojo front end. Without this the distribution shipped the parser's headers
# and no parser -- it was statically linked inside the binaries and nothing
# out-of-tree could call it.
echo "== Mojo front end =="
FE="$B/KGEN/libMojoCompiler.dylib"
if [ -f "$FE" ] && [ "$(lib_symbols "$FE" 'MojoParserContext')" -gt 10 ]; then
  cp -f "$FE" "$D/lib/"
  components_store mojocompiler "$HEAD_COMMIT" "$FE:lib" \
    || echo "   (could not write the component cache)"
  echo "   $(du -h "$D/lib/libMojoCompiler.dylib" | cut -f1), parser API exported"
elif components_have mojocompiler && ! components_stale mojocompiler KGEN bazel; then
  components_restore mojocompiler "$D" || { echo "   component cache unreadable"; exit 1; }
  echo "   from the component cache ($(components_source mojocompiler), $(components_built mojocompiler))"
else
  echo "   no usable libMojoCompiler.dylib -- build //KGEN:MojoCompilerShared"
  exit 1
fi

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
# Two lines of clang++, so they live in their own script and this calls it:
# working on the runtime otherwise means a full distribution build to pick up
# a C++ change, and what people do instead is not rebuild and then debug a
# stale dylib for an hour. ./tools/make-gpu-runtime.sh is that loop.
"$ROOT/tools/make-gpu-runtime.sh" "$D"

# The stdlib, the examples and the IDE's own source are copies, not builds,
# and the copies must also happen on the bazel-free path (make-app.sh), so
# they live in one script both paths call.
"$ROOT/tools/sync-dist-sources.sh" "$D"

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
     -o "$D/bin/roast" \
     -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
     -Xlinker "$ROOT/tools/roast-info.plist" \
     -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __sdef \
     -Xlinker "$ROOT/ide/Roast.sdef" \
     >"$D/bin/.roast.log" 2>&1; then
  rm -f "$D/bin/.roast.log"
  echo "   roast ($(stat -f%z "$D/bin/roast" | awk '{printf "%.0f KB", $1/1024}'))"
else
  echo "   FAILED -- roast did not build:"
  grep -m3 'error' "$D/bin/.roast.log" | sed 's/^/     /'
  echo "   full log: $D/bin/.roast.log  (NO_IDE=1 to build a dist without the IDE)"
  rm -f "$D/bin/roast"
  exit 1
fi

echo "== python =="
# CPython belongs to the TOOLCHAIN, not to the editor. Roast has always
# looked for it at <toolchain>/Python (python_env.runtime_home), and while
# the app carried a whole toolchain the two happened to coincide. A thin
# app has no Resources to hide it in, and the database generator needs an
# interpreter before any editor runs, so it lives here where both can
# reach it.
if [ -x "$D/Python/Python.framework/Versions/Current/bin/python3" ] \
   && [ "${PYTHON_REBUILD:-0}" != 1 ]; then
  echo "   already present ($(du -sh "$D/Python" | cut -f1)) -- PYTHON_REBUILD=1 to redo"
else
  "$ROOT/tools/bundle-python.sh" "$D/Python"
fi

# An interpreter nothing can reach is freight, not a feature. Roast finds it
# by framework path, and so does the database generator, but a person opening
# Terminal had no way to run the Python they had just installed -- and the
# only place the installer ever mentioned Python was the dialog offering to
# delete it. bin/python3 is the entry point, beside cocoamojo and lldb,
# where the rest of the toolchain keeps its commands.
#
# PYTHONHOME is the relocation contract: a copied framework still carries its
# build prefix, and without this the interpreter looks for its standard
# library where it was built rather than where it is.
cat > "$D/bin/python3" <<'PYWRAP'
#!/usr/bin/env bash
# The CocoaMojo Python -- the same interpreter Roast uses for its per-project
# environments, and the one that builds share/cocoa.sqlite at install time.
#
#   python3                     a REPL
#   python3 -m venv myenv       an environment that stays yours
#   python3 script.py
#
# This does NOT go on your PATH and does not shadow any Python you already
# have; it is reachable by this path, deliberately and only.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOME_DIR="$HERE/Python/Python.framework/Versions/Current"
[ -x "$HOME_DIR/bin/python3" ] || {
  echo "python3: no interpreter at $HOME_DIR" >&2; exit 1; }
exec env PYTHONHOME="$HOME_DIR" "$HOME_DIR/bin/python3" "$@"
PYWRAP
chmod +x "$D/bin/python3"
echo "   bin/python3: reachable beside cocoamojo"

echo "== cocoa database generator =="
# The 343 MB database is no longer shipped: the installer builds it on the
# machine it installs to, in about fifteen seconds, from that machine's own
# SDK. So what ships is the generator -- 112 KB of stdlib-only Python --
# and the database it produces describes the frameworks the person actually
# has, rather than a snapshot of whichever Mac cut the release.
KBSRC="${COCOAKB_SRC:-$ROOT/../CocoaBaseMCP}"
if [ -f "$KBSRC/build.py" ]; then
  mkdir -p "$D/share/cocoakb"
  # schema.sql is not optional: build.py reads it to create the tables.
  # --delete would take the generated cocoa.sqlite with it on a rebuild,
  # so protect it -- regenerating 350 MB to stage 112 KB is a poor trade.
  rsync -a --delete --filter 'P cocoa.sqlite' \
        --include '*.py' --include '*.sql' --include '*/' --exclude '*' \
        "$KBSRC/" "$D/share/cocoakb/"
  echo "   $(ls "$D/share/cocoakb"/*.py | wc -l | tr -d ' ') modules + schema"
else
  echo "   WARNING: no generator at $KBSRC -- the database cannot be built"
fi

echo "== cocoa database =="
if [ -f "$KB" ]; then cp -f "$KB" "$D/share/cocoa.sqlite"
else echo "   WARNING: no cocoa.sqlite at $KB -- set COCOAKB=..."; fi

echo
echo "$D ready ($(du -sh "$D" | cut -f1))"
echo "  dist/CocoaMojo/bin/cocoamojo --run examples/mandelbrot/main.mojo"
