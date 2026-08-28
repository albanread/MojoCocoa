#!/bin/bash
# Validate the arm64 Cocoa port end to end. See COCOA_ARM64.md.
#
# The must_fail spikes are the interesting half: the design's whole claim is
# that a name the database does not know becomes a COMPILE ERROR rather than a
# wrong answer, so a run where they quietly succeed is a FAILED run.
set -uo pipefail
cd "$(dirname "$0")/.."

# The raw binary cannot find std.mojoc on its own; something has to supply the
# stdlib import paths. Prefer the built distribution, which supplies those and
# everything else besides and needs no daemon; fall back to bazel when there is
# no distribution yet.
#
# Override either explicitly:
#   MOJO_RUN="dist/CocoaMojo/bin/cocoamojo --run" ./spikes/run-cocoa-checks.sh
# COCOAMOJO points at the distribution to test. Overridable so compiler work
# can build a private one and leave dist/CocoaMojo -- which a running Roast is
# sitting on -- alone:
#   COCOAMOJO=/tmp/mine/CocoaMojo/bin/cocoamojo ./spikes/run-cocoa-checks.sh
COCOAMOJO="${COCOAMOJO:-dist/CocoaMojo/bin/cocoamojo}"
if [ -z "${MOJO_RUN:-}" ] && [ -x "$COCOAMOJO" ]; then
  MOJO_RUN="$COCOAMOJO --run"
  MOJO="${COCOAMOJO}-compiler"
else
  MOJO_RUN=${MOJO_RUN:-"./bazelw run --ui_event_filters=-info,-stdout --noshow_progress //KGEN:mojo -- run"}
  MOJO=${MOJO:-./bazel-bin/KGEN/tools/mojo/mojo-full}
fi
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
         weakref_test.mojo nserror_test.mojo fn_test.mojo dispatch_test.mojo let_test.mojo \
         registrar_test.mojo class_test.mojo struct_arg_test.mojo \
         struct_ret_test.mojo box_test.mojo class_field_test.mojo \
         objc_decorator_test.mojo dealloc_test.mojo field_init_test.mojo \
         inherit_test.mojo class_method_test.mojo; do run_ok "$f"; done

# The one test with clang on the other end. Everything above has Mojo at both
# ends and so proves only self-consistency; this links a dylib built by the
# compiler that built AppKit, and lets it send the messages.
echo
echo "must agree with clang about the C ABI:"
oracle_dir="$(mktemp -d)"
trap 'rm -rf "$oracle_dir"' EXIT
printf '  %-24s ' "abi_oracle_test.mojo"
if [ ! -x "$COCOAMOJO" ]; then
  echo "SKIP (needs ./tools/release.sh -- the driver owns the link line)"
elif clang -dynamiclib -O1 -lobjc -o "$oracle_dir/liboracle.dylib" \
       "$PWD/spikes/s5-cocoakb/abi_oracle.c" 2>"$oracle_dir/cc.log" &&
   out=$("$COCOAMOJO" --build \
          "$PWD/spikes/s5-cocoakb/abi_oracle_test.mojo" \
          -o "$oracle_dir/abi_oracle" \
          -Xlinker -L"$oracle_dir" -Xlinker -loracle \
          -Xlinker -rpath -Xlinker "$oracle_dir" 2>&1 &&
        "$oracle_dir/abi_oracle" 2>&1); then
  echo "PASS"; pass=$((pass+1))
else
  echo "FAIL"; fail=$((fail+1)); sed 's/^/      /' <<<"$out" | head -12
fi

echo
echo "must be rejected at compile time:"
for f in must_fail.mojo must_fail_argcount.mojo must_fail_fn_raises.mojo must_fail_let_assign.mojo; do run_mustfail "$f"; done

echo
echo "$pass passed, $fail failed"
exit $(( fail > 0 ))
