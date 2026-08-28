#!/usr/bin/env bash
# Package Roast as a Mac application: Roast.app, and a .dmg to hand someone.
#
#   ./tools/make-app.sh              build Roast.app and Roast-<ver>.dmg
#   ./tools/make-app.sh --no-dmg     the bundle only
#   APP_DIR=/tmp/mine ./tools/make-app.sh
#
# Needs a distribution: run ./tools/release.sh first. This does not compile
# anything except Roast itself -- it takes the toolchain the distribution
# already assembled and folds it into a bundle.
#
# WHAT AN APPLICATION HAS TO CARRY
#
# Roast is an IDE, so shipping it means shipping a compiler. Everything the
# editor does beyond typing needs the toolchain: cmd-B runs `cocoamojo`,
# completions and diagnostics come from `mojo-lsp-server`, both need the
# stdlib sources and the Cocoa database, and the Examples menu reads
# share/examples. So the whole distribution goes in Contents/Resources,
# minus one part: include/ is 172 MB of LLVM headers for building out-of-tree
# C++ against the compiler, which no application does.
#
# HOW THE APP FINDS IT
#
# Two mechanisms, one for the loader and one for the program.
#
# The loader: `cocoamojo` bakes an ABSOLUTE rpath into everything it links,
# naming the distribution it built from -- fine on this machine, meaningless
# on anyone else's. The copy in the bundle gets an @executable_path rpath
# added and the absolute one deleted, so it resolves its dylibs wherever the
# .app is dragged.
#
# The program: a double-clicked app inherits no environment, so there is no
# COCOAMOJO_ROOT. `toolchain_root()` in the IDE falls back to asking NSBundle
# where it is, which is why the layout below puts the toolchain exactly at
# Contents/Resources/CocoaMojo and not somewhere prettier.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
D="$ROOT/dist/CocoaMojo"
OUT="${APP_DIR:-$ROOT/dist}"
APP="$OUT/Roast.app"
C="$APP/Contents"

want_dmg=1
[ "${1:-}" = "--no-dmg" ] && want_dmg=0

[ -x "$D/bin/cocoamojo" ] || {
  echo "no distribution at dist/CocoaMojo -- run ./tools/release.sh first"
  exit 1
}

VER="$(date +%Y.%m.%d)"
GITREV="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

echo "== Roast.app =="
rm -rf "$APP"
mkdir -p "$C/MacOS" "$C/Resources"

# ── the toolchain ──────────────────────────────────────────────────────────
# --delete-excluded as well as --delete, so an include/ left by an earlier
# run cannot survive into a bundle that is supposed to be without one.
echo "== toolchain =="
rsync -a --delete --delete-excluded \
      --exclude 'include/' --exclude '.roast.log' \
      "$D/" "$C/Resources/CocoaMojo/"
echo "   $(du -sh "$C/Resources/CocoaMojo" | cut -f1) (include/ left out)"

# ── the executable ─────────────────────────────────────────────────────────
# Built here rather than copied from bin/, so the app always carries the IDE
# at the current source rather than whatever the distribution last assembled.
echo "== roast =="
COCOAMOJO_ROOT="$D" "$D/bin/cocoamojo" --build "$ROOT/ide/roast.mojo" \
    -o "$C/MacOS/Roast" >"$OUT/.roast-app.log" 2>&1 || {
  echo "   FAILED -- see $OUT/.roast-app.log"; exit 1
}
rm -f "$OUT/.roast-app.log"

# From Contents/MacOS, the dylibs are two levels up and across. The absolute
# rpath naming this machine's checkout is deleted rather than left as a
# fallback: leaving it means the app works here and only here, and does so
# silently, which is the worst way to find out.
install_name_tool -add_rpath "@executable_path/../Resources/CocoaMojo/lib" \
    "$C/MacOS/Roast" 2>/dev/null || true
install_name_tool -delete_rpath "$D/lib" "$C/MacOS/Roast" 2>/dev/null || true
echo "   $(stat -f%z "$C/MacOS/Roast" | awk '{printf "%.0f KB", $1/1024}'), rpath relocated"

# ── the bundle's paperwork ─────────────────────────────────────────────────
# LSMinimumSystemVersion matches what the toolchain needs; NSHighResolution
# because a text editor on a blurry backing store is unusable. The document
# type makes .mojo files openable with Roast from the Finder -- Roast does
# not implement application:openFile: yet, so this advertises rather than
# promises, and is the next thing to wire.
cat > "$C/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Roast</string>
  <key>CFBundleDisplayName</key>       <string>Roast</string>
  <key>CFBundleExecutable</key>        <string>Roast</string>
  <key>CFBundleIdentifier</key>        <string>org.mojococoa.roast</string>
  <key>CFBundleVersion</key>           <string>$VER</string>
  <key>CFBundleShortVersionString</key><string>$VER</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleSignature</key>         <string>????</string>
  <key>LSMinimumSystemVersion</key>    <string>15.0</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>MojoCocoaSourceRevision</key>   <string>$GITREV</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>      <string>Mojo source</string>
      <key>CFBundleTypeRole</key>      <string>Editor</string>
      <key>LSItemContentTypes</key>    <array><string>public.plain-text</string></array>
      <key>CFBundleTypeExtensions</key><array><string>mojo</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST
printf 'APPL????' > "$C/PkgInfo"

# An icon if one has been drawn; the generic app icon otherwise. Named rather
# than assumed, so adding tools/roast.icns is all it takes.
if [ -f "$ROOT/tools/roast.icns" ]; then
  cp -f "$ROOT/tools/roast.icns" "$C/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" \
      "$C/Info.plist" >/dev/null
  echo "   icon: tools/roast.icns"
fi

# ── signing ────────────────────────────────────────────────────────────────
# Ad-hoc, and deep: an unsigned bundle on Apple Silicon will not launch at
# all, and every nested Mach-O needs its own signature. This is not
# notarisation -- someone downloading the .dmg still has to allow it once in
# System Settings -- but it is the difference between "asks permission" and
# "is killed on sight".
echo "== signing =="
if codesign --force --deep --sign - --timestamp=none "$APP" 2>/dev/null; then
  codesign --verify --deep "$APP" 2>/dev/null \
    && echo "   ad-hoc signed and verified" \
    || echo "   WARNING: signed but verification failed"
else
  echo "   WARNING: could not sign -- the app may not launch"
fi

echo
echo "$APP ($(du -sh "$APP" | cut -f1))"

[ "$want_dmg" = 0 ] && exit 0

# ── the disk image ─────────────────────────────────────────────────────────
# A staging folder with the app and a symlink to /Applications, which is the
# drag-here convention every Mac user already knows. UDBZ compresses hardest,
# which matters: the Cocoa database alone is a third of a gigabyte and is
# exactly the sort of thing bzip2 is good at.
echo "== disk image =="
DMG="$OUT/Roast-$VER.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/Roast.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/README.txt" <<TXT
Roast $VER ($GITREV)

An IDE for cocoa-mojo, written in cocoa-mojo. Drag Roast to Applications.

It carries its own toolchain -- compiler, language server, standard library
and the Cocoa database -- so cmd-B builds and cmd-R runs with nothing else
installed. The Examples menu opens the projects it ships with.

First launch: macOS will refuse an app it has not seen before. Right-click
Roast and choose Open, or allow it in System Settings > Privacy & Security.
This build is ad-hoc signed, not notarised.

Requires Apple Silicon and macOS 15 or later.
TXT

rm -f "$DMG"
hdiutil create -quiet -srcfolder "$STAGE" -volname "Roast $VER" \
    -format UDBZ -fs HFS+ "$DMG"
echo "   $DMG ($(du -sh "$DMG" | cut -f1))"
echo
echo "open $DMG"
