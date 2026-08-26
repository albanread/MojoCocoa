#!/usr/bin/env bash
# Verify a CocoaMojo distribution: build every demo, run the ones that finish,
# and check the GPU runtime still exports its symbols.
#
#   ./tools/check-dist.sh
set -uo pipefail
cd "$(dirname "$0")/.."
CM="dist/CocoaMojo/bin/cocoamojo"
[ -x "$CM" ] || { echo "no distribution -- run ./tools/release.sh first"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
ok()   { printf '  OK   %-16s %s\n' "$1" "${2:-}"; }
bad()  { printf '  FAIL %-16s %s\n' "$1" "${2:-}"; fail=1; }

# The symbol count is checked first because everything GPU depends on it and the
# failure is silent: a hidden-visibility regression links fine and dies at run
# time with "Symbols not found". See RELEASE.md.
n=$(nm -gU dist/CocoaMojo/lib/libCocoaMojoGPU.dylib 2>/dev/null | grep -c AsyncRT) || n=0
[ "$n" -gt 100 ] && ok libCocoaMojoGPU "$n AsyncRT symbols exported" \
                 || bad libCocoaMojoGPU "only $n AsyncRT symbols -- visibility regression"

# Same check for LLVM, and for the same reason: under the toolchain's default
# hidden visibility this lands near 200 instead of tens of thousands, the dylib
# links, and nothing outside it can call in.
l=$(nm -gU dist/CocoaMojo/lib/libLLVM.dylib 2>/dev/null | grep -c '4llvm') || l=0
sz=$(du -h dist/CocoaMojo/lib/libLLVM.dylib 2>/dev/null | cut -f1)
[ "$l" -gt 10000 ] && ok libLLVM "$l llvm:: symbols exported, $sz" \
                   || bad libLLVM "only $l llvm:: symbols -- visibility regression"

# And that the compiler is actually using it rather than carrying its own copy.
otool -L dist/CocoaMojo/bin/cocoamojo-compiler 2>/dev/null | grep -q 'libLLVM.dylib' \
  && ok "compiler link" "dynamic against libLLVM.dylib" \
  || bad "compiler link" "LLVM is statically linked -- dynamic_deps not in effect"

# The language server: hand it an LSP initialize request and read back the
# capabilities. An editor's first move, so if this is broken nothing else works.
if [ -x dist/CocoaMojo/bin/mojo-lsp-server ]; then
  body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}'
  printf 'Content-Length: %d\r\n\r\n%s' "${#body}" "$body" > "$TMP/lsp_init"
  timeout 30 dist/CocoaMojo/bin/mojo-lsp-server < "$TMP/lsp_init" >"$TMP/lsp_out" 2>"$TMP/lsp_err"
  caps=$(grep -oE '"[a-zA-Z]+Provider"' "$TMP/lsp_out" 2>/dev/null | sort -u | wc -l | tr -d ' ')
  if [ "${caps:-0}" -ge 8 ]; then
    ok "mojo-lsp-server" "$caps capabilities advertised"
  elif grep -q 'registered more than once' "$TMP/lsp_err" 2>/dev/null; then
    # See RELEASE.md: two copies of LLVM's CommandLine in one process.
    bad "mojo-lsp-server" "duplicate LLVM CommandLine registry"
  else
    bad "mojo-lsp-server" "initialize returned $caps capabilities"
  fi
else
  bad "mojo-lsp-server" "not in the distribution"
fi

# The out-of-tree consumer: compile and run a real LLVM program against the
# distribution's headers and dylib, nothing else. This is what the IDE will do.
if clang++ -std=c++17 -fno-rtti tools/ide-probe/ide_probe.cpp \
     -I dist/CocoaMojo/include -L dist/CocoaMojo/lib -lLLVM \
     -Wl,-rpath,"$PWD/dist/CocoaMojo/lib" -o "$TMP/ide_probe" \
     >"$TMP/ide_probe.log" 2>&1; then
  targets=$(env -i "$TMP/ide_probe" 2>&1 | grep '^registered targets:' | cut -d: -f2-)
  if [ -z "$targets" ]; then
    bad "llvm consumer" "built but produced no target list"
  elif echo "$targets" | grep -qi 'x86\|riscv'; then
    # Headers and dylib disagree about which LLVM this is.
    bad "llvm consumer" "generated Targets.def is stale:$targets"
  else
    ok "llvm consumer" "compiles and runs against dist;$targets"
  fi
else
  bad "llvm consumer" "$(grep -m1 -E 'error|fatal' "$TMP/ide_probe.log" || echo 'build failed')"
fi

for src in spikes/mandelbrot/mandelbrot.mojo spikes/mandelbrot/window_smoke.mojo \
           spikes/playground/playground.mojo spikes/playground/p0_window.mojo \
           spikes/life/life.mojo; do
  name=$(basename "$src" .mojo)
  [ -f "$src" ] || { bad "$name" "source missing at $src"; continue; }
  if ! "$CM" --build "$src" -o "$TMP/$name" >"$TMP/$name.log" 2>&1; then
    bad "$name" "$(grep -m1 'error' "$TMP/$name.log" || echo 'build failed')"
    continue
  fi

  case "$name" in
    window_smoke)
      # Pumps a fixed number of event cycles and exits, so it can be run here.
      out=$("$TMP/$name" 2>&1 | tail -1)
      [[ "$out" == *PASS* ]] && ok "$name" "$out" || bad "$name" "$out"
      ;;
    mandelbrot)
      # Renders until its window closes; sample the timings and stop it.
      "$TMP/$name" >"$TMP/$name.run" 2>&1 &
      pid=$!; sleep 12; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
      gpu=$(grep -m1 'GPU:.*ms' "$TMP/$name.run" | sed 's/^ *//')
      fps=$(grep -m1 'fps'       "$TMP/$name.run" | sed 's/^ *//')
      [ -n "$gpu" ] && ok "$name" "$gpu ${fps:+| $fps}" \
                    || bad "$name" "no GPU timing -- runtime did not come up"
      ;;
    *)
      # Windowed apps that wait on a run loop: building them is the check.
      ok "$name" "built"
      ;;
  esac
done

echo
[ "$fail" -eq 0 ] && echo "distribution OK" || echo "distribution has failures"
exit $fail
