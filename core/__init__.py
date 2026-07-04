"""Core library for Hindsight project-aware memory routing.

Provides project detection (git root → bank name) and a Hindsight
client wrapper that automatically routes to the correct bank.

Bank naming: <repo_name> (e.g. credo_main, backend)
- In a git repo: bank is the repo directory name
- Outside a git repo: bank is 'system'
"""

from core.project import detect_project, sanitise, resolve_working_dir
from core.config import load_config, Config
from core.client import HindsightClient

__all__ = [
    "detect_project",
    "sanitise",
    "resolve_working_dir",
    "load_config",
    "Config",
    "HindsightClient",
]
