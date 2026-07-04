"""Hindsight Project-Aware MCP Server.

Exposes Hindsight memory tools via the Model Context Protocol with
automatic project detection and bank routing.

Bank naming:
- Inside a git repo → bank is the repo name (e.g. 'credo_main')
- Outside a git repo → bank is 'system'

All agents that support MCP (Claude Code, Copilot, OpenCode, Codex, etc.)
connect to this server and get the same project-aware memory behaviour.
"""

from __future__ import annotations

import json
import logging
import os
import sys
from typing import Any

# Add parent dir to path so `core` is importable when running as script
_here = os.path.dirname(os.path.abspath(__file__))
_parent = os.path.dirname(_here)
if _parent not in sys.path:
    sys.path.insert(0, _parent)

from mcp.server.fastmcp import FastMCP
from mcp.server.stdio import stdio_server

from core.client import HindsightClient
from core.config import load_config
from core.project import SHARED_BANK, detect_project

logger = logging.getLogger("hindsight-mcp")

# ---------------------------------------------------------------------------
# Server setup
# ---------------------------------------------------------------------------

mcp = FastMCP(
    "hindsight",
    instructions=(
        "Hindsight project-aware memory tools. "
        "Memories are automatically routed to project-specific banks based on "
        "the current git repository. Use retain to store knowledge, recall to "
        "search it, and reflect for reasoned answers across all memories."
    ),
)

# Client is initialised lazily on first tool call
_client: HindsightClient | None = None


def _get_client() -> HindsightClient:
    """Get or create the Hindsight client."""
    global _client
    if _client is None:
        config = load_config()
        _client = HindsightClient(config)
        _client.connect()
    return _client


# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------


@mcp.tool()
def hindsight_retain(
    content: str,
    context: str = "",
    tags: list[str] | None = None,
    bank: str = "",
) -> str:
    """Store information in long-term memory.

    Hindsight automatically extracts structured facts, resolves entities,
    and indexes for retrieval. Memories are stored in the current project's
    bank automatically.

    Args:
        content: The information to store.
        context: Short label (e.g. 'user preference', 'project decision').
        tags: Optional tags for categorisation.
        bank: Override bank (default: auto-detected from project).
              Use 'system' for cross-project knowledge.
    """
    client = _get_client()
    result = client.retain(
        content=content,
        bank=bank,
        context=context or None,
        tags=tags,
    )
    return json.dumps(result)


@mcp.tool()
def hindsight_recall(
    query: str,
    bank: str = "",
) -> str:
    """Search long-term memory.

    Returns memories ranked by relevance using semantic search, keyword
    matching, entity graph traversal, and reranking. Searches both the
    current project bank and the shared system bank by default.

    Args:
        query: What to search for.
        bank: Override bank to search (default: project + system).
    """
    client = _get_client()
    result = client.recall(query=query, bank=bank)
    return json.dumps(result)


@mcp.tool()
def hindsight_reflect(
    query: str,
    bank: str = "",
) -> str:
    """Synthesise a reasoned answer from long-term memories.

    Unlike recall, this reasons across all stored memories to produce
    a coherent response.

    Args:
        query: The question to reflect on.
        bank: Override bank (default: project bank).
    """
    client = _get_client()
    result = client.reflect(query=query, bank=bank)
    return json.dumps(result)


@mcp.tool()
def hindsight_project(
    action: str,
    project: str = "",
) -> str:
    """Show or override the current project context for memory routing.

    Args:
        action: 'show' to display current routing, 'set' to override project name.
        project: Project name (required for 'set' action).
    """
    client = _get_client()

    if action == "show":
        return json.dumps(client.project_info())
    elif action == "set":
        if not project:
            return json.dumps({"error": "project name required for 'set'"})
        new_bank = client.set_project(project)
        return json.dumps({
            "result": f"Project set to '{client.project}'",
            "project_bank": new_bank,
        })
    else:
        return json.dumps({"error": f"Unknown action: {action}"})


@mcp.tool()
def hindsight_banks(
    action: str,
    bank_id: str = "",
    name: str = "",
) -> str:
    """List, inspect, or create Hindsight memory banks.

    Args:
        action: One of 'list', 'create', 'delete', 'stats'.
        bank_id: Bank ID (for create/delete/stats).
        name: Human-readable bank name (for create).
    """
    client = _get_client()

    if action == "list":
        return json.dumps(client.list_banks())
    elif action == "create":
        if not bank_id:
            return json.dumps({"error": "bank_id required for create"})
        return json.dumps(client.create_bank(bank_id, name))
    elif action == "delete":
        if not bank_id:
            return json.dumps({"error": "bank_id required for delete"})
        return json.dumps(client.delete_bank(bank_id))
    elif action == "stats":
        return json.dumps(client.bank_stats(bank_id))
    else:
        return json.dumps({"error": f"Unknown action: {action}"})


# ---------------------------------------------------------------------------
# Resources (project info as a readable resource)
# ---------------------------------------------------------------------------


@mcp.resource("hindsight://project")
def get_project_info() -> str:
    """Current project routing information."""
    client = _get_client()
    info = client.project_info()
    return (
        f"Project: {info['project']}\n"
        f"Bank: {info['project_bank']}\n"
        f"Shared: {info['shared_bank']}\n"
        f"CWD: {info['cwd']}\n"
        f"Search shared: {info['search_shared']}"
    )


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main():
    """Run the MCP server on stdio transport."""
    logging.basicConfig(
        level=logging.WARNING,
        format="%(name)s: %(message)s",
        stream=sys.stderr,
    )
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
