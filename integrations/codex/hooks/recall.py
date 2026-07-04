#!/usr/bin/env python3
"""Hindsight auto-recall hook for Codex CLI.

Runs on UserPromptSubmit to inject relevant memories into context.
Configured via ~/.codex/hooks.json.

Reads the user prompt from CODEX_USER_PROMPT env var or stdin,
searches project + shared banks, and prints memories to stdout.
"""

import json
import os
import sys

# Add repo root to path
_here = os.path.dirname(os.path.abspath(__file__))
# Navigate: hooks/ -> codex/ -> integrations/ -> repo root
_repo_root = os.path.dirname(os.path.dirname(os.path.dirname(_here)))
if _repo_root not in sys.path:
    sys.path.insert(0, _repo_root)

# Also try installed location
_config_dir = os.path.join(os.path.expanduser("~"), ".config", "hindsight-custom", "lib")
if os.path.isdir(_config_dir) and _config_dir not in sys.path:
    sys.path.insert(0, _config_dir)

from core.client import HindsightClient
from core.config import load_config


def main():
    # Read the user prompt from environment or stdin
    query = os.environ.get("CODEX_USER_PROMPT", "")
    if not query:
        try:
            query = sys.stdin.read().strip()
        except Exception:
            pass

    if not query:
        return

    # Truncate long queries
    max_chars = 800
    if len(query) > max_chars:
        query = query[:max_chars]

    try:
        cfg = load_config()
        if not cfg.is_configured:
            return

        client = HindsightClient(cfg)
        client.connect()
        result = client.recall(query=query)
        text = result.get("result", "")

        if text and "No relevant" not in text:
            print("--- Hindsight Memory ---")
            print(text)
            print("--- End Memory ---")
    except Exception:
        pass  # Silent failure — don't block the agent


if __name__ == "__main__":
    main()
