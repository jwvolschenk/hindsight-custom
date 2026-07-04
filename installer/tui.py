#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
from dataclasses import dataclass
from pathlib import Path

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.widgets import Button, Checkbox, Footer, Header, Input, Label, RichLog, Static


VERSION = "0.1.0"
DEFAULT_API_URL = "https://api.hindsight.vectorize.io"
AGENTS = [
    ("hermes", "Hermes Agent"),
    ("claude-code", "Claude Code"),
    ("opencode", "OpenCode"),
    ("codex", "Codex CLI"),
    ("copilot", "GitHub Copilot"),
]


@dataclass
class AgentState:
    key: str
    label: str
    available: bool
    installed: bool


def config_dir() -> Path:
    return Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "hindsight-custom"


def config_file() -> Path:
    return config_dir() / "config.json"


def _json_has(path: Path, top_key: str, child_key: str) -> bool:
    try:
        data = json.loads(path.read_text())
    except Exception:
        return False
    return child_key in data.get(top_key, {})


def detect_agents() -> list[AgentState]:
    home = Path.home()
    states: list[AgentState] = []

    for key, label in AGENTS:
        available = False
        installed = False

        if key == "hermes":
            available = (home / ".hermes").exists()
            installed = (home / ".hermes/plugins/hindsight-custom/__init__.py").exists()
        elif key == "claude-code":
            available = (home / ".claude").exists() or bool(_which("claude"))
            installed = _json_has(home / ".claude/settings.json", "mcpServers", "hindsight")
        elif key == "opencode":
            available = (home / ".config/opencode/opencode.json").exists() or bool(_which("opencode"))
            installed = _json_has(home / ".config/opencode/opencode.json", "mcp", "hindsight")
        elif key == "codex":
            available = (home / ".codex").exists() or bool(_which("codex"))
            installed = _codex_installed(home / ".codex/hooks.json")
        elif key == "copilot":
            available = (home / ".vscode").exists() or bool(_which("code"))
            installed = _json_has(home / ".vscode/mcp.json", "servers", "hindsight")

        states.append(AgentState(key, label, available, installed))

    return states


def _which(command: str) -> str | None:
    paths = os.environ.get("PATH", "").split(os.pathsep)
    for path in paths:
        candidate = Path(path) / command
        if candidate.exists() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def _codex_installed(path: Path) -> bool:
    try:
        data = json.loads(path.read_text())
    except Exception:
        return False
    hooks = data.get("hooks", {})
    for hook_list in hooks.values():
        for hook in hook_list:
            if "hindsight" in " ".join(hook.get("args", [])):
                return True
    return False


def load_config() -> dict[str, object]:
    defaults: dict[str, object] = {
        "api_url": os.environ.get("HINDSIGHT_API_URL", DEFAULT_API_URL),
        "apiKey": os.environ.get("HINDSIGHT_API_KEY", ""),
        "timeout": 300,
        "budget": "mid",
        "search_shared": True,
        "auto_retain": True,
        "retain_every_n_turns": 3,
        "recall_max_input_chars": 800,
    }
    path = config_file()
    if not path.exists():
        return defaults
    try:
        current = json.loads(path.read_text())
    except Exception:
        return defaults
    defaults.update(current)
    if os.environ.get("HINDSIGHT_API_KEY"):
        defaults["apiKey"] = os.environ["HINDSIGHT_API_KEY"]
    if os.environ.get("HINDSIGHT_API_URL"):
        defaults["api_url"] = os.environ["HINDSIGHT_API_URL"]
    return defaults


def save_config(api_url: str, api_key: str) -> Path:
    cfg = load_config()
    cfg["api_url"] = api_url.strip() or DEFAULT_API_URL
    cfg["apiKey"] = api_key.strip()
    path = config_file()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(cfg, indent=2) + "\n")
    return path


def installer_script_path() -> Path:
    configured = os.environ.get("HINDSIGHT_INSTALLER_SCRIPT")
    if configured:
        return Path(configured).resolve()
    bundled_dir = getattr(sys, "_MEIPASS", None)
    if bundled_dir:
        bundled = Path(bundled_dir) / "install.sh"
        if bundled.exists():
            return bundled
    return Path("install.sh").resolve()


class HindsightInstallerApp(App[None]):
    TITLE = f"Hindsight Control {VERSION}"
    CSS = """
    Screen {
        background: #101214;
        color: #e8eef2;
        layout: vertical;
    }
    #body {
        height: 1fr;
        padding: 1 2;
    }
    .panel {
        border: solid #3b454d;
        border-title-color: #7dd3fc;
        background: #171b1f;
        padding: 1 2;
        margin: 0 1;
    }
    #left {
        width: 42;
        height: 1fr;
    }
    #right {
        width: 1fr;
        height: 1fr;
    }
    .section {
        color: #7dd3fc;
        text-style: bold;
        height: 1;
        margin-top: 1;
    }
    .hint {
        color: #9aa7b0;
        height: 1;
    }
    .agent {
        height: 3;
    }
    Input {
        height: 3;
        background: #0b0d0f;
        border: tall #3b454d;
    }
    Input:focus {
        border: tall #7dd3fc;
    }
    #actions {
        height: 5;
        margin-top: 1;
    }
    Button {
        height: 3;
        margin-right: 1;
    }
    #log {
        height: 1fr;
        background: #0b0d0f;
        border: solid #3b454d;
        padding: 0 1;
    }
    #status {
        height: 6;
        background: #0b0d0f;
        border: solid #3b454d;
        padding: 1 2;
        margin-bottom: 1;
    }
    """

    BINDINGS = [
        Binding("r", "refresh", "Refresh"),
        Binding("i", "install", "Install"),
        Binding("u", "update", "Update"),
        Binding("x", "uninstall", "Uninstall"),
        Binding("q", "quit", "Quit"),
        Binding("ctrl+c", "quit", "Quit", priority=True),
    ]

    def __init__(self) -> None:
        super().__init__()
        self.installer_script = installer_script_path()
        self.states = detect_agents()
        self._busy = False

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        with Horizontal(id="body"):
            with Vertical(id="left", classes="panel") as left:
                left.border_title = "Targets"
                yield Static("Agent integrations", classes="section")
                for state in self.states:
                    label = f"{state.label} [{'installed' if state.installed else 'not installed'}]"
                    yield Checkbox(label, value=state.installed or state.available, id=f"agent-{state.key}", classes="agent")
                yield Static("Configuration", classes="section")
                cfg = load_config()
                yield Label("Hindsight API URL", classes="hint")
                yield Input(str(cfg.get("api_url") or DEFAULT_API_URL), id="api-url")
                yield Label("API key", classes="hint")
                yield Input(str(cfg.get("apiKey") or ""), password=True, id="api-key")
                with Horizontal(id="actions"):
                    yield Button("Install", id="install", variant="success")
                    yield Button("Update", id="update", variant="primary")
                    yield Button("Uninstall", id="uninstall", variant="error")
            with Vertical(id="right", classes="panel") as right:
                right.border_title = "Hindsight Control"
                yield Static(id="status")
                yield RichLog(highlight=True, markup=True, id="log")
        yield Footer()

    def on_mount(self) -> None:
        self._refresh_status()
        self._log("[bold #7dd3fc]Ready.[/] Select agents, adjust config, then choose an action.")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        actions = {
            "install": self.action_install,
            "update": self.action_update,
            "uninstall": self.action_uninstall,
        }
        action = actions.get(str(event.button.id))
        if action:
            action()

    def action_refresh(self) -> None:
        self.states = detect_agents()
        self._refresh_status()
        self._log("Status refreshed.")

    def action_install(self) -> None:
        agents = self._selected_agents()
        if not agents:
            self._log("[bold red]Select at least one agent to install.[/]")
            return
        path = save_config(self.query_one("#api-url", Input).value, self.query_one("#api-key", Input).value)
        self._log(f"Saved config: [cyan]{path}[/]")
        self._run_installer(["install", "--agents", ",".join(agents), "--skip-config"])

    def action_update(self) -> None:
        self._run_installer(["update", "--skip-config"])

    def action_uninstall(self) -> None:
        agents = self._selected_agents()
        if not agents:
            self._log("[bold red]Select at least one agent to uninstall.[/]")
            return
        self._run_installer(["uninstall", "--agents", ",".join(agents), "--skip-config", "--yes"])

    def _selected_agents(self) -> list[str]:
        selected: list[str] = []
        for key, _label in AGENTS:
            if self.query_one(f"#agent-{key}", Checkbox).value:
                selected.append(key)
        return selected

    def _run_installer(self, args: list[str]) -> None:
        if self._busy:
            self._log("[dim]Another installer action is still running.[/]")
            return
        if not self.installer_script.exists():
            self._log(f"[bold red]Installer script not found:[/] {self.installer_script}")
            return

        self._busy = True
        command = ["bash", str(self.installer_script), "--legacy", *args]
        self._log(f"[bold]Running:[/] {' '.join(command[2:])}")

        def worker() -> None:
            env = os.environ.copy()
            env["HINDSIGHT_INSTALLER_NO_TUI"] = "1"
            proc = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                env=env,
            )
            assert proc.stdout is not None
            for line in proc.stdout:
                self.call_from_thread(self._log, line.rstrip())
            return_code = proc.wait()
            self.call_from_thread(self._installer_done, return_code)

        threading.Thread(target=worker, daemon=True).start()

    def _installer_done(self, return_code: int) -> None:
        self._busy = False
        if return_code == 0:
            self._log("[bold green]Action completed.[/] Restart affected agents to activate changes.")
        else:
            self._log(f"[bold red]Action failed with exit code {return_code}.[/]")
        self.states = detect_agents()
        self._refresh_status()

    def _refresh_status(self) -> None:
        lines = []
        for state in self.states:
            if state.installed:
                badge = "[bold green]installed[/]"
            elif state.available:
                badge = "[yellow]detected[/]"
            else:
                badge = "[dim]not detected[/]"
            lines.append(f"{state.label:<16} {badge}")
        self.query_one("#status", Static).update("\n".join(lines))

    def _log(self, message: str) -> None:
        self.query_one("#log", RichLog).write(message)


def main() -> None:
    HindsightInstallerApp().run()


if __name__ == "__main__":
    main()
