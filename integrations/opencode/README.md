# OpenCode Integration for Hindsight Project Memory

Adds project-aware Hindsight memory to [OpenCode](https://github.com/opencode-ai/opencode) as a native plugin with tools and hooks.

## How it works

1. **Native plugin** (TypeScript) registers `hindsight_retain`, `hindsight_recall`, `hindsight_reflect` as tools
2. **Project detection** automatically routes memories to project-specific banks
3. **MCP server** available as fallback if npm is not available for building the native plugin
4. Uses the same project detection logic as the MCP server and Hermes plugin — identical behaviour across all agents

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/jwvolschenk/hindsight-custom/main/install.sh | bash
```

The installer will:
1. Copy the plugin source to `~/.config/hindsight-custom/opencode-plugin/`
2. Build the TypeScript plugin (if npm/pnpm is available)
3. Add the plugin to `opencode.json`

If npm is not available, it falls back to MCP server configuration.

## What gets installed

- `~/.config/hindsight-custom/opencode-plugin/` — built native plugin
- `opencode.json` — plugin reference (or MCP server config as fallback)

## Plugin structure

```
integrations/opencode/
  package.json           # npm package manifest
  tsconfig.json          # TypeScript config
  src/
    index.ts             # Plugin entry point (tools + hooks)
    project.ts           # Project detection (git root → bank name)
    client.ts            # Hindsight API client (fetch-based)
```

## Tools registered

| Tool | Description |
|------|-------------|
| `hindsight_retain` | Store a memory (auto-routes to project bank) |
| `hindsight_recall` | Search memories (project + system banks) |
| `hindsight_reflect` | Reason across all memories |

## Bank routing

- Git repo at `~/repos/myapp/` → bank `myapp`
- Home directory or `/tmp` → bank `system`
- Both are searched on every recall by default

## Config

Environment variables (set in `opencode.json` or shell):

| Variable | Default | Description |
|----------|---------|-------------|
| `HINDSIGHT_API_URL` | `https://api.hindsight.vectorize.io` | Hindsight API endpoint |
| `HINDSIGHT_API_KEY` | (none) | API key |
| `HINDSIGHT_BUDGET` | `mid` | Recall budget: low, mid, high |
| `HINDSIGHT_SEARCH_SHARED` | `true` | Also search system bank |
