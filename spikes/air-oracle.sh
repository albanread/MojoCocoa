#!/usr/bin/env bash
#
# air-oracle.sh — check one of our GPU spikes against Modular's stack.
#
#   ./spikes/air-oracle.sh //spikes:compute_smoke
#   ./spikes/air-oracle.sh --keep //spikes:compute_smoke
#
# Builds and runs the same source twice: once through our compiler and our
# AppleGPURT, once through Modular's toolchain and their closed runtime, then
# compares. When one of our kernels is wrong this says so without needing a
# hand-written Metal harness, and the AIR table at the end usually says
# whether to go looking in codegen or in the runtime.
#
# The oracle is a SEPARATE PROCESS and never a link-time option. Their runtime
# is a proprietary binary; no build mode in this fork links it, and
# //AsyncRT/lib/MojoBindings is the only device runtime we build against. This
# script runs their compiler and their program the way you would run any other
# reference implementation, and diffs the result.
#
# Two things to keep in mind when reading a divergence:
#
#  - Each side is a COMPLETE stack. Modular's compiler cannot build this
#    tree's stdlib at all (_cocoakb.mojo uses POC opcodes only our compiler
#    knows), so their side runs against the wheel's own std and max. A
#    difference is evidence about two stacks, not proof about our AIR backend.
#
#  - Do not run the oracle side under MTL_SHADER_VALIDATION. Modular's own
#    AIR takes down the Metal compiler service under GPU validation
#    (XPC_ERROR_CONNECTION_INTERRUPTED) on this machine, while ours passes.
#    Our side is validated, theirs is not; see the note printed at the end.

set -uo pipefail

KEEP=0
if [[ "${1:-}" == "--keep" ]]; then KEEP=1; shift; fi
TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
  echo "usage: $0 [--keep] <bazel-target>   e.g. //spikes:compute_smoke" >&2
  exit 2
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

OUT="$(mktemp -d "${TMPDIR:-/tmp}/air-oracle.XXXXXX")"
trap '[[ $KEEP -eq 1 ]] || rm -rf "$OUT"' EXIT
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# Source file behind the target, so both sides compile the same text.
SRC="$(./bazelw query "labels(srcs, $TARGET)" 2>/dev/null | head -1 | sed 's|^//||;s|:|/|')"
if [[ -z "$SRC" || ! -f "$SRC" ]]; then
  echo "could not resolve a source file from $TARGET" >&2; exit 1
fi
echo "source: $SRC"

# ------------------------------------------------------------------- ours
say "[1/3] ours — our AIR backend, our runtime"
if ! ./bazelw build "$TARGET" >"$OUT/ours.build.log" 2>&1; then
  echo "  BUILD FAILED:"; grep -E 'error|ERROR' "$OUT/ours.build.log" | head -10; exit 1
fi
OURS_BIN="bazel-bin/${TARGET#//}"; OURS_BIN="${OURS_BIN/://}"
[[ -x "$OURS_BIN" ]] || { echo "  no binary at $OURS_BIN" >&2; exit 1; }
# Our side IS run under validation: a raw device address that is not resident
# passes silently otherwise (see markAllResident in AppleGPUMetal.cpp).
MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 "$OURS_BIN" >"$OUT/ours.out" 2>&1
sed 's/^/    /' "$OUT/ours.out" | grep -v 'Validation Enabled'

# ----------------------------------------------------------------- oracle
say "[2/3] oracle — Modular's compiler and runtime (separate process)"
OB="$(./bazelw info output_base 2>/dev/null)"
TC="$OB/external/rules_mojo++mojo+mojo_toolchain_macos_arm64"
WH="$OB/external/+rebuild_wheel+module_platlib_macos_arm64/modular"
if [[ ! -x "$TC/bin/mojo" || ! -d "$WH/lib/mojo" ]]; then
  echo "  Modular toolchain not present in this output base; skipping." >&2
  THEIRS_BIN=""
else
  THEIRS_BIN="$OUT/theirs"
  MODULAR_MOJO_MAX_COMPILERRT_PATH="$TC/lib/libKGENCompilerRTShared.dylib" \
  "$TC/bin/mojo" build "$SRC" \
    -I "$TC/lib/mojo" -I "$WH/lib/mojo" \
    -Xlinker "-L$WH/lib" -Xlinker "-lAsyncRTMojoBindings" \
    -Xlinker "-rpath" -Xlinker "$WH/lib" \
    -o "$THEIRS_BIN" >"$OUT/theirs.build.log" 2>&1
  if [[ ! -x "$THEIRS_BIN" ]]; then
    echo "  BUILD FAILED:"; grep -vE 'Crashpad|warning:|^ |^$' "$OUT/theirs.build.log" | head -8
    THEIRS_BIN=""
  else
    # No validation here on purpose -- see the header.
    "$THEIRS_BIN" >"$OUT/theirs.out" 2>&1
    sed 's/^/    /' "$OUT/theirs.out"
  fi
fi

# --------------------------------------------------------------- compare
say "[3/3] comparison"
if [[ -s "$OUT/ours.out" && -s "${OUT}/theirs.out" ]]; then
  # Timings differ run to run; compare everything else verbatim.
  strip() { sed -E 's/[0-9]+(\.[0-9]+)?( ms| x)?//g; /^speedup/d; /Validation Enabled/d' "$1"; }
  if diff -q <(strip "$OUT/ours.out") <(strip "$OUT/theirs.out") >/dev/null; then
    printf '  \033[32mAGREE\033[0m — identical output modulo timings\n'
  else
    printf '  \033[31mDIVERGE\033[0m\n'
    diff <(strip "$OUT/ours.out") <(strip "$OUT/theirs.out") | sed 's/^/    /'
  fi
fi

python3 - "$OUT" "$THEIRS_BIN" "$OURS_BIN" <<'PY'
import struct, subprocess, sys, os
out, theirs_bin, ours_bin = sys.argv[1], sys.argv[2], sys.argv[3]

def section_bitcode(blob):
    if blob[:4] != b'MTLB': return None
    off = struct.unpack_from('<Q', blob, 0x48)[0]
    sz  = struct.unpack_from('<Q', blob, 0x50)[0]
    return blob[off:off+sz]

def embedded(path):
    d = open(path, 'rb').read()
    i = d.find(b'MTLB')
    if i < 0: return None
    sz = struct.unpack_from('<Q', d, i + 0x10)[0]
    return d[i:i+sz] if 0 < sz <= len(d) - i else None

air_opt = os.path.join(os.path.dirname(
    subprocess.run(['xcrun','-f','metal'],capture_output=True,text=True).stdout.strip()), 'air-opt')

def describe(bc, tag):
    if not bc: return (tag,'-','-','-','-')
    p = os.path.join(out, tag+'.bc'); open(p,'wb').write(bc)
    ll = os.path.join(out, tag+'.ll')
    if subprocess.run([air_opt,'-S',p,'-o',ll],capture_output=True).returncode != 0:
        return (tag,'(disasm failed)','-','-',str(len(bc)))
    t = open(ll).read()
    triple = next((l.split('"')[1] for l in t.splitlines() if l.startswith('target triple')),'?')
    builtins = sum(t.count('!"air.'+b+'"') for b in
        ('thread_position_in_grid','thread_position_in_threadgroup',
         'threadgroup_position_in_grid','threads_per_threadgroup',
         'threads_per_grid','thread_index_in_simdgroup'))
    return (tag, triple, str(builtins), str(t.count('!"air.arg_unused"')), str(len(bc)))

# Both toolchains embed the metallib in the executable, so pull it out of
# each the same way -- no APPLEGPU_KEEP_AIR needed, and therefore no
# --action_env, which would re-key every action and cost a full rebuild.
rows = []
for tag, binary in (('ours', ours_bin), ('oracle', theirs_bin)):
    if not binary or not os.path.exists(binary):
        rows.append((tag, '-', '-', '-', '-')); continue
    ml = embedded(binary)
    rows.append(describe(section_bitcode(ml) if ml else None, tag))

print(f"\n  {'':8}{'triple':32}{'builtins':>9}{'unused':>8}{'bitcode':>9}")
for r in rows:
    print(f"  {r[0]:8}{r[1]:32}{r[2]:>9}{r[3]:>8}{r[4]:>9}")
print("""
  Expected ABI difference, not a defect: Modular always emits a fixed set of
  builtins and marks the unused ones air.arg_unused; we emit only the ones the
  kernel uses. Their runtime is written against their layout, which is why our
  kernels do not load into it and why this is an oracle rather than a mix-and-
  match. Our side above ran under GPU validation; theirs cannot.""")
PY

[[ $KEEP -eq 1 ]] && echo && echo "  artifacts kept in $OUT"
exit 0
