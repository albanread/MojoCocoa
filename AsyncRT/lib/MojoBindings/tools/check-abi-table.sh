#!/usr/bin/env bash
# Fail if ABI-NOTES.md no longer matches the runtime source.
#
# The point of a generated table is that it cannot drift. Without a check that
# is only true in principle: the first person to implement a stub and not
# re-run the generator leaves a table that says "not implemented" about
# working code, and from then on nobody believes any row of it.
#
#   ./tools/check-abi-table.sh        # verify
#   ./tools/gen-abi-table.py > ../ABI-NOTES.md   # update
set -uo pipefail
# Runs from a source checkout AND from a bazel sandbox, where the script and
# its data land at workspace-relative paths under the runfiles root rather
# than beside each other. Look for the generator in both places.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gen=""
for cand in "$here/gen-abi-table.py" \
            "AsyncRT/lib/MojoBindings/tools/gen-abi-table.py" \
            "$here/../../../../AsyncRT/lib/MojoBindings/tools/gen-abi-table.py"; do
  [[ -f "$cand" ]] && { gen="$cand"; break; }
done
[[ -n "$gen" ]] || { echo "cannot locate gen-abi-table.py (looked from $here, cwd $PWD)" >&2; exit 2; }
want="$(dirname "$gen")/../ABI-NOTES.md"
got="$(mktemp)"
trap 'rm -f "$got"' EXIT

python3 "$gen" > "$got" || exit 2

# The generator stamps the current commit, which changes on every commit and
# says nothing about drift. Compare everything else.
if diff -u <(grep -v '^Source: ' "$want") <(grep -v '^Source: ' "$got") > /dev/null; then
  echo "ABI-NOTES.md is up to date"
  exit 0
fi

echo "ABI-NOTES.md has drifted from the runtime source:" >&2
diff -u <(grep -v '^Source: ' "$want") <(grep -v '^Source: ' "$got") | head -40 >&2
echo >&2
echo "Regenerate with:  AsyncRT/lib/MojoBindings/tools/gen-abi-table.py > AsyncRT/lib/MojoBindings/ABI-NOTES.md" >&2
exit 1
