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
from textual.css.query import NoMatches
from textual.widgets import Button, Checkbox, Footer, Header, Input, Label, RichLog, Static


VERSION = "0.2.0"
DEFAULT_API_URL = "https://api.hindsight.vectorize.io"
SPINNER = "|/-\\"
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
        width: 52;
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
    .mode-title {
        color: #e8eef2;
        text-style: bold;
        height: 1;
        margin-bottom: 1;
    }
    .mode-note {
        color: #9aa7b0;
        height: auto;
        margin-bottom: 1;
    }
    .mode-view.hidden {
        display: none;
    }
    .home-action {
        width: 1fr;
        height: 4;
        margin-bottom: 1;
    }
    .agent {
        height: 3;
    }
    .agent-list {
        height: auto;
        margin-bottom: 1;
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
        height: auto;
        margin-top: 1;
    }
    .actions-row {
        height: auto;
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
        height: 9;
        background: #0b0d0f;
        border: solid #3b454d;
        padding: 1 2;
        margin-bottom: 1;
    }
    #progress {
        height: 1;
        color: #9aa7b0;
        margin-bottom: 1;
    }
    #progress.active {
        color: #7dd3fc;
        text-style: bold;
    }
    """

    BINDINGS = [
        Binding("r", "refresh", "Refresh"),
        Binding("i", "install_mode", "Install"),
        Binding("u", "update_mode", "Update"),
        Binding("x", "uninstall_mode", "Uninstall"),
        Binding("q", "quit", "Quit"),
        Binding("ctrl+c", "quit", "Quit", priority=True),
    ]

    def __init__(self) -> None:
        super().__init__()
        self.installer_script = installer_script_path()
        self.states = detect_agents()
        self._busy = False
        self._mode = "home"
        self._spinner_index = 0
        self._progress_text = "Idle"

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        with Horizontal(id="body"):
            with Vertical(id="left", classes="panel") as left:
                left.border_title = "Workflow"
                with Vertical(id="home-view", classes="mode-view"):
                    yield Static("Choose an action", classes="mode-title")
                    yield Static("Manage Hindsight integrations from one place.", classes="mode-note")
                    yield Button("Install / Reconfigure", id="mode-install", variant="success", classes="home-action")
                    yield Button("Update Installed Files", id="mode-update", variant="primary", classes="home-action")
                    yield Button("Uninstall", id="mode-uninstall", variant="error", classes="home-action")
                    yield Static("Use r to refresh detection or Ctrl+C to quit.", classes="hint")

                with Vertical(id="install-view", classes="mode-view hidden"):
                    yield Button("Back", id="back-install", variant="default")
                    yield Static("Install / Reconfigure", classes="mode-title")
                    yield Static("Only already installed agents are selected by default.", classes="mode-note")
                    yield Static("Agent integrations", classes="section")
                    with Vertical(classes="agent-list"):
                        for state in self.states:
                            yield Checkbox(
                                self._agent_label(state),
                                value=state.installed,
                                id=f"install-agent-{state.key}",
                                classes="agent install-agent",
                            )
                    yield Static("Configuration", classes="section")
                    cfg = load_config()
                    yield Label("Hindsight API URL", classes="hint")
                    yield Input(str(cfg.get("api_url") or DEFAULT_API_URL), id="api-url")
                    yield Label("API key", classes="hint")
                    yield Input(str(cfg.get("apiKey") or ""), password=True, id="api-key")
                    with Horizontal(classes="actions-row"):
                        yield Button("Install Selected", id="run-install", variant="success")

                with Vertical(id="update-view", classes="mode-view hidden"):
                    yield Button("Back", id="back-update", variant="default")
                    yield Static("Update", classes="mode-title")
                    yield Static("Updates the shared MCP server, core library, and deployed hooks for installed agents.", classes="mode-note")
                    yield Static("Installed integrations", classes="section")
                    yield Static(id="update-targets")
                    with Horizontal(classes="actions-row"):
                        yield Button("Run Update", id="run-update", variant="primary")

                with Vertical(id="uninstall-view", classes="mode-view hidden"):
                    yield Button("Back", id="back-uninstall", variant="default")
                    yield Static("Uninstall", classes="mode-title")
                    yield Static("Only installed agents are selected by default.", classes="mode-note")
                    yield Static("Installed integrations", classes="section")
                    with Vertical(classes="agent-list"):
                        for state in self.states:
                            yield Checkbox(
                                self._agent_label(state),
                                value=state.installed,
                                id=f"uninstall-agent-{state.key}",
                                classes="agent uninstall-agent",
                            )
                    yield Static(id="uninstall-empty", classes="hint")
                    with Horizontal(classes="actions-row"):
                        yield Button("Uninstall Selected", id="run-uninstall", variant="error")
            with Vertical(id="right", classes="panel") as right:
                right.border_title = "Hindsight Control"
                yield Static(id="status")
                yield Static("Idle", id="progress")
                yield RichLog(highlight=True, markup=True, id="log")
        yield Footer()

    def on_mount(self) -> None:
        self.set_interval(0.15, self._tick_progress)
        self._show_mode("home")
        self._refresh_status()
        self._log("[bold #7dd3fc]Ready.[/] Choose install, update, or uninstall.")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        actions = {
            "mode-install": lambda: self._show_mode("install"),
            "mode-update": lambda: self._show_mode("update"),
            "mode-uninstall": lambda: self._show_mode("uninstall"),
            "back-install": lambda: self._show_mode("home"),
            "back-update": lambda: self._show_mode("home"),
            "back-uninstall": lambda: self._show_mode("home"),
            "run-install": self.action_install,
            "run-update": self.action_update,
            "run-uninstall": self.action_uninstall,
        }
        action = actions.get(str(event.button.id))
        if action:
            action()

    def action_refresh(self) -> None:
        self.states = detect_agents()
        self._sync_agent_widgets()
        self._refresh_status()
        self._log("Status refreshed.")

    def action_install_mode(self) -> None:
        self._show_mode("install")

    def action_update_mode(self) -> None:
        self._show_mode("update")

    def action_uninstall_mode(self) -> None:
        self._show_mode("uninstall")

    def action_install(self) -> None:
        agents = self._selected_agents("install")
        if not agents:
            self._log("[bold red]Select at least one agent to install.[/]")
            return
        path = save_config(self.query_one("#api-url", Input).value, self.query_one("#api-key", Input).value)
        self._log(f"Saved config: [cyan]{path}[/]")
        self._run_installer(["install", "--agents", ",".join(agents), "--skip-config"])

    def action_update(self) -> None:
        self._run_installer(["update", "--skip-config"])

    def action_uninstall(self) -> None:
        agents = self._selected_agents("uninstall")
        if not agents:
            self._log("[bold red]Select at least one agent to uninstall.[/]")
            return
        self._run_installer(["uninstall", "--agents", ",".join(agents), "--skip-config", "--yes"])

    def _selected_agents(self, prefix: str) -> list[str]:
        selected: list[str] = []
        for key, _label in AGENTS:
            try:
                checkbox = self.query_one(f"#{prefix}-agent-{key}", Checkbox)
            except NoMatches:
                continue
            if checkbox.value:
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
        self._set_progress("Running installer")
        command = ["bash", str(self.installer_script), "--legacy", *args]
        self._log(f"[bold]Host command:[/] {' '.join(command)}")

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
        self._set_progress("Idle")
        if return_code == 0:
            self._log("[bold green]Action completed.[/] Restart affected agents to activate changes.")
        else:
            self._log(f"[bold red]Action failed with exit code {return_code}.[/]")
        self.states = detect_agents()
        self._sync_agent_widgets()
        self._refresh_status()

    def _show_mode(self, mode: str) -> None:
        self._mode = mode
        for view_id in ("home-view", "install-view", "update-view", "uninstall-view"):
            view = self.query_one(f"#{view_id}", Vertical)
            if view_id == f"{mode}-view" or (mode == "home" and view_id == "home-view"):
                view.remove_class("hidden")
            else:
                view.add_class("hidden")
        self.query_one("#left", Vertical).border_title = {
            "home": "Workflow",
            "install": "Install",
            "update": "Update",
            "uninstall": "Uninstall",
        }[mode]
        self._refresh_status()

    def _refresh_status(self) -> None:
        installed = [state for state in self.states if state.installed]
        detected = [state for state in self.states if state.available and not state.installed]
        lines = [f"[bold #7dd3fc]{self._mode_label()}[/]"]
        lines.append("")
        if self._mode == "home":
            lines.append("Choose an action on the left.")
        elif self._mode == "install":
            lines.append("Tick agents to install or reconfigure.")
            lines.append("Installed agents are selected by default.")
        elif self._mode == "update":
            lines.append("Updates shared core files and installed hooks.")
        elif self._mode == "uninstall":
            lines.append("Tick installed agents to remove.")
        lines.append("")
        lines.append(f"Installed: [bold green]{len(installed)}[/]")
        lines.append(f"Detected only: [yellow]{len(detected)}[/]")
        self.query_one("#status", Static).update("\n".join(lines))
        self._refresh_target_summaries()

    def _log(self, message: str) -> None:
        self.query_one("#log", RichLog).write(message)

    def _refresh_target_summaries(self) -> None:
        installed = [state.label for state in self.states if state.installed]
        update_text = "\n".join(f"  {label}" for label in installed) if installed else "  No installed integrations detected."
        self.query_one("#update-targets", Static).update(update_text)
        self.query_one("#uninstall-empty", Static).update("" if installed else "No installed integrations detected.")

    def _sync_agent_widgets(self) -> None:
        for state in self.states:
            for prefix in ("install", "uninstall"):
                try:
                    checkbox = self.query_one(f"#{prefix}-agent-{state.key}", Checkbox)
                except NoMatches:
                    continue
                checkbox.value = state.installed
                checkbox.label = self._agent_label(state)

    def _agent_label(self, state: AgentState) -> str:
        if state.installed:
            suffix = "installed"
        elif state.available:
            suffix = "detected"
        else:
            suffix = "not detected"
        return f"{state.label}  [{suffix}]"

    def _mode_label(self) -> str:
        return {
            "home": "Start",
            "install": "Install / Reconfigure",
            "update": "Update",
            "uninstall": "Uninstall",
        }[self._mode]

    def _set_progress(self, text: str) -> None:
        self._progress_text = text
        progress = self.query_one("#progress", Static)
        if self._busy:
            progress.add_class("active")
        else:
            progress.remove_class("active")
            progress.update(text)

    def _tick_progress(self) -> None:
        if not self._busy:
            return
        self._spinner_index = (self._spinner_index + 1) % len(SPINNER)
        frame = SPINNER[self._spinner_index]
        self.query_one("#progress", Static).update(f"{frame} {self._progress_text} ...")


def main() -> None:
    HindsightInstallerApp().run()


if __name__ == "__main__":
    main()
