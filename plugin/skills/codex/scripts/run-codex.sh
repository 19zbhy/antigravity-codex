#!/usr/bin/env bash
set -euo pipefail

# Append Homebrew, npm global bin, and ChatGPT desktop codex-cli paths as fallbacks in GUI shells
export PATH="${PATH}:/opt/homebrew/bin:/usr/local/bin:${HOME}/.npm-global/bin:/Applications/ChatGPT.app/Contents/Resources/codex-cli/codex-path:/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_MD_PATH="${SCRIPT_DIR}/../SKILL.md"
RULES_MD_PATH="${SCRIPT_DIR}/../../../rules/AGENTS.md"
CODEX_DIR="${CODEX_HOME:-${HOME}/.codex}"
CONFIG_FILE="${CODEX_DIR}/config.toml"
CACHE_FILE="${CODEX_DIR}/models_cache.json"

usage() {
  cat <<'EOF' >&2
Usage:
  run-codex.sh doctor
  run-codex.sh list-options
  run-codex.sh sync-options [skill_md_path]
  run-codex.sh list-projects
  run-codex.sh init-shared      <workspace_dir> [--exclude-state]
  run-codex.sh list-sessions    <workspace_dir> [--limit <N>]
  run-codex.sh show-session     <session_id> [--turns <N>]
  run-codex.sh cleanup-worktree <worktree_path> [--delete-branch] [--force]
  run-codex.sh execute <workspace_dir> [<plan_file> [output_last_message_file]] [--prompt <text>] [--output <file>] [--model <name>] [--effort <level>] [--tier <priority|default|flex|fast>] [--worktree] [--structured | --schema <file>] [--no-isolate] [--verbose]
  run-codex.sh review  <workspace_dir> [<spec_file> [output_last_message_file]] [--prompt <text>] [--output <file>] [--base <branch>] [--adversarial] [--model <name>] [--effort <level>] [--tier <priority|default|flex|fast>] [--structured | --schema <file>] [--no-isolate] [--verbose]
  run-codex.sh resume  <workspace_dir> [<fix_file>  [output_last_message_file]] [--prompt <text>] [--output <file>] [--session <id> | --last] [--model <name>] [--effort <level>] [--tier <priority|default|flex|fast>] [--quit-app-on-lock] [--no-isolate] [--verbose]
  run-codex.sh fork    <workspace_dir> [<plan_file> [output_last_message_file]] [--prompt <text>] [--output <file>] [--session <id>] [--model <name>] [--effort <level>] [--tier <priority|default|flex|fast>] [--no-isolate] [--verbose]

Environment variables (overridden by CLI flags):
  CODEX_MODEL       Override model name (defaults to top-level ~/.codex/config.toml)
  CODEX_EFFORT      Override model_reasoning_effort (e.g. low | medium | high | xhigh | max | ultra)
  CODEX_TIER        Override service_tier (priority | default | flex | fast)
  CODEX_ISOLATE=0   Disable --ignore-user-config whitelist isolation (load full desktop config.toml)
  CODEX_VERBOSE=1   Stream full codex process output to stdout instead of quiet log-summary mode.
  CODEX_QUIT_APP_ON_LOCK=1  Allow resume to gracefully close Codex Desktop App and retry once when hitting 'already has an active writer'.
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

# Extract aggregated token usage across turn.completed events in structured JSONL stdout
extract_usage_from_jsonl() {
  local events_file="$1"
  if [[ ! -f "$events_file" ]] || [[ ! -s "$events_file" ]]; then
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -Rs '
      split("\n")
      | map(try fromjson catch empty)
      | map(select(type == "object" and .type == "turn.completed" and (.usage | type == "object")))
      | if length == 0 then empty
        else
          {
            in: (map(.usage.input_tokens // 0) | add),
            cached: (map(.usage.cached_input_tokens // 0) | add),
            out: (map(.usage.output_tokens // 0) | add)
          }
          | "tokens: input=\(.in) (cached=\(.cached)) output=\(.out) total=\(.in + .out)"
        end
    ' "$events_file" 2>/dev/null | sed 's/^"//; s/"$//' || true
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$events_file" <<'PY' 2>/dev/null || true
import json, sys
inp = cached = out = turns = 0
with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as f:
    for raw in f:
        line = raw.strip()
        if not line.startswith("{"):
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if isinstance(obj, dict) and obj.get("type") == "turn.completed":
            u = obj.get("usage")
            if isinstance(u, dict):
                turns += 1
                inp += int(u.get("input_tokens") or 0)
                cached += int(u.get("cached_input_tokens") or 0)
                out += int(u.get("output_tokens") or 0)
if turns > 0:
    print(f"tokens: input={inp} (cached={cached}) output={out} total={inp + out}")
PY
  elif command -v node >/dev/null 2>&1; then
    node -e '
const fs = require("fs");
let inp = 0, cached = 0, out = 0, turns = 0;
for (const raw of fs.readFileSync(process.argv[1], "utf8").split(/\r?\n/)) {
  const line = raw.trim();
  if (!line.startsWith("{")) continue;
  try {
    const obj = JSON.parse(line);
    if (obj && obj.type === "turn.completed" && obj.usage && typeof obj.usage === "object") {
      turns++;
      inp += Number(obj.usage.input_tokens || 0);
      cached += Number(obj.usage.cached_input_tokens || 0);
      out += Number(obj.usage.output_tokens || 0);
    }
  } catch (_) {}
}
if (turns > 0) console.log(`tokens: input=${inp} (cached=${cached}) output=${out} total=${inp + out}`);
' "$events_file" 2>/dev/null || true
  fi
}

emit_projects() {
  local state_db="${CODEX_DIR}/state_5.sqlite"
  if [[ ! -f "$state_db" ]]; then
    return 0
  fi
  local out=""
  local py_bin
  for py_bin in "$(command -v python3 2>/dev/null || true)" "/usr/bin/python3"; do
    if [[ -n "$py_bin" ]] && [[ -x "$py_bin" ]]; then
      out="$("$py_bin" - "$state_db" <<'PY' 2>/dev/null || true
import sqlite3, sys
try:
    conn = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
    conn.execute("SELECT 1 FROM sqlite_master LIMIT 1").fetchone()
except sqlite3.OperationalError:
    conn = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro&immutable=1", uri=True)
cur = conn.cursor()
cur.execute("""
SELECT p.name, pr.path
FROM projects p
JOIN project_roots pr ON p.id = pr.project_id
WHERE pr.position = (
  SELECT MIN(pr2.position) FROM project_roots pr2 WHERE pr2.project_id = p.id
)
ORDER BY p.position ASC
""")
for name, path in cur.fetchall():
    if name and path:
        print(f"  - {name} | {path}")
conn.close()
PY
)"
      if [[ -n "$out" ]]; then
        printf '%s\n' "$out"
        return 0
      fi
    fi
  done
  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 -readonly "$state_db" \
      "SELECT '  - ' || p.name || ' | ' || pr.path FROM projects p JOIN project_roots pr ON p.id = pr.project_id WHERE pr.position = (SELECT MIN(pr2.position) FROM project_roots pr2 WHERE pr2.project_id = p.id) ORDER BY p.position ASC;" 2>/dev/null || true
  fi
}

emit_project_sessions() {
  local state_db="${CODEX_DIR}/state_5.sqlite"
  if [[ ! -f "$state_db" ]]; then
    return 0
  fi
  local out=""
  local py_bin
  for py_bin in "$(command -v python3 2>/dev/null || true)" "/usr/bin/python3"; do
    if [[ -n "$py_bin" ]] && [[ -x "$py_bin" ]]; then
      out="$("$py_bin" - "$state_db" <<'PY' 2>/dev/null || true
import datetime, os, sqlite3, sys
try:
    conn = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
    conn.execute("SELECT 1 FROM sqlite_master LIMIT 1").fetchone()
except sqlite3.OperationalError:
    conn = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro&immutable=1", uri=True)
cur = conn.cursor()
cols = {r[1] for r in cur.execute("PRAGMA table_info(threads)").fetchall()}
title_expr = "COALESCE(NULLIF(name, ''), NULLIF(title, ''), preview, '')" if "name" in cols else "COALESCE(NULLIF(title, ''), preview, '')"
ts_expr = "COALESCE(NULLIF(recency_at, 0), updated_at)" if "recency_at" in cols else "updated_at"
projs = cur.execute("""
SELECT p.name, pr.path
FROM projects p
JOIN project_roots pr ON p.id = pr.project_id
WHERE pr.position = (
  SELECT MIN(pr2.position) FROM project_roots pr2 WHERE pr2.project_id = p.id
)
ORDER BY p.position ASC
""").fetchall()
lines = []
for pname, ppath in projs:
    if not pname or not ppath:
        continue
    norm = os.path.realpath(ppath).rstrip("/")
    rows = cur.execute(
        f"""
        SELECT id, {ts_expr}, {title_expr}
        FROM threads
        WHERE archived = 0
          AND COALESCE(model, '') != 'codex-auto-review'
          AND (rtrim(cwd, '/') = ? OR rtrim(cwd, '/') = ?)
        ORDER BY {ts_expr} DESC
        LIMIT 6
        """,
        (ppath.rstrip("/"), norm),
    ).fetchall()
    if rows:
        lines.append(f"  - {pname}:")
        for sid, ts, title in rows:
            dt = datetime.datetime.fromtimestamp(ts).strftime("%m-%d %H:%M") if isinstance(ts, (int, float)) and ts > 0 else str(ts)
            clean_title = " ".join(str(title).split())[:60]
            lines.append(f"    - {sid} | {dt} | {clean_title}")
conn.close()
if lines:
    print("\n".join(lines))
PY
)"
      if [[ -n "$out" ]]; then
        printf '%s\n' "$out"
        return 0
      fi
    fi
  done
}

emit_options() {
  local include_sessions="${1:-0}"
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
  echo "- service_tiers: priority (快速/Fast), default (标准)"
  local proj_lines=""
  proj_lines="$(emit_projects || true)"
  if [[ -n "$proj_lines" ]]; then
    echo "- projects:"
    printf '%s\n' "$proj_lines"
  fi
  if [[ "$include_sessions" == "1" ]]; then
    local sess_lines=""
    sess_lines="$(emit_project_sessions || true)"
    if [[ -n "$sess_lines" ]]; then
      echo "- project_sessions:"
      printf '%s\n' "$sess_lines"
    fi
  fi
}

sync_options_into_skill() {
  local target_skill="${1:-$SKILL_MD_PATH}"
  local include_sessions="${2:-auto}"
  if [[ ! -f "$target_skill" ]]; then
    return 0
  fi
  if ! grep -q "CODEX_LIVE_OPTIONS_START" "$target_skill" || ! grep -q "CODEX_LIVE_OPTIONS_END" "$target_skill"; then
    return 0
  fi
  if [[ "$include_sessions" == "auto" ]]; then
    if [[ "$(basename "$target_skill")" == "SKILL.md" ]]; then
      include_sessions="1"
    else
      include_sessions="0"
    fi
  fi
  local opts_tmp
  opts_tmp="$(mktemp "${TMPDIR:-/tmp}/codex-opts.XXXXXX")"
  emit_options "$include_sessions" > "$opts_tmp"
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

if [[ "$MODE" == "doctor" ]]; then
  FAILURES=0
  echo "=== antigravity-codex doctor ==="
  if command -v codex >/dev/null 2>&1; then
    CODEX_BIN_PATH="$(command -v codex)"
    CODEX_VER="$(codex --version 2>&1 | head -n 1 || true)"
    echo "  [OK]   codex CLI: ${CODEX_VER:-found} (${CODEX_BIN_PATH})"
    if codex login status >/dev/null 2>&1; then
      LOGIN_MSG="$(codex login status 2>&1 | head -n 1 || true)"
      echo "  [OK]   codex auth: ${LOGIN_MSG:-authenticated}"
    else
      echo "  [FAIL] codex auth: not signed in (run 'codex login' in terminal)"
      FAILURES=$((FAILURES + 1))
    fi
    DOC_HELP="$(codex exec --help 2>&1 || true)"
    CAPS=()
    echo "$DOC_HELP" | grep -q -- '--json' && CAPS+=("--json")
    echo "$DOC_HELP" | grep -q -- '--output-schema' && CAPS+=("--output-schema")
    echo "$DOC_HELP" | grep -q -- '--worktree' && CAPS+=("--worktree")
    echo "$DOC_HELP" | grep -q -- '--ignore-user-config' && CAPS+=("--ignore-user-config")
    echo "$DOC_HELP" | grep -q -- '--approve-for-me' && CAPS+=("--approve-for-me")
    echo "  [OK]   codex exec flags: ${CAPS[*]:-basic}"
  else
    echo "  [FAIL] codex CLI: not found in PATH"
    FAILURES=$((FAILURES + 1))
  fi

  if [[ -f "$CONFIG_FILE" ]]; then
    DM="$(read_toml_top_level "model" "$CONFIG_FILE")"
    DE="$(read_toml_top_level "model_reasoning_effort" "$CONFIG_FILE")"
    DT="$(read_toml_top_level "service_tier" "$CONFIG_FILE")"
    DP="$(read_toml_top_level "model_provider" "$CONFIG_FILE")"
    echo "  [OK]   config.toml: model=${DM:-default} effort=${DE:-default} tier=${DT:-default} provider=${DP:-openai}"
  else
    echo "  [WARN] config.toml: not found at ${CONFIG_FILE}"
  fi

  if [[ -f "$CACHE_FILE" ]]; then
    echo "  [OK]   models_cache.json: found (${CACHE_FILE})"
  else
    echo "  [WARN] models_cache.json: not found (run codex once to populate)"
  fi

  if [[ -f "${CODEX_DIR}/state_5.sqlite" ]]; then
    PROJ_COUNT="$(emit_projects | wc -l | tr -d '[:space:]')"
    echo "  [OK]   state_5.sqlite: found (${PROJ_COUNT:-0} Codex projects)"
  else
    echo "  [WARN] state_5.sqlite: not found (Codex Desktop project/session lookup unavailable)"
  fi

  if command -v git >/dev/null 2>&1; then
    GIT_VER="$(git --version 2>&1 | head -n 1 || true)"
    echo "  [OK]   git: ${GIT_VER}"
  else
    echo "  [WARN] git: not found (--worktree and git diff summaries unavailable)"
  fi

  HELPERS=()
  command -v python3 >/dev/null 2>&1 && HELPERS+=("python3")
  command -v jq >/dev/null 2>&1 && HELPERS+=("jq")
  command -v node >/dev/null 2>&1 && HELPERS+=("node")
  command -v sqlite3 >/dev/null 2>&1 && HELPERS+=("sqlite3")
  echo "  [OK]   helpers: ${HELPERS[*]:-none (fallback awk only)}"

  if [[ -f "$SKILL_MD_PATH" ]]; then
    if grep -q '<USER_HOME>' "$SKILL_MD_PATH"; then
      echo "  [WARN] SKILL.md: still contains <USER_HOME> placeholder (run install.sh)"
    elif grep -Fxq -- '- (not synced yet)' "$SKILL_MD_PATH"; then
      echo "  [WARN] SKILL.md: live options not synced yet (run sync-options)"
    else
      echo "  [OK]   SKILL.md: installed and live options synced (${SKILL_MD_PATH})"
    fi
  else
    echo "  [WARN] SKILL.md: not found at ${SKILL_MD_PATH}"
  fi

  if [[ "$FAILURES" -gt 0 ]]; then
    echo "==> Doctor finished with ${FAILURES} failure(s)."
    exit 1
  fi
  echo "==> Doctor passed: environment is ready."
  exit 0
fi

if [[ "$MODE" == "cleanup-worktree" ]]; then
  [[ $# -ge 1 ]] || usage
  WT_PATH="$1"
  shift
  DELETE_BRANCH="0"
  FORCE_CLEANUP="0"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --delete-branch) DELETE_BRANCH="1"; shift ;;
      --force) FORCE_CLEANUP="1"; shift ;;
      *) echo "ERROR: Unknown option '$1' for cleanup-worktree" >&2; usage ;;
    esac
  done
  if ! command -v git >/dev/null 2>&1; then
    echo "ERROR: 'git' is required for cleanup-worktree." >&2
    exit 127
  fi
  if [[ ! -d "$WT_PATH" ]]; then
    echo "ERROR: Worktree directory does not exist: $WT_PATH" >&2
    exit 2
  fi
  WT_REAL="$(cd "$WT_PATH" && pwd -P)"
  if [[ -d "${WT_REAL}/.git" ]]; then
    echo "ERROR: Refusing to remove main Git repository checkout: $WT_REAL" >&2
    exit 2
  fi
  if [[ ! -f "${WT_REAL}/.git" ]]; then
    echo "ERROR: Directory is not a linked Git worktree: $WT_REAL" >&2
    exit 2
  fi
  COMMON_GIT_DIR="$(git -C "$WT_REAL" rev-parse --git-common-dir 2>/dev/null || true)"
  if [[ -z "$COMMON_GIT_DIR" ]]; then
    echo "ERROR: Unable to resolve parent Git repository for worktree: $WT_REAL" >&2
    exit 2
  fi
  if [[ "$COMMON_GIT_DIR" != /* ]]; then
    COMMON_GIT_DIR="$(cd "${WT_REAL}/${COMMON_GIT_DIR}" && pwd -P)"
  else
    COMMON_GIT_DIR="$(cd "$COMMON_GIT_DIR" && pwd -P)"
  fi
  MAIN_REPO="$(dirname "$COMMON_GIT_DIR")"
  WT_BRANCH="$(git -C "$WT_REAL" symbolic-ref --short HEAD 2>/dev/null || true)"
  WT_HEAD="$(git -C "$WT_REAL" rev-parse --verify HEAD 2>/dev/null || true)"

  if [[ "$FORCE_CLEANUP" != "1" ]]; then
    DIRTY_STATUS="$(git -C "$WT_REAL" status --porcelain 2>/dev/null || true)"
    if [[ -n "$DIRTY_STATUS" ]]; then
      echo "ERROR: Worktree has uncommitted changes. Commit/stash them first or pass --force: $WT_REAL" >&2
      exit 2
    fi

    if [[ -n "$WT_HEAD" ]]; then
      if [[ -z "$WT_BRANCH" ]]; then
        REACHABLE_REFS="$(git -C "$MAIN_REPO" for-each-ref --contains "$WT_HEAD" --format='%(refname)' refs/heads refs/tags 2>/dev/null || true)"
        if [[ -z "$REACHABLE_REFS" ]]; then
          SHORT_HEAD="$(git -C "$WT_REAL" rev-parse --short HEAD 2>/dev/null || printf '%s' "$WT_HEAD")"
          echo "ERROR: Detached worktree HEAD (${SHORT_HEAD}) has commits not reachable from any branch or tag. Create a branch to preserve them or pass --force: $WT_REAL" >&2
          exit 2
        fi
      elif [[ "$DELETE_BRANCH" == "1" ]]; then
        OTHER_REFS="$(git -C "$MAIN_REPO" for-each-ref --contains "$WT_HEAD" --format='%(refname)' refs/heads refs/tags 2>/dev/null | grep -v "^refs/heads/${WT_BRANCH}$" || true)"
        if [[ -z "$OTHER_REFS" ]]; then
          echo "ERROR: Branch '${WT_BRANCH}' has commits not reachable from any other branch or tag. Merge it first or pass --force: $WT_REAL" >&2
          exit 2
        fi
      fi
    fi
  fi

  if [[ "$FORCE_CLEANUP" == "1" ]]; then
    git -C "$MAIN_REPO" worktree remove --force "$WT_REAL"
  else
    git -C "$MAIN_REPO" worktree remove "$WT_REAL"
  fi
  echo "==> [Codex Engineer] Removed worktree: $WT_REAL"

  if [[ "$DELETE_BRANCH" == "1" ]] && [[ -n "$WT_BRANCH" ]]; then
    if [[ "$FORCE_CLEANUP" == "1" ]]; then
      git -C "$MAIN_REPO" branch -D "$WT_BRANCH"
    else
      git -C "$MAIN_REPO" branch -d "$WT_BRANCH"
    fi
    echo "==> [Codex Engineer] Deleted branch: $WT_BRANCH"
  fi
  exit 0
fi

if [[ "$MODE" == "list-options" ]]; then
  emit_options
  exit 0
fi

if [[ "$MODE" == "sync-options" ]]; then
  if [[ $# -ge 1 ]]; then
    sync_options_into_skill "$1"
  else
    sync_options_into_skill "$SKILL_MD_PATH"
    sync_options_into_skill "$RULES_MD_PATH"
  fi
  exit 0
fi

if [[ "$MODE" == "list-projects" ]]; then
  proj_lines="$(emit_projects || true)"
  if [[ -n "$proj_lines" ]]; then
    printf '%s\n' "$proj_lines"
  else
    echo "No Codex projects found in ${CODEX_DIR}/state_5.sqlite"
  fi
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
try:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.execute("SELECT 1 FROM sqlite_master LIMIT 1").fetchone()
except sqlite3.OperationalError:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro&immutable=1", uri=True)
cur = conn.cursor()
cols = {row[1] for row in cur.execute("PRAGMA table_info(threads)").fetchall()}
title_expr = "COALESCE(NULLIF(name, ''), NULLIF(title, ''), preview, '')" if "name" in cols else "COALESCE(NULLIF(title, ''), preview, '')"
ts_expr = "COALESCE(NULLIF(recency_at, 0), updated_at)" if "recency_at" in cols else "updated_at"
cur.execute(
    f"""
    SELECT id, {ts_expr}, COALESCE(model, ''), {title_expr}
    FROM threads
    WHERE archived = 0
      AND COALESCE(model, '') != 'codex-auto-review'
      AND (cwd = ? OR rtrim(cwd, '/') = ?)
    ORDER BY {ts_expr} DESC
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
        dt = datetime.datetime.fromtimestamp(ts).strftime("%m-%d %H:%M") if isinstance(ts, (int, float)) and ts > 0 else str(ts)
        clean_title = " ".join(str(title).split())[:80]
        print(f"{sid} | {dt} | {model or 'default'} | {clean_title}")
PY
  elif command -v sqlite3 >/dev/null 2>&1; then
    ESCAPED_WS="${TARGET_WS//\'/\'\'}"
    sqlite3 -readonly -separator ' | ' "$STATE_DB" \
      "SELECT id, strftime('%m-%d %H:%M', COALESCE(NULLIF(recency_at, 0), updated_at), 'unixepoch', 'localtime'), COALESCE(model, 'default'), replace(replace(substr(COALESCE(NULLIF(name, ''), NULLIF(title, ''), preview, ''), 1, 80), char(10), ' '), char(13), ' ') FROM threads WHERE archived = 0 AND COALESCE(model, '') != 'codex-auto-review' AND rtrim(cwd, '/') = '${ESCAPED_WS%/}' ORDER BY COALESCE(NULLIF(recency_at, 0), updated_at) DESC LIMIT ${LIMIT};" 2>/dev/null || \
    sqlite3 -readonly -separator ' | ' "$STATE_DB" \
      "SELECT id, strftime('%m-%d %H:%M', updated_at, 'unixepoch', 'localtime'), COALESCE(model, 'default'), replace(replace(substr(COALESCE(NULLIF(title, ''), preview, ''), 1, 80), char(10), ' '), char(13), ' ') FROM threads WHERE archived = 0 AND COALESCE(model, '') != 'codex-auto-review' AND rtrim(cwd, '/') = '${ESCAPED_WS%/}' ORDER BY updated_at DESC LIMIT ${LIMIT};"
  else
    echo "ERROR: Neither python3 nor sqlite3 is available to read $STATE_DB" >&2
    exit 127
  fi
  exit 0
fi

if [[ "$MODE" == "show-session" ]]; then
  [[ $# -ge 1 ]] || usage
  TARGET_SID="$1"
  shift
  TURNS="10"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --turns)
        [[ $# -ge 2 ]] || { echo "ERROR: --turns requires a positive integer" >&2; exit 2; }
        TURNS="$2"
        shift 2
        ;;
      *) echo "ERROR: Unknown option '$1' for show-session" >&2; usage ;;
    esac
  done
  if ! [[ "$TURNS" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: --turns must be a positive integer, got '$TURNS'" >&2
    exit 2
  fi
  STATE_DB="${CODEX_DIR}/state_5.sqlite"
  if [[ ! -f "$STATE_DB" ]]; then
    echo "ERROR: Codex session database not found at: $STATE_DB" >&2
    exit 2
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required for show-session." >&2
    exit 127
  fi
  python3 - "$STATE_DB" "$TARGET_SID" "$TURNS" <<'PY'
import json, os, sqlite3, sys
db_path, sid, max_turns = sys.argv[1], sys.argv[2], int(sys.argv[3])
try:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.execute("SELECT 1 FROM sqlite_master LIMIT 1").fetchone()
except sqlite3.OperationalError:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro&immutable=1", uri=True)
cols = {r[1] for r in conn.execute("PRAGMA table_info(threads)").fetchall()}
title_expr = "COALESCE(NULLIF(name, ''), title, '')" if "name" in cols else "COALESCE(title, '')"
row = conn.execute(f"SELECT rollout_path, cwd, {title_expr}, COALESCE(model, '') FROM threads WHERE id = ?", (sid,)).fetchone()
conn.close()
if not row:
    sys.stderr.write(f"ERROR: Session ID not found in state_5.sqlite: {sid}\n")
    sys.exit(2)
rollout_path, cwd, title, model = row
print(f"=== Codex Session Context: {sid} ===")
print(f"Workspace: {cwd}")
if title:
    print(f"Title: {title}")
if model:
    print(f"Model: {model}")
if not rollout_path or not os.path.isfile(rollout_path):
    print("(Rollout transcript file not found on disk)")
    sys.exit(0)
SKIP_PREFIXES = (
    "# AGENTS.md instructions for ",
    "<environment_context>",
    "<INSTRUCTIONS>",
    "<permissions instructions>",
    "<app-context>",
    "<collaboration_mode>",
)
msgs = []
with open(rollout_path, "r", encoding="utf-8", errors="replace") as f:
    for raw in f:
        line = raw.strip()
        if not line.startswith("{"):
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if obj.get("type") != "response_item":
            continue
        payload = obj.get("payload") or {}
        if payload.get("type") != "message":
            continue
        role = payload.get("role")
        if role not in ("user", "assistant"):
            continue
        parts = []
        for item in (payload.get("content") or []):
            if isinstance(item, dict) and item.get("type") in ("input_text", "output_text", "text"):
                t = (item.get("text") or "").strip()
                if t:
                    parts.append(t)
        text = "\n".join(parts).strip()
        if not text:
            continue
        if role == "user" and any(text.startswith(sp) for sp in SKIP_PREFIXES):
            continue
        if len(text) > 1200:
            text = text[:1200] + "... [truncated]"
        msgs.append((role, text))
selected = msgs[-max_turns:]
print(f"Showing last {len(selected)} of {len(msgs)} message(s):")
print("")
for role, text in selected:
    print(f"[{role.upper()}] {text}")
    print("---")
PY
  exit 0
fi

if [[ $# -lt 1 ]]; then
  usage
fi

WORKSPACE_DIR="$1"
shift

INPUT_FILE=""
OUTPUT_FILE=""
PROMPT_TEXT=""
SESSION_ID=""
ALLOW_LAST="0"
MODEL="${CODEX_MODEL:-}"
EFFORT="${CODEX_EFFORT:-}"
TIER="${CODEX_TIER:-}"
ISOLATE="${CODEX_ISOLATE:-1}"
USE_WORKTREE="0"
USE_STRUCTURED="0"
SCHEMA_FILE=""
ADVERSARIAL="0"
BASE_REF=""
QUIT_APP_ON_LOCK="${CODEX_QUIT_APP_ON_LOCK:-0}"
VERBOSE="${CODEX_VERBOSE:-0}"

# Optional positional args: <input_file> [output_last_message_file] (when not starting with --)
if [[ $# -gt 0 ]] && [[ "$1" != --* ]]; then
  INPUT_FILE="$1"
  shift
fi
if [[ $# -gt 0 ]] && [[ "$1" != --* ]]; then
  OUTPUT_FILE="$1"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt|-p)
      [[ $# -ge 2 ]] || { echo "ERROR: --prompt requires a value" >&2; exit 2; }
      PROMPT_TEXT="$2"
      shift 2
      ;;
    --output|-o)
      [[ $# -ge 2 ]] || { echo "ERROR: --output requires a file path" >&2; exit 2; }
      OUTPUT_FILE="$2"
      shift 2
      ;;
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
    --structured)
      USE_STRUCTURED="1"
      shift
      ;;
    --schema)
      [[ $# -ge 2 ]] || { echo "ERROR: --schema requires a file path" >&2; exit 2; }
      SCHEMA_FILE="$2"
      shift 2
      ;;
    --adversarial)
      ADVERSARIAL="1"
      shift
      ;;
    --base)
      [[ $# -ge 2 ]] || { echo "ERROR: --base requires a Git branch or ref" >&2; exit 2; }
      BASE_REF="$2"
      shift 2
      ;;
    --no-isolate)
      ISOLATE="0"
      shift
      ;;
    --quit-app-on-lock)
      QUIT_APP_ON_LOCK="1"
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

TMP_PROMPT_FILE=""
cleanup_tmp_prompt() {
  if [[ -n "$TMP_PROMPT_FILE" ]] && [[ -f "$TMP_PROMPT_FILE" ]]; then
    rm -f "$TMP_PROMPT_FILE"
  fi
}
trap cleanup_tmp_prompt EXIT

if [[ "$ADVERSARIAL" == "1" ]] || [[ -n "$BASE_REF" ]]; then
  if [[ "$MODE" != "review" ]]; then
    echo "ERROR: --adversarial and --base are only supported with 'review'." >&2
    exit 2
  fi
fi

# Allow 'review --base <ref>' (or '--adversarial') without an explicit spec file
if [[ "$MODE" == "review" ]] && [[ -z "$INPUT_FILE" ]] && [[ -z "$PROMPT_TEXT" ]] && [[ -n "$BASE_REF" ]]; then
  PROMPT_TEXT="Review all changes in git diff ${BASE_REF}...HEAD (and any uncommitted changes in the working tree)."
fi

if [[ -n "$PROMPT_TEXT" ]]; then
  if [[ -n "$INPUT_FILE" ]] && [[ "$INPUT_FILE" != "-" ]]; then
    echo "ERROR: Input file and --prompt are mutually exclusive." >&2
    exit 2
  fi
  TMP_PROMPT_FILE="$(mktemp "${TMPDIR:-/tmp}/codex-prompt.XXXXXX")"
  printf '%s\n' "$PROMPT_TEXT" > "$TMP_PROMPT_FILE"
  INPUT_FILE="$TMP_PROMPT_FILE"
fi

if [[ -z "$INPUT_FILE" ]] || [[ ! -f "$INPUT_FILE" ]] || [[ ! -s "$INPUT_FILE" ]]; then
  echo "ERROR: Input plan/instructions file is missing or empty (or pass --prompt <text>): ${INPUT_FILE:-<none>}" >&2
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

# Structured JSON output schema (--structured uses bundled report.schema.json, or custom --schema <file>)
SCHEMA_FLAGS=()
if [[ "$USE_STRUCTURED" == "1" ]] || [[ -n "$SCHEMA_FILE" ]]; then
  if [[ "$MODE" != "execute" ]] && [[ "$MODE" != "review" ]]; then
    echo "ERROR: --structured / --schema is only supported with 'execute' or 'review'." >&2
    exit 2
  fi
  if [[ -z "$SCHEMA_FILE" ]]; then
    SCHEMA_FILE="${SCRIPT_DIR}/../resources/report.schema.json"
  fi
  if [[ ! -f "$SCHEMA_FILE" ]]; then
    echo "ERROR: Output schema file does not exist: $SCHEMA_FILE" >&2
    exit 2
  fi
  if ! echo "$EXEC_HELP" | grep -q -- '--output-schema'; then
    echo "ERROR: --structured / --schema was requested, but the installed codex CLI does not support --output-schema." >&2
    exit 2
  fi
  SCHEMA_FLAGS=(--output-schema "$SCHEMA_FILE")
fi

BASE_DIFF_CONTEXT=""
if [[ -n "$BASE_REF" ]]; then
  if [[ "$IS_GIT_REPO" -ne 1 ]]; then
    echo "ERROR: --base requires a Git repository, but '$WORKSPACE_DIR' is not inside a Git work tree." >&2
    exit 2
  fi
  if ! git rev-parse --verify "${BASE_REF}^{commit}" >/dev/null 2>&1; then
    echo "ERROR: --base ref '${BASE_REF}' does not exist in this Git repository." >&2
    exit 2
  fi
  BASE_DIFF_STAT="$(git diff --stat "${BASE_REF}...HEAD" 2>/dev/null | head -n 40 || true)"
  BASE_DIFF_CONTEXT=" Focus specifically on changes relative to base ref '${BASE_REF}' (inspect 'git diff ${BASE_REF}...HEAD' and any uncommitted changes). Diff stat summary: ${BASE_DIFF_STAT:-no committed diff vs ${BASE_REF}}."
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
if [[ ${#SCHEMA_FLAGS[@]} -gt 0 ]]; then
  OVERRIDE_DESC+=("schema=on")
fi
if [[ "$ADVERSARIAL" == "1" ]]; then
  OVERRIDE_DESC+=("adversarial=on")
fi
if [[ -n "$BASE_REF" ]]; then
  OVERRIDE_DESC+=("base=${BASE_REF}")
fi

release_codex_app_lock() {
  if [[ -n "${CODEX_RELEASE_LOCK_CMD:-}" ]]; then
    eval "$CODEX_RELEASE_LOCK_CMD" || true
    return 0
  fi
  case "$(uname -s 2>/dev/null || echo unknown)" in
    Darwin)
      local app_server_procs target_app=""
      app_server_procs="$(ps -eo args= 2>/dev/null | grep -E '(^|/)codex([[:space:]]|$).*app-server' | grep -v grep || true)"
      if printf '%s\n' "$app_server_procs" | grep -q 'Codex\.app'; then
        target_app="Codex"
      elif printf '%s\n' "$app_server_procs" | grep -q 'ChatGPT\.app'; then
        target_app="ChatGPT"
      fi

      if [[ -n "$target_app" ]]; then
        echo "==> [Codex Engineer] Identified lock holder app: ${target_app}" >&2
        osascript -e "if application \"${target_app}\" is running then tell application \"${target_app}\" to quit" >/dev/null 2>&1 || true
      elif [[ -n "$app_server_procs" ]]; then
        echo "==> [Codex Engineer] Lock holder app could not be uniquely identified; refusing to blindly quit ChatGPT. Only closing Codex if running." >&2
        osascript -e 'if application "Codex" is running then tell application "Codex" to quit' >/dev/null 2>&1 || true
      else
        echo "==> [Codex Engineer] No active codex app-server process detected; skipping app quit." >&2
        return 0
      fi

      local waited=0
      while [[ "$waited" -lt 12 ]]; do
        if ! ps -eo args= 2>/dev/null | grep -E '(^|/)codex([[:space:]]|$).*app-server' | grep -qv grep; then
          break
        fi
        sleep 0.5
        waited=$((waited + 1))
      done
      ;;
    Linux)
      pkill -u "$(id -u)" -TERM -f '(^|/)codex([[:space:]]|$).*app-server' >/dev/null 2>&1 || true
      sleep 1
      ;;
  esac
}

run_codex_cmd() {
  local exit_code=0
  local start_ts end_ts elapsed_s
  local attempt=1
  start_ts="$(date +%s)"

  # When the user explicitly confirmed --quit-app-on-lock for resume, release the lock upfront
  # so we skip a redundant doomed first attempt.
  if [[ "$MODE" == "resume" ]] && [[ "$QUIT_APP_ON_LOCK" == "1" ]]; then
    echo "==> [Codex Engineer] Closing Codex Desktop App gracefully before resuming..." >&2
    release_codex_app_lock
  fi

  while true; do
    exit_code=0
    if [[ "$USE_JSON_EVENTS" -eq 1 ]]; then
      if [[ "$VERBOSE" == "1" ]]; then
        "$@" < "$INPUT_FILE" 2>"$LOG_FILE" | tee "$EVENTS_FILE" || exit_code=${PIPESTATUS[0]}
        if [[ -s "$LOG_FILE" ]]; then
          cat "$LOG_FILE" >&2
        fi
      else
        "$@" < "$INPUT_FILE" >"$EVENTS_FILE" 2>"$LOG_FILE" || exit_code=$?
      fi
    else
      if [[ "$VERBOSE" == "1" ]]; then
        "$@" < "$INPUT_FILE" 2>&1 | tee "$LOG_FILE" || exit_code=${PIPESTATUS[0]}
      else
        "$@" < "$INPUT_FILE" >"$LOG_FILE" 2>&1 || exit_code=$?
      fi
    fi

    if [[ "$exit_code" -ne 0 ]] && [[ "$MODE" == "resume" ]] && [[ "$attempt" -eq 1 ]]; then
      if grep -qi "already has an active writer" "$LOG_FILE" "$EVENTS_FILE" 2>/dev/null; then
        if [[ "$QUIT_APP_ON_LOCK" == "1" ]]; then
          echo "==> [Codex Engineer] Thread still locked ('already has an active writer'). Waiting briefly and retrying resume..." >&2
          release_codex_app_lock
          attempt=2
          continue
        else
          echo "HINT_THREAD_LOCKED: Thread is locked by Codex Desktop App ('already has an active writer'). Ask the user to confirm quitting Codex App (--quit-app-on-lock) or fall back to 'fork'." >&2
        fi
      fi
    fi
    break
  done
  end_ts="$(date +%s)"
  elapsed_s=$((end_ts - start_ts))

  # Capture authoritative Codex session ID using the matching parser for the active output mode
  local captured_sid=""
  if [[ "$USE_JSON_EVENTS" -eq 1 ]]; then
    captured_sid="$(extract_session_id_from_jsonl "$EVENTS_FILE" || true)"
  else
    captured_sid="$(extract_session_id_from_text "$LOG_FILE" || true)"
  fi
  if [[ "$MODE" == "fork" ]]; then
    if [[ -n "$captured_sid" ]] && [[ "$captured_sid" != "${FORK_SOURCE_SESSION_ID:-}" ]]; then
      printf '%s\n' "$captured_sid" > "$SESSION_FILE"
    else
      rm -f "$SESSION_FILE"
    fi
  elif [[ -n "$captured_sid" ]]; then
    printf '%s\n' "$captured_sid" > "$SESSION_FILE"
  fi

  # Silently refresh embedded live model & project catalog in SKILL.md and rules/AGENTS.md
  sync_options_into_skill "$SKILL_MD_PATH" 2>/dev/null || true
  sync_options_into_skill "$RULES_MD_PATH" 2>/dev/null || true

  if [[ "$exit_code" -ne 0 ]]; then
    echo "" >&2
    echo "ERROR: codex exited with code $exit_code (after ${elapsed_s}s)." >&2
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

  if [[ "$MODE" == "fork" ]]; then
    if [[ -z "$captured_sid" ]] || [[ "$captured_sid" == "${FORK_SOURCE_SESSION_ID:-}" ]]; then
      echo "ERROR: fork completed without a distinct new session ID (source: '${FORK_SOURCE_SESSION_ID:-unknown}'). Cleared stale session file to prevent accidentally resuming the source thread." >&2
      exit 1
    fi
  fi

  if [[ -n "$captured_sid" ]]; then
    echo "==> [Codex Engineer] Session ID: $captured_sid (saved to $SESSION_FILE)"
  fi

  local usage_summary=""
  if [[ "$USE_JSON_EVENTS" -eq 1 ]]; then
    usage_summary="$(extract_usage_from_jsonl "$EVENTS_FILE" || true)"
  fi
  if [[ -n "$usage_summary" ]]; then
    echo "==> [Codex Engineer] Telemetry: duration=${elapsed_s}s | ${usage_summary}"
  else
    echo "==> [Codex Engineer] Telemetry: duration=${elapsed_s}s"
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
    if [[ "$IS_GIT_REPO" -eq 1 ]] && [[ "$MODE" != "review" ]]; then
      local git_status_out git_diff_stat
      git_status_out="$(git status --short 2>/dev/null | head -n 40 || true)"
      if [[ -n "$git_status_out" ]]; then
        echo ""
        echo "=== Git Workspace Changes ==="
        printf '%s\n' "$git_status_out"
        git_diff_stat="$(git diff --stat 2>/dev/null | head -n 40 || true)"
        if [[ -n "$git_diff_stat" ]]; then
          echo "--- git diff --stat ---"
          printf '%s\n' "$git_diff_stat"
        fi
      fi
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
      ${SCHEMA_FLAGS[@]+"${SCHEMA_FLAGS[@]}"} \
      ${OVERRIDE_FLAGS[@]+"${OVERRIDE_FLAGS[@]}"} \
      ${GIT_FLAGS[@]+"${GIT_FLAGS[@]}"} \
      ${OUT_FLAGS[@]+"${OUT_FLAGS[@]}"} \
      "$PROMPT_HEADER"
    ;;

  review)
    # Reset stale artifacts from previous runs
    rm -f "$OUTPUT_FILE" "$SESSION_FILE" "$EVENTS_FILE"
    if [[ "$ADVERSARIAL" == "1" ]]; then
      PROMPT_HEADER="You are a Red-Team Adversarial Code & Design Auditor in a Google Antigravity + OpenAI Codex workflow. You are running in strict read-only mode inside $(pwd) — do not modify any files. Do NOT praise the code; actively try to break it. Hunt for flawed assumptions, edge-case crashes, race conditions, locking/state bugs, security/permission boundary gaps, and silent failure modes.${BASE_DIFF_CONTEXT} Inspect files or diffs concisely (never dump full large files to stdout) and report concrete findings grouped by severity (P0 Critical / P1 High / P2 Medium / P3 Low) with exact file:line references, minimal reproduction paths, and direct fixes."
      echo "==> [Codex Reviewer] Starting adversarial read-only audit in: $WORKSPACE_DIR"
    else
      PROMPT_HEADER="You are a Principal Code Reviewer & Architecture Auditor in a Google Antigravity + OpenAI Codex workflow. You are running in strict read-only mode inside $(pwd) — do not attempt to modify any files.${BASE_DIFF_CONTEXT} Read the audit scope in <stdin>, inspect the relevant source files or git diff concisely (never dump full large files to stdout), and report concrete findings grouped by severity (Critical / Warning / Suggestion) with exact file:line references and actionable recommendations."
      echo "==> [Codex Reviewer] Starting read-only audit in: $WORKSPACE_DIR"
    fi
    echo "==> [Codex Reviewer] Audit spec: $INPUT_FILE"
    run_codex_cmd codex exec \
      "${APPROVAL_FLAGS[@]}" \
      --color never \
      ${JSON_FLAGS[@]+"${JSON_FLAGS[@]}"} \
      ${ISOLATE_FLAGS[@]+"${ISOLATE_FLAGS[@]}"} \
      ${SCHEMA_FLAGS[@]+"${SCHEMA_FLAGS[@]}"} \
      ${OVERRIDE_FLAGS[@]+"${OVERRIDE_FLAGS[@]}"} \
      ${GIT_FLAGS[@]+"${GIT_FLAGS[@]}"} \
      ${OUT_FLAGS[@]+"${OUT_FLAGS[@]}"} \
      "$PROMPT_HEADER"
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
        -
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
        -
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
    FORK_SOURCE_SESSION_ID="$SESSION_ID"
    # Clear stale summary, events, AND source .session_id AFTER reading source ID so a failed/unidentified fork never leaves a pointer back to the source thread
    rm -f "$OUTPUT_FILE" "$EVENTS_FILE" "$SESSION_FILE"
    echo "==> [Codex Engineer] Forking Codex session '${FORK_SOURCE_SESSION_ID}' in: $WORKSPACE_DIR"
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
      "$FORK_SOURCE_SESSION_ID" \
      -
    ;;

  *)
    echo "ERROR: Unknown subcommand '$MODE' (expected 'doctor', 'list-options', 'sync-options', 'list-projects', 'init-shared', 'list-sessions', 'show-session', 'cleanup-worktree', 'execute', 'review', 'resume', or 'fork')." >&2
    usage
    ;;
esac
