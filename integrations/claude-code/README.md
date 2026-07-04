# Claude Code Integration for Hindsight Project Memory

Adds project-aware Hindsight memory to [Claude Code](https://docs.anthropic.com/en/docs/claude-code) as a native plugin with MCP server + lifecycle hooks.

## How it works

1. **Plugin manifest** (`.claude-plugin/plugin.json`) — registers with Claude Code's plugin system
2. **MCP server** provides retain/recall/reflect/tools via stdio transport
3. **Hook scripts** handle auto-recall on prompt submit and auto-retain on response
4. Uses the same core library as the MCP server — identical behaviour across all agents

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/jwvolschenk/hindsight-custom/main/install.sh | bash
```

Or install just Claude Code:

```bash
./install.sh install --agents 2
```

## What gets installed

- `~/.claude/plugins/hindsight-custom/` — plugin manifest
- `~/.claude/settings.json` — MCP server config (merged with existing)
- `~/.claude/hooks/hindsight-recall.sh` — auto-recall hook
- `~/.claude/hooks/hindsight-retain.sh` — auto-retain hook

## Plugin structure

```
.claude-plugin/
  plugin.json          # Plugin manifest (name, version, description)
```

## MCP Server

The MCP server runs via stdio and exposes five tools:

| Tool | Description |
|------|-------------|
| `hindsight_retain` | Store a memory (auto-routes to project bank) |
| `hindsight_recall` | Search memories (project + system banks) |
| `hindsight_reflect` | Reason across all memories |
| `hindsight_project` | Show/override active project |
| `hindsight_banks` | List/create/delete banks |

## Bank routing

- Git repo at `~/repos/myapp/` → bank `myapp`
- Home directory or `/tmp` → bank `system`
- Both are searched on every recall by default
