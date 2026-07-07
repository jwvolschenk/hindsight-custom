#!/usr/bin/env bash
# Hindsight MCP server launcher for VS Code
# Detects the active workspace and passes --cwd to the MCP server.
#
# Detection strategies (in order):
# 1. HINDSIGHT_CWD env var (user-set override)
# 2. VSCODE_GIT_WORKSPACE_FOLDER env var (VS Code git extension)
# 3. Most recently active LOCAL VS Code workspace from workspaceStorage
# 4. Inherited CWD from VS Code
#
# Use this as the "command" in VS Code mcp.json if the default CWD
# doesn't match your workspace.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="$SCRIPT_DIR/.venv/bin/python3"
ORIGINAL_CWD="$PWD"

# Strategy 1: HINDSIGHT_CWD env var (explicit override)
if [ -n "${HINDSIGHT_CWD:-}" ]; then
    exec "$PYTHON" -m mcp_server --cwd "$HINDSIGHT_CWD"
fi

# Strategy 2: VSCODE_GIT_WORKSPACE_FOLDER (VS Code git extension)
if [ -n "${VSCODE_GIT_WORKSPACE_FOLDER:-}" ]; then
    exec "$PYTHON" -m mcp_server --cwd "$VSCODE_GIT_WORKSPACE_FOLDER"
fi

# Strategy 3: Most recently active LOCAL VS Code workspace
find_vscode_workspace() {
    local ws_dir="${HOME}/.config/Code/User/workspaceStorage"
    [ -d "$ws_dir" ] || return 1

    local newest
    newest=$(find "$ws_dir" -name "workspace.json" -not -name "workspaces.json" \
                  -printf '%T@ %p\n' 2>/dev/null | sort -rn | while read -r ts path; do
        if python3 -c "
import json, sys
with open('$path') as f: d = json.load(f)
uri = d.get('folder', '')
if not uri.startswith('file://'): sys.exit(1)
" 2>/dev/null; then
            echo "$path"
            break
        fi
    done)
    [ -n "$newest" ] || return 1

    python3 -c "
import json, urllib.parse, sys
with open('$newest') as f: d = json.load(f)
uri = d.get('folder', '')
if uri.startswith('file://'):
    print(urllib.parse.unquote(uri[7:]))
else:
    sys.exit(1)
" 2>/dev/null
}

ws_folder=$(find_vscode_workspace) || true
if [ -n "${ws_folder:-}" ] && [ -d "$ws_folder" ]; then
    exec "$PYTHON" -m mcp_server --cwd "$ws_folder"
fi

# Strategy 4: Use the inherited CWD (what VS Code gave us)
exec "$PYTHON" -m mcp_server --cwd "$ORIGINAL_CWD"
