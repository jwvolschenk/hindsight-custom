# Hindsight Custom — Agent-Agnostic Project Memory

Agent-agnostic project-aware memory routing for Hindsight.
Works with any MCP-compatible agent (Claude Code, Copilot, OpenCode, Codex)
plus a native Hermes Agent plugin.

## Structure

```
core/                          Shared library
  project.py                   Project detection (git root -> bank name)
  config.py                    Config loading (file + env vars)
  client.py                    Hindsight client with bank routing

mcp_server/                    Unified MCP server (stdio transport)
  server.py                    FastMCP server exposing 5 tools
  config.example.json          Config template

integrations/                  Agent-specific plugins
  hermes/                      Hermes Agent MemoryProvider plugin
  claude-code/                 Claude Code hooks + MCP config
  opencode/                    OpenCode MCP config
  codex/                       Codex CLI hooks + MCP config
  copilot/                     GitHub Copilot MCP + instructions

install.sh                     Unified installer (all agents)
pyproject.toml                 Python package definition
```

## Key rules

- Bank naming: `<repo_name>` (e.g. credo_main, backend, frontend)
- Outside git repos: bank is `system`
- Config: `~/.config/hindsight-custom/config.json`
- Env vars: `HINDSIGHT_API_KEY`, `HINDSIGHT_API_URL`
- MCP server runs on stdio transport (one process per agent connection)
- Core library is shared between MCP server and all integrations

## When modifying

- Core logic: edit `core/` files
- MCP tools: edit `mcp_server/server.py`
- Agent integration: edit `integrations/<agent>/`
- After changes: `./install.sh` to redeploy
- Restart affected agents

## Dependencies

- Python >= 3.10
- hindsight-client >= 0.6.0
- mcp >= 1.0.0
