"""Configuration loading for Hindsight custom memory.

Config is loaded from (in priority order):
1. Explicit path passed to load_config()
2. $HINDSIGHT_CONFIG env var
3. ~/.hindsight-custom/config.json

Environment variables override config file values:
- HINDSIGHT_API_KEY overrides apiKey
- HINDSIGHT_API_URL overrides api_url
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import List, Optional

_DEFAULT_API_URL = "https://api.hindsight.vectorize.io"
_DEFAULT_TIMEOUT = 120


@dataclass
class Config:
    """Resolved configuration for the Hindsight memory system."""

    api_url: str = _DEFAULT_API_URL
    api_key: str = ""
    timeout: int = _DEFAULT_TIMEOUT
    budget: str = "mid"
    search_shared: bool = True

    # Retain controls
    auto_retain: bool = True
    retain_every_n_turns: int = 3
    retain_async: bool = True
    retain_context: str = "conversation"

    # Recall controls
    recall_max_tokens: int = 4096
    recall_types: List[str] = field(default_factory=lambda: ["observation"])
    recall_max_input_chars: int = 800
    recall_deduplicate: bool = True

    @property
    def is_configured(self) -> bool:
        """Return True if we have enough config to connect."""
        return bool(self.api_key or self.api_url != _DEFAULT_API_URL)


def load_config(path: Optional[Path] = None) -> Config:
    """Load and merge configuration from file + environment.

    Args:
        path: Explicit config file path. If None, uses default locations.

    Returns:
        Resolved Config with env vars taking precedence.
    """
    raw: dict = {}

    # Find config file
    if path and path.exists():
        raw = _read_json(path)
    else:
        for candidate in _default_paths():
            if candidate.exists():
                raw = _read_json(candidate)
                break

    # Build config with env overrides
    cfg = Config(
        api_url=_env_or("HINDSIGHT_API_URL", raw.get("api_url", _DEFAULT_API_URL)),
        api_key=_env_or(
            "HINDSIGHT_API_KEY",
            raw.get("apiKey") or raw.get("api_key") or raw.get("api-key", ""),
        ),
        timeout=int(raw.get("timeout", _DEFAULT_TIMEOUT)),
        budget=raw.get("budget", "mid"),
        search_shared=raw.get("search_shared", True),
        auto_retain=raw.get("auto_retain", True),
        retain_every_n_turns=max(1, int(raw.get("retain_every_n_turns", 3))),
        retain_async=raw.get("retain_async", True),
        retain_context=raw.get("retain_context", "conversation"),
        recall_max_tokens=int(raw.get("recall_max_tokens", 4096)),
        recall_types=raw.get("recall_types", ["observation"]),
        recall_max_input_chars=int(raw.get("recall_max_input_chars", 800)),
        recall_deduplicate=raw.get("recall_deduplicate", True),
    )
    return cfg


def _default_paths() -> List[Path]:
    """Return candidate config file paths in priority order."""
    candidates = []

    # XDG config home
    xdg = os.environ.get("XDG_CONFIG_HOME", "")
    if xdg:
        candidates.append(Path(xdg) / "hindsight-custom" / "config.json")

    # ~/.hindsight-custom/config.json
    try:
        home = Path.home()
        candidates.append(home / ".hindsight-custom" / "config.json")
        # Also check Hermes-specific location for backward compat
        candidates.append(home / ".hermes" / "hindsight-custom" / "config.json")
    except (OSError, RuntimeError):
        pass

    return candidates


def _read_json(path: Path) -> dict:
    """Read a JSON file, returning empty dict on error."""
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}


def _env_or(env_var: str, default: str) -> str:
    """Return env var value if set, otherwise the default."""
    val = os.environ.get(env_var, "").strip()
    return val if val else default
