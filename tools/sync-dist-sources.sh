#!/usr/bin/env bash
# Sync every source-only tree from this repository into dist/CocoaMojo.
#
#   ./tools/sync-dist-sources.sh              -> dist/CocoaMojo
#   ./tools/sync-dist-sources.sh /some/dist   -> there
#
# Two release paths exist. make-dist.sh assembles the whole distribution --
# compiler, runtimes, database -- and is where bazel lives. make-app.sh plus
# RoastInstaller's make-release.sh rebuild only Roast and repackage, with no
# bazel at all. Both ship dist/ as it stands, so every tree that is COPIED
# rather than COMPILED must be refreshed by both paths, or the fast path
# ships a fresh binary beside stale source. That is not hypothetical: on
# 2026-09-01 an image carried a Roast built from ide/roast.mojo at 11:40
# beside a share/ide-source from 09:32, and the stdlib a fresh install
# seeded into user space did not know `nsenum`.
#
# So the copies live HERE, and both paths call this. Idempotent by
# construction -- rsync --delete removes drift in both directions -- so a
# second run in a row changes nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
D="${1:-$ROOT/dist/CocoaMojo}"

[ -d "$D" ] || {
  echo "no distribution at $D -- run ./tools/release.sh first"
  exit 1
}

echo "== packages =="
# Sources, not .mojoc: a precompiled package records a compiler version and
# this tree's compiler rejects packages built by a different one.
mkdir -p "$D/lib/mojo"
rsync -a --delete "$ROOT/mojo/stdlib/"      "$D/lib/mojo/stdlib/"
rsync -a --delete "$ROOT/max/mojo/"         "$D/lib/mojo/max/"
rsync -a --delete "$ROOT/max/kernels/src/"  "$D/lib/mojo/kernels/"
# gamepane, the retro game pane: shipped as a package like the rest, minus
# its tests, which build from the repository against the same sources.
rsync -a --delete --delete-excluded \
      --exclude='tests/' \
      --include='*/' --include='*.mojo' --exclude='*' \
      "$ROOT/gamepane/" "$D/lib/mojo/gamepane/gamepane/"

echo "== examples =="
# Shipped with the toolchain because they are the answer to "what does a
# project look like" -- each folder is one, with its main.mojo, and Roast
# opens them as they are. Copied without build/ or anything a previous run
# left behind, so a fresh distribution is sources only.
# --delete-excluded as well as --delete: without it rsync protects excluded
# files that are already in the destination, so a build/ from an earlier run
# would survive every rebuild of the distribution.
rsync -a --delete --delete-excluded \
      --exclude 'build/' --exclude '*.png' --exclude '.DS_Store' \
      "$ROOT/examples/" "$D/share/examples/"
# A binary left behind by someone running `cocoamojo build -o name` inside an
# example folder is not part of the example, and rsync cannot tell it from a
# source. build/ is excluded above; this catches the other spelling.
stray="$(find "$D/share/examples" -type f -perm +111 ! -name '*.sh' | wc -l | tr -d ' ')"
if [ "$stray" -gt 0 ]; then
  find "$D/share/examples" -type f -perm +111 ! -name '*.sh' -delete
  echo "   dropped $stray stray executable(s)"
fi
echo "   $(find "$D/share/examples" -name '*.mojo' | wc -l | tr -d ' ') files in $(ls "$D/share/examples" | grep -vc README) projects"

echo "== the IDE's source =="
# Roast is written in the language it edits, so its source ships as a
# project people can open, read and build -- the most complete example the
# toolchain has, and the answer to "how would I write something like this".
# A directory sync with a filter, not `ide/*.mojo` as a file list: rsync's
# --delete only mirrors directories, so the file-list spelling can add but
# never remove -- a renamed module would ship under both names forever.
# --delete-excluded clears anything else; README.md is regenerated below.
rsync -a --delete --delete-excluded \
      --include='*.mojo' --exclude='*' \
      "$ROOT/ide/" "$D/share/ide-source/"
cat > "$D/share/ide-source/README.md" <<'IDEREADME'
# Roast, in Roast

The source of the editor you are reading it in. Roast is written in
cocoa-mojo and talks to AppKit directly -- no bridge, no wrapper library --
so this doubles as the largest worked example of `class`, the typed
`Obj`/`Cls` surface, the Cocoa database and the debugger APIs.

Build it with cmd-B; `roast.mojo` is the entry point. The copy in
Application Support is yours: edit it freely, and File > Reset Standard
Library & Examples restores the shipped one.

Files worth opening first:

- `roast.mojo`      the window, menus, toolbar, agent surface
- `gridview.mojo`   the editor view: NSTextInputClient, drawing, the lexer
- `rope.mojo`       the text engine, with its own test suite
- `dap.mojo`        the debug adapter conversation
- `lsp.mojo`        the language server conversation
IDEREADME
echo "   $(ls "$D/share/ide-source"/*.mojo | wc -l | tr -d ' ') files"
