#!/usr/bin/env bash
# Hindsight auto-recall hook for Claude Code
# Runs before each prompt submission to inject relevant memories.
#
# Installed to: ~/.claude/hooks/hindsight-recall.sh
# Wired via:    Claude Code hooks system

set -euo pipefail

QUERY="${CLAUDE_USER_PROMPT:-}"
[ -z "$QUERY" ] && exit 0

# Truncate long queries
if [ ${#QUERY} -gt 800 ]; then
    QUERY="${QUERY:0:800}"
fi

# Find the core library — try installed location first, then repo
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
result = client.recall(query='''$QUERY''')
text = result.get('result', '')
if text and 'No relevant' not in text:
    print('--- Hindsight Memory ---')
    print(text)
    print('--- End Memory ---')
" 2>/dev/null || true
