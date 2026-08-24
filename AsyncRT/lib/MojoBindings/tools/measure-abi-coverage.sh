#!/usr/bin/env bash
# Measure which AsyncRT_* symbols the built tests actually reference.
#
# Not from the linked executables: the runtime is alwayslink=True, so every
# symbol shows up as defined text in every binary whether or not anything
# calls it, and nm on an executable reports 100% coverage of everything. That
# is the trap this script exists to avoid.
#
# Bazel leaves the pre-link Mojo object beside each test as `*.mojo.test.lo`.
# Mojo monomorphises the whole program into that one object, so its UNDEFINED
# symbol set is the program's actual ABI demand. That is the measurement.
#
# Limits, which the generated table repeats: this is static reachability, so a
# count >= 1 means "linked against", not "executed" -- an upper bound. A count
# of 0 means genuinely never referenced, and that direction is sound.
#
#   ./tools/measure-abi-coverage.sh > ABI-COVERAGE.tsv
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../../.." && pwd)"
bin="$repo/bazel-bin"
[[ -d "$bin" ]] || { echo "no bazel-bin at $bin; build first" >&2; exit 2; }

objs=$(find -L "$bin" -name '*.lo' 2>/dev/null)
n=$(printf '%s\n' "$objs" | grep -c . || true)
[[ "$n" -gt 0 ]] || { echo "no *.lo objects found; build the tests first" >&2; exit 2; }

printf '# measured over %s pre-link objects\n' "$n"
printf '# symbol\tobjects_referencing\n'
for o in $objs; do
  # -u: undefined only. Strip the leading underscore. One line per symbol per
  # object, deduped, so an object contributes at most 1 to any count.
  nm -u "$o" 2>/dev/null \
    | grep -oE '_AsyncRT_[A-Za-z0-9_]+' \
    | sed 's/^_//' \
    | grep -v '^AsyncRT_\(GetCurrentCPUDevice\|GetOrCreateCPUDevice\|ReleaseCPUDevice\|ParallelismLevel\)$' \
    | sort -u
done | sort | uniq -c | sort -rn | awk '{printf "%s\t%s\n", $2, $1}'
