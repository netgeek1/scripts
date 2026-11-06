#!/usr/bin/env bash
#
# Build a single self-contained audiobook-tagger binary (no Python install
# needed to RUN the result).
#
# Creates a throwaway virtual environment, installs mutagen plus the optional
# libraries, and runs PyInstaller to produce one portable executable. Python IS
# required to BUILD (run this once); it is NOT required to run the result on
# another machine of the same OS/arch.
#
# Output:  ./dist/audiobook-tagger
#
# Usage:
#   ./build.sh                 # normal build
#   ./build.sh --clean         # wipe build/ dist/ *.spec first
#   SCRIPT=foo.py ./build.sh   # bundle a different source file
#
# Notes:
#   - Build on the same OS/arch you want the binary for (a Linux build makes a
#     Linux binary; it will not run on Windows or macOS).
#   - mutagen is GPL-2.0-or-later. A bundled binary that embeds it is, as a
#     whole, covered by the GPL. Shipping the .py with deps installed separately
#     keeps them independent works. Fine for personal use either way.

set -euo pipefail
cd "$(dirname "$0")"

SCRIPT="${SCRIPT:-audiobook_tagger.py}"
NAME="${NAME:-audiobook-tagger}"
VENV="${VENV:-.build-venv}"

# ---- options -------------------------------------------------------------
CLEAN=0
for arg in "$@"; do
    case "$arg" in
        --clean) CLEAN=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

if [[ ! -f "$SCRIPT" ]]; then
    echo "error: source script '$SCRIPT' not found next to this build script." >&2
    exit 1
fi

# ---- find python ---------------------------------------------------------
PY=""
for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
done
if [[ -z "$PY" ]]; then
    echo "error: no python3 found. Install Python 3.9+ and re-run." >&2
    exit 1
fi
echo "Using Python: $("$PY" --version 2>&1)"

if [[ "$CLEAN" == "1" ]]; then
    echo "Cleaning build/ dist/ *.spec ..."
    rm -rf build dist ./*.spec
fi

# ---- isolated build venv -------------------------------------------------
if [[ ! -d "$VENV" ]]; then
    echo "Creating build venv in $VENV ..."
    "$PY" -m venv "$VENV"
fi
VENV_PY="$VENV/bin/python"

echo "Installing build dependencies ..."
"$VENV_PY" -m pip install --upgrade pip >/dev/null
# mutagen is the only hard dependency; the rest light up optional features.
"$VENV_PY" -m pip install mutagen rapidfuzz Pillow PyYAML certifi pyinstaller

# ---- build ---------------------------------------------------------------
ICON_ARGS=()
# PyInstaller on Linux ignores --icon for ELF binaries; left out by design.

echo "Running PyInstaller ..."
"$VENV_PY" -m PyInstaller \
    --onefile \
    --console \
    --name "$NAME" \
    --collect-submodules mutagen \
    --collect-data certifi \
    --noconfirm \
    "${ICON_ARGS[@]}" \
    "$SCRIPT"

OUT="dist/$NAME"
if [[ -f "$OUT" ]]; then
    SIZE="$(du -h "$OUT" | cut -f1)"
    echo ""
    echo "Built: $OUT  ($SIZE)"
    echo "Test it:  $OUT --version"
    echo ""
    echo "Copy that single file to any same-OS/arch machine - no Python needed."
else
    echo "error: build finished but '$OUT' was not found." >&2
    exit 1
fi
