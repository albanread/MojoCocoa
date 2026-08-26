#!/bin/bash
# Validate the arm64 Cocoa port end to end. See COCOA_ARM64.md.
#
# The must_fail spikes are the interesting half: the design's whole claim is
# that a name the database does not know becomes a COMPILE ERROR rather than a
# wrong answer, so a run where they quietly succeed is a FAILED run.
set -uo pipefail
cd "$(dirname "$0")/.."

# The raw binary cannot find std.mojoc on its own; //KGEN:mojo is the wrapper
# that supplies the stdlib import paths (see bazel/docs/usage.md).
MOJO_RUN=${MOJO_RUN:-"./bazelw run --ui_event_filters=-info,-stdout --noshow_progress //KGEN:mojo -- run"}
MOJO=./bazel-bin/KGEN/tools/mojo/mojo-full
# Default assumes CocoaBaseMCP is checked out beside this repo. Override with
# MODULAR_MOJO_MAX_COCOAKB_PATH if it lives elsewhere.
export MODULAR_MOJO_MAX_COCOAKB_PATH=${MODULAR_MOJO_MAX_COCOAKB_PATH:-\
"$PWD/../CocoaBaseMCP/cocoa.sqlite"}

[ -x "$MOJO" ] || { echo "no compiler at $MOJO -- build it with:"; \
  echo "  ./bazelw build --config=build-mojo //KGEN:mojo"; exit 1; }
[ -f "$MODULAR_MOJO_MAX_COCOAKB_PATH" ] || { \
  echo "no cocoa.sqlite at $MODULAR_MOJO_MAX_COCOAKB_PATH"; \
  echo "  build it with: python3 ../CocoaBaseMCP/build.py"; exit 1; }

echo "compiler: $MOJO"
echo "database: $MODULAR_MOJO_MAX_COCOAKB_PATH"
echo

pass=0; fail=0
run_ok() {   # must compile AND run
  printf '  %-24s ' "$1"
  if out=$($MOJO_RUN "$PWD/spikes/s5-cocoakb/$1" 2>&1); then
    echo "PASS"; pass=$((pass+1))
  else
    echo "FAIL"; fail=$((fail+1)); sed 's/^/      /' <<<"$out" | head -12
  fi
}
run_mustfail() {   # must FAIL TO COMPILE, and say why
  printf '  %-24s ' "$1"
  if out=$($MOJO_RUN "$PWD/spikes/s5-cocoakb/$1" 2>&1); then
    echo "FAIL (compiled, but must not)"; fail=$((fail+1))
  else
    echo "PASS (rejected at comptime)"; pass=$((pass+1))
    sed 's/^/      /' <<<"$out" | grep -iE "cocoa|metadata|unknown|no " | head -2
  fi
}

echo "must compile and run:"
for f in check.mojo objc_smoke.mojo foundation_demo.mojo typecheck_test.mojo \
         ownership_test.mojo stret_test.mojo callback_probe.mojo \
         weakref_test.mojo nserror_test.mojo; do run_ok "$f"; done

echo
echo "must be rejected at compile time:"
for f in must_fail.mojo must_fail_argcount.mojo; do run_mustfail "$f"; done

echo
echo "$pass passed, $fail failed"
exit $(( fail > 0 ))
