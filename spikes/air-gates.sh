#!/usr/bin/env bash
#
# air-gates.sh — the two AIR checks that cannot run inside the compiler.
#
#   ./spikes/air-gates.sh records <target>   # gate 2: bitstream record diff
#   ./spikes/air-gates.sh golden <file.metal># gate 3: what Apple emits
#
# Three things reject our AIR, they are not the same thing, and the AIR
# reader answers all of them with the same few words -- "Invalid record",
# "Unexpected bitcode file!", or a compiler service that dies with
# XPC_ERROR_CONNECTION_INTERRUPTED. Each gate separates out one class:
#
#   1. INVALID IR -- our own bug, rejected by every reader including modern
#      LLVM's. Caught in-process: AirBackend runs llvm::verifyModule before
#      serialising, so this class now names its own instruction. Not here.
#
#   2. VERSION SKEW -- valid modern LLVM that Apple's frozen reader predates:
#      poison (LLVM 12), freeze (10), fneg (8), memory(none) (16), GEP
#      nusw/nuw (19), attribute codes above ~77, llvm.stepvector. Found by
#      diffing our bitstream record inventory against output from a compiler
#      that works. `records` below.
#
#   3. AIR SEMANTICS -- not skew at all, a different target: no generic
#      address space, no native int<->float casts (air.convert.* calls),
#      cross-lane ops must be convergent. Only Apple's own compiler can teach
#      these. `golden` below.
#
# Gate 2 runs Modular's toolchain as a REFERENCE PROCESS. Nothing in this
# fork links their binaries; see spikes/air-oracle.sh for the same boundary.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
MODE="${1:-}"; shift || true
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

BCA="$(command -v llvm-bcanalyzer || echo /opt/homebrew/opt/llvm/bin/llvm-bcanalyzer)"
[[ -x "$BCA" ]] || { echo "need llvm-bcanalyzer (brew install llvm)" >&2; exit 2; }

# Pull the bitcode out of a .metallib, a wrapped .air, or an executable that
# has one linked into it. Same header walk in all three cases: MTLB magic,
# total size at 0x10, bitcode section at 0x48/0x50.
extract_bc() {
python3 - "$1" "$2" <<'PY'
import struct, sys
src, dst = sys.argv[1], sys.argv[2]
d = open(src, 'rb').read()
if d[:4] == b'\xde\xc0\x17\x0b':           # already wrapped bitcode
    open(dst, 'wb').write(d); sys.exit(0)
i = d.find(b'MTLB')
if i < 0:
    sys.exit(1)
sz = struct.unpack_from('<Q', d, i + 0x10)[0]
ml = d[i:i+sz]
off = struct.unpack_from('<Q', ml, 0x48)[0]
bsz = struct.unpack_from('<Q', ml, 0x50)[0]
open(dst, 'wb').write(ml[off:off+bsz])
PY
}

profile() { # $1 = bitcode -> record kinds, one per line
  "$BCA" --dump "$1" 2>/dev/null | grep -oE '<[A-Za-z_0-9]+' | sort -u
}

case "$MODE" in
records)
  TARGET="${1:-//spikes:compute_smoke}"
  SRC="$(./bazelw query "labels(srcs, $TARGET)" 2>/dev/null | head -1 | sed 's|^//||;s|:|/|')"
  [[ -f "$SRC" ]] || { echo "cannot resolve a source from $TARGET" >&2; exit 1; }
  OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
  say "[1/3] ours"
  ./bazelw build "$TARGET" >"$OUT/b.log" 2>&1 || {
    echo "  build failed:"; grep -E 'error|ERROR' "$OUT/b.log" | head -5; }
  OURS="bazel-bin/${TARGET#//}"; OURS="${OURS/://}"

  say "[2/3] reference (Modular's toolchain, separate process)"
  OB="$(./bazelw info output_base 2>/dev/null)"
  TC="$OB/external/rules_mojo++mojo+mojo_toolchain_macos_arm64"
  WH="$OB/external/+rebuild_wheel+module_platlib_macos_arm64/modular"
  REF=""
  if [[ -x "$TC/bin/mojo" ]]; then
    MODULAR_MOJO_MAX_COMPILERRT_PATH="$TC/lib/libKGENCompilerRTShared.dylib" \
    "$TC/bin/mojo" build "$SRC" -I "$TC/lib/mojo" -I "$WH/lib/mojo" \
      -Xlinker "-L$WH/lib" -Xlinker "-lAsyncRTMojoBindings" \
      -Xlinker "-rpath" -Xlinker "$WH/lib" \
      -o "$OUT/ref" >"$OUT/r.log" 2>&1
    [[ -x "$OUT/ref" ]] && REF="$OUT/ref" || {
      echo "  reference build failed:"; grep -vE 'warning|note|^ |^$' "$OUT/r.log" | head -4; }
  else
    echo "  Modular toolchain not fetched into this output base; skipping."
  fi

  say "[3/3] record inventory"
  [[ -f "$OURS" ]] && extract_bc "$OURS" "$OUT/o.bc" && profile "$OUT/o.bc" > "$OUT/o.txt" || : > "$OUT/o.txt"
  [[ -n "$REF" ]]  && extract_bc "$REF"  "$OUT/r.bc" && profile "$OUT/r.bc" > "$OUT/r.txt" || : > "$OUT/r.txt"
  if [[ -s "$OUT/o.txt" && -s "$OUT/r.txt" ]]; then
    ONLY="$(comm -23 "$OUT/o.txt" "$OUT/r.txt")"
    if [[ -z "$ONLY" ]]; then
      printf '  \033[32mCLEAN\033[0m — we emit no record kind the reference does not\n'
    else
      printf '  \033[31mOURS-ONLY record kinds\033[0m (each is version skew until shown otherwise):\n'
      echo "$ONLY" | sed 's/^/    /'
      cat <<'NOTE'

  Decode UnknownCodeN by block. In CONSTANTS: 26 = CST_CODE_POISON,
  25 = CE_UNOP, 27 = DSO_LOCAL_EQUIVALENT. Fix in LLVMIRDowngradePass,
  which runs after optimisation precisely so the optimiser cannot
  reintroduce what it removes.
NOTE
    fi
  else
    echo "  need both sides to compare"
  fi
  ;;

golden)
  SRC="${1:-}"
  [[ -f "$SRC" ]] || { echo "usage: $0 golden <file.metal>" >&2; exit 2; }
  say "Apple's own AIR for $SRC"
  LL="$(mktemp -t golden).ll"
  xcrun metal -S -emit-llvm "$SRC" -o "$LL" || exit 1
  echo "  target:   $(grep -m1 '^target triple' "$LL" | cut -d'"' -f2)"
  echo "  air.*  symbols Apple emits:"
  grep -oE '@air\.[a-zA-Z0-9_.]+' "$LL" | sort -u | sed 's/^/    /'
  echo "  attribute groups:"
  grep -E '^attributes #' "$LL" | sed 's/^/    /'
  echo "  constructs Apple NEVER uses here (if we emit these, we are wrong):"
  for c in addrspacecast 'addrspace(0)' sitofp uitofp fptosi fptoui poison freeze; do
    n=$(grep -c -- "$c" "$LL")
    [[ "$n" == "0" ]] && echo "    $c"
  done
  echo "  full IR kept at: $LL"
  ;;

*)
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
  exit 2 ;;
esac
