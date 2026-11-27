# Read-Only Code Review & Audit Spec

> 执行方式：通过 codex 技能调用 `run-codex.sh review` 在 `read-only` 沙箱中由 Codex CLI 只读审计（严禁修改任何文件）
> Codex 运行配置：model=<默认或指定> | effort=<默认或指定> | tier=<默认或指定>

## 1. Audit Scope & Focus（审查范围与重点）
- **Workspace Root**: `/absolute/path/to/workspace`
- **Target Files / Diff / Modules**: Specify what to inspect.
- **Focus Areas**: Correctness, edge cases, security, concurrency, performance, or architecture smells.

## 2. Output Format（输出要求）
- Group findings by severity (`Critical` / `Warning` / `Suggestion`) with exact `file:line` references, concrete failure scenarios, and concise fix recommendations.
- Do not dump entire source files; keep findings crisp and actionable.
