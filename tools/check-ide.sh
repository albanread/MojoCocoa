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

# The rope, first: it is the thing the latency claim rests on, it is pure Mojo,
# and it needs no window. Its own suite asserts values and prints timings.
if "$CM" --build ide/rope_test.mojo -o "$TMP/rope_test" >"$TMP/rope_build.log" 2>&1; then
  rope_out=$(timeout 300 "$TMP/rope_test" 2>&1)
  if echo "$rope_out" | grep -q '^rope OK'; then
    ok "rope" "$(echo "$rope_out" | grep -c '  OK ') checks"
    echo "$rope_out" | grep -E 'bytes:|build:|line lookup:|edit:|snapshot:' \
      | sed 's/^ */         /'
  else
    bad "rope" "$(echo "$rope_out" | grep -m1 FAIL || echo 'tests failed')"
  fi
else
  bad "rope" "$(grep -m1 'error' "$TMP/rope_build.log" || echo 'build failed')"
fi

# JSON, which the language server conversation rests on.
if "$CM" --build ide/json_test.mojo -o "$TMP/json_test" >"$TMP/json_build.log" 2>&1; then
  json_out=$(timeout 120 "$TMP/json_test" 2>&1)
  if echo "$json_out" | grep -q '^json OK'; then
    ok "json" "$(echo "$json_out" | grep -c '  OK ') checks — escapes, surrogate pairs, round trip"
  else
    bad "json" "$(echo "$json_out" | grep -m1 FAIL || echo 'tests failed')"
  fi
else
  bad "json" "$(grep -m1 'error' "$TMP/json_build.log" || echo 'build failed')"
fi

# Editing behaviour, also without a window: the text input client's risk is
# the arithmetic, not the Objective-C plumbing.
if "$CM" --build ide/edit_test.mojo -o "$TMP/edit_test" >"$TMP/edit_build.log" 2>&1; then
  edit_out=$(timeout 120 "$TMP/edit_test" 2>&1)
  if echo "$edit_out" | grep -q '^edit OK'; then
    ok "editing" "$(echo "$edit_out" | grep -c '  OK ') checks — UTF-8 backspace, column keeping, UTF-16 offsets"
  else
    bad "editing" "$(echo "$edit_out" | grep -m1 FAIL || echo 'tests failed')"
  fi
else
  bad "editing" "$(grep -m1 'error' "$TMP/edit_build.log" || echo 'build failed')"
fi

# The language server, for real: spawn it, initialize, open a file with a
# deliberate error, read the diagnostic back. Needs an import path or every
# parse fails on `std` and the diagnostics are about configuration.
if "$CM" --build ide/lsp_test.mojo -o "$TMP/lsp_test" >"$TMP/lsp_build.log" 2>&1; then
  lsp_out=$(ROAST_LSP="$PWD/dist/CocoaMojo/bin/mojo-lsp-server" \
            ROAST_IMPORTS="$PWD/dist/CocoaMojo/lib/mojo/stdlib" \
            timeout 180 "$TMP/lsp_test" 2>&1)
  if echo "$lsp_out" | grep -q '^lsp OK'; then
    ok "lsp client" "handshake and diagnostics from the real server"
    echo "$lsp_out" | grep -E '^ +line [0-9]+ col' | head -3 | sed 's/^ */         /'
  else
    bad "lsp client" "$(echo "$lsp_out" | grep -m1 FAIL || echo 'tests failed')"
  fi
else
  bad "lsp client" "$(grep -m1 'error' "$TMP/lsp_build.log" || echo 'build failed')"
fi

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

# Implementing the selectors is not conformance, and AppKit asks. The app says
# so on startup when the protocol is missing.
if echo "$out" | grep -q 'NSTextInputClient protocol not registered'; then
  bad "input client" "class does not conform — IME will not work"
else
  ok "input client" "NSTextInputClient conformance registered"
fi

# The editor surface: a document sized from the rope, which only happens if the
# buffer loaded, the font was measured and the view was installed.
doc=$(echo "$out" | grep -m1 'document:' | sed 's/roast: document: //')
if [ -n "$doc" ] && echo "$doc" | grep -qv 'x 0.0'; then
  ok "grid view" "$doc"
else
  bad "grid view" "${doc:-no document reported}"
fi

# The frame is derived from the screen now, not written into the source, so
# assert that it is usable rather than that it is one particular number: wide
# and tall enough for the layout to mean anything, and not off the top.
frame=$(echo "$out" | grep -m1 'frame:' | sed 's/roast: frame: //')
fw=${frame%% *}; fw=${fw%.*}
fh=$(echo "$frame" | awk '{print $3}'); fh=${fh%.*}
if [ -n "$fw" ] && [ "$fw" -ge 640 ] && [ -n "$fh" ] && [ "$fh" -ge 400 ]; then
  ok "frame" "$frame"
else
  bad "frame" "${frame:-none} — below the minimum usable size"
fi

echo
[ "$fail" -eq 0 ] && echo "IDE shell OK" || echo "IDE shell has failures"
exit $fail
