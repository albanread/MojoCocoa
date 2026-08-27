#!/usr/bin/env bash
# A copy of the IDE's own source to open in the IDE, so experiments happen on a
# throwaway and never on the tree.
#
#   ./tools/roast-sandbox.sh          make/refresh ~/roast-sandbox
#   ./tools/roast-sandbox.sh <dir>    somewhere else
#
# The point is not tidiness. An editor under development will lose text: a
# rope bug, a bad save, a crash between write and flush. Editing the source it
# is built from means one of those takes the compiler with it.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="${1:-$HOME/roast-sandbox}"

rm -rf "$DEST"
mkdir -p "$DEST"
cp ide/*.mojo "$DEST/"
mkdir -p "$DEST/notes"
cat > "$DEST/notes/scratch.mojo" <<'EOF'
# Scratch. Nothing here is loaded by anything.
#
#   ⌃Space  complete      ⌘F  find      ⌘S  save      ⌘Z  undo
from std.objc import ObjCClass, msg_send, ObjCObject


def main():
    let NSWindow = ObjCClass.lookup["NSWindow"]()
    # Put the caret after setTit and press control-space.
    _ = msg_send[ObjCObject, "NSWindow", "setTit"]()
EOF
cat > "$DEST/README.md" <<'EOF'
# Roast sandbox

A copy. Edit freely; nothing here is built and nothing here is the source.
Refresh it with `./tools/roast-sandbox.sh`, which deletes and recreates it.
EOF
echo "sandbox at $DEST"
ls "$DEST" | sed 's/^/  /'
