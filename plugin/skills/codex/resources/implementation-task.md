# Implementation Task Spec

> 执行方式：用户确认后通过 codex 技能调用 `run-codex.sh execute` 交由 Codex CLI 自主工程实现与现场自测闭环
> Codex 运行配置：model=<默认或指定> | effort=<默认或指定> | tier=<默认或指定>

## 1. Goal & Behavior（目标与体验逻辑）
- Describe the user-facing behavior, business goal, and expected inputs/outputs in plain language.

## 2. Edge Cases & Guardrails（防坑与边缘情况）
- Empty / malformed inputs, concurrency or state sync, backward compatibility constraints.

## 3. Workspace Root & Scope Boundaries（架构切入点与作用域红线）
- **Workspace Root**: `/absolute/path/to/workspace`
- **Relevant Modules / Conventions**: Existing files or patterns to follow.
- **Do NOT Touch**: Files/directories strictly out of scope; do not run `git commit` or `git push`.

## 4. Self-Test & Acceptance Criteria（现场自测与交付标准）
- Build / typecheck / lint / unit test commands Codex must run and pass before finishing.
