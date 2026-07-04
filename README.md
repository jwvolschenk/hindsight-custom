# Hindsight Custom — Project-Aware Memory for Any Agent

Agent-agnostic, project-aware memory routing for [Hindsight](https://vectorize.io/hindsight).
Automatically detects which git repository you're working in and routes memories to
project-specific banks. Works with any MCP-compatible coding agent.

## What it does

```
~/repos/credo_main/  →  bank: credo_main
~/repos/backend/     →  bank: backend
~/repos/frontend/    →  bank: frontend
~  or  /tmp          →  bank: system
```

Every recall searches **both** the project bank and the shared `system` bank,
so cross-project knowledge is always available.

## Supported Agents

| Agent | Integration | Auto-recall | Auto-retain |
|-------|------------|:-----------:|:-----------:|
| **Hermes Agent** | MemoryProvider plugin | ✅ prefetch | ✅ every N turns |
| **Claude Code** | MCP + hooks | ✅ hook | ✅ hook |
| **Codex CLI** | MCP + hooks | ✅ hook | ✅ hook |
| **OpenCode** | MCP server | via tools | via tools |
| **GitHub Copilot** | MCP + instructions | via tools | via tools |

## Architecture

```mermaid
flowchart TB
    subgraph Agents["Coding Agents"]
        A1["Hermes Agent"]
        A2["Claude Code"]
        A3["Codex CLI"]
        A4["OpenCode"]
        A5["GitHub Copilot"]
    end

    subgraph Integrations["Agent Integrations"]
        I1["MemoryProvider\nPlugin"]
        I2["Hooks\n(recall/retain)"]
        I3["Hooks +\nhooks.json"]
        I4["MCP Config\n(opencode.json)"]
        I5["MCP Config\n(.vscode/mcp.json)"]
    end

    subgraph Core["Core Library"]
        P["project.py\nGit root → bank name"]
        C["config.py\nConfig loading"]
        H["client.py\nHindsight API wrapper"]
    end

    subgraph MCP["MCP Server"]
        S["server.py\nFastMCP (stdio)"]
    end

    subgraph Backend["Hindsight API"]
        API["retain / recall / reflect"]
        B1["bank: credo_main"]
        B2["bank: backend"]
        B3["bank: system"]
    end

    A1 --> I1
    A2 --> I2
    A3 --> I3
    A4 --> I4
    A5 --> I5

    I1 -->|direct| Core
    I2 -->|stdio| MCP
    I3 -->|stdio| MCP
    I4 -->|stdio| MCP
    I5 -->|stdio| MCP

    S --> Core
    I1 --> Core
    H --> API

    API --- B1
    API --- B2
    API --- B3
```

## Project Detection Flow

```mermaid
flowchart TD
    START["Agent opens terminal\nin a directory"] --> RESOLVE["Resolve CWD\n(os.getcwd)"]
    RESOLVE --> CHECK_GIT{"Directory or\nparent has\n.git?"}

    CHECK_GIT -->|Yes| CHECK_HOME{"Is git root\nthe same as\n$HOME?"}
    CHECK_HOME -->|Yes| SKIP["Skip (dotfiles repo)"]
    SKIP --> CHECK_GIT
    CHECK_HOME -->|No| SANITISE["Sanitise repo name\n(lowercase, alphanumeric)"]
    SANITISE --> BANK["bank: &lt;repo_name&gt;\ne.g. credo_main"]

    CHECK_GIT -->|No| SYSTEM["bank: system\n(cross-project shared)"]

    BANK --> SEARCH["Recall searches\nproject bank + system bank"]
    SYSTEM --> SEARCH

    style BANK fill:#1a6b3c,color:#fff
    style SYSTEM fill:#2d5a8e,color:#fff
```

## Installation Flow

```mermaid
flowchart TD
    RUN["curl | bash\nor ./install.sh"] --> DETECT["Detect installed agents\n(hermes, claude, opencode,\ncodex, vscode)"]
    DETECT --> PROMPT{"Show detected\nagents and\nprompt user"}

    PROMPT --> SELECT["User selects agents\nto configure"]
    SELECT --> ENDPOINT["Ask: Default cloud\nor self-hosted URL?"]
    ENDPOINT --> KEY["Ask: API key"]
    KEY --> INSTALL_CORE["Install core library\n+ MCP server\nto ~/.config/\nhindsight-custom/lib/"]
    INSTALL_CORE --> INSTALL_DEPS["pip install\nhindsight-client mcp"]
    INSTALL_DEPS --> INSTALL_AGENTS{"For each\nselected agent"}

    INSTALL_AGENTS --> H1["Hermes:\nPlugin + config.yaml"]
    INSTALL_AGENTS --> H2["Claude Code:\nMCP in settings.json\n+ hook scripts"]
    INSTALL_AGENTS --> H3["Codex CLI:\nhooks.json\n+ config.toml\n+ hook scripts"]
    INSTALL_AGENTS --> H4["OpenCode:\nMCP in opencode.json"]
    INSTALL_AGENTS --> H5["Copilot:\nMCP in .vscode/mcp.json\n+ instructions"]

    H1 --> DONE["Restart agents to activate"]
    H2 --> DONE
    H3 --> DONE
    H4 --> DONE
    H5 --> DONE
```

## Memory Flow (Per Agent)

```mermaid
sequenceDiagram
    participant User
    participant Agent
    participant Hooks
    participant MCP as MCP Server
    participant Core as Core Library
    participant API as Hindsight API

    Note over User,API: Session Start
    Agent->>MCP: Connect (stdio)
    MCP->>Core: detect_project(CWD)
    Core-->>MCP: project="credo_main"
    MCP->>API: ensure_bank("credo_main")

    Note over User,API: User sends prompt
    Agent->>Hooks: UserPromptSubmit
    Hooks->>Core: recall("what DB does this use?")
    Core->>API: recall(bank="credo_main", query=...)
    Core->>API: recall(bank="system", query=...)
    API-->>Core: results
    Core-->>Hooks: memories
    Hooks-->>Agent: inject context

    Note over User,API: Agent responds
    Agent->>Hooks: Stop
    Hooks->>Core: retain(exchange)
    Core->>API: retain(bank="credo_main", content=...)
    API-->>Core: stored
```

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/jwvolschenk/hindsight-custom/main/install.sh | bash
```

On an interactive terminal the installer opens **Hindsight Control**, a Textual
management UI for configuring API settings, installing agent integrations,
updating the shared MCP server, and selectively uninstalling integrations.

Force the legacy shell installer:

```bash
curl -fsSL https://raw.githubusercontent.com/jwvolschenk/hindsight-custom/main/install.sh | bash -s -- --legacy
```

Install specific agents only:

```bash
./install.sh install --agents claude-code,codex
```

Non-interactive (all agents, no prompts):

```bash
./install.sh install --all --yes
```

Build a standalone TUI binary:

```bash
./scripts/build-installer-binary.sh
```

## Configuration

Config file: `~/.config/hindsight-custom/config.json`

```json
{
  "api_url": "https://api.hindsight.vectorize.io",
  "apiKey": "your-api-key",
  "timeout": 300,
  "budget": "mid",
  "search_shared": true,
  "auto_retain": true,
  "retain_every_n_turns": 3,
  "recall_max_input_chars": 800
}
```

Or set environment variables: `HINDSIGHT_API_KEY`, `HINDSIGHT_API_URL`.

### Key Settings

| Setting | Default | Description |
|---------|---------|-------------|
| `search_shared` | `true` | Also search `system` bank on recall |
| `retain_every_n_turns` | `3` | Auto-retain frequency (1 = every turn) |
| `budget` | `"mid"` | Recall budget: `low`, `mid`, `high` |
| `recall_max_input_chars` | `800` | Truncate queries to this length |

## MCP Server

The MCP server is the heart of the integration. All agents connect to it via
stdio transport. It exposes five tools:

| Tool | Description |
|------|-------------|
| `hindsight_retain` | Store a memory (auto-routes to project bank) |
| `hindsight_recall` | Search memories (project + system banks) |
| `hindsight_reflect` | Reason across all memories for a coherent answer |
| `hindsight_project` | Show or override the active project |
| `hindsight_banks` | List, create, delete, or inspect banks |

Run directly for testing:

```bash
python3 -m mcp_server
```

## Project Structure

```
hindsight-custom/
├── core/                    Shared Python library
│   ├── project.py           Git root → bank name detection
│   ├── config.py            Config loading (file + env vars)
│   └── client.py            Hindsight API wrapper with bank routing
│
├── mcp_server/              MCP server (stdio transport)
│   ├── server.py            FastMCP server with 5 tools
│   ├── __main__.py          python -m mcp_server
│   └── config.example.json  Config template
│
├── integrations/            Agent-specific code
│   ├── hermes/              MemoryProvider plugin (direct core usage)
│   ├── claude-code/         Hooks (recall.sh, retain.sh) + README
│   ├── codex/               Hooks + hooks.json + README
│   ├── opencode/            MCP config + README
│   └── copilot/             MCP config + instructions + README
│
├── install.sh               Interactive unified installer
├── pyproject.toml           Python package definition
├── AGENTS.md                Agent development guide
└── README.md                This file
```

## Uninstall

```bash
./install.sh --uninstall
```

## Development

```bash
# Clone
git clone git@github.com:jwvolschenk/hindsight-custom.git
cd hindsight-custom

# Install deps
pip install hindsight-client mcp

# Test core library
python3 -c "from core.project import detect_project; print(detect_project())"

# Test MCP server starts
python3 -m mcp_server

# Run the installer
./install.sh --all
```

## How Agents Connect

| Agent | Transport | Auto-hooks | Config File |
|-------|-----------|------------|-------------|
| **Hermes** | Direct (Python) | sync_turn, prefetch | `~/.hermes/config.yaml` |
| **Claude Code** | stdio MCP | UserPromptSubmit, Stop | `~/.claude/settings.json` |
| **Codex CLI** | stdio MCP | UserPromptSubmit, Stop | `~/.codex/config.toml` + `hooks.json` |
| **OpenCode** | stdio MCP | via tools | `opencode.json` |
| **Copilot** | stdio MCP | via instructions | `.vscode/mcp.json` |

## License

MIT
