#!/usr/bin/env bash
# Hindsight Custom — Unified Installer/Updater/Uninstaller
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/jwvolschenk/hindsight-custom/main/install.sh | bash
#   ./install.sh                       # interactive mode
#   ./install.sh install               # skip mode prompt
#   ./install.sh update                # update MCP server/core only
#   ./install.sh uninstall             # selective uninstall
#   ./install.sh install --agents codex,claude-code
#   ./install.sh --legacy              # force shell UI
#

# ── CRLF self-heal: if downloaded on Windows, strip \r and re-exec ────────
# When run as ./install.sh, $0 is the file; when piped (curl | bash), $0 is
# "bash" and the script is on stdin.  Handle both.
if [[ "$0" != "bash" && "$0" != "-bash" ]]; then
    # Direct execution — check the file itself
    if head -c 1000 "$0" 2>/dev/null | grep -qP '\r'; then
        exec bash <(tr -d '\r' < "$0") "$@"
    fi
else
    # Piped (curl | bash) — read stdin, strip CRs, re-exec from cleaned copy
    _clean=$(mktemp "${TMPDIR:-/tmp}/hindsight-install.XXXXXX")
    tr -d '\r' > "$_clean"
    exec bash "$_clean" "$@"
fi

set -euo pipefail

REPO="jwvolschenk/hindsight-custom"
BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/$REPO/$BRANCH"
RELEASE_VERSION="${HINDSIGHT_INSTALLER_VERSION:-latest}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hindsight-custom"
CONFIG_FILE="$CONFIG_DIR/config.json"
INSTALL_DIR="$CONFIG_DIR/lib"
TEMP_DIR=$(mktemp -d)

# State
MODE=""          # install, update, uninstall
INSTALL_AGENTS=""
SKIP_CONFIG=false
FORCE_LEGACY=false
YES=false
AGENT_LIST="hermes claude-code opencode codex copilot"

# ── helpers ─────────────────────────────────────────────────────────────────

cleanup() { rm -rf "$TEMP_DIR"; }
trap cleanup EXIT

# Interactive read — works when piped (curl | bash)
ask() {
    local prompt="$1" varname="$2" default="${3:-}"
    if $YES; then
        eval "$varname='$default'"
        return
    fi
    if [ -t 0 ]; then
        read -rp "$prompt" "$varname"
    elif { printf "%s" "$prompt" > /dev/tty && read -r "$varname" < /dev/tty; } 2>/dev/null; then
        return
    else
        eval "$varname='$default'"
    fi
}

# Backup a config file
backup() {
    local file="$1"
    if [ -f "$file" ]; then
        local backup_dir="${CONFIG_DIR}/backups"
        mkdir -p "$backup_dir"
        local ts=$(date +%Y%m%d_%H%M%S)
        local base=$(basename "$file")
        cp "$file" "$backup_dir/${base}.${ts}.bak"
    fi
}

# Inject/replace a marked section in a file
MARKER_START="<!-- HINDSIGHT-CUSTOM:START -->"
MARKER_END="<!-- HINDSIGHT-CUSTOM:END -->"

inject_section() {
    local target="$1" content_file="$2"
    if [ ! -f "$target" ]; then
        cp "$content_file" "$target"
        return
    fi
    if grep -q "HINDSIGHT-CUSTOM:START" "$target" 2>/dev/null; then
        python3 -c "
ms, me = '$MARKER_START', '$MARKER_END'
with open('$target') as f: lines = f.readlines()
with open('$content_file') as f: new = f.read()
out, inside = [], False
for l in lines:
    if ms in l: inside = True; out.append(new + '\n'); continue
    if me in l: inside = False; continue
    if not inside: out.append(l)
with open('$target','w') as f: f.writelines(out)
" 2>/dev/null
    else
        echo "" >> "$target"
        cat "$content_file" >> "$target"
    fi
}

strip_section() {
    local target="$1"
    [ ! -f "$target" ] && return
    grep -q "HINDSIGHT-CUSTOM:START" "$target" 2>/dev/null || return
    python3 -c "
ms, me = 'HINDSIGHT-CUSTOM:START', 'HINDSIGHT-CUSTOM:END'
with open('$target') as f: lines = f.readlines()
out, inside = [], False
for l in lines:
    if ms in l: inside = True; continue
    if me in l: inside = False; continue
    if not inside: out.append(l)
while out and out[-1].strip() == '': out.pop()
with open('$target','w') as f: f.writelines(out); f.write('\n')
" 2>/dev/null
}

# ── agent detection ─────────────────────────────────────────────────────────

declare -A AGENT_LABEL
declare -A AGENT_INSTALLED  # 1 = has hindsight configured, 0 = not

detect_agents() {
    AGENT_LABEL[hermes]="Hermes Agent"
    AGENT_LABEL[claude-code]="Claude Code"
    AGENT_LABEL[opencode]="OpenCode"
    AGENT_LABEL[codex]="Codex CLI"
    AGENT_LABEL[copilot]="GitHub Copilot"

    # Hermes — check if plugin dir has our __init__.py
    if [ -d "$HOME/.hermes" ]; then
        if [ -f "$HOME/.hermes/plugins/hindsight-custom/__init__.py" ]; then
            AGENT_INSTALLED[hermes]=1
        elif [ -f "$HOME/.hermes/config.yaml" ] && command -v python3 &>/dev/null && \
           python3 -c "import yaml; d=yaml.safe_load(open('$HOME/.hermes/config.yaml')); assert 'hindsight' in d.get('mcp_servers',{})" 2>/dev/null; then
            # MCP server registered but plugin dir missing
            AGENT_INSTALLED[hermes]=1
        else
            AGENT_INSTALLED[hermes]=0
        fi
    fi

    # Claude Code — check settings.json for hindsight MCP entry
    if command -v claude &>/dev/null || [ -d "$HOME/.claude" ]; then
        if [ -f "$HOME/.claude/settings.json" ] && command -v python3 &>/dev/null && \
           python3 -c "import json; d=json.load(open('$HOME/.claude/settings.json')); assert 'hindsight' in d.get('mcpServers',{})" 2>/dev/null; then
            AGENT_INSTALLED[claude-code]=1
        else
            AGENT_INSTALLED[claude-code]=0
        fi
    fi

    # OpenCode — check opencode.jsonc for hindsight plugin or MCP
    local oc_cfg="$HOME/.config/opencode/opencode.jsonc"
    if command -v opencode &>/dev/null || [ -f "$oc_cfg" ]; then
        if [ -f "$oc_cfg" ] && command -v python3 &>/dev/null && \
           python3 -c "
import json
d=json.load(open('$oc_cfg'))
has_plugin = any('hindsight' in str(p) for p in d.get('plugin', []))
has_mcp = 'hindsight' in d.get('mcp', {})
assert has_plugin or has_mcp
" 2>/dev/null; then
            AGENT_INSTALLED[opencode]=1
        else
            AGENT_INSTALLED[opencode]=0
        fi
    fi

    # Codex — check hooks.json for hindsight hooks
    if command -v codex &>/dev/null || [ -d "$HOME/.codex" ]; then
        if [ -f "$HOME/.codex/hooks.json" ] && command -v python3 &>/dev/null && \
           python3 -c "
import json
d=json.load(open('$HOME/.codex/hooks.json'))
hooks=d.get('hooks',{})
found=False
for ev,hlist in hooks.items():
    for h in hlist:
        if 'hindsight' in ' '.join(h.get('args',[])): found=True
assert found
" 2>/dev/null; then
            AGENT_INSTALLED[codex]=1
        else
            AGENT_INSTALLED[codex]=0
        fi
    fi

    # Copilot — check ~/.vscode/mcp.json or ~/.copilot/mcp-config.json for hindsight
    if [ -d "$HOME/.vscode" ] || command -v code &>/dev/null || [ -d "$HOME/.copilot" ]; then
        if ([ -f "$HOME/.vscode/mcp.json" ] && command -v python3 &>/dev/null && \
           python3 -c "import json; d=json.load(open('$HOME/.vscode/mcp.json')); assert 'hindsight' in d.get('servers',{})" 2>/dev/null) || \
           ([ -f "$HOME/.copilot/mcp-config.json" ] && command -v python3 &>/dev/null && \
           python3 -c "import json; d=json.load(open('$HOME/.copilot/mcp-config.json')); assert 'hindsight' in d.get('mcpServers',{})" 2>/dev/null); then
            AGENT_INSTALLED[copilot]=1
        else
            AGENT_INSTALLED[copilot]=0
        fi
    fi
}

# ── checkbox selector ───────────────────────────────────────────────────────
# Usage: checkbox_select <filter> <pre_selected>
# filter: "all", "installed", "not-installed"
# pre_selected: "all-installed", "none", "all"
# Sets: INSTALL_AGENTS (comma-separated)

checkbox_select() {
    local filter="${1:-all}"
    local pre_selected="${2:-none}"

    local -a KEY_LIST=()
    local -a LABEL_LIST=()
    local -a STATE_LIST=()

    for agent in $AGENT_LIST; do
        [ -z "${AGENT_INSTALLED[$agent]+x}" ] && continue

        local is_installed="${AGENT_INSTALLED[$agent]}"

        # Apply filter
        case "$filter" in
            installed)      [ "$is_installed" -ne 1 ] && continue ;;
            not-installed)  [ "$is_installed" -ne 0 ] && continue ;;
        esac

        KEY_LIST+=("$agent")
        LABEL_LIST+=("${AGENT_LABEL[$agent]}")

        # Pre-selection
        case "$pre_selected" in
            all-installed) STATE_LIST+=$(( is_installed )) ;;
            all)           STATE_LIST+=(1) ;;
            *)             STATE_LIST+=(0) ;;
        esac
    done

    local count=${#KEY_LIST[@]}
    if [ "$count" -eq 0 ]; then
        echo "  No matching agents found."
        return 1
    fi

    if ! { : < /dev/tty; } 2>/dev/null; then
        INSTALL_AGENTS=""
        for i in $(seq 0 $((count - 1))); do
            if [ "${STATE_LIST[$i]:-0}" -eq 1 ]; then
                [ -n "$INSTALL_AGENTS" ] && INSTALL_AGENTS="$INSTALL_AGENTS,"
                INSTALL_AGENTS="$INSTALL_AGENTS${KEY_LIST[$i]}"
            fi
        done
        return 0
    fi

    local cursor=0
    local _drawn=0

    exec 3<&0
    exec 0</dev/tty
    local old_stty
    old_stty=$(stty -g)
    stty -echo -icanon min 0 time 0

    draw() {
        [ "$_drawn" -gt 0 ] && printf "\033[%dA" "$_drawn"
        local lines=0

        for i in $(seq 0 $((count - 1))); do
            printf "\033[2K"

            # Cursor
            [ "$i" -eq "$cursor" ] && printf "  \033[36m>\033[0m " || printf "    "

            # Checkbox
            if [ "${STATE_LIST[$i]:-0}" -eq 1 ]; then
                printf "\033[32m[x]\033[0m "
            else
                printf "[ ] "
            fi

            # Label + installed badge
            local badge=""
            local agent_key="${KEY_LIST[$i]}"
            if [ "${AGENT_INSTALLED[$agent_key]:-0}" -eq 1 ]; then
                badge=" \033[90m(installed)\033[0m"
            fi
            printf "%d. %s%b" "$((i + 1))" "${LABEL_LIST[$i]}" "$badge"
            printf "\n"
            lines=$((lines + 1))
        done

        printf "\033[2K\033[90m  ↑↓ navigate   space toggle   enter confirm\033[0m\n"
        lines=$((lines + 1))
        _drawn=$lines
    }

    echo ""
    for _ in $(seq 1 $((count + 1))); do echo ""; done
    draw

    while true; do
        local key=""
        IFS= read -rsn1 key
        if [[ "$key" == $'\x1b' ]]; then
            IFS= read -rsn1 -t 0.1 key
            if [[ "$key" == "[" ]]; then
                IFS= read -rsn1 -t 0.1 key
                case "$key" in
                    A) cursor=$(( (cursor - 1 + count) % count )); draw ;;
                    B) cursor=$(( (cursor + 1) % count )); draw ;;
                esac
            fi
        elif [[ "$key" == " " ]]; then
            STATE_LIST[$cursor]=$(( 1 - ${STATE_LIST[$cursor]:-0} ))
            draw
        elif [[ "$key" == "" ]] || [[ "$key" == $'\n' ]]; then
            break
        fi
    done

    stty "$old_stty"
    exec 0<&3 3<&-

    INSTALL_AGENTS=""
    for i in $(seq 0 $((count - 1))); do
        if [ "${STATE_LIST[$i]:-0}" -eq 1 ]; then
            [ -n "$INSTALL_AGENTS" ] && INSTALL_AGENTS="$INSTALL_AGENTS,"
            INSTALL_AGENTS="$INSTALL_AGENTS${KEY_LIST[$i]}"
        fi
    done

    return 0
}

has_agent() {
    echo ",$INSTALL_AGENTS," | grep -q ",$1," 2>/dev/null
}

normalize_agents() {
    local raw="$1"
    local out=""
    local item key
    raw="${raw// /}"
    raw="${raw//;/,}"
    IFS=',' read -ra parts <<< "$raw"
    for item in "${parts[@]}"; do
        key=""
        case "$item" in
            1|hermes) key="hermes" ;;
            2|claude|claude-code) key="claude-code" ;;
            3|opencode|open-code) key="opencode" ;;
            4|codex|codex-cli) key="codex" ;;
            5|copilot|github-copilot) key="copilot" ;;
            "") ;;
            *) echo "Unknown agent: $item" >&2; exit 1 ;;
        esac
        if [ -n "$key" ] && ! echo ",$out," | grep -q ",$key," 2>/dev/null; then
            [ -n "$out" ] && out="$out,"
            out="$out$key"
        fi
    done
    INSTALL_AGENTS="$out"
}

all_detected_agents() {
    local out=""
    for agent in $AGENT_LIST; do
        [ -z "${AGENT_INSTALLED[$agent]+x}" ] && continue
        [ -n "$out" ] && out="$out,"
        out="$out$agent"
    done
    INSTALL_AGENTS="$out"
}

run_limited() {
    local seconds="$1"
    shift
    if command -v timeout &>/dev/null; then
        timeout "$seconds" "$@"
    else
        "$@"
    fi
}

installer_asset_name() {
    local os arch
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch="$(uname -m)"

    case "$os" in
        linux) os="linux" ;;
        *) return 1 ;;
    esac

    case "$arch" in
        x86_64|amd64) arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        *) return 1 ;;
    esac

    printf "hindsight-installer-%s-%s" "$os" "$arch"
}

release_download_url() {
    local asset="$1"
    if [ "$RELEASE_VERSION" = "latest" ]; then
        printf "https://github.com/%s/releases/latest/download/%s" "$REPO" "$asset"
    else
        printf "https://github.com/%s/releases/download/%s/%s" "$REPO" "$RELEASE_VERSION" "$asset"
    fi
}

maybe_launch_binary() {
    $FORCE_LEGACY && return 0
    [ -n "$MODE" ] && return 0
    [ "${HINDSIGHT_INSTALLER_NO_TUI:-}" = "1" ] && return 0
    [ -t 1 ] || return 0
    command -v curl &>/dev/null || return 0

    local asset url binary
    if ! asset="$(installer_asset_name)"; then
        echo "      No prebuilt installer binary for this platform; using legacy installer."
        return 0
    fi

    url="$(release_download_url "$asset")"
    binary="$TEMP_DIR/$asset"

    echo "[*] Downloading Hindsight Control binary ..."
    if ! curl --connect-timeout 10 --max-time 90 -fsSL "$url" -o "$binary" 2>/dev/null; then
        echo "      Binary unavailable at $url"
        echo "      Falling back to source installer."
        return 0
    fi

    chmod +x "$binary"
    if { : < /dev/tty; } 2>/dev/null; then
        exec </dev/tty
    fi

    echo "[*] Starting Hindsight Control ..."
    HINDSIGHT_INSTALLER_BOOTSTRAP="$0" "$binary"
    exit $?
}

maybe_launch_tui() {
    $FORCE_LEGACY && return 0
    [ -n "$MODE" ] && return 0
    [ "${HINDSIGHT_INSTALLER_NO_TUI:-}" = "1" ] && return 0
    [ -t 1 ] || return 0
    command -v python3 &>/dev/null || return 0

    local tui="$SRC/installer/tui.py"
    if [ ! -f "$tui" ]; then
        return 0
    fi
    if { : < /dev/tty; } 2>/dev/null; then
        exec </dev/tty
    else
        echo "      No interactive TTY available; using legacy installer."
        return 0
    fi

    if python3 -c "import textual" >/dev/null 2>&1; then
        echo "[*] Starting Hindsight Control TUI ..."
        HINDSIGHT_INSTALLER_SCRIPT="$SRC/install.sh" python3 "$tui"
        exit $?
    fi

    if command -v uv &>/dev/null; then
        local venv="$TEMP_DIR/tui-venv"
        echo "[*] Preparing temporary TUI environment with uv ..."
        if run_limited 120 uv venv "$venv" --quiet && \
           run_limited 120 uv pip install --python "$venv/bin/python" textual --quiet; then
            echo "[*] Starting Hindsight Control TUI ..."
            HINDSIGHT_INSTALLER_SCRIPT="$SRC/install.sh" "$venv/bin/python" "$tui"
            exit $?
        fi
        echo "      TUI dependency setup with uv failed or timed out; using legacy installer."
    fi

    if run_limited 60 python3 -m venv "$TEMP_DIR/tui-venv" >/dev/null 2>&1; then
        echo "[*] Preparing temporary TUI environment with pip ..."
        if ! run_limited 120 "$TEMP_DIR/tui-venv/bin/python" -m pip install --quiet textual; then
            echo "      TUI dependency setup with pip failed or timed out; using legacy installer."
            return 0
        fi
        echo "[*] Starting Hindsight Control TUI ..."
        HINDSIGHT_INSTALLER_SCRIPT="$SRC/install.sh" "$TEMP_DIR/tui-venv/bin/python" "$tui"
        exit $?
    fi

    echo "      Textual is not available and Python venv could not be created; using legacy installer."
    return 0
}

# ── source fetching ─────────────────────────────────────────────────────────

fetch_source() {
    echo "[*] Fetching source ..."
    local fetched=false
    local script_dir=""

    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd 2>/dev/null || true)"
    if [ -n "$script_dir" ] && [ -d "$script_dir/core" ] && [ -d "$script_dir/mcp_server" ]; then
        SRC="$script_dir"
        echo "      Using local source: $SRC"
        return
    fi
    if [ -d "$PWD/core" ] && [ -d "$PWD/mcp_server" ]; then
        SRC="$PWD"
        echo "      Using local source: $SRC"
        return
    fi

    if ! $fetched && command -v git &>/dev/null; then
        GIT_TERMINAL_PROMPT=0 git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15 \
            clone --depth=1 --branch "$BRANCH" "https://github.com/$REPO.git" "$TEMP_DIR/repo" --quiet 2>/dev/null && fetched=true
    fi
    if ! $fetched && command -v curl &>/dev/null && command -v tar &>/dev/null; then
        mkdir -p "$TEMP_DIR/tarball"
        if curl --connect-timeout 10 --max-time 60 -fsSL "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" -o "$TEMP_DIR/source.tar.gz" 2>/dev/null; then
            tar -xzf "$TEMP_DIR/source.tar.gz" -C "$TEMP_DIR/tarball" --strip-components=1 2>/dev/null && fetched=true
        fi
    fi
    if ! $fetched; then
        mkdir -p "$TEMP_DIR/flat"
        for f in core/__init__.py core/project.py core/config.py core/client.py \
                 mcp_server/__init__.py mcp_server/__main__.py mcp_server/server.py mcp_server/hindsight-mcp-launcher.sh \
                 installer/__init__.py installer/tui.py \
                 integrations/hermes/__init__.py integrations/hermes/config.example.json \
                 integrations/claude-code/.claude-plugin/plugin.json \
                 integrations/claude-code/hooks/hooks.json integrations/claude-code/hooks/recall.sh integrations/claude-code/hooks/retain.sh \
                 integrations/codex/hooks/recall.py integrations/codex/hooks/retain.py \
                 integrations/opencode/package.json integrations/opencode/tsconfig.json \
                 integrations/opencode/src/project.ts integrations/opencode/src/client.ts integrations/opencode/src/index.ts \
                 integrations/copilot/.claude-plugin/plugin.json integrations/copilot/hooks.json \
                 integrations/copilot/copilot-instructions.md install.sh; do
            mkdir -p "$TEMP_DIR/flat/$(dirname "$f")"
            curl --connect-timeout 10 --max-time 30 -fsSL "$BASE_URL/$f" -o "$TEMP_DIR/flat/$f" 2>/dev/null || true
        done
        fetched=true
    fi

    if [ -d "$TEMP_DIR/repo/core" ]; then
        SRC="$TEMP_DIR/repo"
    elif [ -d "$TEMP_DIR/tarball/core" ]; then
        SRC="$TEMP_DIR/tarball"
    elif [ -d "$TEMP_DIR/flat/core" ]; then
        SRC="$TEMP_DIR/flat"
    else
        echo "ERROR: Could not fetch source."
        exit 1
    fi
    echo "      Source ready."
}

# ── config setup ────────────────────────────────────────────────────────────

setup_config() {
    $SKIP_CONFIG && return
    echo "[*] Config ..."

    local api_url="https://api.hindsight.vectorize.io"
    local api_key=""
    local has_key=false

    # Check existing config
    if [ -f "$CONFIG_FILE" ] && command -v python3 &>/dev/null; then
        api_url=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('api_url',''))" 2>/dev/null || echo "$api_url")
        api_key=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('apiKey',''))" 2>/dev/null || echo "")
        [ -n "$api_key" ] && has_key=true
    fi

    # Check env
    if [ -n "${HINDSIGHT_API_KEY:-}" ]; then
        api_key="$HINDSIGHT_API_KEY"
        has_key=true
    fi

    if [ -f "$CONFIG_FILE" ]; then
        echo "      Config exists: $CONFIG_FILE"
        ask "      Reconfigure? [y/N]: " reconfig "N"
        [ "$reconfig" != "y" ] && [ "$reconfig" != "Y" ] && return
    fi

    echo ""
    echo "      Hindsight endpoint:"
    echo "      [1] Cloud (https://api.hindsight.vectorize.io)"
    echo "      [2] Self-hosted"
    ask "      Select [1]: " ep "1"
    [ "$ep" = "2" ] && ask "      URL: " api_url ""

    echo ""
    ask "      API key (blank to skip): " api_key ""
    [ -n "$api_key" ] && has_key=true

    mkdir -p "$CONFIG_DIR"
    python3 -c "
import json
json.dump({'api_url':'$api_url','apiKey':'$api_key','timeout':300,'budget':'mid',
    'search_shared':True,'auto_retain':True,'retain_every_n_turns':3,'recall_max_input_chars':800},
    open('$CONFIG_FILE','w'),indent=2)
" 2>/dev/null
    echo "      Saved: $CONFIG_FILE"
}

# ── core install ────────────────────────────────────────────────────────────

install_core() {
    echo "[*] Installing core library + MCP server ..."
    mkdir -p "$INSTALL_DIR/core" "$INSTALL_DIR/mcp_server"
    cp "$SRC/core/__init__.py" "$INSTALL_DIR/core/"
    cp "$SRC/core/project.py" "$INSTALL_DIR/core/"
    cp "$SRC/core/config.py" "$INSTALL_DIR/core/"
    cp "$SRC/core/client.py" "$INSTALL_DIR/core/"
    cp "$SRC/mcp_server/__init__.py" "$INSTALL_DIR/mcp_server/"
    cp "$SRC/mcp_server/__main__.py" "$INSTALL_DIR/mcp_server/"
    cp "$SRC/mcp_server/server.py" "$INSTALL_DIR/mcp_server/"
    if [ -f "$SRC/mcp_server/hindsight-mcp-launcher.sh" ]; then
        cp "$SRC/mcp_server/hindsight-mcp-launcher.sh" "$INSTALL_DIR/"
        chmod +x "$INSTALL_DIR/hindsight-mcp-launcher.sh"
    fi
    echo "      $INSTALL_DIR"

    # Python deps — install into a self-contained venv
    setup_mcp_venv
}

# Set up a venv with mcp + hindsight-client so the MCP server works
# regardless of system Python restrictions (PEP 668).
# Sets MCP_PYTHON for agent installers to use.
MCP_PYTHON="python3"
setup_mcp_venv() {
    local venv="$INSTALL_DIR/.venv"
    if [ -d "$venv/bin" ] && "$venv/bin/python3" -c "import mcp, hindsight_client" 2>/dev/null; then
        MCP_PYTHON="$venv/bin/python3"
        echo "      MCP venv: $venv (already set up)"
        return 0
    fi

    echo "[*] Setting up MCP server venv ..."
    if ! python3 -m venv "$venv" 2>/dev/null; then
        echo "  [!] Could not create venv (python3-venv not installed)."
        echo "      Falling back to system python3 — MCP server may not work."
        echo "      Fix: sudo apt install python3.12-venv (or your distro's equivalent)"
        return 1
    fi

    if "$venv/bin/pip" install --quiet hindsight-client mcp 2>/dev/null; then
        MCP_PYTHON="$venv/bin/python3"
        echo "      MCP venv: $venv"
    else
        echo "  [!] pip install failed in venv. MCP server may not work."
        return 1
    fi
}

# ── agent install ───────────────────────────────────────────────────────────

install_hermes() {
    local dir="$HOME/.hermes/plugins/hindsight-custom"
    mkdir -p "$dir"
    cp "$SRC/integrations/hermes/__init__.py" "$dir/"
    # Remove old symlink if present (plugin now finds core via install dir path)
    rm -f "$dir/core" 2>/dev/null || true
    rm -rf "$dir/__pycache__" 2>/dev/null || true
    if [ -f "$HOME/.hermes/config.yaml" ]; then
        backup "$HOME/.hermes/config.yaml"
        if grep -q "provider: hindsight-custom" "$HOME/.hermes/config.yaml"; then
            echo "  [✓] Hermes — plugin already active"
        elif grep -q "provider: hindsight" "$HOME/.hermes/config.yaml"; then
            sed -i 's/provider: hindsight$/provider: hindsight-custom/' "$HOME/.hermes/config.yaml"
            echo "  [✓] Hermes — plugin activated"
        fi
    fi

    # Register MCP server in Hermes config for explicit tool access
    register_hermes_mcp_server
}

# Register the hindsight MCP server in ~/.hermes/config.yaml
register_hermes_mcp_server() {
    local hermes_cfg="$HOME/.hermes/config.yaml"
    local venv_python="$INSTALL_DIR/.venv/bin/python"
    local lib_dir="$INSTALL_DIR"

    # Resolve to absolute paths
    venv_python="$(eval echo "$venv_python")"
    lib_dir="$(eval echo "$lib_dir")"

    # Verify the MCP server can start
    if [ ! -f "$venv_python" ]; then
        echo "  [!] MCP server venv python not found at $venv_python"
        echo "      Skipping MCP server registration. Run update to retry."
        return 1
    fi

    # Verify mcp package is installed
    if ! "$venv_python" -c "from mcp.server.fastmcp import FastMCP; print('OK')" 2>/dev/null; then
        echo "  [!] MCP package not installed in venv. Installing..."
        if ! "$INSTALL_DIR/.venv/bin/pip" install --quiet mcp 2>/dev/null; then
            echo "  [!] Failed to install mcp package. Skipping MCP server registration."
            return 1
        fi
    fi

    # Verify mcp_server module can be imported
    if ! (cd "$lib_dir" && "$venv_python" -c "from mcp_server.server import main; print('OK')" 2>/dev/null); then
        echo "  [!] MCP server module import failed. Skipping MCP server registration."
        return 1
    fi

    # Create hermes config if it doesn't exist
    if [ ! -f "$hermes_cfg" ]; then
        mkdir -p "$(dirname "$hermes_cfg")"
        cat > "$hermes_cfg" <<EOF
# Hermes Agent Configuration
mcp_servers:
  hindsight:
    command: $venv_python
    args:
      - -m
      - mcp_server
    env:
      PYTHONPATH: $lib_dir
    timeout: 120
    connect_timeout: 30
EOF
        echo "  [✓] Hermes — MCP server registered (new config)"
        return 0
    fi

    # Config exists — use Python to safely update YAML
    backup "$hermes_cfg"
    python3 << PYEOF
import sys

config_path = "$hermes_cfg"
venv_python = "$venv_python"
lib_dir = "$lib_dir"

# Read existing config
with open(config_path, 'r') as f:
    content = f.read()

# Check if hindsight MCP server is already configured correctly
if f"command: {venv_python}" in content and "mcp_server" in content:
    print("  [✓] Hermes — MCP server already configured")
    sys.exit(0)

# Try to use PyYAML if available
try:
    import yaml
    with open(config_path, 'r') as f:
        config = yaml.safe_load(f) or {}

    if 'mcp_servers' not in config:
        config['mcp_servers'] = {}

    config['mcp_servers']['hindsight'] = {
        'command': venv_python,
        'args': ['-m', 'mcp_server'],
        'env': {'PYTHONPATH': lib_dir},
        'timeout': 120,
        'connect_timeout': 30,
    }

    with open(config_path, 'w') as f:
        yaml.dump(config, f, default_flow_style=False, sort_keys=False)

    print("  [✓] Hermes — MCP server registered (PyYAML)")
    sys.exit(0)

except ImportError:
    pass

# Fallback: text-based YAML manipulation
lines = content.split('\n')

# Find or create mcp_servers section
mcp_servers_idx = None
hindsight_idx = None
indent_level = 0

for i, line in enumerate(lines):
    stripped = line.lstrip()
    if stripped.startswith('mcp_servers:'):
        mcp_servers_idx = i
        indent_level = len(line) - len(stripped)
    elif mcp_servers_idx is not None and stripped.startswith('hindsight:'):
        # Check if this is under mcp_servers (same or deeper indent)
        line_indent = len(line) - len(stripped)
        if line_indent > indent_level:
            hindsight_idx = i
            break
        else:
            # Not under mcp_servers, reset
            mcp_servers_idx = None

# Build the hindsight config block
hindsight_block = [
    ' ' * (indent_level + 2) + 'hindsight:',
    ' ' * (indent_level + 4) + f'command: {venv_python}',
    ' ' * (indent_level + 4) + 'args:',
    ' ' * (indent_level + 6) + '- -m',
    ' ' * (indent_level + 6) + '- mcp_server',
    ' ' * (indent_level + 4) + 'env:',
    ' ' * (indent_level + 6) + f'PYTHONPATH: {lib_dir}',
    ' ' * (indent_level + 4) + 'timeout: 120',
    ' ' * (indent_level + 4) + 'connect_timeout: 30',
]

if hindsight_idx is not None:
    # Replace existing hindsight block
    # Find the end of the hindsight block (next key at same indent or mcp_servers indent)
    end_idx = hindsight_idx + 1
    while end_idx < len(lines):
        line = lines[end_idx]
        if line.strip() == '':
            end_idx += 1
            continue
        line_indent = len(line) - len(line.lstrip())
        if line_indent <= indent_level + 2 and line.strip():
            break
        end_idx += 1
    lines[hindsight_idx:end_idx] = hindsight_block
    print("  [✓] Hermes — MCP server updated")
elif mcp_servers_idx is not None:
    # Add hindsight under existing mcp_servers
    # Find the end of mcp_servers section
    insert_idx = mcp_servers_idx + 1
    while insert_idx < len(lines):
        line = lines[insert_idx]
        if line.strip() == '':
            insert_idx += 1
            continue
        line_indent = len(line) - len(line.lstrip())
        if line_indent <= indent_level:
            break
        insert_idx += 1
    # Insert before the next top-level section
    for i, block_line in enumerate(hindsight_block):
        lines.insert(insert_idx + i, block_line)
    print("  [✓] Hermes — MCP server registered")
else:
    # No mcp_servers section — add it at the top level
    # Find a good insertion point (after last top-level section or at end)
    insert_idx = len(lines)
    # Remove trailing empty lines
    while insert_idx > 0 and lines[insert_idx - 1].strip() == '':
        insert_idx -= 1

    mcp_header = 'mcp_servers:'
    lines.insert(insert_idx, '')
    insert_idx += 1
    lines.insert(insert_idx, mcp_header)
    insert_idx += 1
    for i, block_line in enumerate(hindsight_block):
        lines.insert(insert_idx + i, block_line)
    print("  [✓] Hermes — MCP server registered (new section)")

with open(config_path, 'w') as f:
    f.write('\n'.join(lines))
    if not lines[-1].endswith('\n'):
        f.write('\n')
PYEOF
}

install_claude() {
    local dir="$HOME/.claude"
    mkdir -p "$dir/hooks"

    # Plugin with bundled hooks
    local plugin_dir="$dir/plugins/hindsight-custom"
    mkdir -p "$plugin_dir/.claude-plugin" "$plugin_dir/hooks"
    cp "$SRC/integrations/claude-code/.claude-plugin/plugin.json" "$plugin_dir/.claude-plugin/"
    cp "$SRC/integrations/claude-code/hooks/hooks.json" "$plugin_dir/hooks/"
    cp "$SRC/integrations/claude-code/hooks/recall.sh" "$plugin_dir/hooks/"
    cp "$SRC/integrations/claude-code/hooks/retain.sh" "$plugin_dir/hooks/"
    chmod +x "$plugin_dir/hooks/"*.sh

    # Also install hooks globally (fallback if plugin hooks don't fire)
    cp "$SRC/integrations/claude-code/hooks/recall.sh" "$dir/hooks/hindsight-recall.sh"
    cp "$SRC/integrations/claude-code/hooks/retain.sh" "$dir/hooks/hindsight-retain.sh"
    chmod +x "$dir/hooks/"hindsight-*.sh

    # MCP server config
    local settings="$dir/settings.json"
    backup "$settings"
    if [ -f "$settings" ] && command -v python3 &>/dev/null; then
        python3 -c "
import json
with open('$settings') as f: cfg=json.load(f)
cfg.setdefault('mcpServers',{})['hindsight']={'command':'$MCP_PYTHON','args':['-m','mcp_server'],'cwd':'$INSTALL_DIR'}
with open('$settings','w') as f: json.dump(cfg,f,indent=2); f.write('\n')
" 2>/dev/null
    else
        mkdir -p "$dir"
        echo "{\"mcpServers\":{\"hindsight\":{\"command\":\"$MCP_PYTHON\",\"args\":[\"-m\",\"mcp_server\"],\"cwd\":\"$INSTALL_DIR\"}}}" > "$settings"
    fi
    echo "  [✓] Claude Code (plugin + hooks + MCP)"
}

install_opencode() {
    # OpenCode uses opencode.jsonc
    local cfg="$HOME/.config/opencode/opencode.jsonc"
    backup "$cfg"

    # Build native plugin (provides hooks for auto-inject/auto-retain)
    local plugin_dir="$CONFIG_DIR/opencode-plugin"
    mkdir -p "$plugin_dir/src"
    cp "$SRC/integrations/opencode/package.json" "$plugin_dir/"
    cp "$SRC/integrations/opencode/tsconfig.json" "$plugin_dir/"
    cp "$SRC/integrations/opencode/src/"*.ts "$plugin_dir/src/" 2>/dev/null || true

    local plugin_built=false
    if command -v npm &>/dev/null; then
        (cd "$plugin_dir" && npm install --silent 2>/dev/null && npm run build --silent 2>/dev/null) && plugin_built=true
    elif command -v pnpm &>/dev/null; then
        (cd "$plugin_dir" && pnpm install --silent 2>/dev/null && pnpm run build --silent 2>/dev/null) && plugin_built=true
    fi

    if [ -f "$cfg" ] && command -v python3 &>/dev/null; then
        python3 -c "
import json
with open('$cfg') as f: d=json.load(f)
if $([ "$plugin_built" = true ] && echo True || echo False):
    # Native plugin: provides tools + hooks (auto-inject, auto-retain)
    plugins = d.get('plugin', [])
    plugin_ref = 'file:$plugin_dir'
    if plugin_ref not in plugins:
        plugins.append(plugin_ref)
    d['plugin'] = plugins
    d.get('mcp',{}).pop('hindsight', None)
else:
    # Fallback: MCP server (tools only, no hooks)
    d.pop('plugin', None)
    d.setdefault('mcp',{})['hindsight']={'type':'local','command':'$MCP_PYTHON'.split()+['-m','mcp_server'],'cwd':'$INSTALL_DIR'}
with open('$cfg','w') as f: json.dump(d,f,indent=2); f.write('\n')
"
    else
        cfg="$HOME/.config/opencode/opencode.jsonc"
        mkdir -p "$(dirname "$cfg")"
        if $plugin_built; then
            echo "{\"plugin\":[\"file:$plugin_dir\"]}" > "$cfg"
        else
            echo "{\"mcp\":{\"hindsight\":{\"type\":\"local\",\"command\":[\"$MCP_PYTHON\",\"-m\",\"mcp_server\"],\"cwd\":\"$INSTALL_DIR\"}}}" > "$cfg"
        fi
    fi

    if $plugin_built; then
        echo "  [✓] OpenCode (native plugin with hooks)"
    else
        echo "  [✓] OpenCode (MCP server — npm not available for native plugin)"
    fi
}

install_codex() {
    local dir="$HOME/.codex"
    mkdir -p "$dir/hooks"
    cp "$SRC/integrations/codex/hooks/recall.py" "$dir/hooks/hindsight-recall.py"
    cp "$SRC/integrations/codex/hooks/retain.py" "$dir/hooks/hindsight-retain.py"
    chmod +x "$dir/hooks/"hindsight-*.py

    # hooks.json
    local hooks_json="$dir/hooks.json"
    backup "$hooks_json"
    python3 -c "
import json, os
hd='$dir/hooks'
new={'UserPromptSubmit':[{'command':'python3','args':[os.path.join(hd,'hindsight-recall.py')]}],
     'Stop':[{'command':'python3','args':[os.path.join(hd,'hindsight-retain.py')]}]}
d={}
try:
    with open('$hooks_json') as f: d=json.load(f)
except: pass
d.setdefault('hooks',{})
for ev,hooks in new.items():
    old=[h for h in d['hooks'].get(ev,[]) if 'hindsight' not in ' '.join(h.get('args',[]))]
    d['hooks'][ev]=old+hooks
with open('$hooks_json','w') as f: json.dump(d,f,indent=2)
" 2>/dev/null

    # config.toml
    local toml="$dir/config.toml"
    backup "$toml"
    if [ -f "$toml" ]; then
        grep -q "codex_hooks" "$toml" 2>/dev/null || echo -e "\n[features]\ncodex_hooks = true" >> "$toml"
        grep -q "hindsight" "$toml" 2>/dev/null || cat >> "$toml" <<EOF

[mcp_servers.hindsight]
command = "$MCP_PYTHON"
args = ["-m", "mcp_server"]
cwd = "$INSTALL_DIR"
EOF
    else
        cat > "$toml" <<EOF
[features]
codex_hooks = true

[mcp_servers.hindsight]
command = "$MCP_PYTHON"
args = ["-m", "mcp_server"]
cwd = "$INSTALL_DIR"
EOF
    fi
    echo "  [✓] Codex CLI"
}

install_copilot() {
    local mcp="$HOME/.vscode/mcp.json"
    backup "$mcp"

    # Install the MCP launcher script (optional, for VS Code if default CWD
    # doesn't match the workspace). Passes --cwd to the MCP server.
    if [ -f "$SRC/mcp_server/hindsight-mcp-launcher.sh" ]; then
        cp "$SRC/mcp_server/hindsight-mcp-launcher.sh" "$INSTALL_DIR/hindsight-mcp-launcher.sh"
        chmod +x "$INSTALL_DIR/hindsight-mcp-launcher.sh"
    fi

    # No explicit cwd — the process inherits the parent's CWD.
    # Copilot CLI: inherits terminal CWD (the user's project dir).
    # VS Code: inherits VS Code's default CWD (usually the workspace).
    # PYTHONPATH ensures the mcp_server module is importable from any CWD.
    # If VS Code CWD doesn't match workspace, swap command to the launcher script.
    if [ -f "$mcp" ] && command -v python3 &>/dev/null; then
        python3 -c "
import json
with open('$mcp') as f: d=json.load(f)
d.setdefault('servers',{})['hindsight']={'command':'$MCP_PYTHON','args':['-m','mcp_server'],'env':{'PYTHONPATH':'$INSTALL_DIR'}}
with open('$mcp','w') as f: json.dump(d,f,indent=2); f.write('\n')
" 2>/dev/null
    else
        mkdir -p "$HOME/.vscode"
        echo "{\"servers\":{\"hindsight\":{\"command\":\"$MCP_PYTHON\",\"args\":[\"-m\",\"mcp_server\"],\"env\":{\"PYTHONPATH\":\"$INSTALL_DIR\"}}}}" > "$mcp"
    fi

    # Copilot MCP config (~/.copilot/mcp-config.json)
    # No explicit cwd — inherits terminal CWD (the user's project dir).
    local copilot_mcp="$HOME/.copilot/mcp-config.json"
    if [ -f "$copilot_mcp" ] && command -v python3 &>/dev/null; then
        backup "$copilot_mcp"
        python3 -c "
import json
with open('$copilot_mcp') as f: d=json.load(f)
d.setdefault('mcpServers',{})['hindsight']={'command':'$MCP_PYTHON','args':['-m','mcp_server'],'env':{'PYTHONPATH':'$INSTALL_DIR'}}
with open('$copilot_mcp','w') as f: json.dump(d,f,indent=2); f.write('\n')
" 2>/dev/null
    elif [ -d "$HOME/.copilot" ]; then
        mkdir -p "$HOME/.copilot"
        echo "{\"mcpServers\":{\"hindsight\":{\"command\":\"$MCP_PYTHON\",\"args\":[\"-m\",\"mcp_server\"],\"env\":{\"PYTHONPATH\":\"$INSTALL_DIR\"}}}}" > "$copilot_mcp"
    fi

    # Plugin manifest + hooks
    local plugin_dir="$CONFIG_DIR/copilot-plugin"
    mkdir -p "$plugin_dir/.claude-plugin"
    cp "$SRC/integrations/copilot/.claude-plugin/plugin.json" "$plugin_dir/.claude-plugin/"
    cp "$SRC/integrations/copilot/hooks.json" "$plugin_dir/" 2>/dev/null || true

    local instructions="$HOME/.github/copilot-instructions.md"
    mkdir -p "$HOME/.github"
    backup "$instructions"
    inject_section "$instructions" "$SRC/integrations/copilot/copilot-instructions.md"
    echo "  [✓] Copilot (plugin + MCP + instructions)"
}

# ── agent uninstall ─────────────────────────────────────────────────────────

uninstall_hermes() {
    rm -rf "$HOME/.hermes/plugins/hindsight-custom" 2>/dev/null || true
    if [ -f "$HOME/.hermes/config.yaml" ]; then
        backup "$HOME/.hermes/config.yaml"
        sed -i 's/provider: hindsight-custom/provider: hindsight/' "$HOME/.hermes/config.yaml" 2>/dev/null || true
    fi
    # Remove MCP server entry from hermes config
    remove_hermes_mcp_server
    echo "  [x] Hermes"
}

# Remove the hindsight MCP server entry from ~/.hermes/config.yaml
remove_hermes_mcp_server() {
    local hermes_cfg="$HOME/.hermes/config.yaml"
    [ ! -f "$hermes_cfg" ] && return 0
    grep -q "hindsight" "$hermes_cfg" 2>/dev/null || return 0

    python3 << PYEOF
import sys

config_path = "$hermes_cfg"

try:
    import yaml
    with open(config_path, 'r') as f:
        config = yaml.safe_load(f) or {}

    if 'mcp_servers' in config and 'hindsight' in config['mcp_servers']:
        del config['mcp_servers']['hindsight']
        if not config['mcp_servers']:
            del config['mcp_servers']
        with open(config_path, 'w') as f:
            yaml.dump(config, f, default_flow_style=False, sort_keys=False)
        print("  [~] Hermes - MCP server entry removed")
    sys.exit(0)
except ImportError:
    pass

# Fallback: text-based removal
with open(config_path, 'r') as f:
    lines = f.readlines()

new_lines = []
skip_until_next_key = False
mcp_servers_indent = -1

for line in lines:
    stripped = line.lstrip()
    indent = len(line) - len(stripped)

    # Detect mcp_servers section
    if stripped.startswith('mcp_servers:') and not skip_until_next_key:
        mcp_servers_indent = indent
        # Check if hindsight is the only entry
        has_other = False
        for future_line in lines[lines.index(line) + 1:]:
            future_stripped = future_line.lstrip()
            future_indent = len(future_line) - len(future_stripped)
            if future_indent <= mcp_servers_indent and future_stripped:
                break
            if future_stripped and not future_stripped.startswith('hindsight:') and future_indent == mcp_servers_indent + 2:
                has_other = True
        if not has_other:
            skip_until_next_key = True
            continue
        new_lines.append(line)
        continue

    # Skip hindsight block under mcp_servers
    if mcp_servers_indent >= 0 and stripped.startswith('hindsight:') and indent == mcp_servers_indent + 2:
        skip_until_next_key = True
        continue

    if skip_until_next_key:
        if indent <= mcp_servers_indent and stripped:
            skip_until_next_key = False
            mcp_servers_indent = -1
            new_lines.append(line)
        continue

    new_lines.append(line)

with open(config_path, 'w') as f:
    f.writelines(new_lines)
PYEOF
}

uninstall_claude() {
    rm -f "$HOME/.claude/hooks/hindsight-recall.sh" "$HOME/.claude/hooks/hindsight-retain.sh" 2>/dev/null || true
    rm -rf "$HOME/.claude/plugins/hindsight-custom" 2>/dev/null || true
    if [ -f "$HOME/.claude/settings.json" ] && command -v python3 &>/dev/null; then
        backup "$HOME/.claude/settings.json"
        python3 -c "
import json
p='$HOME/.claude/settings.json'
with open(p) as f: d=json.load(f)
d.get('mcpServers',{}).pop('hindsight',None)
if 'mcpServers' in d and not d['mcpServers']: del d['mcpServers']
with open(p,'w') as f: json.dump(d,f,indent=2); f.write('\n')
" 2>/dev/null || true
    fi
    echo "  [x] Claude Code"
}

uninstall_opencode() {
    local cfg="$HOME/.config/opencode/opencode.jsonc"
    if [ -f "$cfg" ] && command -v python3 &>/dev/null; then
        backup "$cfg"
        python3 -c "
import json
p='$cfg'
with open(p) as f: d=json.load(f)
# Remove hindsight plugin
d['plugin'] = [p for p in d.get('plugin', []) if 'hindsight' not in str(p)]
if not d.get('plugin'): d.pop('plugin', None)
# Remove hindsight MCP
d.get('mcp',{}).pop('hindsight',None)
if 'mcp' in d and not d['mcp']: del d['mcp']
with open(p,'w') as f: json.dump(d,f,indent=2); f.write('\n')
" 2>/dev/null || true
    fi
    echo "  [x] OpenCode"
}

uninstall_codex() {
    rm -f "$HOME/.codex/hooks/hindsight-recall.py" "$HOME/.codex/hooks/hindsight-retain.py" 2>/dev/null || true
    if [ -f "$HOME/.codex/hooks.json" ] && command -v python3 &>/dev/null; then
        backup "$HOME/.codex/hooks.json"
        python3 -c "
import json,os
p='$HOME/.codex/hooks.json'
with open(p) as f: d=json.load(f)
for ev in list(d.get('hooks',{}).keys()):
    d['hooks'][ev]=[h for h in d['hooks'][ev] if 'hindsight' not in ' '.join(h.get('args',[]))]
    if not d['hooks'][ev]: del d['hooks'][ev]
if not d.get('hooks'): os.remove(p)
else:
    with open(p,'w') as f: json.dump(d,f,indent=2)
" 2>/dev/null || true
    fi
    if [ -f "$HOME/.codex/config.toml" ] && command -v python3 &>/dev/null; then
        backup "$HOME/.codex/config.toml"
        python3 -c "
import re
p='$HOME/.codex/config.toml'
with open(p) as f: c=f.read()
c=re.sub(r'\n?\[features\]\ncodex_hooks\s*=\s*true\n?','\n',c)
c=re.sub(r'\n?\[mcp_servers\.hindsight\]\n.*?cwd\s*=.*?\n','\n',c,flags=re.S)
c=re.sub(r'\n{3,}','\n\n',c)
with open(p,'w') as f: f.write(c)
" 2>/dev/null || true
    fi
    echo "  [x] Codex CLI"
}

uninstall_copilot() {
    if [ -f "$HOME/.vscode/mcp.json" ] && command -v python3 &>/dev/null; then
        backup "$HOME/.vscode/mcp.json"
        python3 -c "
import json,os
p='$HOME/.vscode/mcp.json'
with open(p) as f: d=json.load(f)
d.get('servers',{}).pop('hindsight',None)
if 'servers' in d and not d['servers']: del d['servers']
if d:
    with open(p,'w') as f: json.dump(d,f,indent=2); f.write('\n')
else: os.remove(p)
" 2>/dev/null || true
    fi
    if [ -f "$HOME/.copilot/mcp-config.json" ] && command -v python3 &>/dev/null; then
        backup "$HOME/.copilot/mcp-config.json"
        python3 -c "
import json
p='$HOME/.copilot/mcp-config.json'
with open(p) as f: d=json.load(f)
d.get('mcpServers',{}).pop('hindsight',None)
with open(p,'w') as f: json.dump(d,f,indent=2); f.write('\n')
" 2>/dev/null || true
    fi
    strip_section "$HOME/.github/copilot-instructions.md"
    echo "  [x] Copilot"
}

# ── mode: install ───────────────────────────────────────────────────────────

mode_install() {
    echo ""
    if [ -z "$INSTALL_AGENTS" ]; then
        echo "Select agents to install:"
        echo ""

        if ! checkbox_select "all" "all-installed"; then
            echo "No agents available."
            return
        fi
    fi

    if [ -z "$INSTALL_AGENTS" ]; then
        echo "No agents selected."
        return
    fi

    echo ""
    echo "Installing for: $INSTALL_AGENTS"
    echo ""

    setup_config
    install_core

    echo "[*] Configuring agents ..."
    has_agent hermes      && install_hermes
    has_agent claude-code && install_claude
    has_agent opencode    && install_opencode
    has_agent codex       && install_codex
    has_agent copilot     && install_copilot

    echo ""
    echo "=== Done ==="
    [ -f "$CONFIG_FILE" ] && echo "Config: $CONFIG_FILE"
    echo "Restart your agents to activate."
}

# ── mode: update ────────────────────────────────────────────────────────────

mode_update() {
    echo ""
    echo "Updating MCP server and core library ..."
    echo ""

    install_core

    # Re-deploy each installed agent (all install functions are idempotent)
    echo "[*] Re-deploying agent integrations ..."

    # Hermes — check by plugin presence or MCP server config
    if [ -f "$HOME/.hermes/plugins/hindsight-custom/__init__.py" ] || \
       ([ -f "$HOME/.hermes/config.yaml" ] && command -v python3 &>/dev/null && \
        python3 -c "import yaml; d=yaml.safe_load(open('$HOME/.hermes/config.yaml')); assert 'hindsight' in d.get('mcp_servers',{})" 2>/dev/null); then
        install_hermes
    fi

    # Claude Code — check by hooks or settings.json
    if [ -f "$HOME/.claude/hooks/hindsight-recall.sh" ] || \
       ([ -f "$HOME/.claude/settings.json" ] && command -v python3 &>/dev/null && \
        python3 -c "import json; d=json.load(open('$HOME/.claude/settings.json')); assert 'hindsight' in d.get('mcpServers',{})" 2>/dev/null); then
        install_claude
    fi

    # OpenCode — check by config entry (plugin or MCP)
    local oc_cfg="$HOME/.config/opencode/opencode.jsonc"
    if [ -f "$oc_cfg" ] && command -v python3 &>/dev/null && \
       python3 -c "
import json
d=json.load(open('$oc_cfg'))
has_plugin = any('hindsight' in str(p) for p in d.get('plugin', []))
has_mcp = 'hindsight' in d.get('mcp', {})
assert has_plugin or has_mcp
" 2>/dev/null; then
        install_opencode
    fi

    # Codex — check by hooks presence
    if [ -f "$HOME/.codex/hooks/hindsight-recall.py" ]; then
        install_codex
    fi

    # Copilot — check by MCP config or plugin dir
    if ([ -f "$HOME/.vscode/mcp.json" ] && command -v python3 &>/dev/null && \
        python3 -c "import json; d=json.load(open('$HOME/.vscode/mcp.json')); assert 'hindsight' in d.get('servers',{})" 2>/dev/null) || \
       [ -d "$CONFIG_DIR/copilot-plugin" ]; then
        install_copilot
    fi

    echo ""
    echo "=== Updated ==="
    echo "Restart your agents to pick up changes."
}

# ── mode: uninstall ─────────────────────────────────────────────────────────

mode_uninstall() {
    echo ""
    if [ -z "$INSTALL_AGENTS" ]; then
        echo "Select agents to uninstall:"
        echo ""

        if ! checkbox_select "installed" "none"; then
            echo "Nothing to uninstall."
            return
        fi
    fi

    if [ -z "$INSTALL_AGENTS" ]; then
        echo "No agents selected."
        return
    fi

    echo ""
    echo "Uninstalling from: $INSTALL_AGENTS"
    echo ""

    has_agent hermes      && uninstall_hermes
    has_agent claude-code && uninstall_claude
    has_agent opencode    && uninstall_opencode
    has_agent codex       && uninstall_codex
    has_agent copilot     && uninstall_copilot

    # Remove core if no agents left
    local any_installed=false
    for agent in $AGENT_LIST; do
        [ "${AGENT_INSTALLED[$agent]:-0}" -eq 1 ] && ! has_agent "$agent" && continue
        [ "${AGENT_INSTALLED[$agent]:-0}" -eq 1 ] && any_installed=true
    done

    if ! $any_installed; then
        ask "  Remove core library + config? [y/N]: " remove_core "N"
        if [ "$remove_core" = "y" ] || [ "$remove_core" = "Y" ]; then
            rm -rf "$INSTALL_DIR" 2>/dev/null || true
            rm -f "$CONFIG_FILE" 2>/dev/null || true
            [ -d "$CONFIG_DIR/backups" ] && echo "  [~] Config removed (backups kept)" || rm -rf "$CONFIG_DIR" 2>/dev/null || true
            echo "  [x] Core library removed"
        fi
    fi

    echo ""
    echo "=== Uninstalled ==="
    echo "Restart your agents to complete removal."
}

# ── main ────────────────────────────────────────────────────────────────────

echo "=== Hindsight Custom ==="
echo ""

# Parse CLI args
while [[ $# -gt 0 ]]; do
    case "$1" in
        install|update|uninstall) MODE="$1"; shift ;;
        --agents) normalize_agents "$2"; shift 2 ;;
        --all) INSTALL_AGENTS="__ALL__"; shift ;;
        --skip-config) SKIP_CONFIG=true; shift ;;
        --yes|-y) YES=true; shift ;;
        --legacy) FORCE_LEGACY=true; shift ;;
        -h|--help)
            echo "Usage: install.sh [install|update|uninstall] [--agents codex,claude-code] [--all] [--legacy]"
            echo ""
            echo "  install    Configure agents + MCP server"
            echo "  update     Update MCP server + core library only"
            echo "  uninstall  Remove agent configs"
            echo "  --agents   Pre-select agents by name or number (comma-separated)"
            echo "  --all      Select every detected agent"
            echo "  --legacy   Force the shell UI instead of the Textual TUI"
            exit 0
            ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

# Detect installed agents
maybe_launch_binary
detect_agents

# Fetch source (needed for all modes)
fetch_source

[ "$INSTALL_AGENTS" = "__ALL__" ] && all_detected_agents
maybe_launch_tui

# Mode selection
if [ -z "$MODE" ]; then
    # Show status summary
    echo ""
    echo "Current status:"
    for agent in $AGENT_LIST; do
        [ -z "${AGENT_INSTALLED[$agent]+x}" ] && continue
        if [ "${AGENT_INSTALLED[$agent]}" -eq 1 ]; then
            printf "  \033[32m[installed]\033[0m  %s\n" "${AGENT_LABEL[$agent]}"
        else
            printf "  [ ]           %s\n" "${AGENT_LABEL[$agent]}"
        fi
    done

    echo ""
    echo "What would you like to do?"
    echo ""
    echo "  [1] Install / Reconfigure"
    echo "  [2] Update (core + MCP server only)"
    echo "  [3] Uninstall"
    echo ""
    ask "Select [1]: " mode_choice "1"

    case "$mode_choice" in
        1) MODE="install" ;;
        2) MODE="update" ;;
        3) MODE="uninstall" ;;
        *) echo "Invalid choice."; exit 1 ;;
    esac
fi

case "$MODE" in
    install)   mode_install ;;
    update)    mode_update ;;
    uninstall) mode_uninstall ;;
esac
