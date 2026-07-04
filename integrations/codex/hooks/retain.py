#!/usr/bin/env python3
"""Hindsight auto-retain hook for Codex CLI.

Runs on Stop event to store the conversation exchange.
Configured via ~/.codex/hooks.json.

Reads user prompt and assistant response from env vars or stdin JSON.
"""

import json
import os
import sys
from datetime import datetime, timezone

# Add repo root to path
_here = os.path.dirname(os.path.abspath(__file__))
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
    user_prompt = os.environ.get("CODEX_USER_PROMPT", "")
    assistant_response = os.environ.get("CODEX_ASSISTANT_RESPONSE", "")

    if not user_prompt and not assistant_response:
        try:
            data = json.loads(sys.stdin.read())
            user_prompt = data.get("user_prompt", "")
            assistant_response = data.get("assistant_response", "")
        except Exception:
            pass

    if not user_prompt and not assistant_response:
        return

    try:
        cfg = load_config()
        if not cfg.is_configured:
            return

        client = HindsightClient(cfg)
        client.connect()

        now = datetime.now(timezone.utc).isoformat()
        content = json.dumps([{
            "role": "user",
            "content": f"User: {user_prompt}",
            "timestamp": now,
        }, {
            "role": "assistant",
            "content": f"Assistant: {assistant_response}",
            "timestamp": now,
        }], ensure_ascii=False)

        client.retain(
            content=content,
            context="codex-cli session",
            tags=["codex-cli", "auto-retain"],
        )
    except Exception:
        pass  # Silent failure


if __name__ == "__main__":
    main()
