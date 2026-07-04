# OpenCode Integration for Hindsight Project Memory

Adds project-aware Hindsight memory to [OpenCode](https://github.com/opencode-ai/opencode) via MCP server.

## How it works

1. **MCP server** provides retain/recall/reflect/tools via stdio transport
2. OpenCode connects to the MCP server automatically
3. Tools are available in the agent's tool palette

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/jwvolschenk/hindsight-custom/main/install.sh | bash
```

Or install just OpenCode integration:

```bash
./install.sh --agents opencode
```

## What gets installed

Adds the Hindsight MCP server to your `opencode.json` config.

## Manual setup

Add to your `opencode.json` (project root or `~/.config/opencode/opencode.json`):

```json
{
  "mcp": {
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

## Bank routing

- Git repo at `~/repos/myapp/` → bank `myapp`
- Home directory or `/tmp` → bank `system`
- Both are searched on every recall by default

## Auto-retain

OpenCode's MCP integration handles tool calls automatically. The agent
will use `hindsight_retain` when it identifies important information to
store. For fully automatic retain, you can add a rule in your OpenCode
config instructing the agent to retain after each significant exchange.
