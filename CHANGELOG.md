# Changelog

All notable changes to `antigravity-codex` are documented in this file.

## [Unreleased]

### Added
- **Adversarial Review & Branch Diff Review**: `run-codex review` now supports `--adversarial` (red-team audit persona + bundled `resources/adversarial-review-task.md`) and `--base <branch>` (`-Adversarial` / `-Base` on Windows) to inspect branch diffs automatically.
- **Safe Installer Preview & Uninstall**: `install.sh` (`--dry-run`, `--uninstall`) and `install.ps1` (`-DryRun`, `-Uninstall`) now support non-destructive preview and clean removal.
- **Project Governance Docs**: Added `SECURITY.md`, `CHANGELOG.md`, and independent community project disclaimer.

## [1.1.0] - 2026-11-27

### Added
- **1-Turn Instant Picker & Localized UI**: Added lightweight `/codex`-scoped `plugin/rules/AGENTS.md` preload, bilingual reasoning-depth labels, and pre-synced top-6 recent sessions per project in `SKILL.md`.
- **Bidirectional Codex Desktop Handoff**: Added `list-projects`, `list-sessions` (reading Codex sidebar `threads.name` & `recency_at`), `show-session`, `init-shared`, and `fork` with SQLite `immutable=1` read-only WAL fallback.
- **Opt-In Desktop Lock Release**: `resume` detects `already has an active writer` (`HINT_THREAD_LOCKED`) and supports explicit user-consented `--quit-app-on-lock` / `-QuitAppOnLock`.
- **Fast Path & Inline Prompts**: Added `--prompt` / `-Prompt` inline flag and Fast Path guidance for lightweight operational tasks.
- **Observability & Lifecycle Tools**: Added `doctor` health check, `--structured` / `--schema` (`resources/report.schema.json`), automatic duration/token telemetry & Git diff summary, and safe `cleanup-worktree`.

## [1.0.0] - 2026-11-27

### Added
- Initial release of the native Google Antigravity × OpenAI Codex `/codex` plugin with Bash (`run-codex.sh`) and Windows PowerShell (`run-codex.ps1`) runners, `--ignore-user-config` whitelist isolation, pinned `--json` session capture, interactive `implementation_plan.md` approval gate, and 3-platform GitHub Actions CI.
