#!/usr/bin/env bash
set -euo pipefail

# Append Homebrew, npm global bin, and ChatGPT desktop codex-cli paths as fallbacks in GUI shells
export PATH="${PATH}:/opt/homebrew/bin:/usr/local/bin:${HOME}/.npm-global/bin:/Applications/ChatGPT.app/Contents/Resources/codex-cli/codex-path:/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_MD_PATH="${SCRIPT_DIR}/../SKILL.md"
CODEX_DIR="${CODEX_HOME:-${HOME}/.codex}"
CONFIG_FILE="${CODEX_DIR}/config.toml"
CACHE_FILE="${CODEX_DIR}/models_cache.json"

usage() {
  cat <<'EOF' >&2
Usage:
  run-codex.sh list-options
  run-codex.sh sync-options [skill_md_path]
  run-codex.sh init-shared   <workspace_dir> [--exclude-state]
  run-codex.sh list-sessions <workspace_dir> [--limit <N>]
  run-codex.sh execute <workspace_dir> <plan_file> [output_last_message_file] [--model <name>] [--effort <level>] [--tier <priority|default|flex|fast>] [--worktree] [--no-isolate] [--verbose]
  run-codex.sh review  <workspace_dir> <spec_file> [output_last_message_file] [--model <name>] [--effort <level>] [--tier <priority|default|flex|fast>] [--no-isolate] [--verbose]
  run-codex.sh resume  <workspace_dir> <fix_file>  [output_last_message_file] [--session <id> | --last] [--model <name>] [--effort <level>] [--tier <priority|default|flex|fast>] [--no-isolate] [--verbose]
  run-codex.sh fork    <workspace_dir> <plan_file> [output_last_message_file] [--session <id>] [--model <name>] [--effort <level>] [--tier <priority|default|flex|fast>] [--no-isolate] [--verbose]

Environment variables (overridden by CLI flags):
  CODEX_MODEL       Override model name (defaults to top-level ~/.codex/config.toml)
  CODEX_EFFORT      Override model_reasoning_effort (e.g. low | medium | high | xhigh | max | ultra)
  CODEX_TIER        Override service_tier (priority | default | flex | fast)
  CODEX_ISOLATE=0   Disable --ignore-user-config whitelist isolation (load full desktop config.toml)
  CODEX_VERBOSE=1   Stream full codex process output to stdout instead of quiet log-summary mode.
EOF
  exit 2
}

# Read ONLY top-level string keys (stops at the first [section] header so [profiles.*] never leaks)
read_toml_top_level() {
  local key="$1"
  local file="$2"
  if [[ ! -f "$file" ]]; then
    return 0
  fi
  awk -v k="$key" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^[[:space:]]*\[/ { exit }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (index(line, k) == 1) {
        rest = substr(line, length(k) + 1)
        if (rest ~ /^[[:space:]]*=/) {
          sub(/^[[:space:]]*=[[:space:]]*/, "", rest)
          if (substr(rest, 1, 1) == "\"") {
            rest = substr(rest, 2)
            sub(/".*/, "", rest)
            print rest
            exit
          } else if (substr(rest, 1, 1) == "\047") {
            rest = substr(rest, 2)
            sub(/\047.*/, "", rest)
            print rest
            exit
          }
        }
      }
    }
  ' "$file"
}

# Check a boolean key strictly inside the [features] TOML table
has_toml_feature_true() {
  local key="$1"
  local file="$2"
  if [[ ! -f "$file" ]]; then
    return 1
  fi
  awk -v k="$key" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^[[:space:]]*\[features\][[:space:]]*(#.*)?$/ { in_feat = 1; next }
    /^[[:space:]]*\[/ { in_feat = 0; next }
    in_feat {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (index(line, k) == 1) {
        rest = substr(line, length(k) + 1)
        if (rest ~ /^[[:space:]]*=[[:space:]]*true([[:space:]]*(#.*)?)?$/) {
          found = 1
          exit
        }
      }
    }
    END { exit (found ? 0 : 1) }
  ' "$file"
}

# Extract session ID strictly from structured JSONL stdout (--json mode):
# Only inspects top-level JSON objects with type == "thread.started" and returns the FIRST match.
extract_session_id_from_jsonl() {
  local events_file="$1"
  if [[ ! -f "$events_file" ]] || [[ ! -s "$events_file" ]]; then
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -Rr 'fromjson? | select(type == "object" and .type == "thread.started" and (.thread_id | type == "string") and (.thread_id | length >= 8)) | .thread_id' "$events_file" 2>/dev/null | head -n 1 || true
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$events_file" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if isinstance(obj, dict) and obj.get("type") == "thread.started":
            tid = obj.get("thread_id")
            if isinstance(tid, str) and len(tid) >= 8:
                print(tid)
                break
PY
  elif command -v node >/dev/null 2>&1; then
    node -e '
const fs = require("fs");
for (const raw of fs.readFileSync(process.argv[1], "utf8").split(/\r?\n/)) {
  const line = raw.trim();
  if (!line.startsWith("{")) continue;
  try {
    const obj = JSON.parse(line);
    if (obj && typeof obj === "object" && obj.type === "thread.started" && typeof obj.thread_id === "string" && obj.thread_id.length >= 8) {
      console.log(obj.thread_id);
      process.exit(0);
    }
  } catch (_) {}
}
' "$events_file"
  else
    awk '
      /^[[:space:]]*\{.*"type"[[:space:]]*:[[:space:]]*"thread\.started"/ {
        if (match($0, /"thread_id"[[:space:]]*:[[:space:]]*"[0-9a-fA-F-]{8,}"/)) {
          val = substr($0, RSTART, RLENGTH)
          sub(/^"thread_id"[[:space:]]*:[[:space:]]*"/, "", val)
          sub(/"$/, "", val)
          print val
          exit
        }
      }
    ' "$events_file"
  fi
}

# Legacy fallback (ONLY when codex CLI does not support --json):
# Matches ONLY the FIRST standalone header line "^session id: <uuid>$" and stops immediately.
# Never searches for JSON events inside mixed text logs.
extract_session_id_from_text() {
  local log_file="$1"
  if [[ ! -f "$log_file" ]] || [[ ! -s "$log_file" ]]; then
    return 0
  fi
  awk '
    {
      low = tolower($0)
      if (low ~ /^[[:space:]]*session id:[[:space:]]*[0-9a-f-]{8,}[[:space:]]*$/) {
        val = $0
        sub(/^[[:space:]]*[Ss][Ee][Ss][Ss][Ii][Oo][Nn] [Ii][Dd]:[[:space:]]*/, "", val)
        sub(/[[:space:]]*$/, "", val)
        print val
        exit
      }
    }
  ' "$log_file"
}

emit_options() {
  local default_model default_effort default_tier
  default_model="$(read_toml_top_level "model" "$CONFIG_FILE")"
  default_effort="$(read_toml_top_level "model_reasoning_effort" "$CONFIG_FILE")"
  default_tier="$(read_toml_top_level "service_tier" "$CONFIG_FILE")"

  echo "- default_model: ${default_model:-default}"
  echo "- default_effort: ${default_effort:-default}"
  echo "- default_tier: ${default_tier:-default}"

  if [[ -f "$CACHE_FILE" ]]; then
    if command -v jq >/dev/null 2>&1; then
      echo "- models:"
      jq -r '.models[]? | select(.visibility == "list") | "  - \(.slug) (\(.display_name // .slug))"' "$CACHE_FILE"
      echo "- efforts: $(jq -r '[.models[]? | select(.visibility == "list") | .supported_reasoning_levels[]?.effort] | unique | join(", ")' "$CACHE_FILE")"
    elif command -v python3 >/dev/null 2>&1; then
      python3 - "$CACHE_FILE" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
models = [m for m in data.get("models", []) if m.get("visibility") == "list"]
print("- models:")
efforts = []
for m in models:
    slug = m.get("slug", "")
    name = m.get("display_name") or slug
    for x in m.get("supported_reasoning_levels", []):
        e = x.get("effort")
        if e and e not in efforts:
            efforts.append(e)
    print(f"  - {slug} ({name})")
print(f"- efforts: {', '.join(efforts)}")
PY
    elif command -v node >/dev/null 2>&1; then
      node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const models = (data.models || []).filter(m => m.visibility === "list");
const efforts = [];
console.log("- models:");
for (const m of models) {
  for (const x of (m.supported_reasoning_levels || [])) {
    if (x.effort && !efforts.includes(x.effort)) efforts.push(x.effort);
  }
  console.log(`  - ${m.slug} (${m.display_name || m.slug})`);
}
console.log(`- efforts: ${efforts.join(", ")}`);
' "$CACHE_FILE"
    else
      echo "- models: (install jq, python3, or node to parse models_cache.json)"
      echo "- efforts: low, medium, high, xhigh"
    fi
  else
    echo "- models: (run codex once to populate ~/.codex/models_cache.json)"
    echo "- efforts: low, medium, high, xhigh"
  fi
  echo "- service_tiers: priority (快速/Fast), default (标准), flex (弹性省流)"
}

sync_options_into_skill() {
  local target_skill="${1:-$SKILL_MD_PATH}"
  if [[ ! -f "$target_skill" ]]; then
    return 0
  fi
  if ! grep -q "CODEX_LIVE_OPTIONS_START" "$target_skill" || ! grep -q "CODEX_LIVE_OPTIONS_END" "$target_skill"; then
    return 0
  fi
  local opts_tmp
  opts_tmp="$(mktemp "${TMPDIR:-/tmp}/codex-opts.XXXXXX")"
  emit_options > "$opts_tmp"
  local out_tmp
  out_tmp="$(mktemp "${TMPDIR:-/tmp}/codex-skill.XXXXXX")"
  awk -v opts_file="$opts_tmp" '
    /<!-- CODEX_LIVE_OPTIONS_START -->/ {
      print
      while ((getline line < opts_file) > 0) print line
      close(opts_file)
      in_block = 1
      next
    }
    /<!-- CODEX_LIVE_OPTIONS_END -->/ {
      in_block = 0
      print
      next
    }
    !in_block { print }
  ' "$target_skill" > "$out_tmp"
  mv "$out_tmp" "$target_skill"
  rm -f "$opts_tmp"
}

if [[ $# -lt 1 ]]; then
  usage
fi

MODE="$1"
shift

if [[ "$MODE" == "list-options" ]]; then
  emit_options
  exit 0
fi

if [[ "$MODE" == "sync-options" ]]; then
  sync_options_into_skill "${1:-$SKILL_MD_PATH}"
  exit 0
fi

if [[ "$MODE" == "init-shared" ]]; then
  [[ $# -ge 1 ]] || usage
  TARGET_WS="$1"
  shift
  EXCLUDE_STATE="0"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --exclude-state) EXCLUDE_STATE="1"; shift ;;
      *) echo "ERROR: Unknown option '$1' for init-shared" >&2; usage ;;
    esac
  done
  if [[ ! -d "$TARGET_WS" ]]; then
    echo "ERROR: Workspace directory does not exist: $TARGET_WS" >&2
    exit 2
  fi
  TARGET_WS="$(cd "$TARGET_WS" && pwd)"
  mkdir -p "${TARGET_WS}/.agents/skills" "${TARGET_WS}/.agents/hooks"

  if [[ ! -f "${TARGET_WS}/AGENTS.md" ]]; then
    cat > "${TARGET_WS}/AGENTS.md" <<'EOF'
# Project Agent Conventions (Shared by Codex & Antigravity)

- **Hot State Handoff**: Read `.agents/state.md` at the start of a session to see recent work from other agents, and update it concisely (< 50 lines) after meaningful code changes.
- **Long-Term Memory**: If a shared Memory MCP (such as `basic-memory`) is available, record lasting architecture decisions, environment caveats, and design trade-offs there.
- **Shared Project Skills**: Place project-specific skills under `.agents/skills/<name>/SKILL.md` so both Codex and Antigravity discover them natively.
EOF
    echo "  [CREATED] ${TARGET_WS}/AGENTS.md"
  else
    echo "  [KEPT]    ${TARGET_WS}/AGENTS.md (already exists)"
  fi

  if [[ ! -f "${TARGET_WS}/.agents/state.md" ]]; then
    cat > "${TARGET_WS}/.agents/state.md" <<'EOF'
# Shared Workspace State

- **Current Goal**: (describe active milestone or task)
- **Last Updated By**: (Codex / Antigravity / /codex)
- **Recent Changes**:
  - None recorded yet.
- **Known Issues / Guardrails**:
  - None recorded yet.
- **Next Steps**:
  - None recorded yet.
EOF
    echo "  [CREATED] ${TARGET_WS}/.agents/state.md"
  else
    echo "  [KEPT]    ${TARGET_WS}/.agents/state.md (already exists)"
  fi

  HOOK_SH="${TARGET_WS}/.agents/hooks/session-context.sh"
  if [[ ! -f "$HOOK_SH" ]]; then
    cat > "$HOOK_SH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
echo "=== Shared Workspace Context ==="
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "-- git status --short --"
  git status --short || true
  echo "-- recent commits --"
  git log -n 5 --oneline 2>/dev/null || true
fi
if [[ -f "${ROOT}/.agents/state.md" ]]; then
  echo "-- .agents/state.md --"
  head -n 60 "${ROOT}/.agents/state.md"
fi
EOF
    chmod +x "$HOOK_SH"
    echo "  [CREATED] ${HOOK_SH}"
  else
    echo "  [KEPT]    ${HOOK_SH} (already exists)"
  fi

  HOOKS_JSON="${TARGET_WS}/.agents/hooks.json"
  if [[ ! -f "$HOOKS_JSON" ]]; then
    cat > "$HOOKS_JSON" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash .agents/hooks/session-context.sh"
          }
        ]
      }
    ]
  }
}
EOF
    echo "  [CREATED] ${HOOKS_JSON}"
  else
    echo "  [KEPT]    ${HOOKS_JSON} (already exists)"
  fi

  if [[ "$EXCLUDE_STATE" == "1" ]]; then
    if git -C "$TARGET_WS" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      GIT_DIR_PATH="$(git -C "$TARGET_WS" rev-parse --git-dir)"
      if [[ "$GIT_DIR_PATH" != /* ]]; then
        GIT_DIR_PATH="${TARGET_WS}/${GIT_DIR_PATH}"
      fi
      EXCLUDE_FILE="${GIT_DIR_PATH}/info/exclude"
      mkdir -p "$(dirname "$EXCLUDE_FILE")"
      touch "$EXCLUDE_FILE"
      if ! grep -Fxq ".agents/state.md" "$EXCLUDE_FILE"; then
        printf '\n.agents/state.md\n' >> "$EXCLUDE_FILE"
        echo "  [UPDATED] Added .agents/state.md to ${EXCLUDE_FILE}"
      else
        echo "  [KEPT]    .agents/state.md already in ${EXCLUDE_FILE}"
      fi
    else
      echo "  [WARN]    --exclude-state skipped: not a Git repository." >&2
    fi
  fi
  echo "==> Shared workspace initialized: ${TARGET_WS}"
  exit 0
fi

if [[ "$MODE" == "list-sessions" ]]; then
  [[ $# -ge 1 ]] || usage
  TARGET_WS="$1"
  shift
  LIMIT="10"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit)
        [[ $# -ge 2 ]] || { echo "ERROR: --limit requires a positive integer" >&2; exit 2; }
        LIMIT="$2"
        shift 2
        ;;
      *) echo "ERROR: Unknown option '$1' for list-sessions" >&2; usage ;;
    esac
  done
  if ! [[ "$LIMIT" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: --limit must be a positive integer, got '$LIMIT'" >&2
    exit 2
  fi
  if [[ ! -d "$TARGET_WS" ]]; then
    echo "ERROR: Workspace directory does not exist: $TARGET_WS" >&2
    exit 2
  fi
  TARGET_WS="$(cd "$TARGET_WS" && pwd -P)"
  STATE_DB="${CODEX_DIR}/state_5.sqlite"
  if [[ ! -f "$STATE_DB" ]]; then
    echo "No Codex session database found at: $STATE_DB"
    exit 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$STATE_DB" "$TARGET_WS" "$LIMIT" <<'PY'
import datetime, os, sqlite3, sys
db_path, cwd_target, limit = sys.argv[1], os.path.realpath(sys.argv[2]), int(sys.argv[3])
conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
cur = conn.cursor()
cur.execute(
    """
    SELECT id, updated_at, COALESCE(model, ''), COALESCE(NULLIF(title, ''), preview, '')
    FROM threads
    WHERE archived = 0 AND (cwd = ? OR rtrim(cwd, '/') = ?)
    ORDER BY updated_at DESC
    LIMIT ?
    """,
    (cwd_target, cwd_target.rstrip("/"), limit),
)
rows = cur.fetchall()
conn.close()
if not rows:
    print(f"No active Codex sessions found for workspace: {cwd_target}")
else:
    for sid, ts, model, title in rows:
        dt = datetime.datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M") if isinstance(ts, (int, float)) and ts > 0 else str(ts)
        clean_title = " ".join(str(title).split())[:80]
        print(f"{sid} | {dt} | {model or 'default'} | {clean_title}")
PY
  elif command -v sqlite3 >/dev/null 2>&1; then
    ESCAPED_WS="${TARGET_WS//\'/\'\'}"
    sqlite3 -readonly -separator ' | ' "$STATE_DB" \
      "SELECT id, datetime(updated_at, 'unixepoch', 'localtime'), COALESCE(model, 'default'), replace(replace(substr(COALESCE(NULLIF(title, ''), preview, ''), 1, 80), char(10), ' '), char(13), ' ') FROM threads WHERE archived = 0 AND rtrim(cwd, '/') = '${ESCAPED_WS%/}' ORDER BY updated_at DESC LIMIT ${LIMIT};"
  else
    echo "ERROR: Neither python3 nor sqlite3 is available to read $STATE_DB" >&2
    exit 127
  fi
  exit 0
fi

if [[ $# -lt 2 ]]; then
  usage
fi

WORKSPACE_DIR="$1"
INPUT_FILE="$2"
shift 2

OUTPUT_FILE=""
SESSION_ID=""
ALLOW_LAST="0"
MODEL="${CODEX_MODEL:-}"
EFFORT="${CODEX_EFFORT:-}"
TIER="${CODEX_TIER:-}"
ISOLATE="${CODEX_ISOLATE:-1}"
USE_WORKTREE="0"
VERBOSE="${CODEX_VERBOSE:-0}"

# Optional 4th positional argument: output_last_message_file (if not starting with --)
if [[ $# -gt 0 ]] && [[ "$1" != --* ]]; then
  OUTPUT_FILE="$1"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model|-m)
      [[ $# -ge 2 ]] || { echo "ERROR: --model requires a value" >&2; exit 2; }
      MODEL="$2"
      shift 2
      ;;
    --effort)
      [[ $# -ge 2 ]] || { echo "ERROR: --effort requires a value" >&2; exit 2; }
      EFFORT="$2"
      shift 2
      ;;
    --tier)
      [[ $# -ge 2 ]] || { echo "ERROR: --tier requires a value" >&2; exit 2; }
      TIER="$2"
      shift 2
      ;;
    --session)
      [[ $# -ge 2 ]] || { echo "ERROR: --session requires a value" >&2; exit 2; }
      SESSION_ID="$2"
      shift 2
      ;;
    --last)
      ALLOW_LAST="1"
      shift
      ;;
    --worktree)
      USE_WORKTREE="1"
      shift
      ;;
    --no-isolate)
      ISOLATE="0"
      shift
      ;;
    --verbose)
      VERBOSE="1"
      shift
      ;;
    *)
      echo "ERROR: Unknown option '$1'" >&2
      usage
      ;;
  esac
done

# Normalize user-facing alias 'fast' -> 'priority'
if [[ "$TIER" == "fast" ]]; then
  TIER="priority"
fi

if ! command -v codex >/dev/null 2>&1; then
  echo "ERROR: 'codex' CLI not found in PATH. Install it via: npm install -g @openai/codex" >&2
  exit 127
fi

if [[ ! -d "$WORKSPACE_DIR" ]]; then
  echo "ERROR: Workspace directory does not exist: $WORKSPACE_DIR" >&2
  exit 2
fi

if [[ ! -f "$INPUT_FILE" ]] || [[ ! -s "$INPUT_FILE" ]]; then
  echo "ERROR: Input plan/instructions file is missing or empty: $INPUT_FILE" >&2
  exit 2
fi

# Portable BSD (macOS) & GNU (Linux) unique temp directory when OUTPUT_FILE is omitted.
# Uses the exact same sibling naming convention (<stem>.md / <stem>.log / <stem>.session_id)
# and stays on disk after completion so printed paths remain valid for inspection or resume.
TMP_RUN_DIR=""
if [[ -n "$OUTPUT_FILE" ]]; then
  mkdir -p "$(dirname "$OUTPUT_FILE")"
  LOG_FILE="${OUTPUT_FILE%.*}.log"
  EVENTS_FILE="${OUTPUT_FILE%.*}.events.jsonl"
  SESSION_FILE="${OUTPUT_FILE%.*}.session_id"
else
  TMP_RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-run.XXXXXX")"
  OUTPUT_FILE="${TMP_RUN_DIR}/last_message.md"
  LOG_FILE="${TMP_RUN_DIR}/last_message.log"
  EVENTS_FILE="${TMP_RUN_DIR}/last_message.events.jsonl"
  SESSION_FILE="${TMP_RUN_DIR}/last_message.session_id"
fi
OUT_FLAGS=(-o "$OUTPUT_FILE")

cd "$WORKSPACE_DIR"

IS_GIT_REPO=0
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  IS_GIT_REPO=1
  GIT_FLAGS=()
else
  GIT_FLAGS=(--skip-git-repo-check)
fi

EXEC_HELP="$(codex exec --help 2>&1 || true)"

# Enable structured JSONL event stream when supported so stdout (events) and stderr (diagnostics) stay separated
USE_JSON_EVENTS=0
JSON_FLAGS=()
if echo "$EXEC_HELP" | grep -q -- '--json'; then
  USE_JSON_EVENTS=1
  JSON_FLAGS=(--json)
fi

# Approval / sandbox flags based on mode (--approve-for-me already implies workspace-write and conflicts with -s)
if [[ "$MODE" == "review" ]]; then
  APPROVAL_FLAGS=(-s read-only)
elif echo "$EXEC_HELP" | grep -q -- '--approve-for-me'; then
  APPROVAL_FLAGS=(--approve-for-me)
else
  APPROVAL_FLAGS=(--full-auto)
fi

# Fail-closed --worktree check: never silently fall back to the main workspace when isolation was requested
WORKTREE_FLAGS=()
if [[ "$USE_WORKTREE" == "1" ]]; then
  if [[ "$MODE" != "execute" ]]; then
    echo "ERROR: --worktree is only supported with 'execute'." >&2
    exit 2
  fi
  if [[ "$IS_GIT_REPO" -ne 1 ]]; then
    echo "ERROR: --worktree requires a Git repository, but '$WORKSPACE_DIR' is not inside a Git work tree." >&2
    exit 2
  fi
  if ! echo "$EXEC_HELP" | grep -q -- '--worktree'; then
    echo "ERROR: --worktree was requested, but the installed codex CLI does not support --worktree. Refusing to fall back to the main workspace." >&2
    exit 2
  fi
  WORKTREE_FLAGS=(--worktree)
fi

# Whitelist isolation (--ignore-user-config): skip desktop plugins & MCPs while keeping auth.json
ISOLATE_FLAGS=()
CFG_PROVIDER="$(read_toml_top_level "model_provider" "$CONFIG_FILE")"
if [[ "$ISOLATE" == "1" ]] && echo "$EXEC_HELP" | grep -q -- '--ignore-user-config'; then
  # Only isolate automatically when using default/openai provider so custom provider blocks remain intact
  if [[ -z "$CFG_PROVIDER" ]] || [[ "$CFG_PROVIDER" == "openai" ]]; then
    ISOLATE_FLAGS=(--ignore-user-config)
    [[ -z "$MODEL" ]]  && MODEL="$(read_toml_top_level "model" "$CONFIG_FILE")"
    [[ -z "$EFFORT" ]] && EFFORT="$(read_toml_top_level "model_reasoning_effort" "$CONFIG_FILE")"
    [[ -z "$TIER" ]]   && TIER="$(read_toml_top_level "service_tier" "$CONFIG_FILE")"
    if has_toml_feature_true "respect_system_proxy" "$CONFIG_FILE"; then
      ISOLATE_FLAGS+=(-c "features.respect_system_proxy=true")
    fi
  else
    echo "==> [Codex Engineer] Custom model_provider='${CFG_PROVIDER}' detected; loading full ~/.codex/config.toml"
  fi
fi

# Build model / reasoning effort / service tier flags
OVERRIDE_FLAGS=()
OVERRIDE_DESC=()
if [[ -n "$MODEL" ]]; then
  OVERRIDE_FLAGS+=(-m "$MODEL")
  OVERRIDE_DESC+=("model=${MODEL}")
fi
if [[ -n "$EFFORT" ]]; then
  OVERRIDE_FLAGS+=(-c "model_reasoning_effort=\"${EFFORT}\"")
  OVERRIDE_DESC+=("effort=${EFFORT}")
fi
if [[ -n "$TIER" ]]; then
  OVERRIDE_FLAGS+=(-c "service_tier=\"${TIER}\"")
  OVERRIDE_DESC+=("tier=${TIER}")
fi
if [[ ${#ISOLATE_FLAGS[@]} -gt 0 ]]; then
  OVERRIDE_DESC+=("isolated=on")
fi
if [[ ${#WORKTREE_FLAGS[@]} -gt 0 ]]; then
  OVERRIDE_DESC+=("worktree=on")
fi

run_codex_cmd() {
  local exit_code=0
  if [[ "$USE_JSON_EVENTS" -eq 1 ]]; then
    if [[ "$VERBOSE" == "1" ]]; then
      "$@" 2>"$LOG_FILE" | tee "$EVENTS_FILE" || exit_code=${PIPESTATUS[0]}
      if [[ -s "$LOG_FILE" ]]; then
        cat "$LOG_FILE" >&2
      fi
    else
      "$@" >"$EVENTS_FILE" 2>"$LOG_FILE" || exit_code=$?
    fi
  else
    if [[ "$VERBOSE" == "1" ]]; then
      "$@" 2>&1 | tee "$LOG_FILE" || exit_code=${PIPESTATUS[0]}
    else
      "$@" >"$LOG_FILE" 2>&1 || exit_code=$?
    fi
  fi

  # Capture authoritative Codex session ID using the matching parser for the active output mode
  local captured_sid=""
  if [[ "$USE_JSON_EVENTS" -eq 1 ]]; then
    captured_sid="$(extract_session_id_from_jsonl "$EVENTS_FILE" || true)"
  else
    captured_sid="$(extract_session_id_from_text "$LOG_FILE" || true)"
  fi
  if [[ -n "$captured_sid" ]]; then
    printf '%s\n' "$captured_sid" > "$SESSION_FILE"
  fi

  # Silently refresh embedded live model catalog in SKILL.md for instant next-turn picker
  sync_options_into_skill "$SKILL_MD_PATH" 2>/dev/null || true

  if [[ "$exit_code" -ne 0 ]]; then
    echo "" >&2
    echo "ERROR: codex exited with code $exit_code." >&2
    if [[ "$VERBOSE" != "1" ]] && [[ -f "$LOG_FILE" ]] && [[ -s "$LOG_FILE" ]]; then
      echo "Full process log: $LOG_FILE" >&2
      echo "--- Last 60 lines of log ---" >&2
      tail -n 60 "$LOG_FILE" >&2 || true
      echo "----------------------------" >&2
    elif [[ "$VERBOSE" != "1" ]] && [[ -f "$EVENTS_FILE" ]] && [[ -s "$EVENTS_FILE" ]]; then
      echo "Event stream log: $EVENTS_FILE" >&2
      echo "--- Last 30 lines of events ---" >&2
      tail -n 30 "$EVENTS_FILE" >&2 || true
      echo "-------------------------------" >&2
    fi
    echo "Hint: If this is an authentication error, run 'codex login' in your terminal once to sign in." >&2
    exit "$exit_code"
  fi

  if [[ -n "$captured_sid" ]]; then
    echo "==> [Codex Engineer] Session ID: $captured_sid (saved to $SESSION_FILE)"
  fi

  if [[ "$VERBOSE" != "1" ]]; then
    if [[ "$USE_JSON_EVENTS" -eq 1 ]]; then
      echo "==> [Codex Engineer] Completed cleanly. Events: $EVENTS_FILE | Full process log: $LOG_FILE"
    else
      echo "==> [Codex Engineer] Completed cleanly. Full process log: $LOG_FILE"
    fi
    if [[ -s "$OUTPUT_FILE" ]]; then
      echo ""
      echo "=== Codex Final Summary ==="
      cat "$OUTPUT_FILE"
    fi
  fi
}

if [[ ${#OVERRIDE_DESC[@]} -gt 0 ]]; then
  echo "==> [Codex Engineer] Runtime config: ${OVERRIDE_DESC[*]}"
else
  echo "==> [Codex Engineer] Runtime config: using ~/.codex/config.toml defaults"
fi

case "$MODE" in
  execute)
    # Reset stale artifacts so a new task can never inherit an older run's summary or session ID
    rm -f "$OUTPUT_FILE" "$SESSION_FILE" "$EVENTS_FILE"
    PROMPT_HEADER="You are the Principal Software Engineer in a Google Antigravity + OpenAI Codex workflow. <stdin> contains the user-approved specification defining the goal, UX/business behavior, edge cases, scope boundaries, and acceptance criteria inside $(pwd). You own the 'How': inspect the relevant code, design clean and idiomatic engineering implementations matching existing codebase conventions, and strictly respect scope boundaries. Keep command outputs concise: never dump full large files or raw multi-hundred-line logs to stdout; prefer targeted line ranges or summarized checks. Do not run git commit or git push. Before finishing, run the relevant build, typecheck, lint, and test commands yourself inside the workspace and fix any failures on the spot so you deliver working, verified code in one pass. End with a concise technical summary of files changed and verification commands executed."
    echo "==> [Codex Engineer] Starting implementation & self-test in: $WORKSPACE_DIR"
    echo "==> [Codex Engineer] Spec file: $INPUT_FILE"
    run_codex_cmd codex exec \
      "${APPROVAL_FLAGS[@]}" \
      --color never \
      ${JSON_FLAGS[@]+"${JSON_FLAGS[@]}"} \
      ${ISOLATE_FLAGS[@]+"${ISOLATE_FLAGS[@]}"} \
      ${WORKTREE_FLAGS[@]+"${WORKTREE_FLAGS[@]}"} \
      ${OVERRIDE_FLAGS[@]+"${OVERRIDE_FLAGS[@]}"} \
      ${GIT_FLAGS[@]+"${GIT_FLAGS[@]}"} \
      ${OUT_FLAGS[@]+"${OUT_FLAGS[@]}"} \
      "$PROMPT_HEADER" < "$INPUT_FILE"
    ;;

  review)
    # Reset stale artifacts from previous runs
    rm -f "$OUTPUT_FILE" "$SESSION_FILE" "$EVENTS_FILE"
    PROMPT_HEADER="You are a Principal Code Reviewer & Architecture Auditor in a Google Antigravity + OpenAI Codex workflow. You are running in strict read-only mode inside $(pwd) — do not attempt to modify any files. Read the audit scope in <stdin>, inspect the relevant source files or git diff concisely (never dump full large files to stdout), and report concrete findings grouped by severity (Critical / Warning / Suggestion) with exact file:line references and actionable recommendations."
    echo "==> [Codex Reviewer] Starting read-only audit in: $WORKSPACE_DIR"
    echo "==> [Codex Reviewer] Audit spec: $INPUT_FILE"
    run_codex_cmd codex exec \
      "${APPROVAL_FLAGS[@]}" \
      --color never \
      ${JSON_FLAGS[@]+"${JSON_FLAGS[@]}"} \
      ${ISOLATE_FLAGS[@]+"${ISOLATE_FLAGS[@]}"} \
      ${OVERRIDE_FLAGS[@]+"${OVERRIDE_FLAGS[@]}"} \
      ${GIT_FLAGS[@]+"${GIT_FLAGS[@]}"} \
      ${OUT_FLAGS[@]+"${OUT_FLAGS[@]}"} \
      "$PROMPT_HEADER" < "$INPUT_FILE"
    ;;

  resume)
    # Explicit option validation & precedence BEFORE touching any existing summary file:
    # 1) --session and --last are mutually exclusive
    # 2) Explicit --session <id>
    # 3) Explicit --last (overrides any existing .session_id file)
    # 4) Auto-read pinned .session_id file
    # 5) Fail closed
    if [[ -n "$SESSION_ID" ]] && [[ "$ALLOW_LAST" == "1" ]]; then
      echo "ERROR: --session and --last are mutually exclusive." >&2
      exit 2
    fi

    RESUME_MODE=""
    if [[ -n "$SESSION_ID" ]]; then
      RESUME_MODE="pinned"
    elif [[ "$ALLOW_LAST" == "1" ]]; then
      RESUME_MODE="last"
    elif [[ -f "$SESSION_FILE" ]]; then
      SESSION_ID="$(head -n 1 "$SESSION_FILE" | tr -d '[:space:]' || true)"
      if [[ -n "$SESSION_ID" ]]; then
        RESUME_MODE="pinned"
      fi
    fi

    if [[ -z "$RESUME_MODE" ]]; then
      echo "ERROR: No pinned session ID found for resume (checked --session and ${SESSION_FILE}). Pass --session <id> or --last explicitly." >&2
      exit 2
    fi

    # Only reset stale summary/events AFTER resume target is validated
    rm -f "$OUTPUT_FILE" "$EVENTS_FILE"
    echo "==> [Codex Engineer] Follow-up review feedback: $INPUT_FILE"
    if [[ "$RESUME_MODE" == "pinned" ]]; then
      echo "==> [Codex Engineer] Resuming pinned Codex session '${SESSION_ID}' in: $WORKSPACE_DIR"
      run_codex_cmd codex exec \
        "${APPROVAL_FLAGS[@]}" \
        --color never \
        resume \
        ${JSON_FLAGS[@]+"${JSON_FLAGS[@]}"} \
        ${ISOLATE_FLAGS[@]+"${ISOLATE_FLAGS[@]}"} \
        ${OVERRIDE_FLAGS[@]+"${OVERRIDE_FLAGS[@]}"} \
        ${GIT_FLAGS[@]+"${GIT_FLAGS[@]}"} \
        ${OUT_FLAGS[@]+"${OUT_FLAGS[@]}"} \
        "$SESSION_ID" \
        - < "$INPUT_FILE"
    else
      echo "==> [Codex Engineer] Explicitly resuming latest Codex session (--last) in: $WORKSPACE_DIR"
      run_codex_cmd codex exec \
        "${APPROVAL_FLAGS[@]}" \
        --color never \
        resume \
        --last \
        ${JSON_FLAGS[@]+"${JSON_FLAGS[@]}"} \
        ${ISOLATE_FLAGS[@]+"${ISOLATE_FLAGS[@]}"} \
        ${OVERRIDE_FLAGS[@]+"${OVERRIDE_FLAGS[@]}"} \
        ${GIT_FLAGS[@]+"${GIT_FLAGS[@]}"} \
        ${OUT_FLAGS[@]+"${OUT_FLAGS[@]}"} \
        - < "$INPUT_FILE"
    fi
    ;;

  fork)
    if [[ -z "$SESSION_ID" ]] && [[ -f "$SESSION_FILE" ]]; then
      SESSION_ID="$(head -n 1 "$SESSION_FILE" | tr -d '[:space:]' || true)"
    fi
    if [[ -z "$SESSION_ID" ]]; then
      echo "ERROR: fork requires a source session ID (pass --session <id> or provide an output path with an existing .session_id file)." >&2
      exit 2
    fi
    # Reset stale summary/events AFTER source session ID is validated
    rm -f "$OUTPUT_FILE" "$EVENTS_FILE"
    echo "==> [Codex Engineer] Forking Codex session '${SESSION_ID}' in: $WORKSPACE_DIR"
    echo "==> [Codex Engineer] Fork prompt file: $INPUT_FILE"
    run_codex_cmd codex exec \
      "${APPROVAL_FLAGS[@]}" \
      --color never \
      fork \
      ${JSON_FLAGS[@]+"${JSON_FLAGS[@]}"} \
      ${ISOLATE_FLAGS[@]+"${ISOLATE_FLAGS[@]}"} \
      ${OVERRIDE_FLAGS[@]+"${OVERRIDE_FLAGS[@]}"} \
      ${GIT_FLAGS[@]+"${GIT_FLAGS[@]}"} \
      ${OUT_FLAGS[@]+"${OUT_FLAGS[@]}"} \
      "$SESSION_ID" \
      - < "$INPUT_FILE"
    ;;

  *)
    echo "ERROR: Unknown subcommand '$MODE' (expected 'list-options', 'sync-options', 'init-shared', 'list-sessions', 'execute', 'review', 'resume', or 'fork')." >&2
    usage
    ;;
esac
