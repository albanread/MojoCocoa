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
cd "$(dirname "$0")/.."
DIST="${DIST_DIR:-$PWD/dist/CocoaMojo}"
RUN="$DIST/bin/cocoamojo"
[ -x "$RUN" ] || { echo "no dist at $DIST -- NO_IDE=1 ./tools/make-dist.sh"; exit 1; }

pass=0; fail=0
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
headless ferns FERNS_FRAMES
headless fernwind FERNWIND_FRAMES
headless fluid FLUID_AUTOSHOT
headless gamepane-starfield GAMEPANE_FRAMES
headless gamepane-plasma GAMEPANE_FRAMES
headless gamepane-platforms GAMEPANE_FRAMES

echo "== gui examples (build + launch) =="
for ex in window othello chip life abcplayer; do build_run "$ex"; done

echo "== pure-Mojo examples =="
for ex in hello animals fern bifurcation; do build_run "$ex"; done

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
echo "  pass $pass   fail $fail"
[ "$fail" -eq 0 ]
