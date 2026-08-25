#!/usr/bin/env bash
# Clear the caches that make compiler changes appear to do nothing.
#
# There are THREE independent caches in this tree, and only one of them is
# bazel's. Losing an afternoon to this is the normal experience, so:
#
#   1. ~/.cache/modular/.mojo_cache -- the Mojo KERNEL cache. Keyed on the
#      kernel body, NOT on the compiler binary and NOT on environment
#      variables. Change a backend pass, rebuild the compiler, recompile the
#      same kernel: you get the CACHED result and the pass never runs. Editing
#      the .mojo file does not help either if the kernel body is unchanged.
#      This is the one that wastes your day.
#   2. bazel's action cache -- keyed on inputs and action definition. An env
#      var only enters the key via --action_env (see rebuild.sh).
#   3. bazel's test result cache -- bypass with --nocache_test_results.
#
# Usage:
#   ./clear_cache.sh            clear the Mojo kernel cache (fast, safe)
#   ./clear_cache.sh --bazel    also expunge bazel's cache (slow: full rebuild)
#   ./clear_cache.sh --daemon   also shut down the bazel server
set -euo pipefail
cd "$(dirname "$0")"

MOJO_CACHE="${HOME}/.cache/modular/.mojo_cache"
if [[ -d "$MOJO_CACHE" ]]; then
  echo "clearing Mojo kernel cache ($(du -sh "$MOJO_CACHE" 2>/dev/null | cut -f1)) at $MOJO_CACHE"
  rm -rf "$MOJO_CACHE"
else
  echo "Mojo kernel cache already absent: $MOJO_CACHE"
fi

for arg in "$@"; do
  case "$arg" in
    --daemon)
      echo "shutting down the bazel server"
      ./bazelw shutdown || true
      ;;
    --bazel)
      echo "expunging bazel's cache -- the next build is a FULL rebuild"
      ./bazelw clean --expunge || true
      ;;
    *)
      echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done
echo "done"
