#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${REPO_ROOT}/install.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/antigravity-codex-test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Copy plugin into an isolated temp copy so running tests NEVER modifies tracked repo files
cp -R "${REPO_ROOT}/plugin" "${TMP_ROOT}/plugin"
RUNNER="${TMP_ROOT}/plugin/skills/codex/scripts/run-codex.sh"
chmod +x "$RUNNER"

PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  [PASS] $name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  [FAIL] $name: expected='$expected' actual='$actual'" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
    echo "  [PASS] $name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  [FAIL] $name: expected to find '$needle' in:" >&2
    printf '%s\n' "$haystack" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if ! printf '%s' "$haystack" | grep -Fq -- "$needle"; then
    echo "  [PASS] $name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  [FAIL] $name: did NOT expect to find '$needle' in:" >&2
    printf '%s\n' "$haystack" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# Create mock codex CLI
MOCK_BIN="${TMP_ROOT}/bin"
mkdir -p "$MOCK_BIN"
ARGS_LOG="${TMP_ROOT}/mock_codex_args.log"

cat > "${MOCK_BIN}/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--version" ]]; then
  echo "codex-cli 0.171.0-mock"
  exit 0
fi

if [[ "${1:-}" == "login" ]] && [[ "${2:-}" == "status" ]]; then
  echo "Logged in using Mock"
  exit 0
fi

if [[ "${1:-}" == "exec" ]] && [[ "${2:-}" == "--help" ]]; then
  echo "Usage: codex exec [OPTIONS] [PROMPT]"
  echo "  --approve-for-me"
  echo "  --ignore-user-config"
  if [[ "${MOCK_NO_WORKTREE:-0}" != "1" ]]; then
    echo "  --worktree"
  fi
  exit 0
fi

# Record all arguments for assertions
printf '%s\n' "$*" >> "${MOCK_ARGS_LOG}"

# Extract -o <file> if present and write a mock summary
OUT_FILE=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "-o" ]]; then
    OUT_FILE="$arg"
    break
  fi
  prev="$arg"
done

# Consume stdin so pipes never SIGPIPE
cat >/dev/null || true

# Optional tiny delay for concurrency testing
if [[ -n "${MOCK_SLEEP:-}" ]]; then
  sleep "${MOCK_SLEEP}"
fi

if [[ "${MOCK_NO_SESSION:-0}" != "1" ]]; then
  echo "session id: ${MOCK_SESSION_ID:-11111111-2222-3333-4444-555555555555}"
fi
if [[ -n "${MOCK_EXTRA_LOG:-}" ]]; then
  printf '%s\n' "${MOCK_EXTRA_LOG}"
fi
if [[ -n "$OUT_FILE" ]] && [[ "${MOCK_NO_SUMMARY:-0}" != "1" ]]; then
  echo "Mock summary completed." > "$OUT_FILE"
fi
exit 0
EOF
chmod +x "${MOCK_BIN}/codex"

export PATH="${MOCK_BIN}:${PATH}"
export MOCK_ARGS_LOG="$ARGS_LOG"

WORKSPACE="${TMP_ROOT}/workspace"
mkdir -p "$WORKSPACE"
PLAN_FILE="${TMP_ROOT}/plan.md"
echo "# Test Plan" > "$PLAN_FILE"

echo "=== Test 1: TOML top-level vs [profiles.*] & [features] scoping ==="
CODEX_HOME_1="${TMP_ROOT}/codex_home_1"
mkdir -p "$CODEX_HOME_1"
cat > "${CODEX_HOME_1}/config.toml" <<'EOF'
# No top-level model set!
service_tier = "priority"

[profiles.dev]
model = "profile-only-model"
model_reasoning_effort = "xhigh"

[other_table]
respect_system_proxy = true
EOF
cat > "${CODEX_HOME_1}/models_cache.json" <<'EOF'
{
  "models": [
    {"slug": "gpt-6.2-sol", "display_name": "GPT-6.2-Sol", "visibility": "list", "supported_reasoning_levels": [{"effort": "low"}, {"effort": "high"}]},
    {"slug": "hidden-model", "display_name": "Hidden", "visibility": "hide", "supported_reasoning_levels": [{"effort": "medium"}]}
  ]
}
EOF

OPTS_OUT="$(CODEX_HOME="$CODEX_HOME_1" "$RUNNER" list-options)"
assert_contains "top-level default_model is default (not profile model)" "- default_model: default" "$OPTS_OUT"
assert_not_contains "profile model does not leak" "profile-only-model" "$OPTS_OUT"
assert_contains "visible model listed" "gpt-6.2-sol (GPT-6.2-Sol)" "$OPTS_OUT"
assert_not_contains "hidden model excluded" "hidden-model" "$OPTS_OUT"

: > "$ARGS_LOG"
CODEX_HOME="$CODEX_HOME_1" "$RUNNER" execute "$WORKSPACE" "$PLAN_FILE" "${TMP_ROOT}/t1_out.md" >/dev/null
T1_ARGS="$(cat "$ARGS_LOG")"
assert_contains "isolation enabled" "--ignore-user-config" "$T1_ARGS"
assert_not_contains "profile model not forwarded" "profile-only-model" "$T1_ARGS"
assert_not_contains "respect_system_proxy outside [features] ignored" "respect_system_proxy" "$T1_ARGS"

echo "=== Test 2: Concurrent runs without OUTPUT_FILE (macOS BSD mktemp fix) ==="
: > "$ARGS_LOG"
MOCK_SLEEP=0.2 CODEX_HOME="$CODEX_HOME_1" "$RUNNER" execute "$WORKSPACE" "$PLAN_FILE" >/dev/null &
PID1=$!
MOCK_SLEEP=0.2 CODEX_HOME="$CODEX_HOME_1" "$RUNNER" execute "$WORKSPACE" "$PLAN_FILE" >/dev/null &
PID2=$!
RC1=0; wait "$PID1" || RC1=$?
RC2=0; wait "$PID2" || RC2=$?
assert_eq "concurrent run 1 exits 0" "0" "$RC1"
assert_eq "concurrent run 2 exits 0" "0" "$RC2"

echo "=== Test 3: --worktree fail-closed checks ==="
: > "$ARGS_LOG"
set +e
WT_NOGIT_ERR="$(CODEX_HOME="$CODEX_HOME_1" "$RUNNER" execute "$WORKSPACE" "$PLAN_FILE" --worktree 2>&1)"
WT_NOGIT_RC=$?
set -e
assert_eq "--worktree fails on non-git dir" "2" "$WT_NOGIT_RC"
assert_contains "--worktree non-git error message" "requires a Git repository" "$WT_NOGIT_ERR"
assert_eq "codex not invoked on non-git worktree failure" "" "$(cat "$ARGS_LOG")"

GIT_WS="${TMP_ROOT}/git_ws"
mkdir -p "$GIT_WS"
(cd "$GIT_WS" && git init -q)
: > "$ARGS_LOG"
set +e
WT_UNSUP_ERR="$(MOCK_NO_WORKTREE=1 CODEX_HOME="$CODEX_HOME_1" "$RUNNER" execute "$GIT_WS" "$PLAN_FILE" --worktree 2>&1)"
WT_UNSUP_RC=$?
set -e
assert_eq "--worktree fails closed when CLI unsupported" "2" "$WT_UNSUP_RC"
assert_contains "--worktree unsupported error message" "Refusing to fall back" "$WT_UNSUP_ERR"
assert_eq "codex not invoked when --worktree unsupported" "" "$(cat "$ARGS_LOG")"

: > "$ARGS_LOG"
CODEX_HOME="$CODEX_HOME_1" "$RUNNER" execute "$GIT_WS" "$PLAN_FILE" --worktree >/dev/null
assert_contains "--worktree passed when supported in git repo" "--worktree" "$(cat "$ARGS_LOG")"

echo "=== Test 4: Session ID capture, stale artifact reset, & fail-closed resume ==="
: > "$ARGS_LOG"
SESS_OUT="${TMP_ROOT}/pinned/last.md"
MOCK_SESSION_ID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" CODEX_HOME="$CODEX_HOME_1" "$RUNNER" execute "$WORKSPACE" "$PLAN_FILE" "$SESS_OUT" >/dev/null
SAVED_SID="$(cat "${TMP_ROOT}/pinned/last.session_id")"
assert_eq "session ID saved cleanly" "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" "$SAVED_SID"

: > "$ARGS_LOG"
CODEX_HOME="$CODEX_HOME_1" "$RUNNER" resume "$WORKSPACE" "$PLAN_FILE" "$SESS_OUT" >/dev/null
RES_ARGS="$(cat "$ARGS_LOG")"
assert_contains "resume uses pinned session ID" "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" "$RES_ARGS"
assert_not_contains "resume does not use --last when session ID pinned" "--last" "$RES_ARGS"

# Task B reuses same output path without emitting session ID or summary -> stale artifacts must be cleared
TASK_B_OUT="$(MOCK_NO_SESSION=1 MOCK_NO_SUMMARY=1 CODEX_HOME="$CODEX_HOME_1" "$RUNNER" execute "$WORKSPACE" "$PLAN_FILE" "$SESS_OUT")"
assert_not_contains "stale summary is not reprinted" "Mock summary completed." "$TASK_B_OUT"
assert_eq "stale session_id file removed" "0" "$( [[ -f "${TMP_ROOT}/pinned/last.session_id" ]] && echo 1 || echo 0 )"

# Resume without pinned session ID fails closed by default
: > "$ARGS_LOG"
set +e
RES_FAIL_ERR="$(CODEX_HOME="$CODEX_HOME_1" "$RUNNER" resume "$WORKSPACE" "$PLAN_FILE" "$SESS_OUT" 2>&1)"
RES_FAIL_RC=$?
set -e
assert_eq "resume fails closed without pinned session ID" "2" "$RES_FAIL_RC"
assert_contains "resume fail-closed error message" "No pinned session ID found" "$RES_FAIL_ERR"
assert_eq "codex not invoked on fail-closed resume" "" "$(cat "$ARGS_LOG")"

# Explicit --last overrides an existing .session_id file
MOCK_SESSION_ID="11111111-1111-1111-1111-111111111111" CODEX_HOME="$CODEX_HOME_1" "$RUNNER" execute "$WORKSPACE" "$PLAN_FILE" "$SESS_OUT" >/dev/null
: > "$ARGS_LOG"
CODEX_HOME="$CODEX_HOME_1" "$RUNNER" resume "$WORKSPACE" "$PLAN_FILE" "$SESS_OUT" --last >/dev/null
EXPLICIT_LAST_ARGS="$(cat "$ARGS_LOG")"
assert_contains "explicit --last passes --last even when .session_id exists" "--last" "$EXPLICIT_LAST_ARGS"
assert_not_contains "explicit --last does not use stale pinned ID" "11111111-1111-1111-1111-111111111111" "$EXPLICIT_LAST_ARGS"

# Mutual exclusion: --session + --last fails closed AND preserves existing summary
echo "Existing summary must survive" > "$SESS_OUT"
set +e
MUTEX_ERR="$(CODEX_HOME="$CODEX_HOME_1" "$RUNNER" resume "$WORKSPACE" "$PLAN_FILE" "$SESS_OUT" --session "abc12345" --last 2>&1)"
MUTEX_RC=$?
set -e
assert_eq "--session + --last fails closed" "2" "$MUTEX_RC"
assert_contains "--session + --last error message" "mutually exclusive" "$MUTEX_ERR"
assert_contains "existing summary preserved on failed resume" "Existing summary must survive" "$(cat "$SESS_OUT")"

# Mixed log: inspected file containing thread_id must NOT overwrite real session id
MIXED_OUT="${TMP_ROOT}/mixed/last.md"
MOCK_SESSION_ID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" \
  MOCK_EXTRA_LOG='Example from inspected file: {"thread_id":"bbbbbbbb-cccc-dddd-eeee-ffffffffffff"}' \
  CODEX_HOME="$CODEX_HOME_1" "$RUNNER" execute "$WORKSPACE" "$PLAN_FILE" "$MIXED_OUT" >/dev/null
assert_eq "mixed log keeps authoritative session ID" "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" "$(cat "${TMP_ROOT}/mixed/last.session_id")"

# Default temp mode retains log/session AND can be resumed directly via its last_message.md
TEMP_MODE_OUT="$(MOCK_SESSION_ID="99999999-8888-7777-6666-555555555555" CODEX_HOME="$CODEX_HOME_1" "$RUNNER" execute "$WORKSPACE" "$PLAN_FILE")"
TEMP_LOG_PATH="$(printf '%s\n' "$TEMP_MODE_OUT" | sed -n 's/.*Full process log: //p' | head -n 1)"
TEMP_MD_PATH="${TEMP_LOG_PATH%.log}.md"
assert_eq "temp-mode log file still exists after exit" "1" "$( [[ -n "$TEMP_LOG_PATH" && -f "$TEMP_LOG_PATH" ]] && echo 1 || echo 0 )"
: > "$ARGS_LOG"
CODEX_HOME="$CODEX_HOME_1" "$RUNNER" resume "$WORKSPACE" "$PLAN_FILE" "$TEMP_MD_PATH" >/dev/null
assert_contains "temp-mode run can be resumed via its last_message.md" "99999999-8888-7777-6666-555555555555" "$(cat "$ARGS_LOG")"
if [[ -n "$TEMP_LOG_PATH" ]]; then
  rm -rf "$(dirname "$TEMP_LOG_PATH")"
fi

echo "=== Test 5: Read-only review & custom provider fallback ==="
: > "$ARGS_LOG"
CODEX_HOME="$CODEX_HOME_1" "$RUNNER" review "$WORKSPACE" "$PLAN_FILE" >/dev/null
REV_ARGS="$(cat "$ARGS_LOG")"
assert_contains "review uses -s read-only" "-s read-only" "$REV_ARGS"
assert_not_contains "review never uses workspace-write" "workspace-write" "$REV_ARGS"

CODEX_HOME_CUSTOM="${TMP_ROOT}/codex_home_custom"
mkdir -p "$CODEX_HOME_CUSTOM"
cat > "${CODEX_HOME_CUSTOM}/config.toml" <<'EOF'
model = "deepseek-coder"
model_provider = "deepseek"

[features]
respect_system_proxy = true
EOF
: > "$ARGS_LOG"
CODEX_HOME="$CODEX_HOME_CUSTOM" "$RUNNER" execute "$WORKSPACE" "$PLAN_FILE" >/dev/null
assert_not_contains "custom provider skips --ignore-user-config" "--ignore-user-config" "$(cat "$ARGS_LOG")"

echo "=== Test 6: End-to-end install.sh ==="
FAKE_HOME="${TMP_ROOT}/fake_home"
mkdir -p "$FAKE_HOME"
TARGET_HOME="$FAKE_HOME" CODEX_HOME="$CODEX_HOME_1" "$INSTALLER" >/dev/null
INSTALLED_SKILL="${FAKE_HOME}/.gemini/config/plugins/codex-collaborator/skills/codex/SKILL.md"
assert_contains "installer replaced <USER_HOME>" "${FAKE_HOME}/.gemini/config/plugins/codex-collaborator/skills/codex/scripts/run-codex.sh" "$(cat "$INSTALLED_SKILL")"
assert_not_contains "no <USER_HOME> placeholder left" "<USER_HOME>" "$(cat "$INSTALLED_SKILL")"
assert_contains "installer synced live model cache" "gpt-6.2-sol (GPT-6.2-Sol)" "$(cat "$INSTALLED_SKILL")"
assert_contains "tracked repo SKILL.md template stayed clean" "(not synced yet)" "$(cat "${REPO_ROOT}/plugin/skills/codex/SKILL.md")"

echo ""
echo "Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed."
if [[ "$FAIL_COUNT" -ne 0 ]]; then
  exit 1
fi
