#!/usr/bin/env bash
# Hindsight auto-retain hook for Claude Code
# Runs after each response to store the conversation.
#
# Installed to: ~/.claude/hooks/hindsight-retain.sh

set -euo pipefail

TRANSCRIPT="${CLAUDE_TRANSCRIPT:-}"
[ -z "$TRANSCRIPT" ] && exit 0

# Truncate very long transcripts
if [ ${#TRANSCRIPT} -gt 10000 ]; then
    TRANSCRIPT="${TRANSCRIPT:0:10000}"
fi

LIB_DIR="$HOME/.config/hindsight-custom/lib"
if [ ! -d "$LIB_DIR/core" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    LIB_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
fi

python3 -c "
import sys, json
sys.path.insert(0, '$LIB_DIR')
from core.client import HindsightClient
from core.config import load_config

cfg = load_config()
if not cfg.is_configured:
    sys.exit(0)

client = HindsightClient(cfg)
client.connect()
client.retain(
    content=sys.stdin.read() if not '''$TRANSCRIPT''' else '''$TRANSCRIPT''',
    context='claude-code session transcript',
    tags=['claude-code', 'auto-retain'],
)
print(f'Retained to bank: {client.project_bank}')
" 2>/dev/null || true
