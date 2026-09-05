#!/usr/bin/env bash
# Every gamepane test, headless, against the DEVELOPMENT toolchain.
#
#   ./tools/check-gamepane.sh
#
# Headless is the whole point: GAMEPANE_FRAMES turns a pane into an unfocused
# Accessory that renders N frames and exits, and GAMEPANE_DUMP makes it write
# the last one out as raw BGRA. So this opens real windows on real drawables
# and still runs to completion over ssh, in a build, or while you are typing
# somewhere else -- nothing steals focus and nothing waits for a human.
#
# Everything in gamepane/tests/ that is named test_* or spike_* runs, in
# order. A file that needs no window ignores the environment.
set -uo pipefail
cd "$(dirname "$0")/.."
DUMP="${TMPDIR:-/tmp}/gamepane-check"
mkdir -p "$DUMP"

pass=0
fail=0
failed=()
for t in $(ls gamepane/tests/spike_*.mojo gamepane/tests/test_*.mojo 2>/dev/null); do
  name="$(basename "$t" .mojo)"
  printf '== %-24s ' "$name"
  out="$(GAMEPANE_FRAMES=30 GAMEPANE_DUMP="$DUMP/$name.bgra" \
         ./tools/gp.sh "$t" 2>&1)"
  if [ $? -eq 0 ]; then
    echo "PASS"
    pass=$((pass + 1))
  else
    echo "FAIL"
    echo "$out" | sed 's/^/   | /'
    fail=$((fail + 1))
    failed+=("$name")
  fi
done

echo
if [ "$fail" -eq 0 ]; then
  echo "gamepane: $pass/$pass green"
else
  echo "gamepane: $pass passed, $fail FAILED -- ${failed[*]}"
  exit 1
fi
