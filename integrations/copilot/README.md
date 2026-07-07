# GitHub Copilot Integration for Hindsight Project Memory

Adds project-aware Hindsight memory to [GitHub Copilot](https://github.com/features/copilot) via MCP server. Works with both Copilot in VS Code (agent mode) and Copilot CLI.

## How it works

1. **MCP server** provides retain/recall/reflect tools via MCP
2. **Copilot instructions** guide the agent to use memory tools appropriately
3. Copilot connects to the MCP server automatically

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/jwvolschenk/hindsight-custom/main/install.sh | bash
```

Or install just Copilot integration:

```bash
./install.sh --agents copilot
```

## What gets installed

- `~/.vscode/mcp.json` — MCP server config for Copilot in VS Code
- `~/.copilot/mcp-config.json` — MCP server config for Copilot CLI (updated if exists)
- `.github/copilot-instructions.md` — memory usage rules (merged with existing)

## Config locations

Copilot has two separate MCP config files:

| File | Used by | Key format |
|------|---------|------------|
| `~/.vscode/mcp.json` | Copilot in VS Code agent mode | `servers` |
| `~/.copilot/mcp-config.json` | Copilot CLI | `mcpServers` |

The installer updates both files when they exist.

## Manual setup

### 1. MCP server config

**VS Code** — add to `~/.vscode/mcp.json`:

```json
{
  "servers": {
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

**Copilot CLI** — add to `~/.copilot/mcp-config.json`:

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

### 2. Copilot instructions

Add to `.github/copilot-instructions.md` in your project or home directory:

```markdown
## Memory

You have access to persistent long-term memory via Hindsight tools:

- `hindsight_retain` — Store important information, decisions, and context
- `hindsight_recall` — Search for relevant memories before answering
- `hindsight_reflect` — Reason across all memories for complex questions

Use `hindsight_recall` at the start of conversations to check for relevant
prior context. Use `hindsight_retain` to store important decisions,
architectural choices, and user preferences.
```

## Bank routing

- Git repo at `~/repos/myapp/` → bank `myapp`
- Home directory or `/tmp` → bank `system`
- Both are searched on every recall by default

## Limitations

GitHub Copilot's MCP support is available in agent mode only (VS Code 1.99+).
The standard Copilot autocomplete/inline suggestions do not use MCP tools.
