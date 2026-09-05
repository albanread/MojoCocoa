#!/usr/bin/env bash
# Every gamepane test, then the demo, headless, against dist/CocoaMojo.
#
#   ./tools/check-gamepane.sh
#
# Headless is the whole point: GAMEPANE_FRAMES turns a pane into an unfocused
# Accessory that renders N frames and exits, and GAMEPANE_DUMP makes it write
# the last one out as raw BGRA. So this opens real windows on real drawables
# and still runs to completion over ssh, in a build, or while you are typing
# somewhere else -- nothing steals focus and nothing waits for a human.
#
# BUILT, not JIT-run. Two reasons, both learned the hard way. The JIT cannot
# resolve AudioToolbox, so anything that opens an audio unit fails there and
# passes as a binary. And a crash under `cocoamojo run` loses buffered stdout,
# so the last few lines before a fault vanish and the crash appears to be
# several statements earlier than it is.
set -uo pipefail
cd "$(dirname "$0")/.."
D="$PWD/dist/CocoaMojo"
[ -x "$D/bin/cocoamojo" ] || { echo "no dist toolchain -- run ./tools/release.sh" >&2; exit 1; }
DUMP="${TMPDIR:-/tmp}/gamepane-check"
mkdir -p "$DUMP"

# The package on the import path, the way the distribution ships it.
rsync -a --delete --exclude='tests/' --delete-excluded \
      --include='*/' --include='*.mojo' --exclude='*' \
      "$PWD/gamepane/" "$D/lib/mojo/gamepane/gamepane/"

pass=0
fail=0
failed=()

run () {  # name, source, extra env
  local name="$1" src="$2"
  printf '== %-24s ' "$name"
  if ! COCOAMOJO_ROOT="$D" "$D/bin/cocoamojo" build "$src" \
        -o "$DUMP/$name" 2>"$DUMP/$name.err"; then
    echo "FAIL (build)"
    grep -m3 'error:' "$DUMP/$name.err" | sed 's/^/   | /'
    fail=$((fail + 1)); failed+=("$name"); return
  fi
  if out="$(GAMEPANE_FRAMES=30 GAMEPANE_DUMP="$DUMP/$name.bgra" \
            "$DUMP/$name" 2>&1)"; then
    echo "PASS"
    pass=$((pass + 1))
  else
    echo "FAIL"
    echo "$out" | tail -12 | sed 's/^/   | /'
    fail=$((fail + 1)); failed+=("$name")
  fi
}

for t in $(ls gamepane/tests/spike_*.mojo gamepane/tests/test_*.mojo 2>/dev/null); do
  run "$(basename "$t" .mojo)" "$t"
done

# The GAME's frame, because that is what ships. A dump of pure black would
# mean every layer drew nothing and every test above still passed -- which
# is exactly the failure a suite of unit tests cannot see.
# The demos stay as coverage for the shader pane and the direct pane, which
# nothing that ships exercises.
run "demo:starfield" examples/gamepane-starfield/main.mojo
run "demo:plasma" examples/gamepane-plasma/main.mojo
run "demo:platforms" examples/gamepane-platforms/main.mojo
# The game, in attract mode -- it plays itself from the frame counter, so
# the run is deterministic and does not read the keyboard.
run "game:galaxigans" examples/galaxigans/main.mojo
if [ -f "$DUMP/game:galaxigans.bgra" ]; then
  printf '== %-24s ' "game frame"
  python3 - "$DUMP/game:galaxigans.bgra" <<'PY'
import sys, collections
d = open(sys.argv[1], 'rb').read()
px = [tuple(d[i:i+3]) for i in range(0, len(d), 4)]
colours = collections.Counter(px)
# "Bright" means clearly above the ground the pane clears to, so what this
# asks is whether the layers ABOVE layer 0 drew anything at all.
#
# An ABSOLUTE floor, not a fraction of the screen: a Galaga is mostly black
# sky, and 1,082 lit pixels out of 307,200 is a full formation, a HUD and a
# ship -- while a fraction of one per cent would call that a blank frame.
# What a blank frame actually looks like is one or two colours and a
# handful of stray pixels, and no threshold between there and here is
# delicate.
bright = sum(n for c, n in colours.items() if sum(c) > 90)
if len(colours) < 8 or bright < 400:
    print("FAIL  %d colours, %d bright pixels of %d -- nothing drew"
          % (len(colours), bright, len(px)))
    sys.exit(1)
print("PASS  %d distinct colours, %d bright pixels of %d"
      % (len(colours), bright, len(px)))
PY
  if [ $? -eq 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); failed+=("demo frame"); fi
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "gamepane: $pass/$pass green"
else
  echo "gamepane: $pass passed, $fail FAILED -- ${failed[*]}"
  exit 1
fi
