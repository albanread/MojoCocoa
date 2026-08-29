#!/usr/bin/env bash
# Copy a relocatable, in-process CPython runtime into a Roast Resources folder.
#
#   tools/bundle-python.sh DEST [PYTHON]
#
# DEST receives Python.framework. PYTHON defaults to ROAST_PYTHON or python3.
# A framework build is required: Mojo loads its Python library in-process, and
# the matching executable is also what creates/manages each project venv.
set -euo pipefail

DEST="${1:?usage: bundle-python.sh DEST [PYTHON]}"
PYTHON_BIN="${2:-${ROAST_PYTHON:-$(command -v python3 || true)}}"
[ -x "$PYTHON_BIN" ] || { echo "no Python interpreter found" >&2; exit 1; }

PYVER="$($PYTHON_BIN -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
FRAMEWORKS="$($PYTHON_BIN -c 'import sysconfig; print(sysconfig.get_config_var("PYTHONFRAMEWORKPREFIX") or "")')"
SOURCE="$FRAMEWORKS/Python.framework"
[ -f "$SOURCE/Versions/$PYVER/Python" ] || {
  echo "$PYTHON_BIN is not a macOS framework build of Python" >&2
  exit 1
}

TARGET="$DEST/Python.framework"
VERSION="$TARGET/Versions/$PYVER"
LIB="$VERSION/lib"
LICENSES="$DEST/Licenses"

rm -rf "$TARGET" "$LICENSES"
mkdir -p "$DEST" "$LICENSES"
rsync -a --exclude '__pycache__/' "$SOURCE/" "$TARGET/"
printf '%s\n' "$PYVER" > "$DEST/VERSION"
# CPython's regression suite is not part of an embedded runtime and is roughly
# half of the standard-library payload. ensurepip, venv, headers and config
# files stay: pip may need all of them to build a source distribution.
rm -rf "$VERSION/lib/python$PYVER/test"

is_macho() {
  file -b "$1" 2>/dev/null | grep -q 'Mach-O'
}

macho_files() {
  find "$TARGET" -type f -print0
}

is_system_dependency() {
  case "$1" in
    /System/Library/*|/usr/lib/*|@*) return 0 ;;
    *) return 1 ;;
  esac
}

copy_license() {
  dep="$1"
  prefix="${dep%%/lib/*}"
  [ "$prefix" != "$dep" ] || return 0
  license="$(find -L "$prefix" -maxdepth 2 -type f \
    \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'NOTICE*' \) \
    -print 2>/dev/null | head -1 || true)"
  [ -n "$license" ] || return 0
  cp -f "$license" "$LICENSES/$(basename "$prefix")-$(basename "$license")"
}

# Copy the non-system dylib closure used by stdlib extension modules. A
# Homebrew Python otherwise appears bundled but imports such as ssl, sqlite3,
# decimal and lzma still reach back into /opt/homebrew.
changed=1
while [ "$changed" = 1 ]; do
  changed=0
  while IFS= read -r -d '' binary; do
    is_macho "$binary" || continue
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      is_system_dependency "$dep" && continue
      case "$dep" in
        *Python.framework/Versions/$PYVER/Python) continue ;;
      esac
      [ -f "$dep" ] || continue
      out="$LIB/$(basename "$dep")"
      if [ ! -f "$out" ]; then
        cp -L "$dep" "$out"
        chmod u+w "$out"
        copy_license "$dep"
        changed=1
      fi
    done < <(otool -L "$binary" | tail -n +2 | sed -E 's/^[[:space:]]*([^ ]+).*/\1/')
  done < <(macho_files)
done

relocated_dependency() {
  consumer="$1"
  name="$2"
  case "$consumer" in
    "$VERSION"/lib/python$PYVER/lib-dynload/*)
      printf '@loader_path/../../%s' "$name" ;;
    "$VERSION"/lib/*)
      printf '@loader_path/%s' "$name" ;;
    "$VERSION"/bin/*)
      printf '@executable_path/../lib/%s' "$name" ;;
    "$VERSION"/Resources/Python.app/Contents/MacOS/*)
      printf '@executable_path/../../../../lib/%s' "$name" ;;
    *)
      printf '@loader_path/%s' "$name" ;;
  esac
}

# Relocate the framework reference in its launchers and every copied absolute
# dylib reference. Direct @loader_path/@executable_path references avoid
# relying on rpaths inherited from the packaging machine.
while IFS= read -r -d '' binary; do
  is_macho "$binary" || continue
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    case "$dep" in
      *Python.framework/Versions/$PYVER/Python)
        [ "$binary" = "$VERSION/Python" ] && continue
        case "$binary" in
          "$VERSION"/bin/*) replacement='@executable_path/../Python' ;;
          "$VERSION"/Resources/Python.app/Contents/MacOS/*)
            replacement='@executable_path/../../../../Python' ;;
          *) replacement='@loader_path/Python' ;;
        esac
        install_name_tool -change "$dep" "$replacement" "$binary" 2>/dev/null
        ;;
      /*)
        is_system_dependency "$dep" && continue
        replacement="$(relocated_dependency "$binary" "$(basename "$dep")")"
        install_name_tool -change "$dep" "$replacement" "$binary" 2>/dev/null
        ;;
    esac
  done < <(otool -L "$binary" | tail -n +2 | sed -E 's/^[[:space:]]*([^ ]+).*/\1/')
done < <(macho_files)

install_name_tool -id "@rpath/Python.framework/Versions/$PYVER/Python" \
  "$VERSION/Python" 2>/dev/null
while IFS= read -r -d '' dylib; do
  install_name_tool -id "@rpath/$(basename "$dylib")" "$dylib" 2>/dev/null
done < <(find "$LIB" -maxdepth 1 -type f -name '*.dylib' -print0)

# A copied Homebrew interpreter contains its build prefix. PYTHONHOME is the
# relocation contract Roast supplies both to venv/pip and to the Mojo program.
# Sign every Mach-O before sealing the framework. `codesign --deep` discovers
# nested bundles but does not reliably replace signatures on loose extension
# modules, and dyld kills the interpreter the first time one of those is read.
# The outer app packaging signs the final bundle again.
while IFS= read -r -d '' binary; do
  is_macho "$binary" || continue
  codesign --force --sign - --timestamp=none "$binary" >/dev/null 2>&1
done < <(macho_files)
codesign --force --deep --sign - --timestamp=none "$TARGET" >/dev/null 2>&1

bad="$(
  while IFS= read -r -d '' binary; do
    is_macho "$binary" || continue
    otool -L "$binary" | tail -n +2 | sed -E 's/^[[:space:]]*([^ ]+).*/\1/'
  done < <(macho_files) |
    grep '^/' | grep -vE '^(/System/Library/|/usr/lib/)' || true
)"
[ -z "$bad" ] || {
  echo "absolute non-system Python dependencies remain:" >&2
  printf '  %s\n' "$bad" >&2
  exit 1
}

SMOKE="$(mktemp -d)"
trap 'rm -rf "$SMOKE"' EXIT
PYTHONHOME="$VERSION" "$VERSION/bin/python3" -c \
  'import ssl, sqlite3, venv; print("python", __import__("sys").version.split()[0], ssl.OPENSSL_VERSION, sqlite3.sqlite_version)'
PYTHONHOME="$VERSION" "$VERSION/bin/python3" -m venv "$SMOKE/env"
PYTHONHOME="$VERSION" "$SMOKE/env/bin/python" -m pip --version

echo "   CPython $PYVER: $(du -sh "$DEST" | cut -f1), relocatable, venv + pip OK"
