# Shared Workspace & Cross-Agent Memory Guide

> Use the **same local project** seamlessly across **Standalone Codex (Desktop/CLI)**, **Standalone Antigravity**, and **Antigravity `/codex`**, with bidirectional change awareness and zero mutation of Codex's internal SQLite database.

---

## Architecture Overview

```text
                    ┌──────────────────────────────┐
                    │   Same Local Git Workspace   │
                    │  Source / AGENTS.md /        │
                    │  .agents/skills/             │
                    │  .agents/state.md (hot state)│
                    │  .agents/hooks.json          │
                    └────┬───────────┬──────────┬──┘
                         │           │          │
            ┌────────────▼─┐   ┌─────▼──┐  ┌────▼──────────────┐
            │  Standalone  │   │  Solo  │  │ Antigravity       │
            │  Codex       │   │  AGY   │  │ /codex Workflow   │
            └───────┬──────┘   └────┬───┘  └───┬───────────────┘
                    │               │          │ (Phase 1 read / Phase 4 write)
                    └───────┬───────┴──────────┘
                            ▼
            ┌───────────────────────────────┐
            │ Optional: basic-memory (MCP)  │
            │ Local Markdown knowledge base │
            └───────────────────────────────┘
```

### 1. Native Shared Layer (Zero Glue Required)
- **`AGENTS.md`**: Natively loaded by both Codex and Antigravity.
- **`.agents/skills/`**: Open Agent Skills path natively discovered by both tools.
- **`.agents/state.md`**: Lightweight (< 50 lines) hot-state handoff document recording active goal, who edited last, recent changes, known issues, and next steps.
- **`.agents/hooks.json` + `.agents/hooks/session-context.sh` (or `.ps1`)**: Lightweight `SessionStart` hook injecting `git status --short`, last 5 `git log --oneline`, and `.agents/state.md` so each agent immediately sees what the other just changed.

### 2. One-Command Workspace Bootstrap (`init-shared`)

Initialize any existing project (including legacy Codex projects) safely and idempotently — never overwrites existing `AGENTS.md` or `.agents/state.md`:

**macOS / Linux:**
```bash
~/.gemini/config/plugins/codex-collaborator/skills/codex/scripts/run-codex.sh init-shared /path/to/project --exclude-state
```

**Windows (PowerShell):**
```powershell
pwsh -NoProfile -File "$HOME\.gemini\config\plugins\codex-collaborator\skills\codex\scripts\run-codex.ps1" init-shared C:\path\to\project -ExcludeState
```

- `--exclude-state` / `-ExcludeState` adds `.agents/state.md` to `.git/info/exclude` so your local handoff notes never pollute `git status` or modify tracked `.gitignore`.

### 3. Continuing Existing Codex Threads (`list-sessions` & `fork`)

Read-only query against `~/.codex/state_5.sqlite` (opened strictly with `?mode=ro`, never mutating Codex's database):

```bash
# List recent active Codex threads for a workspace
~/.gemini/config/plugins/codex-collaborator/skills/codex/scripts/run-codex.sh list-sessions /path/to/project --limit 10

# Continue directly inside an existing Codex thread (default in /codex)
~/.gemini/config/plugins/codex-collaborator/skills/codex/scripts/run-codex.sh resume /path/to/project /path/to/plan.md /path/to/out.md --session <thread_id>

# Or non-destructively fork an existing Codex thread into a new session
~/.gemini/config/plugins/codex-collaborator/skills/codex/scripts/run-codex.sh fork /path/to/project /path/to/plan.md /path/to/out.md --session <thread_id>
```

### 4. Optional Long-Term Shared Memory (`basic-memory`)

For cross-project, searchable long-term memory stored as plain local Markdown:
1. Install [`basicmachines-co/basic-memory`](https://github.com/basicmachines-co/basic-memory) (`brew install basic-memory` or `uv tool install basic-memory`).
2. Register `basic-memory mcp` in both `~/.codex/config.toml` and `~/.gemini/config/mcp_config.json`.
3. In `/codex`, **Antigravity** reads `basic-memory` during Phase 1 planning and acts as the **single writer** during Phase 4 review, so Codex stays lean with `--ignore-user-config` while both sides share the exact same long-term knowledge base.
