#!/usr/bin/env bash
# Build and run every example, and hold the msg_send count at zero.
#
# The ratchet is the point: sprint P6 moved the whole examples tree onto the
# typed surface, and this is what keeps it there. A new example written at
# the msg_send level fails this check until it is migrated; a regression in
# an existing one fails it immediately.
#
#   ./tools/check-examples.sh          everything
#
# GUI apps that run forever are verified by building them and launching under
# a timeout: exit 124 (killed while running) with no crash output is a pass.
# The frame-limited apps run their N frames headless and must exit cleanly.
set -uo pipefail
# Every compile in this run gets a FRESH Mojo compile cache. The cache under
# ~/.cache/modular/.mojo_cache is keyed by source and version string, not by
# the compiler binary or the environment, so after a compiler rebuild it can
# hand back kernels the previous compiler produced -- and a suite that runs
# cached kernels verifies nothing about the compiler it is meant to check
# (defects.md D22).
export MODULAR_CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mojo-cache.XXXXXX")"
trap 'rm -rf "$MODULAR_CACHE_DIR"' EXIT
cd "$(dirname "$0")/.."
DIST="${DIST_DIR:-$PWD/dist/CocoaMojo}"
RUN="$DIST/bin/cocoamojo"
[ -x "$RUN" ] || { echo "no dist at $DIST -- NO_IDE=1 ./tools/make-dist.sh"; exit 1; }

pass=0; fail=0; skip=0
build_run() {  # build, then run under a timeout
  local ex="$1" log="/tmp/ex-$1"
  if ! "$RUN" --build "examples/$ex/main.mojo" -o "/tmp/exb-$ex" 2>"$log.err"; then
    echo "  FAIL $ex (build)"; sed 's/^/      /' "$log.err" | grep -m3 error; fail=$((fail+1)); return
  fi
  timeout 5 "/tmp/exb-$ex" >"$log.out" 2>&1
  local ec=$?
  if [ $ec -eq 124 ] && ! grep -qE "Terminating app|uncaught exception" "$log.out"; then
    echo "  OK   $ex (built, ran, stayed up)"; pass=$((pass+1))
  elif [ $ec -eq 0 ] && ! grep -qE "Terminating app|uncaught exception" "$log.out"; then
    echo "  OK   $ex (built, ran, exited cleanly)"; pass=$((pass+1))
  else
    echo "  FAIL $ex (exit $ec)"; grep -m2 -E "error|Terminating" "$log.out" | sed 's/^/      /'; fail=$((fail+1))
  fi
}
headless() {  # frame-limited: env var, clean exit required
  local ex="$1" var="$2"
  if ! "$RUN" --build "examples/$ex/main.mojo" -o "/tmp/exb-$ex" 2>"/tmp/ex-$1.err"; then
    echo "  FAIL $ex (build)"; fail=$((fail+1)); return
  fi
  if env "$var=3" timeout 60 "/tmp/exb-$ex" >"/tmp/ex-$1.out" 2>&1; then
    echo "  OK   $ex (3 frames headless)"; pass=$((pass+1))
  else
    echo "  FAIL $ex"; tail -3 "/tmp/ex-$1.out" | sed 's/^/      /'; fail=$((fail+1))
  fi
}

echo "== headless examples =="
headless mandelbrot MANDEL_FRAMES
headless grayscott GRAYSCOTT_FRAMES
headless physarum PHYSARUM_FRAMES
headless ferns FERNS_FRAMES
headless fernwind FERNWIND_FRAMES
headless fluid FLUID_AUTOSHOT
headless gamepane-starfield GAMEPANE_FRAMES
headless gamepane-plasma GAMEPANE_FRAMES
headless gamepane-platforms GAMEPANE_FRAMES
headless galaxigans GAMEPANE_FRAMES
headless galaxigans-deluxe GAMEPANE_FRAMES

echo "== gui examples (build + launch) =="
for ex in window othello chip life abcplayer; do build_run "$ex"; done

echo "== pure-Mojo examples =="
for ex in hello animals fern bifurcation; do build_run "$ex"; done

# Modular's own examples, carried over unmodified. README calls these out as
# the strongest claim in the paragraph -- "including their GPU kernels, which
# run on the Apple GPU as written" -- and until now nothing checked them.
#
# Exit 0 alone is too weak here: tiled-matmul prints "No GPU detected" and
# exits 0 when has_accelerator() is false, which is precisely the failure the
# claim is about. So each one must also PRINT the thing that proves it ran,
# and must not print the fallback.
build_run_expect() {  # ex, required-substring, [forbidden-substring]
  local ex="$1" want="$2" deny="${3:-}" log="/tmp/ex-$1"
  if ! "$RUN" --build "examples/$ex/main.mojo" -o "/tmp/exb-$ex" 2>"$log.err"; then
    echo "  FAIL $ex (build)"; sed 's/^/      /' "$log.err" | grep -m3 error; fail=$((fail+1)); return
  fi
  timeout 60 "/tmp/exb-$ex" >"$log.out" 2>&1
  local ec=$?
  if [ $ec -ne 0 ]; then
    echo "  FAIL $ex (exit $ec)"; grep -m2 -E "error|Terminating" "$log.out" | sed 's/^/      /'; fail=$((fail+1)); return
  fi
  if [ -n "$deny" ] && grep -qF "$deny" "$log.out"; then
    echo "  FAIL $ex (took the fallback path: \"$deny\")"; fail=$((fail+1)); return
  fi
  if ! grep -qF "$want" "$log.out"; then
    echo "  FAIL $ex (ran, but never printed \"$want\")"; fail=$((fail+1)); return
  fi
  echo "  OK   $ex (built, ran, printed its result)"; pass=$((pass+1))
}

echo "== Modular's own examples (carried over unmodified) =="
build_run_expect vector-add   "Resulting vector:"
build_run_expect grayscale    "Resulting grayscale image:"
build_run_expect tiled-matmul "Tiled Matrix Multiplication GPU Example" "No GPU detected"
build_run_expect process      "== Test:"
build_run_expect operators    "c1 ="

echo "== python-interop example =="
# life-python needs pygame-ce at runtime. A missing dep is reported as a SKIP
# and counted, never folded into the pass total -- an invisible skip is how a
# suite starts lying about its own coverage.
if python3 -c "import pygame" >/dev/null 2>&1; then
  build_run life-python
else
  echo "  SKIP life-python (pygame-ce not installed: pip install -r examples/life-python/requirements.txt)"
  skip=$((skip+1))
fi

echo "== the ratchet =="
# gamepane is held to the same line as examples/. Protocol-typed Metal calls
# go through `send`, which IS the sanctioned spelling -- what is banned is the
# raw msg_send escape hatch, which nothing in this tree needs any more.
n=$(grep -rc "msg_send\[" examples/ gamepane/ --include="*.mojo" | awk -F: '{s+=$2} END {print s+0}')
if [ "$n" -eq 0 ]; then
  echo "  OK   msg_send count under examples/ and gamepane/: 0 (sprint P6 line, held)"
  pass=$((pass+1))
else
  echo "  FAIL msg_send count under examples/ and gamepane/: $n (was 0 at sprint P6)"
  grep -rl "msg_send\[" examples/ gamepane/ --include="*.mojo" | sed 's/^/      /'
  fail=$((fail+1))
fi

echo
echo "  pass $pass   fail $fail   skip $skip"
[ "$fail" -eq 0 ]
