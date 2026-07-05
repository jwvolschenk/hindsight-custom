#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BUILD_VENV="/tmp/hindsight-build-venv"

# Use a venv to avoid PEP 668 issues with system Python
echo "Setting up build environment ..."
python3 -m venv "$BUILD_VENV"
"$BUILD_VENV/bin/pip" install --quiet ".[installer]" pyinstaller

echo "Building binary ..."
"$BUILD_VENV/bin/python" -m PyInstaller \
  --onefile \
  --name hindsight-installer-linux-x86_64 \
  --collect-all textual \
  --add-data "$ROOT_DIR/install.sh:." \
  --distpath dist \
  --workpath /tmp/hindsight-installer-build \
  --specpath /tmp/hindsight-installer-spec \
  --noconfirm \
  installer/tui.py

rm -rf "$BUILD_VENV" /tmp/hindsight-installer-build /tmp/hindsight-installer-spec
echo "Binary: dist/hindsight-installer-linux-x86_64"
