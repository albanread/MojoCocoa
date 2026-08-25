#!/usr/bin/env bash
# Rebuild the Mojo compiler and PROVE the change is in the binary you run.
#
# "Did you rebuild?" is the wrong question to have to ask, because bazel
# reporting success does not mean the binary you then invoke contains your
# edit, and a stale Mojo kernel cache means a current binary can still produce
# the old result. This script does the rebuild, clears the kernel cache, and
# checks for a marker string so the answer is evidence rather than assumption.
#
# Usage:
#   ./rebuild.sh                       rebuild the compiler, clear kernel cache
#   ./rebuild.sh -v "some string"      also assert that string is in the binary
#   ./rebuild.sh --keep-cache          rebuild but leave the kernel cache alone
#
# Passing an env var into a compile:
#   bazel does NOT forward your shell environment into compile actions. Use
#     ./bazelw test //some:target --action_env=FOO=1
#   which both forwards FOO and changes the action key, so the action actually
#   re-runs. Exporting FOO in your shell does nothing for a bazel build.
#
#   COST: --action_env enters the key of EVERY action, so it invalidates the
#   whole graph -- expect a full rebuild (~3,600 actions here), not just the
#   kernel you care about. It is the honest way to A/B a compiler flag, but do
#   not reach for it casually, and expect to pay it again when you take the
#   flag back off. For a one-off inspection of emitted code, prefer
#     mojo build --emit asm --target-accelerator apple-m4 -I mojo/stdlib
#       -I max/kernels/src -I max/mojo -o /tmp/out file.mojo
#   with the env var exported normally, which bypasses bazel entirely -- but
#   clear the kernel cache first or you will read yesterday's answer.
set -euo pipefail
cd "$(dirname "$0")"

TARGET="//KGEN/tools/mojo:mojo"
BIN="bazel-bin/KGEN/tools/mojo/mojo"
VERIFY=""
KEEP_CACHE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v) VERIFY="${2:-}"; shift 2 ;;
    --keep-cache) KEEP_CACHE=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

before=""
[[ -f "$BIN" ]] && before="$(stat -f '%m %z' "$BIN" 2>/dev/null || true)"

echo "building $TARGET"
./bazelw build "$TARGET"

after="$(stat -f '%m %z' "$BIN" 2>/dev/null || true)"
if [[ -n "$before" && "$before" == "$after" ]]; then
  echo "note: binary is byte-identical to before (mtime+size unchanged)."
  echo "      that is expected if nothing it depends on changed."
else
  echo "binary updated: $BIN"
fi
ls -laL "$BIN" | awk '{print "  size:", $5, " mtime:", $6, $7, $8}'

if [[ -n "$VERIFY" ]]; then
  n="$(strings -a "$BIN" 2>/dev/null | grep -cF "$VERIFY" || true)"
  if [[ "$n" -gt 0 ]]; then
    echo "verified: \"$VERIFY\" present in the binary ($n occurrence(s))"
  else
    echo "FAILED: \"$VERIFY\" is NOT in the binary -- you are about to run stale code" >&2
    exit 1
  fi
fi

if [[ "$KEEP_CACHE" -eq 0 ]]; then
  ./clear_cache.sh
else
  echo "kernel cache left in place (--keep-cache); results may be stale"
fi
