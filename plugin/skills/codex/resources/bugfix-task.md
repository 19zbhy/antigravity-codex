# Bugfix Task Spec

> 执行方式：用户确认后通过 codex 技能调用 `run-codex.sh execute` 交由 Codex CLI 精准修复并自测闭环
> Codex 运行配置：model=<默认或指定> | effort=<默认或指定> | tier=<默认或指定>

## 1. Symptom & Reproduction（现象与复现路径）
- Expected behavior vs. actual buggy behavior, plus minimal reproduction steps or failing test.

## 2. Root Cause & Fix Direction（根因与修复方向）
- Confirmed root cause and surgical fix constraints (avoid unrelated refactors).

## 3. Workspace Root & Scope Boundaries（作用域红线）
- **Workspace Root**: `/absolute/path/to/workspace`
- **Allowed Files**: Narrow list of affected files/modules.
- **Do NOT Touch**: Unrelated modules; do not run `git commit` or `git push`.

## 4. Regression Verification（回归验证标准）
- Add/update a regression test covering this bug and pass the build/test commands below.
