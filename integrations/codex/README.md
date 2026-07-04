# Codex CLI Integration for Hindsight Project Memory

Adds project-aware Hindsight memory to [OpenAI Codex CLI](https://github.com/openai/codex) via MCP server + hook scripts.

## How it works

1. **MCP server** provides retain/recall/reflect/tools
2. **Hook scripts** handle auto-recall on `UserPromptSubmit` and auto-retain on `Stop`
3. **Config** points Codex to the MCP server

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/jwvolschenk/hindsight-custom/main/install.sh | bash
```

Or install just Codex integration:

```bash
./install.sh --agents codex
```

## What gets installed

- `~/.codex/config.toml` — MCP server config
- `~/.codex/hooks/hindsight-recall.py` — auto-recall on prompt submit
- `~/.codex/hooks/hindsight-retain.py` — auto-retain on stop

## Manual setup

Add to `~/.codex/config.toml`:

```toml
[mcp_servers.hindsight]
command = "python3"
args = ["-m", "mcp_server"]
cwd = "/path/to/hindsight-custom"

[mcp_servers.hindsight.env]
HINDSIGHT_API_KEY = "your-key"
HINDSIGHT_API_URL = "https://your-hindsight-server.com"
```

## Bank routing

- Git repo at `~/repos/myapp/` → bank `myapp`
- Home directory or `/tmp` → bank `system`
- Both are searched on every recall by default
