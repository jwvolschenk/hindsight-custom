#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

python3 -m pip install --user --quiet ".[installer]" pyinstaller
python3 -m PyInstaller \
  --onefile \
  --name hindsight-installer \
  --collect-all textual \
  --add-data "install.sh:." \
  --distpath dist \
  --workpath /tmp/hindsight-installer-build \
  --specpath /tmp/hindsight-installer-spec \
  --noconfirm \
  installer/tui.py

echo "Binary: dist/hindsight-installer"
