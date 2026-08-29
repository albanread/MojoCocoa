#!/usr/bin/env bash
# Sign every Mach-O in a payload, hardened, ready for notarization.
#
#   ./tools/sign-payload.sh [dist/payload]
#   SIGN_ID="Developer ID Application: …" ./tools/sign-payload.sh
#   ./tools/sign-payload.sh --adhoc        rehearse without an identity
#
# Notarization refuses a bundle containing ONE unsigned Mach-O, and this
# payload has fifteen before Python. So this walks an inventory rather than
# signing a folder and hoping:
#
#   - inside out. A dylib signed after the binary that loads it invalidates
#     that binary's signature; `--deep` is Apple's own deprecated shortcut
#     for this and gets the order wrong often enough that they say not to.
#   - against MACHO-MANIFEST, written when the payload was assembled. If the
#     count found now differs from the count recorded then, the payload
#     changed in transit and the release stops here -- rather than an hour
#     later as a notarization failure that names nothing useful.
#   - then verifies every one, because a signature nobody checked is a
#     signature that fails on someone else's machine.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

ADHOC=0
[ "${1:-}" = "--adhoc" ] && { ADHOC=1; shift; }
PAYLOAD="${1:-$ROOT/dist/payload}"
ENTITLEMENTS="$ROOT/tools/entitlements/toolchain.plist"
# Signing identity and notary profile are personal: a Developer ID names a
# real person and a notarytool profile is tied to an Apple ID, so they live
# in tools/signing.local.sh, which is gitignored. The environment still
# wins, for CI or a one-off.
[ -f "$ROOT/tools/signing.local.sh" ] && . "$ROOT/tools/signing.local.sh"
IDENT="${SIGN_ID:-}"
[ "$ADHOC" = 1 ] && IDENT="-"

[ -d "$PAYLOAD" ] || { echo "no payload at $PAYLOAD -- run make-payload.sh"; exit 1; }
[ -f "$ENTITLEMENTS" ] || { echo "no entitlements at $ENTITLEMENTS"; exit 1; }
# AMFI parses this file, not plutil, and it is stricter -- a double hyphen
# inside an XML comment is enough. codesign treats a plist it cannot parse
# as no entitlements at all and carries on, so the toolchain ends up signed
# WITHOUT the JIT and library-validation exceptions and nothing says so
# until the debugger will not load its plugin. Prove it parses first.
probe="$(mktemp -d)"; cp /usr/bin/true "$probe/probe"
if ! codesign --force --sign - --entitlements "$ENTITLEMENTS" "$probe/probe" 2>&1 \
     | grep -q .; then :; fi
if codesign --force --sign - --entitlements "$ENTITLEMENTS" "$probe/probe" 2>&1 \
   | grep -q 'Failed to parse entitlements'; then
  echo "   FAILED -- AMFI cannot parse $ENTITLEMENTS"
  echo "   (an XML comment containing a double hyphen is the usual cause)"
  rm -rf "$probe"; exit 1
fi
rm -rf "$probe"

echo "== signing $PAYLOAD =="
if [ "$ADHOC" = 1 ]; then
  echo "   identity: ad-hoc (rehearsal -- will NOT notarize)"
else
  echo "   identity: $IDENT"
  # The listing is captured ONCE and both tested and reported. Running
  # security twice -- testing the first result, printing the second -- can
  # announce that the identity is missing directly above a listing that
  # contains it, which is what it did. Piping into `grep -q` was its own
  # hazard: grep exits at the first match, security takes SIGPIPE, and
  # under `set -o pipefail` the pipeline reports failure for a search that
  # succeeded.
  identities="$(security find-identity -v -p codesigning || true)"
  case "$identities" in
    *"$IDENT"*) ;;
    *)
      echo "   FAILED -- that identity is not in the keychain:"
      printf '%s\n' "$identities" | sed 's/^/     /'
      echo "   (if it IS listed above, the keychain was locked when this"
      echo "    ran -- unlock it and try again)"
      exit 1 ;;
  esac
fi

# What is here now.
found="$(mktemp)"; trap 'rm -f "$found"' EXIT
set +e   # `file | grep -q` is non-zero for every script it steps over
find "$PAYLOAD" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) \
  -print0 2>/dev/null | while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q 'Mach-O'; then printf '%s\n' "${f#$PAYLOAD/}"; fi
  done | sort > "$found"
set -e
n_found=$(wc -l < "$found" | tr -d ' ')

# What was here when the payload was assembled.
MANIFEST="$PAYLOAD/MACHO-MANIFEST"
if [ -f "$MANIFEST" ]; then
  if ! diff -q "$MANIFEST" "$found" >/dev/null; then
    echo "   FAILED -- the payload changed since it was assembled:"
    diff "$MANIFEST" "$found" | sed 's/^/     /' | head -12
    exit 1
  fi
  echo "   inventory: $n_found Mach-O files, matching the manifest"
else
  echo "   inventory: $n_found Mach-O files (no manifest to check against)"
fi

# Inside out: dylibs and frameworks first, then everything else. Within each
# group, deepest path first, so a nested library is signed before whatever
# contains it.
sign_one() {
  codesign --force --timestamp --options runtime \
           --entitlements "$ENTITLEMENTS" --sign "$IDENT" "$1" 2>&1 \
    | grep -v 'replacing existing signature' || true
}

signed=0
for pass in libs rest; do
  while IFS= read -r rel; do
    case "$rel" in
      *.dylib|*.so|*/Frameworks/*) [ "$pass" = libs ] || continue ;;
      *)                           [ "$pass" = rest ] || continue ;;
    esac
    sign_one "$PAYLOAD/$rel"
    signed=$((signed + 1))
  done < <(awk '{ print length($0)"\t"$0 }' "$found" | sort -rn | cut -f2-)
done
echo "   signed: $signed"

# Bundles last, and as bundles: their contents are signed above, and the
# bundle's own seal must be taken after them or it seals a stale hash.
for app in "$PAYLOAD"/*.app "$PAYLOAD"/CocoaMojo/*.app; do
  [ -d "$app" ] || continue
  sign_one "$app"
  echo "   sealed: $(basename "$app")"
done

echo "== verifying =="
bad=0
# A framework is not verified the way a lone Mach-O is. Passing its main
# executable to --verify --strict makes codesign resolve the enclosing
# bundle and fail with "No such file or directory" -- Apple's own Tcl, Tk
# and Ruby frameworks fail the same check, so it is the check that is
# wrong, not the signature. Frameworks are verified once, as bundles, with
# --deep (which validates every nested Mach-O) and --strict=symlinks (which
# enforces the rule that no link may leave the bundle, and unlike plain
# --strict actually names the offender).
frameworks="$(mktemp)"
while IFS= read -r rel; do
  case "$rel" in
    *.framework/*)
      printf '%s\n' "${rel%%.framework/*}.framework" >> "$frameworks"
      continue ;;
  esac
  codesign --verify --strict "$PAYLOAD/$rel" 2>/dev/null || {
    echo "   FAIL $rel"; bad=1; }
done < "$found"
sort -u "$frameworks" | while IFS= read -r fw; do
  [ -n "$fw" ] || continue
  if codesign --verify --deep --strict=symlinks "$PAYLOAD/$fw" 2>/dev/null; then
    echo "   framework OK $fw"
  else
    echo "   FAIL $fw"
    codesign --verify --deep --strict=symlinks "$PAYLOAD/$fw" 2>&1 | head -3 | sed 's/^/        /'
    echo fail >> "$frameworks.bad"
  fi
done
[ -f "$frameworks.bad" ] && bad=1
rm -f "$frameworks" "$frameworks.bad"
for app in "$PAYLOAD"/*.app "$PAYLOAD"/CocoaMojo/*.app; do
  [ -d "$app" ] || continue
  codesign --verify --deep --strict "$app" 2>/dev/null || {
    echo "   FAIL $(basename "$app")"; bad=1; }
done
[ "$bad" = 0 ] || { echo "   verification FAILED"; exit 1; }
echo "   all $n_found verified"

if [ "$ADHOC" = 0 ]; then
  echo "== entitlements, as they landed =="
  codesign -d --entitlements - --xml "$PAYLOAD/CocoaMojo/bin/cocoamojo-compiler" 2>/dev/null \
    | plutil -p - 2>/dev/null | grep -E 'allow-jit|library-validation' | sed 's/^/  /'
fi
echo
echo "payload signed. Next: build the DMG and notarize with profile"
echo "\$NOTARY_PROFILE."
