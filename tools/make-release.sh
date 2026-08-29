#!/usr/bin/env bash
# Build the release disk image: payload, installer, signed, notarized,
# stapled, verified.
#
#   ./tools/make-release.sh                 the whole thing
#   ./tools/make-release.sh --no-notarize   everything but the round trip
#   SIGN_ID="…" NOTARY_PROFILE=[redacted] ./tools/make-release.sh
#
# The order is the only order that works, and each step is here because
# doing it later breaks the one before:
#
#   1. assemble    the payload, in the shape it installs as
#   2. build       Install Roast.app, from Swift
#   3. sign        every Mach-O in the payload, then the installer, then
#                  the app bundles -- inside out, because signing a library
#                  after its loader invalidates the loader
#   4. image       a read-only DMG of the lot
#   5. sign        the DMG itself
#   6. notarize    submit and wait
#   7. staple      the ticket onto the DMG, so it installs offline
#   8. verify      spctl, as a stranger's Mac would see it
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

NOTARIZE=1
[ "${1:-}" = "--no-notarize" ] && NOTARIZE=0
IDENT="${SIGN_ID:-Developer ID Application: [redacted] ([redacted])}"
PROFILE="${NOTARY_PROFILE:-[redacted]}"
VER="${VERSION:-$(date +%Y.%m.%d)}"
OUT="$ROOT/dist"
STAGE="$OUT/release-stage"
DMG="$OUT/Roast-$VER.dmg"

echo "== 1/8  payload =="
VERSION="$VER" PAYLOAD_DIR="$STAGE/payload" ./tools/make-payload.sh \
  | sed 's/^/   /'

echo "== 2/8  installer =="
APP="$STAGE/Install Roast.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$APP/Contents/MacOS/Install Roast" tools/installer/*.swift
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Install Roast</string>
  <key>CFBundleDisplayName</key>       <string>Install Roast</string>
  <key>CFBundleExecutable</key>        <string>Install Roast</string>
  <key>CFBundleIdentifier</key>        <string>org.mojococoa.installer</string>
  <key>CFBundleVersion</key>           <string>$VER</string>
  <key>CFBundleShortVersionString</key><string>$VER</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>LSMinimumSystemVersion</key>    <string>15.0</string>
  <key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"
[ -f "$ROOT/tools/roast.icns" ] && {
  cp -f "$ROOT/tools/roast.icns" "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" \
      "$APP/Contents/Info.plist" >/dev/null
}
echo "   $(stat -f%z "$APP/Contents/MacOS/Install Roast" \
      | awk '{printf "%.0f KB", $1/1024}')"

echo "== 3/8  signing the payload =="
SIGN_ID="$IDENT" ./tools/sign-payload.sh "$STAGE/payload" | sed 's/^/   /'

echo "== 4/8  signing the installer =="
# No entitlements: it copies files. The hardened runtime with nothing
# switched off is the strongest thing to ask for, so ask for it.
codesign --force --timestamp --options runtime --sign "$IDENT" "$APP" \
  2>&1 | grep -v 'replacing existing signature' || true
codesign --verify --deep --strict "$APP" && echo "   installer signed"

cat > "$STAGE/Read Me.txt" <<TXT
CocoaMojo $VER

Open "Install Roast" and press Install. It puts the toolchain --
compiler, language server, debugger, standard library, examples and the
IDE's own source -- in /Applications/Roast, with Roast beside it.

The same window resets a toolchain you have experimented on, and uninstalls
everything. Uninstall keeps your work unless you tick the box: an edited
standard library, your projects, and your Python environments live in
Application Support and are not the installer's to throw away.

Keep this disk image: Reset and Uninstall need the payload on it.

Requires Apple Silicon and macOS 15 or later.
TXT

echo "== 5/8  disk image =="
rm -f "$DMG"
hdiutil create -quiet -srcfolder "$STAGE" -volname "Roast $VER" \
    -format UDBZ -fs HFS+ "$DMG"
echo "   $DMG ($(du -sh "$DMG" | cut -f1))"

echo "== 6/8  signing the image =="
codesign --force --timestamp --sign "$IDENT" "$DMG" 2>&1 \
  | grep -v 'replacing existing signature' || true
codesign --verify --strict "$DMG" && echo "   image signed"

if [ "$NOTARIZE" = 0 ]; then
  echo
  echo "$DMG (not notarized -- --no-notarize)"
  exit 0
fi

echo "== 7/8  notarizing =="
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait \
  | sed 's/^/   /'

echo "== 8/8  stapling and verifying =="
xcrun stapler staple "$DMG" | sed 's/^/   /'
# spctl is the question a stranger's Mac asks, and the only one that counts.
spctl -a -vv -t install "$DMG" 2>&1 | sed 's/^/   /'
echo
echo "$DMG"
echo "  open $DMG"
