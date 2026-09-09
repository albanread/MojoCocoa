#!/usr/bin/env bash
# Package Trench as a Mac application: Trench.app.
#
#   ./tools/make-trench-app.sh                 build into ./build/Trench.app
#   APP_DIR=/Applications ./tools/make-trench-app.sh
#
# Why a bundle and not the bare binary. The binary already carries a
# __TEXT,__info_plist, which is enough for a Dock icon and a menu bar. It is
# NOT enough for AppleScript to find the app by name: `tell application
# "Trench"` asks Launch Services, and Launch Services only knows about
# bundles. tools/make-app.sh records the same finding for Roast and adds the
# measurement -- the sdef embedded in a __TEXT,__sdef section reads back
# byte-identical with segedit, and sdef(1) still will not resolve it. So the
# terminology has to arrive as a FILE in Contents/Resources, named by
# OSAScriptingDefinition.
#
# Unlike Roast, Trench ships no toolchain: it is one executable and the two
# runtime dylibs the GPU path needs. Everything else it draws it computes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="${DIST:-$ROOT/dist/CocoaMojo}"
OUT="${APP_DIR:-$ROOT/build}"
APP="$OUT/Trench.app"
VER="$(date +%Y.%m.%d)"

if [ ! -x "$DIST/bin/cocoamojo" ]; then
  echo "no distribution at $DIST -- run ./tools/make-dist.sh first" >&2
  exit 1
fi

echo "== Trench.app =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

# The executable. Built here rather than copied, so the app is never stale
# against the source, and with the two sections the bare binary wants too:
# the plist is what gives the process its identity before Launch Services
# has any say, which is what the TCC prompts read.
echo "   compiling"
"$DIST/bin/cocoamojo" --build "$ROOT/examples/moonshot/trench.mojo" \
  -o "$APP/Contents/MacOS/Trench" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
  -Xlinker "$ROOT/tools/trench-info.plist" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __sdef \
  -Xlinker "$ROOT/examples/moonshot/Trench.sdef"

# The two dylibs, and an rpath that finds them inside the bundle rather than
# in the build tree the binary was linked in.
for lib in libKGENCompilerRTShared.dylib libCocoaMojoGPU.dylib; do
  if [ -f "$DIST/lib/$lib" ]; then
    cp "$DIST/lib/$lib" "$APP/Contents/Frameworks/"
  else
    echo "   WARNING: $lib not in $DIST/lib" >&2
  fi
done
install_name_tool -add_rpath "@executable_path/../Frameworks" \
  "$APP/Contents/MacOS/Trench" 2>/dev/null || true

cp "$ROOT/examples/moonshot/Trench.sdef" "$APP/Contents/Resources/Trench.sdef"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Trench</string>
  <key>CFBundleDisplayName</key>       <string>Trench</string>
  <key>CFBundleExecutable</key>        <string>Trench</string>
  <key>CFBundleIdentifier</key>        <string>org.mojococoa.trench</string>
  <key>CFBundleVersion</key>           <string>$VER</string>
  <key>CFBundleShortVersionString</key><string>$VER</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleSignature</key>         <string>????</string>
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <!-- Scriptable. The events work by raw code without this; what the two
       keys add is the words, and sdef(1) resolves them only for a bundle. -->
  <key>NSAppleScriptEnabled</key>      <true/>
  <key>OSAScriptingDefinition</key>    <string>Trench.sdef</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: unsigned bundles are refused outright on Apple silicon.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true

# Tell Launch Services it exists, which is the step that makes
# `tell application "Trench"` resolve without opening the app once by hand.
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREG" ] && "$LSREG" -f "$APP" || true

echo "   $APP ($(du -sh "$APP" | cut -f1))"
echo
echo "   open $APP"
echo "   osascript -e 'tell application \"Trench\" to do command \"status\"'"
