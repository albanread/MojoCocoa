#!/usr/bin/env bash
# Run a gamepane file against the DEVELOPMENT toolchain.
#
# Never the installed one: /Applications/Roast is notarized, and a rebuilt
# libCocoaMojoGPU.dylib cannot be dropped into it -- dyld refuses the
# replacement whatever it is signed with. Development uses dist/CocoaMojo,
# which is ours.
#
#   ./tools/gp.sh gamepane/tests/test_window.mojo
set -euo pipefail
cd "$(dirname "$0")/.."
D="$PWD/dist/CocoaMojo"
[ -x "$D/bin/cocoamojo" ] || { echo "no dist toolchain -- run ./tools/release.sh" >&2; exit 1; }
# The package goes on the import path the way the distribution will ship it,
# so a test or a demo just says `from gamepane.api import ...`. The doubled
# name is the layout the driver expects: lib/mojo/gamepane is the container
# it puts on -I, gamepane/ inside it is the package -- the same shape as
# lib/mojo/max/max. Only the shippable tiers go; tests build from the repo.
rsync -a --delete --exclude='tests/' --delete-excluded \
      --include='*/' --include='*.mojo' --exclude='*' \
      "$PWD/gamepane/" "$D/lib/mojo/gamepane/gamepane/"
exec env COCOAMOJO_ROOT="$D" "$D/bin/cocoamojo" run "$@"
