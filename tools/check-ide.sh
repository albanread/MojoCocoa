#!/usr/bin/env bash
# Verify the Roast shell: build it, run the whole lifecycle unattended, and
# check that AppKit reports the pieces it should have.
#
#   ./tools/check-ide.sh
#
# The app reports its own state rather than being screenshotted, for the same
# reason window_smoke does: a screenshot needs an unlocked screen and a human,
# and this has to run in CI. ROAST_AUTOCLOSE_TICKS drives launch -> ticks ->
# close -> terminate with nobody at the keyboard.
set -uo pipefail
cd "$(dirname "$0")/.."
CM="dist/CocoaMojo/bin/cocoamojo"
[ -x "$CM" ] || { echo "no distribution -- run ./tools/release.sh first"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
ok()  { printf '  OK   %-18s %s\n' "$1" "${2:-}"; }
bad() { printf '  FAIL %-18s %s\n' "$1" "${2:-}"; fail=1; }

if ! "$CM" --build ide/roast.mojo -o "$TMP/roast" >"$TMP/build.log" 2>&1; then
  bad "build" "$(grep -m1 'error' "$TMP/build.log" || echo 'build failed')"
  echo; echo "IDE shell has failures"; exit 1
fi
ok "build" "$(stat -f%z "$TMP/roast" | awk '{printf "%.0f KB", $1/1024}')"

out=$(ROAST_AUTOCLOSE_TICKS=12 timeout 90 "$TMP/roast" 2>&1)

check() {  # <label> <pattern> <description>
  if echo "$out" | grep -q "$2"; then ok "$1" "$3"; else
    bad "$1" "expected $2 — got: $(echo "$out" | grep -m1 "$1" || echo 'nothing')"
  fi
}

check "window"      "window visible: True"  "on screen"
check "toolbar"     "toolbar: True"         "attached"
check "split view"  "split panes: 2"        "sidebar + editor area"
check "menu bar"    "menu bar items: 5"     "app, File, Edit, Build, Window"
check "lifecycle"   "applicationWillTerminate" "launch → close → terminate clean"

# The frame should be the size asked for, plus the toolbar's contribution.
if echo "$out" | grep -q 'frame: 1100.0'; then
  ok "frame" "$(echo "$out" | grep -m1 'frame:' | sed 's/roast: //')"
else
  bad "frame" "$(echo "$out" | grep -m1 'frame:' || echo 'no frame reported')"
fi

echo
[ "$fail" -eq 0 ] && echo "IDE shell OK" || echo "IDE shell has failures"
exit $fail
