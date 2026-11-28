# Security Policy

## Security & Sandbox Design

`antigravity-codex` is designed to keep local dual-agent workflows safe by default without weakening Codex CLI's built-in protections:

- **No Sandbox Bypass**: We intentionally do **not** pass `--dangerously-bypass-approvals-and-sandbox` or `--dangerously-bypass-hook-trust`.
  - Write tasks (`execute`, `resume`, `fork`) run with `--approve-for-me` (or `--full-auto` on older CLIs), staying inside `workspace-write` sandbox boundaries.
  - Audit tasks (`review`, including `--adversarial`) strictly enforce `-s read-only`.
- **Fail-Closed Isolation**:
  - `--worktree` refuses to execute (never silently falling back to the main working tree) if the target directory is not a Git repository or the installed Codex CLI lacks `--worktree`.
  - `cleanup-worktree` refuses to remove the main repository checkout, dirty worktrees, or unmerged branches unless `--force` is explicitly passed.
  - `resume` never silently guesses `--last` when a pinned session ID is missing.
- **Explicit Consent for Desktop Lock Release**:
  - If `resume` encounters `already has an active writer` from Codex Desktop App, `run-codex` fails closed by default and never terminates your desktop app unless `--quit-app-on-lock` / `-QuitAppOnLock` is explicitly supplied after user confirmation.
- **Read-Only Local State Access & Zero Telemetry**:
  - Local Codex metadata (`~/.codex/config.toml`, `~/.codex/models_cache.json`, `~/.codex/state_5.sqlite`) is accessed strictly read-only (`?mode=ro`, falling back to `&immutable=1` under WAL locks).
  - No usage data, prompts, or workspace contents are transmitted to any third-party service by this plugin.

## Reporting a Vulnerability

If you discover a security issue (such as shell injection, path traversal, or unintended file modification), please open a private security advisory on GitHub or contact the maintainer via GitHub Issues without posting sensitive exploit details publicly.
