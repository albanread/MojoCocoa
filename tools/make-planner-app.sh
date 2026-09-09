#!/usr/bin/env bash
# Package Mission Planner as a Mac application: the .app, a .dmg, signed with
# a Developer ID, notarized by Apple and stapled so it opens offline.
#
#   ./tools/make-planner-app.sh                      ad-hoc signature, no dmg
#   SIGN_ID="Developer ID Application: NAME (TEAM)" ./tools/make-planner-app.sh
#   SIGN_ID="..." NOTARY_PROFILE=macvm ./tools/make-planner-app.sh
#   APP_DIR=/tmp/mine ./tools/make-planner-app.sh
#
# The three levels are deliberate. With no SIGN_ID it signs ad hoc, which runs
# on this machine and nowhere else. With SIGN_ID it is a real Developer ID
# signature with the hardened runtime, which Gatekeeper still refuses on a
# downloaded copy -- correctly, as `source=Unnotarized Developer ID`. With
# NOTARY_PROFILE as well it is the whole chain.
#
# WHY A BUNDLE AT ALL
#
# The binary already carries a __TEXT,__info_plist, which is enough for a Dock
# icon, a menu bar and a TCC identity. It is not enough for `tell application
# "Mission Planner"`: that asks Launch Services, and Launch Services only knows
# about bundles. tools/make-app.sh records the same finding for Roast, with the
# measurement -- an sdef embedded in a __TEXT,__sdef section reads back
# byte-identical with segedit and sdef(1) still will not resolve it. So the
# terminology has to arrive as a FILE named by OSAScriptingDefinition.
#
# ORDER MATTERS, TWICE
#
#   1. Nested code is signed BEFORE the bundle. codesign seals what it finds;
#      sign the bundle first and the dylibs you sign afterwards invalidate the
#      seal you just made.
#   2. The .app is notarized and stapled BEFORE the dmg is built. A ticket on
#      the dmg does not travel with the app when someone drags it out, so that
#      copy can only be validated by calling Apple -- which stalls or fails on
#      a first launch that is offline. The macVM runbook measured exactly this:
#      the dmg passed spctl while the app inside had no ticket.
#
# Unlike Roast this ships no toolchain: one executable, and the two runtime
# dylibs the GPU path needs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="${DIST:-$ROOT/dist/CocoaMojo}"
OUT="${APP_DIR:-$ROOT/build}"
APP="$OUT/Mission Planner.app"
DMG="$OUT/MissionPlanner.dmg"
VER="$(date +%Y.%m.%d)"
SIGN_ID="${SIGN_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

if [ ! -x "$DIST/bin/cocoamojo" ]; then
  echo "no distribution at $DIST -- run ./tools/make-dist.sh first" >&2
  exit 1
fi

echo "== Mission Planner.app =="
rm -rf "$APP" "$DMG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

echo "   compiling"
"$DIST/bin/cocoamojo" --build "$ROOT/examples/moonshot/planner.mojo" \
  -o "$APP/Contents/MacOS/MissionPlanner" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
  -Xlinker "$ROOT/tools/mission-planner-info.plist" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __sdef \
  -Xlinker "$ROOT/examples/moonshot/MissionPlanner.sdef" >/dev/null

# The dylibs, as a CLOSURE rather than a list. libKGENCompilerRTShared pulls
# in libMSupportGlobals and libAsyncRTRuntimeGlobals, and a hand-written list
# of two shipped a bundle that could not launch: dyld fell back to the build
# tree, and once the app was signed with a Team ID it refused that copy --
# "mapping process and mapped file (non-platform) have different Team IDs".
# Unsigned, the fallback had worked and hidden the missing library entirely.
echo "   resolving dylibs"
deps_of() {  # path -> the @rpath leaf names it needs
  otool -L "$1" 2>/dev/null | sed -n 's|^[[:space:]]*@rpath/\([^ ]*\).*|\1|p'
}
pending="$(deps_of "$APP/Contents/MacOS/MissionPlanner")"
copied=""
while [ -n "$pending" ]; do
  next=""
  for lib in $pending; do
    case " $copied " in *" $lib "*) continue ;; esac
    if [ ! -f "$DIST/lib/$lib" ]; then
      echo "   WARNING: $lib not in $DIST/lib" >&2
      copied="$copied $lib"
      continue
    fi
    cp "$DIST/lib/$lib" "$APP/Contents/Frameworks/"
    copied="$copied $lib"
    next="$next $(deps_of "$DIST/lib/$lib")"
  done
  pending="$next"
done
echo "   ${copied# }"
# The binary was linked against the build tree; inside a bundle the dylibs
# live beside it and this is how it finds them there.
install_name_tool -add_rpath "@executable_path/../Frameworks" \
  "$APP/Contents/MacOS/MissionPlanner" 2>/dev/null || true

cp "$ROOT/examples/moonshot/MissionPlanner.sdef" "$APP/Contents/Resources/"

# The icon, if it has been drawn. tools/make-planner-icon.py writes it; the
# name in Resources has to match CFBundleIconFile below.
if [ -f "$ROOT/tools/mission-planner.icns" ]; then
  cp -f "$ROOT/tools/mission-planner.icns" "$APP/Contents/Resources/AppIcon.icns"
  echo "   icon: tools/mission-planner.icns"
else
  echo "   no icon -- run ./tools/make-planner-icon.py" >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Mission Planner</string>
  <key>CFBundleDisplayName</key>       <string>Mission Planner</string>
  <key>CFBundleExecutable</key>        <string>MissionPlanner</string>
  <key>CFBundleIdentifier</key>        <string>org.mojococoa.missionplanner</string>
  <key>CFBundleVersion</key>           <string>$VER</string>
  <key>CFBundleShortVersionString</key><string>$VER</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleSignature</key>         <string>????</string>
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>LSApplicationCategoryType</key> <string>public.app-category.education</string>
  <key>NSHumanReadableCopyright</key>  <string>MojoCocoa</string>
  <key>CFBundleIconFile</key>          <string>AppIcon</string>
  <!-- Scriptable. The events work by raw code without these; what they add
       is the words, and sdef(1) resolves them only for a bundle. -->
  <key>NSAppleScriptEnabled</key>      <true/>
  <key>OSAScriptingDefinition</key>    <string>MissionPlanner.sdef</string>
</dict>
</plist>
PLIST

# ── signing ──────────────────────────────────────────────────────────────
sign_one() {  # path
  if [ -n "$SIGN_ID" ]; then
    codesign --force --options runtime --timestamp \
      --sign "$SIGN_ID" "$1"
  else
    codesign --force --sign - --timestamp=none "$1"
  fi
}

if [ -n "$SIGN_ID" ]; then
  echo "   signing as $SIGN_ID"
  echo "   (hardened runtime and a secure timestamp: both required to notarize,"
  echo "    and the timestamp means this machine must be online)"
else
  echo "   signing ad hoc -- runs here, nowhere else"
fi
# Nested code first; the bundle seal covers what is already signed.
for lib in "$APP/Contents/Frameworks/"*.dylib; do
  [ -f "$lib" ] && sign_one "$lib"
done
sign_one "$APP"

codesign --verify --deep --strict "$APP" \
  && echo "   signature verifies"

if [ -n "$SIGN_ID" ]; then
  codesign -dv --verbose=4 "$APP" 2>&1 \
    | grep -E "^Authority|^Timestamp|^TeamIdentifier|Runtime Version" | sed 's/^/     /'
fi

LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREG" ] && "$LSREG" -f "$APP" || true

# ── notarizing the app, then packaging it ────────────────────────────────
if [ -n "$NOTARY_PROFILE" ]; then
  if [ -z "$SIGN_ID" ]; then
    echo "   NOTARY_PROFILE set without SIGN_ID: Apple will not notarize an" >&2
    echo "   ad-hoc signature. Set both, or neither." >&2
    exit 1
  fi
  echo
  echo "== notarizing the app =="
  # notarytool takes an archive, not a bundle. ditto --keepParent preserves
  # the .app wrapper inside the zip, which is what the service expects.
  ZIP="$OUT/MissionPlanner-app.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$ZIP"
  # Staple the BUNDLE, not the zip: the ticket has to live in the thing the
  # user ends up with.
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi

echo
echo "== disk image =="
STAGE="$OUT/.dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Mission Planner.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Mission Planner" -srcfolder "$STAGE" \
  -ov -format ULFO "$DMG" >/dev/null
rm -rf "$STAGE"
[ -n "$SIGN_ID" ] && codesign --force --sign "$SIGN_ID" --timestamp "$DMG"

if [ -n "$NOTARY_PROFILE" ]; then
  echo
  echo "== notarizing the disk image =="
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

echo
echo "   $APP"
echo "   $DMG ($(du -h "$DMG" | cut -f1))"
if [ -n "$NOTARY_PROFILE" ]; then
  echo
  spctl -a -vv "$APP" 2>&1 | sed 's/^/   /'
fi
echo
echo "   open '$APP'"
echo "   osascript -e 'tell application \"Mission Planner\" to do command \"status\"'"
