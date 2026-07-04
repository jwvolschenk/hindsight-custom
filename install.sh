#!/usr/bin/env bash
# Hindsight Project Memory — Unified Installer
#
# Installs the MCP server and agent-specific integrations for:
#   - Hermes Agent (memory provider plugin)
#   - Claude Code (MCP + hooks)
#   - OpenCode (MCP config)
#   - Codex CLI (MCP + hooks)
#   - GitHub Copilot (MCP + instructions)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/jwvolschenk/hindsight-custom/main/install.sh | bash
#   ./install.sh --agents claude-code,codex    # skip prompt, install specific agents
#   ./install.sh --all                          # skip prompt, install all
#   ./install.sh --uninstall                    # remove everything
#
set -euo pipefail

REPO="jwvolschenk/hindsight-custom"
BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/$REPO/$BRANCH"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hindsight-custom"
CONFIG_FILE="$CONFIG_DIR/config.json"
TEMP_DIR=$(mktemp -d)

# Defaults
INSTALL_AGENTS=""
UNINSTALL=false

# Interactive read — works when piped (curl | bash) by reading from /dev/tty
ask() {
    local prompt="$1"
    local varname="$2"
    local default="${3:-}"
    if [ -t 0 ]; then
        # stdin is a terminal — normal read
        read -rp "$prompt" "$varname"
    elif [ -r /dev/tty ]; then
        # stdin is a pipe (curl | bash) — read from terminal directly
        printf "%s" "$prompt" > /dev/tty
        read -r "$varname" < /dev/tty
    else
        # No terminal available — use default
        eval "$varname='$default'"
    fi
}

# Backup a config file before modifying it
backup() {
    local file="$1"
    if [ -f "$file" ]; then
        local backup_dir="${CONFIG_DIR}/backups"
        mkdir -p "$backup_dir"
        local ts=$(date +%Y%m%d_%H%M%S)
        local base=$(basename "$file")
        local backup="$backup_dir/${base}.${ts}.bak"
        cp "$file" "$backup"
        echo "      Backed up: $file -> $backup"
    fi
}

cleanup() { rm -rf "$TEMP_DIR"; }
trap cleanup EXIT

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --agents) INSTALL_AGENTS="$2"; shift 2 ;;
        --all) INSTALL_AGENTS="all"; shift ;;
        --uninstall) UNINSTALL=true; shift ;;
        -h|--help)
            echo "Usage: install.sh [--agents hermes,claude-code,...] [--all] [--uninstall]"
            echo ""
            echo "Options:"
            echo "  --agents LIST   Comma-separated list of agents to install"
            echo "  --all           Install all agents without prompting"
            echo "  --uninstall     Remove everything"
            echo "  -h, --help      Show this help"
            echo ""
            echo "Available agents: hermes, claude-code, opencode, codex, copilot"
            exit 0
            ;;
        *) echo "Unknown option: $1 (try --help)"; exit 1 ;;
    esac
done

echo "=== Hindsight Project Memory Installer ==="
echo ""

# --- Detect installed agents -------------------------------------------------

declare -A AGENT_FOUND
AGENT_LIST="hermes claude-code opencode codex copilot"

detect_agents() {
    # Hermes Agent
    if [ -d "$HOME/.hermes" ] && [ -f "$HOME/.hermes/config.yaml" ]; then
        AGENT_FOUND[hermes]="Hermes Agent (~/.hermes)"
    fi

    # Claude Code
    if command -v claude &>/dev/null || [ -d "$HOME/.claude" ]; then
        AGENT_FOUND[claude-code]="Claude Code"
    fi

    # OpenCode
    if command -v opencode &>/dev/null || [ -f "$HOME/.config/opencode/opencode.json" ]; then
        AGENT_FOUND[opencode]="OpenCode"
    fi

    # Codex CLI
    if command -v codex &>/dev/null || [ -d "$HOME/.codex" ]; then
        AGENT_FOUND[codex]="Codex CLI"
    fi

    # GitHub Copilot (VS Code)
    if [ -d "$HOME/.vscode" ] || command -v code &>/dev/null; then
        AGENT_FOUND[copilot]="GitHub Copilot (VS Code)"
    fi
}

prompt_user() {
    local detected_count=${#AGENT_FOUND[@]}

    if [ "$detected_count" -eq 0 ]; then
        echo "No supported agents detected."
        echo "Available agents: $AGENT_LIST"
        echo ""
        ask "Enter agents to install (comma-separated, or 'all'): " choice ""
        if [ -z "$choice" ]; then
            echo "No agents selected. Exiting."
            exit 0
        fi
        INSTALL_AGENTS="$choice"
        return
    fi

    echo "Detected agents:"
    echo ""
    local i=1
    local -a AGENT_KEYS=()
    for agent in $AGENT_LIST; do
        if [ -n "${AGENT_FOUND[$agent]+x}" ]; then
            echo "  [$i] ${AGENT_FOUND[$agent]} ($agent)"
            AGENT_KEYS+=("$agent")
            i=$((i + 1))
        fi
    done
    echo ""
    echo "  [A] All detected agents"
    echo "  [M] Manual selection (type agent names)"
    echo ""

    ask "Select agents to install [A]: " choice "A"
    choice="${choice:-A}"

    if [ "$choice" = "A" ] || [ "$choice" = "a" ]; then
        INSTALL_AGENTS=$(IFS=,; echo "${AGENT_KEYS[*]}")
    elif [ "$choice" = "M" ] || [ "$choice" = "m" ]; then
        echo ""
        echo "Available: $AGENT_LIST"
        ask "Enter agents (comma-separated): " INSTALL_AGENTS ""
    elif [[ "$choice" =~ ^[0-9]+$ ]]; then
        # Single number selection
        local idx=$((choice - 1))
        if [ "$idx" -ge 0 ] && [ "$idx" -lt ${#AGENT_KEYS[@]} ]; then
            INSTALL_AGENTS="${AGENT_KEYS[$idx]}"
        else
            echo "Invalid selection."
            exit 1
        fi
    elif [[ "$choice" =~ ^[0-9,]+$ ]]; then
        # Multiple numbers like "1,3"
        local selected=""
        IFS=',' read -ra NUMS <<< "$choice"
        for num in "${NUMS[@]}"; do
            local idx=$((num - 1))
            if [ "$idx" -ge 0 ] && [ "$idx" -lt ${#AGENT_KEYS[@]} ]; then
                [ -n "$selected" ] && selected="$selected,"
                selected="$selected${AGENT_KEYS[$idx]}"
            fi
        done
        INSTALL_AGENTS="$selected"
    else
        INSTALL_AGENTS="$choice"
    fi

    if [ -z "$INSTALL_AGENTS" ]; then
        echo "No agents selected. Exiting."
        exit 0
    fi

    echo ""
    echo "Will install for: $INSTALL_AGENTS"
    echo ""
}

should_install() {
    local agent="$1"
    if [ "$INSTALL_AGENTS" = "all" ]; then return 0; fi
    echo ",$INSTALL_AGENTS," | grep -q ",$agent," 2>/dev/null
}

# --- Detect and prompt -------------------------------------------------------

detect_agents

if [ -z "$INSTALL_AGENTS" ]; then
    prompt_user
fi

echo "Installing for: $INSTALL_AGENTS"
echo ""

# --- Fetch source -----------------------------------------------------------

echo "[*] Fetching source ..."
FETCHED=false

if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
    if gh repo clone "$REPO" "$TEMP_DIR/repo" -- --depth=1 --quiet 2>/dev/null; then
        FETCHED=true
    fi
fi

if ! $FETCHED; then
    if git clone --depth=1 "git@github.com:$REPO.git" "$TEMP_DIR/repo" --quiet 2>/dev/null; then
        FETCHED=true
    fi
fi

if ! $FETCHED; then
    mkdir -p "$TEMP_DIR/flat"
    for f in core/__init__.py core/project.py core/config.py core/client.py \
             mcp_server/__init__.py mcp_server/__main__.py mcp_server/server.py \
             pyproject.toml; do
        curl -fsSL "$BASE_URL/$f" -o "$TEMP_DIR/flat/$(basename "$f")" 2>/dev/null || true
    done
    FETCHED=true
fi

if ! $FETCHED; then
    echo "ERROR: Could not fetch source from github.com:$REPO"
    exit 1
fi

# Resolve source root
if [ -d "$TEMP_DIR/repo/core" ]; then
    SRC="$TEMP_DIR/repo"
elif [ -d "$TEMP_DIR/flat" ]; then
    SRC="$TEMP_DIR/flat"
else
    echo "ERROR: Source not found after fetch."
    exit 1
fi

# --- Uninstall ---------------------------------------------------------------

if $UNINSTALL; then
    echo "[*] Uninstalling ..."

    rm -rf "$HOME/.hermes/plugins/hindsight-custom" 2>/dev/null || true
    rm -rf "$HOME/.hermes/hindsight-custom" 2>/dev/null || true
    if [ -f "$HOME/.hermes/config.yaml" ]; then
        sed -i 's/provider: hindsight-custom/provider: hindsight/' "$HOME/.hermes/config.yaml" 2>/dev/null || true
    fi
    echo "  [x] Hermes plugin removed"

    rm -f "$HOME/.claude/hooks/hindsight-recall.sh" 2>/dev/null || true
    rm -f "$HOME/.claude/hooks/hindsight-retain.sh" 2>/dev/null || true
    echo "  [x] Claude Code hooks removed"

    rm -rf "$CONFIG_DIR" 2>/dev/null || true
    echo "  [x] Config removed"

    echo ""
    echo "=== Uninstalled ==="
    echo "MCP server configs in agent configs were NOT modified."
    echo "Remove the 'hindsight' entry from your agent configs manually."
    exit 0
fi

# --- Install core ------------------------------------------------------------

echo "[1/6] Installing core library ..."
INSTALL_DIR="$CONFIG_DIR/lib"
mkdir -p "$INSTALL_DIR/core" "$INSTALL_DIR/mcp_server"
cp "$SRC/core/__init__.py" "$INSTALL_DIR/core/"
cp "$SRC/core/project.py" "$INSTALL_DIR/core/"
cp "$SRC/core/config.py" "$INSTALL_DIR/core/"
cp "$SRC/core/client.py" "$INSTALL_DIR/core/"
cp "$SRC/mcp_server/__init__.py" "$INSTALL_DIR/mcp_server/"
cp "$SRC/mcp_server/__main__.py" "$INSTALL_DIR/mcp_server/"
cp "$SRC/mcp_server/server.py" "$INSTALL_DIR/mcp_server/"
echo "      $INSTALL_DIR/"

# --- Install Python dependencies -------------------------------------------

echo "[2/6] Installing Python dependencies ..."
DEPS_INSTALLED=false
if command -v pip3 &>/dev/null; then
    pip3 install --user --quiet hindsight-client mcp 2>/dev/null && DEPS_INSTALLED=true || true
fi
if ! $DEPS_INSTALLED && command -v pip &>/dev/null; then
    pip install --user --quiet hindsight-client mcp 2>/dev/null && DEPS_INSTALLED=true || true
fi
if ! $DEPS_INSTALLED && command -v uv &>/dev/null; then
    uv pip install --quiet hindsight-client mcp 2>/dev/null && DEPS_INSTALLED=true || true
fi
if ! $DEPS_INSTALLED; then
    echo "      WARNING: Could not auto-install deps."
    echo "      Run manually: pip install hindsight-client mcp"
fi

# --- Config ------------------------------------------------------------------

echo "[3/6] Setting up config ..."
mkdir -p "$CONFIG_DIR"

HAS_KEY=false
API_URL="https://api.hindsight.vectorize.io"
API_KEY=""

# Check for existing key in env
if [ -n "${HINDSIGHT_API_KEY:-}" ]; then
    HAS_KEY=true
    API_KEY="$HINDSIGHT_API_KEY"
fi
if [ -f "$HOME/.hermes/.env" ] && grep -q "HINDSIGHT_API_KEY" "$HOME/.hermes/.env" 2>/dev/null; then
    HAS_KEY=true
fi

if [ -f "$CONFIG_FILE" ]; then
    echo "      Config exists: $CONFIG_FILE"
    if command -v python3 &>/dev/null; then
        EXISTING_URL=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('api_url',''))" 2>/dev/null || echo "")
        EXISTING_KEY=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('apiKey',''))" 2>/dev/null || echo "")
        [ -n "$EXISTING_URL" ] && API_URL="$EXISTING_URL"
        [ -n "$EXISTING_KEY" ] && API_KEY="$EXISTING_KEY" && HAS_KEY=true
    fi
    echo ""
    ask "      Reconfigure endpoint and key? [y/N]: " reconfig "N"
    if [ "$reconfig" != "y" ] && [ "$reconfig" != "Y" ]; then
        echo "      Keeping existing config."
    else
        # Fall through to prompts below
        rm -f "$CONFIG_FILE"
    fi
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo ""
    echo "      Hindsight API Configuration"
    echo "      ─────────────────────────────"
    echo ""
    echo "      [1] Default (https://api.hindsight.vectorize.io — cloud)"
    echo "      [2] Self-hosted (enter your own URL)"
    echo ""
    ask "      Select endpoint [1]: " endpoint_choice "1"
    endpoint_choice="${endpoint_choice:-1}"

    if [ "$endpoint_choice" = "2" ]; then
        ask "      Enter Hindsight API URL: " custom_url ""
        if [ -n "$custom_url" ]; then
            API_URL="$custom_url"
        fi
    fi

    echo ""
    ask "      Enter API key (leave blank to skip): " entered_key ""
    if [ -n "$entered_key" ]; then
        API_KEY="$entered_key"
        HAS_KEY=true
    fi

    # Write config
    python3 -c "
import json
config = {
    'api_url': '$API_URL',
    'apiKey': '$API_KEY',
    'timeout': 300,
    'budget': 'mid',
    'search_shared': True,
    'auto_retain': True,
    'retain_every_n_turns': 3,
    'recall_max_input_chars': 800
}
with open('$CONFIG_FILE', 'w') as f:
    json.dump(config, f, indent=2)
    f.write('\n')
" 2>/dev/null || cat > "$CONFIG_FILE" <<DEFAULT_CFG
{
  "api_url": "$API_URL",
  "apiKey": "$API_KEY",
  "timeout": 300,
  "budget": "mid",
  "search_shared": true,
  "auto_retain": true,
  "retain_every_n_turns": 3,
  "recall_max_input_chars": 800
}
DEFAULT_CFG

    echo ""
    echo "      Created: $CONFIG_FILE"
fi

# --- Check credentials ------------------------------------------------------

echo "[4/6] Checking credentials ..."
if $HAS_KEY; then
    echo "      API key configured."
else
    echo "      WARNING: No API key set."
    echo "      Edit $CONFIG_FILE and set 'apiKey', or export HINDSIGHT_API_KEY"
fi

# --- Install agent integrations ---------------------------------------------

echo "[5/6] Installing agent integrations ..."

# Hermes Agent
if should_install hermes; then
    HERMES_PLUGIN_DIR="$HOME/.hermes/plugins/hindsight-custom"
    mkdir -p "$HERMES_PLUGIN_DIR"
    cp "$SRC/integrations/hermes/__init__.py" "$HERMES_PLUGIN_DIR/"
    if [ ! -d "$HERMES_PLUGIN_DIR/core" ]; then
        ln -s "$INSTALL_DIR/core" "$HERMES_PLUGIN_DIR/core" 2>/dev/null || \
        cp -r "$INSTALL_DIR/core" "$HERMES_PLUGIN_DIR/core"
    fi
    HERMES_CONFIG="$HOME/.hermes/config.yaml"
    backup "$HERMES_CONFIG"
    if [ -f "$HERMES_CONFIG" ]; then
        if grep -q "provider: hindsight-custom" "$HERMES_CONFIG"; then
            echo "  [✓] Hermes — already active"
        elif grep -q "provider: hindsight" "$HERMES_CONFIG"; then
            sed -i 's/provider: hindsight$/provider: hindsight-custom/' "$HERMES_CONFIG"
            echo "  [✓] Hermes — activated (hindsight -> hindsight-custom)"
        else
            echo "  [~] Hermes — set memory.provider: hindsight-custom in config.yaml"
        fi
    else
        echo "  [~] Hermes — set memory.provider: hindsight-custom in config.yaml"
    fi
else
    echo "  [-] Hermes — skipped"
fi

# Claude Code
if should_install claude-code; then
    CLAUDE_DIR="$HOME/.claude"
    CLAUDE_SETTINGS="$CLAUDE_DIR/settings.json"
    mkdir -p "$CLAUDE_DIR/hooks"

    if [ -f "$SRC/integrations/claude-code/hooks/recall.sh" ]; then
        cp "$SRC/integrations/claude-code/hooks/recall.sh" "$CLAUDE_DIR/hooks/hindsight-recall.sh"
        chmod +x "$CLAUDE_DIR/hooks/hindsight-recall.sh"
    fi
    if [ -f "$SRC/integrations/claude-code/hooks/retain.sh" ]; then
        cp "$SRC/integrations/claude-code/hooks/retain.sh" "$CLAUDE_DIR/hooks/hindsight-retain.sh"
        chmod +x "$CLAUDE_DIR/hooks/hindsight-retain.sh"
    fi

    if [ -f "$CLAUDE_SETTINGS" ] && command -v python3 &>/dev/null; then
        backup "$CLAUDE_SETTINGS"
        python3 -c "
import json
with open('$CLAUDE_SETTINGS') as f:
    cfg = json.load(f)
if 'mcpServers' not in cfg:
    cfg['mcpServers'] = {}
cfg['mcpServers']['hindsight'] = {
    'command': 'python3',
    'args': ['-m', 'mcp_server'],
    'cwd': '$INSTALL_DIR',
}
with open('$CLAUDE_SETTINGS', 'w') as f:
    json.dump(cfg, f, indent=2)
" 2>/dev/null && echo "  [✓] Claude Code — MCP server + hooks configured" || \
        echo "  [~] Claude Code — hooks installed, add MCP server to settings.json manually"
    else
        mkdir -p "$CLAUDE_DIR"
        cat > "$CLAUDE_SETTINGS" <<CLAUDE_CFG
{
  "mcpServers": {
    "hindsight": {
      "command": "python3",
      "args": ["-m", "mcp_server"],
      "cwd": "$INSTALL_DIR"
    }
  }
}
CLAUDE_CFG
        echo "  [✓] Claude Code — settings created"
    fi
else
    echo "  [-] Claude Code — skipped"
fi

# OpenCode
if should_install opencode; then
    OPENCODE_CONFIG="$HOME/.config/opencode/opencode.json"
    if [ -f "$OPENCODE_CONFIG" ] && command -v python3 &>/dev/null; then
        backup "$OPENCODE_CONFIG"
        python3 -c "
import json
with open('$OPENCODE_CONFIG') as f:
    cfg = json.load(f)
if 'mcp' not in cfg:
    cfg['mcp'] = {}
cfg['mcp']['hindsight'] = {
    'command': 'python3',
    'args': ['-m', 'mcp_server'],
    'cwd': '$INSTALL_DIR',
}
with open('$OPENCODE_CONFIG', 'w') as f:
    json.dump(cfg, f, indent=2)
" 2>/dev/null && echo "  [✓] OpenCode — MCP server added" || \
        echo "  [~] OpenCode — add MCP server to opencode.json manually"
    else
        mkdir -p "$(dirname "$OPENCODE_CONFIG")"
        cat > "$OPENCODE_CONFIG" <<OPENCODE_CFG
{
  "mcp": {
    "hindsight": {
      "command": "python3",
      "args": ["-m", "mcp_server"],
      "cwd": "$INSTALL_DIR"
    }
  }
}
OPENCODE_CFG
        echo "  [✓] OpenCode — config created"
    fi
else
    echo "  [-] OpenCode — skipped"
fi

# Codex CLI
if should_install codex; then
    CODEX_DIR="$HOME/.codex"
    CODEX_HOOKS_DIR="$CODEX_DIR/hooks"
    mkdir -p "$CODEX_HOOKS_DIR"

    # Install hook scripts
    if [ -f "$SRC/integrations/codex/hooks/recall.py" ]; then
        cp "$SRC/integrations/codex/hooks/recall.py" "$CODEX_HOOKS_DIR/hindsight-recall.py"
        chmod +x "$CODEX_HOOKS_DIR/hindsight-recall.py"
    fi
    if [ -f "$SRC/integrations/codex/hooks/retain.py" ]; then
        cp "$SRC/integrations/codex/hooks/retain.py" "$CODEX_HOOKS_DIR/hindsight-retain.py"
        chmod +x "$CODEX_HOOKS_DIR/hindsight-retain.py"
    fi

    # Wire hooks.json with correct absolute paths
    CODEX_HOOKS_JSON="$CODEX_DIR/hooks.json"
    backup "$CODEX_HOOKS_JSON"
    python3 -c "
import json, os

hooks_dir = '$CODEX_HOOKS_DIR'
new_hooks = {
    'UserPromptSubmit': [{'command': 'python3', 'args': [os.path.join(hooks_dir, 'hindsight-recall.py')]}],
    'Stop': [{'command': 'python3', 'args': [os.path.join(hooks_dir, 'hindsight-retain.py')]}],
}

# Merge with existing hooks.json if present
existing = {}
if os.path.exists('$CODEX_HOOKS_JSON'):
    try:
        with open('$CODEX_HOOKS_JSON') as f:
            existing = json.load(f)
    except Exception:
        pass

if 'hooks' not in existing:
    existing['hooks'] = {}

for event, hooks in new_hooks.items():
    # Remove any old hindsight hooks first
    old = existing['hooks'].get(event, [])
    filtered = [h for h in old if 'hindsight' not in ' '.join(h.get('args', []))]
    existing['hooks'][event] = filtered + hooks

with open('$CODEX_HOOKS_JSON', 'w') as f:
    json.dump(existing, f, indent=2)
" 2>/dev/null && echo "  [✓] Codex CLI — hooks.json wired" || \
        echo "  [~] Codex CLI — hooks installed, wire them in ~/.codex/hooks.json"

    # Enable hooks in config.toml
    CODEX_CONFIG="$CODEX_DIR/config.toml"
    backup "$CODEX_CONFIG"
    if [ -f "$CODEX_CONFIG" ]; then
        if ! grep -q "codex_hooks" "$CODEX_CONFIG" 2>/dev/null; then
            echo -e "\n[features]\ncodex_hooks = true" >> "$CODEX_CONFIG"
        fi
    else
        mkdir -p "$CODEX_DIR"
        cat > "$CODEX_CONFIG" <<CODEX_CFG
[features]
codex_hooks = true
CODEX_CFG
    fi

    # Add MCP server config
    if ! grep -q "hindsight" "$CODEX_CONFIG" 2>/dev/null; then
        cat >> "$CODEX_CONFIG" <<CODEX_CFG

[mcp_servers.hindsight]
command = "python3"
args = ["-m", "mcp_server"]
cwd = "$INSTALL_DIR"
CODEX_CFG
    fi
    echo "  [✓] Codex CLI — MCP server + hooks configured"
else
    echo "  [-] Codex CLI — skipped"
fi

# GitHub Copilot
if should_install copilot; then
    VSCODE_MCP="$HOME/.vscode/mcp.json"
    backup "$VSCODE_MCP"
    if [ -f "$VSCODE_MCP" ] && command -v python3 &>/dev/null; then
        python3 -c "
import json
with open('$VSCODE_MCP') as f:
    cfg = json.load(f)
if 'servers' not in cfg:
    cfg['servers'] = {}
cfg['servers']['hindsight'] = {
    'command': 'python3',
    'args': ['-m', 'mcp_server'],
    'cwd': '$INSTALL_DIR',
}
with open('$VSCODE_MCP', 'w') as f:
    json.dump(cfg, f, indent=2)
" 2>/dev/null && echo "  [✓] Copilot — MCP server added to VS Code" || \
        echo "  [~] Copilot — add MCP server to ~/.vscode/mcp.json manually"
    else
        mkdir -p "$HOME/.vscode"
        cat > "$VSCODE_MCP" <<VSCODE_CFG
{
  "servers": {
    "hindsight": {
      "command": "python3",
      "args": ["-m", "mcp_server"],
      "cwd": "$INSTALL_DIR"
    }
  }
}
VSCODE_CFG
        echo "  [✓] Copilot — VS Code MCP config created"
    fi

    COPILOT_INSTRUCTIONS="$HOME/.github/copilot-instructions.md"
    if [ -f "$SRC/integrations/copilot/copilot-instructions.md" ]; then
        mkdir -p "$HOME/.github"
        backup "$COPILOT_INSTRUCTIONS"
        if [ -f "$COPILOT_INSTRUCTIONS" ] && grep -q "Hindsight" "$COPILOT_INSTRUCTIONS" 2>/dev/null; then
            echo "  [✓] Copilot — instructions already present"
        else
            echo "" >> "$COPILOT_INSTRUCTIONS"
            cat "$SRC/integrations/copilot/copilot-instructions.md" >> "$COPILOT_INSTRUCTIONS"
            echo "  [✓] Copilot — instructions appended"
        fi
    fi
else
    echo "  [-] Copilot — skipped"
fi

# --- Summary -----------------------------------------------------------------

echo "[6/6] Verifying ..."

if python3 -c "import sys; sys.path.insert(0, '$INSTALL_DIR'); from core.project import detect_project; print('      Core library: OK')" 2>/dev/null; then
    true
else
    echo "      Core library: IMPORT FAILED (check hindsight-client is installed)"
fi

echo ""
echo "=== Installed ==="
echo ""
echo "Config: $CONFIG_FILE"
echo "Library: $INSTALL_DIR"
echo ""
if ! $HAS_KEY; then
    echo "NEXT STEP: Set your API key:"
    echo "  Edit $CONFIG_FILE and set 'apiKey'"
    echo "  Or: export HINDSIGHT_API_KEY=your-key"
    echo ""
fi
echo "Restart your agents to activate."
echo "Docs: https://github.com/$REPO"
