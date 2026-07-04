# GitHub Copilot Integration for Hindsight Project Memory

Adds project-aware Hindsight memory to [GitHub Copilot](https://github.com/features/copilot) in VS Code agent mode via MCP server.

## How it works

1. **MCP server** provides retain/recall/reflect/tools via VS Code's MCP support
2. **Copilot instructions** guide the agent to use memory tools appropriately
3. VS Code connects to the MCP server automatically when Copilot agent mode is active

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/jwvolschenk/hindsight-custom/main/install.sh | bash
```

Or install just Copilot integration:

```bash
./install.sh --agents copilot
```

## What gets installed

- `.vscode/mcp.json` in your home directory — MCP server config
- `.github/copilot-instructions.md` — memory usage rules (merged with existing)

## Manual setup

### 1. MCP server config

Add to `~/.vscode/mcp.json` (global) or `.vscode/mcp.json` (per-project):

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
