# Claude Code Integration for Hindsight Project Memory

Adds project-aware Hindsight memory to [Claude Code](https://docs.anthropic.com/en/docs/claude-code) via MCP server + hook scripts.

## How it works

1. **MCP server** provides retain/recall/reflect/tools
2. **Hook scripts** handle auto-recall on session start and auto-retain on session end
3. **Settings** configure the MCP server connection

## Install

The unified installer handles everything:

```bash
curl -fsSL https://raw.githubusercontent.com/jwvolschenk/hindsight-custom/main/install.sh | bash
```

Or install just Claude Code integration:

```bash
./install.sh --agents claude-code
```

## What gets installed

- `~/.claude/settings.json` — MCP server config (merged with existing)
- `~/.claude/hooks/hindsight-retain.sh` — auto-retain hook
- `~/.claude/hooks/hindsight-recall.sh` — auto-recall hook

## Manual setup

If you prefer to configure manually:

1. Add to `~/.claude/settings.json`:
```json
{
  "mcpServers": {
    "hindsight": {
      "command": "python3",
      "args": ["-m", "mcp_server"],
      "cwd": "/path/to/hindsight-custom",
      "env": {
        "HINDSIGHT_API_KEY": "your-key",
        "HINDSIGHT_API_URL": "https://your-hindsight-server.com"
      }
    }
  }
}
```

2. The tools `hindsight_retain`, `hindsight_recall`, `hindsight_reflect`,
   `hindsight_project`, and `hindsight_banks` will be available automatically.

## Bank routing

- Git repo at `~/repos/myapp/` → bank `myapp`
- Home directory or `/tmp` → bank `system`
- Both are searched on every recall by default
