"""Project detection: CWD → git root → bank name.

Bank naming:
- Inside a git repo → bank is the sanitised repo directory name (e.g. 'credo_main')
- Inside $HOME git repo → falls through to 'system' (dotfiles repo)
- Outside a git repo → 'system'

Resolution order for working directory:
1. HINDSIGHT_CWD env var (set by MCP config or agent hooks)
2. cwd argument (if provided)
3. os.getcwd()
"""

from __future__ import annotations

import os
from pathlib import Path

SHARED_BANK = "system"


def resolve_working_dir() -> Path:
    """Get the current working directory.

    Checks HINDSIGHT_CWD env var first — this lets MCP server configs
    pass the agent's project directory even when the server process
    starts in a different directory (e.g. the install/lib dir).
    """
    env_cwd = os.environ.get("HINDSIGHT_CWD", "").strip()
    if env_cwd:
        p = Path(env_cwd).resolve()
        if p.is_dir():
            return p
    return Path(os.getcwd()).resolve()


def detect_project(cwd: Path | None = None) -> str:
    """Derive a project name from CWD by walking up to find .git.

    Returns the git repo directory name if inside a git repo.
    Returns 'system' for anything outside a git repo (home dir, /tmp, etc.).
    """
    if cwd is None:
        cwd = resolve_working_dir()

    resolved = cwd.resolve()
    home = _home()

    for parent in [resolved, *resolved.parents]:
        if (parent / ".git").exists():
            # Skip if git root is $HOME (dotfiles repo) — treat as system
            if home and parent == home:
                continue
            return sanitise(parent.name)

    return SHARED_BANK


def sanitise(value: str) -> str:
    """Sanitise a string for use as a bank ID.

    Converts special characters to hyphens, collapses runs,
    strips leading/trailing hyphens, and lowercases.
    """
    if not value:
        return ""
    out = []
    prev_dash = False
    for ch in value:
        if ch.isalnum() or ch in "-_":
            out.append(ch)
            prev_dash = False
        elif not prev_dash:
            out.append("-")
            prev_dash = True
    return "".join(out).strip("-_").lower()


def _home() -> Path | None:
    """Return resolved $HOME, or None if unavailable."""
    try:
        return Path.home().resolve()
    except (OSError, RuntimeError):
        return None
