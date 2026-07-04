"""Hermes Agent memory provider plugin for Hindsight Custom.

Implements the Hermes MemoryProvider ABC by using the same core library
that the MCP server uses. This ensures conformity across all agents:
- MCP server: core library via MCP protocol
- Hermes plugin: core library via direct Python import
- Claude Code / Codex / OpenCode / Copilot: MCP server via stdio

The core library is installed at ~/.config/hindsight-custom/lib/.
This plugin adds that path to sys.path and imports HindsightClient.
"""

from __future__ import annotations

import json
import logging
import os
import queue
import sys
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

# ── Hermes imports ──────────────────────────────────────────────────────────
from agent.memory_provider import MemoryProvider

# ── Core library ────────────────────────────────────────────────────────────
# Find the installed core library (same code the MCP server uses)
_INSTALL_DIR = os.path.join(
    os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")),
    "hindsight-custom", "lib"
)
if os.path.isdir(_INSTALL_DIR) and _INSTALL_DIR not in sys.path:
    sys.path.insert(0, _INSTALL_DIR)

from core.client import HindsightClient
from core.config import load_config
from core.project import SHARED_BANK

logger = logging.getLogger(__name__)

# ── Tool schemas (exposed to the LLM via Hermes) ───────────────────────────

_RETAIN_SCHEMA = {
    "name": "hindsight_retain",
    "description": (
        "Store information to long-term memory. Hindsight automatically "
        "extracts structured facts, resolves entities, and indexes for retrieval. "
        "Memories are stored in the current project's bank automatically."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "content": {"type": "string", "description": "The information to store."},
            "context": {"type": "string", "description": "Short label (e.g. 'user preference', 'project decision')."},
            "tags": {"type": "array", "items": {"type": "string"}, "description": "Optional tags."},
            "bank": {"type": "string", "description": "Override bank (default: auto-detected from project). Use 'system' for cross-project knowledge."},
        },
        "required": ["content"],
    },
}

_RECALL_SCHEMA = {
    "name": "hindsight_recall",
    "description": (
        "Search long-term memory. Returns memories ranked by relevance. "
        "Searches both the current project bank and the shared system bank."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "query": {"type": "string", "description": "What to search for."},
            "bank": {"type": "string", "description": "Override bank to search (default: project + system)."},
        },
        "required": ["query"],
    },
}

_REFLECT_SCHEMA = {
    "name": "hindsight_reflect",
    "description": "Synthesise a reasoned answer from long-term memories.",
    "parameters": {
        "type": "object",
        "properties": {
            "query": {"type": "string", "description": "The question to reflect on."},
            "bank": {"type": "string", "description": "Override bank (default: project bank)."},
        },
        "required": ["query"],
    },
}

_BANKS_SCHEMA = {
    "name": "hindsight_banks",
    "description": "List, inspect, or create Hindsight memory banks.",
    "parameters": {
        "type": "object",
        "properties": {
            "action": {"type": "string", "enum": ["list", "create", "delete", "stats"], "description": "Action to perform."},
            "bank_id": {"type": "string", "description": "Bank ID (for create/delete/stats)."},
            "name": {"type": "string", "description": "Human-readable bank name (for create)."},
        },
        "required": ["action"],
    },
}

_PROJECT_SCHEMA = {
    "name": "hindsight_project",
    "description": "Show or override the current project context for memory routing.",
    "parameters": {
        "type": "object",
        "properties": {
            "action": {"type": "string", "enum": ["show", "set"], "description": "'show' to display current routing, 'set' to override project name."},
            "project": {"type": "string", "description": "Project name (for 'set' action)."},
        },
        "required": ["action"],
    },
}


# ── Provider ────────────────────────────────────────────────────────────────

class HindsightProjectProvider(MemoryProvider):
    """Hindsight memory provider with per-project bank routing for Hermes.

    Uses the same HindsightClient from core/ that the MCP server uses,
    ensuring identical behaviour across all agent integrations.
    """

    def __init__(self):
        self._client: HindsightClient | None = None
        self._config = None
        self._session_id: str = ""
        self._platform: str = ""

        # Retain controls
        self._auto_retain: bool = True
        self._retain_every_n_turns: int = 3
        self._retain_context: str = "conversation between Hermes Agent and the User"
        self._turn_counter: int = 0
        self._session_turns: list[str] = []
        self._document_id: str = ""

        # Writer queue for async retain
        self._retain_queue: queue.Queue = queue.Queue()
        self._writer_thread: threading.Thread | None = None
        self._shutting_down = threading.Event()

        # Prefetch
        self._prefetch_result: str = ""
        self._prefetch_lock = threading.Lock()
        self._prefetch_thread: threading.Thread | None = None

    @property
    def name(self) -> str:
        return "hindsight-custom"

    def is_available(self) -> bool:
        cfg = load_config()
        return cfg.is_configured

    def initialize(self, session_id: str, **kwargs) -> None:
        self._session_id = str(session_id or "").strip()
        self._platform = str(kwargs.get("platform") or "").strip()

        self._config = load_config()
        self._client = HindsightClient(self._config)
        self._client.connect()

        self._auto_retain = self._config.auto_retain
        self._retain_every_n_turns = self._config.retain_every_n_turns

        start_ts = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
        self._document_id = f"{self._session_id}-{start_ts}"
        self._session_turns = []
        self._turn_counter = 0

        logger.info(
            "hindsight-custom initialized: project=%s, bank=%s, shared=%s, retain_every=%d",
            self._client.project, self._client.project_bank,
            SHARED_BANK, self._retain_every_n_turns,
        )

    def system_prompt_block(self) -> str:
        if not self._client:
            return ""
        return (
            f"# Hindsight Project Memory\n"
            f"Active bank: `{self._client.project_bank}`\n"
            f"Shared knowledge bank: `{SHARED_BANK}`\n"
            f"Use `hindsight_retain` to store project decisions and context. "
            f"Use `hindsight_recall` to search prior work. "
            f"Use `hindsight_project` to check or change the active project.\n"
        )

    # ── Prefetch (auto-recall) ──────────────────────────────────────────────

    def prefetch(self, query: str, *, session_id: str = "") -> str:
        if self._prefetch_thread and self._prefetch_thread.is_alive():
            self._prefetch_thread.join(timeout=3.0)
        with self._prefetch_lock:
            result = self._prefetch_result
            self._prefetch_result = ""
        if not result:
            return ""
        header = (
            "# Hindsight Memory (persistent cross-session context)\n"
            "Use this to answer questions about the user and prior sessions. "
            "Do not call tools to look up information that is already present here."
        )
        return f"{header}\n\n{result}"

    def queue_prefetch(self, query: str, *, session_id: str = "") -> None:
        if not self._auto_retain or self._shutting_down.is_set() or not self._client:
            return
        if self._config.recall_max_input_chars and len(query) > self._config.recall_max_input_chars:
            query = query[:self._config.recall_max_input_chars]

        def _run():
            try:
                resp = self._client.recall(query)
                text = resp.get("result", "")
                if text and "No relevant" not in text:
                    with self._prefetch_lock:
                        self._prefetch_result = text
            except Exception as e:
                logger.debug("Prefetch failed: %s", e)

        self._prefetch_thread = threading.Thread(target=_run, daemon=True, name="htp-prefetch")
        self._prefetch_thread.start()

    # ── Sync turn (auto-retain) ─────────────────────────────────────────────

    def sync_turn(self, user_content, assistant_content, *, session_id="", messages=None):
        if not self._auto_retain or self._shutting_down.is_set() or not self._client:
            return
        if session_id:
            self._session_id = str(session_id).strip()

        now = datetime.now(timezone.utc).isoformat()
        turn = json.dumps([
            {"role": "user", "content": f"User: {user_content}", "timestamp": now},
            {"role": "assistant", "content": f"Assistant: {assistant_content}", "timestamp": now},
        ], ensure_ascii=False)
        self._session_turns.append(turn)
        self._turn_counter += 1

        if self._turn_counter % self._retain_every_n_turns != 0:
            return

        content = "[" + ",".join(self._session_turns) + "]"
        tags = [f"session:{self._session_id}"] if self._session_id else None

        def _do_retain():
            try:
                self._client.retain(
                    content=content,
                    context=self._retain_context,
                    tags=tags,
                    document_id=self._document_id,
                    metadata={
                        "retained_at": now,
                        "message_count": str(len(self._session_turns) * 2),
                        "turn_index": str(self._turn_counter),
                        "session_id": self._session_id,
                        "platform": self._platform,
                    },
                )
                logger.debug("Retain succeeded: %d turns", len(self._session_turns))
            except Exception as e:
                logger.warning("Retain failed: %s", e)

        self._ensure_writer()
        self._retain_queue.put(_do_retain)

    def _ensure_writer(self):
        if self._writer_thread and self._writer_thread.is_alive():
            return
        def _drain():
            while not self._shutting_down.is_set():
                try:
                    job = self._retain_queue.get(timeout=1.0)
                    if job is None: break
                    job()
                except queue.Empty: continue
        self._writer_thread = threading.Thread(target=_drain, daemon=True, name="htp-writer")
        self._writer_thread.start()

    # ── Session lifecycle ───────────────────────────────────────────────────

    def on_session_switch(self, new_session_id, **kwargs):
        new_id = str(new_session_id or "").strip()
        if not new_id or not self._client: return

        if self._session_turns:
            old_content = "[" + ",".join(self._session_turns) + "]"
            try:
                self._client.retain(
                    content=old_content, context=self._retain_context,
                    tags=[f"session:{self._session_id}"] if self._session_id else None,
                    document_id=self._document_id,
                )
            except Exception as e:
                logger.debug("Flush-on-switch failed: %s", e)

        self._session_id = new_id
        start_ts = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
        self._document_id = f"{self._session_id}-{start_ts}"
        self._session_turns = []
        self._turn_counter = 0
        self._client.connect()

    def on_session_end(self, messages):
        if self._session_turns and self._client:
            old_content = "[" + ",".join(self._session_turns) + "]"
            try:
                self._client.retain(
                    content=old_content, context=self._retain_context,
                    tags=[f"session:{self._session_id}"] if self._session_id else None,
                    document_id=self._document_id,
                )
            except Exception as e:
                logger.debug("Session-end flush failed: %s", e)

    def shutdown(self):
        self._shutting_down.set()
        if self._session_turns and self._client:
            try: self.on_session_end([])
            except Exception: pass
        if self._writer_thread and self._writer_thread.is_alive():
            self._retain_queue.put(None)
            self._writer_thread.join(timeout=5)
        if self._client:
            self._client.shutdown()

    # ── Tools (same as MCP server tools) ────────────────────────────────────

    def get_tool_schemas(self):
        return [_RETAIN_SCHEMA, _RECALL_SCHEMA, _REFLECT_SCHEMA, _BANKS_SCHEMA, _PROJECT_SCHEMA]

    def handle_tool_call(self, tool_name, args, **kwargs):
        if not self._client:
            return json.dumps({"error": "Hindsight client not initialized"})

        if tool_name == "hindsight_retain":
            return json.dumps(self._client.retain(
                content=args.get("content", ""), bank=args.get("bank", ""),
                context=args.get("context"), tags=args.get("tags"),
            ))
        elif tool_name == "hindsight_recall":
            return json.dumps(self._client.recall(
                query=args.get("query", ""), bank=args.get("bank", ""),
            ))
        elif tool_name == "hindsight_reflect":
            return json.dumps(self._client.reflect(
                query=args.get("query", ""), bank=args.get("bank", ""),
            ))
        elif tool_name == "hindsight_banks":
            action = args.get("action", "list")
            if action == "list":   return json.dumps(self._client.list_banks())
            if action == "create": return json.dumps(self._client.create_bank(args.get("bank_id", ""), args.get("name", "")))
            if action == "delete": return json.dumps(self._client.delete_bank(args.get("bank_id", "")))
            if action == "stats":  return json.dumps(self._client.bank_stats(args.get("bank_id", "")))
            return json.dumps({"error": f"Unknown action: {action}"})
        elif tool_name == "hindsight_project":
            action = args.get("action", "show")
            if action == "show": return json.dumps(self._client.project_info())
            if action == "set":
                project = args.get("project", "")
                if not project: return json.dumps({"error": "project name required"})
                new_bank = self._client.set_project(project)
                return json.dumps({"result": f"Project set to '{self._client.project}'", "project_bank": new_bank})
            return json.dumps({"error": f"Unknown action: {action}"})

        return json.dumps({"error": f"Unknown tool: {tool_name}"})


# ── Plugin registration ─────────────────────────────────────────────────────

def register(ctx):
    """Register as a Hermes memory provider plugin."""
    ctx.register_memory_provider(HindsightProjectProvider())
