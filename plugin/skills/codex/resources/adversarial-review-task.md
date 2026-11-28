# Adversarial Code & Design Review Specification

> Mode: Strict `read-only` adversarial audit (`run-codex.sh review ... --adversarial [--base <branch>]`). Do NOT modify any files.

## 1. Target & Scope
- **Workspace Root**: `/absolute/path/to/workspace`
- **Target Branch / Files**: (e.g. changes vs `main`, or specific modules)

## 2. Adversarial Attack Vectors (Actively Try to Break It)
Do not praise the implementation. Assume bugs, hidden assumptions, and failure paths exist and hunt for:
1. **Broken Assumptions & Edge Cases**: Empty/null/malformed inputs, path spaces/special characters, platform differences (macOS BSD vs GNU Linux vs Windows PowerShell), partial failures, and stale state.
2. **Concurrency, Locking & State Races**: Simultaneous runs, file/DB locks, non-atomic writes, leftover artifacts, or interrupted executions.
3. **Security & Permission Boundaries**: Command/shell injection, unquoted variables, privilege escalation, unintended file writes outside scope, or secret/PII leakage.
4. **Silent Failure & Misleading UX**: Swallowed exit codes, fallback paths that silently weaken guarantees, or error messages that hide root causes.

## 3. Output Format
Group concrete findings strictly by severity (`P0 / Critical`, `P1 / High`, `P2 / Medium`, `P3 / Low`):
- Exact `file:line` reference
- Minimal reproduction scenario or concrete failure path
- Direct, minimal fix recommendation

If no credible issues exist in a category, state that briefly without filler.
