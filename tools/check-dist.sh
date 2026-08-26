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
