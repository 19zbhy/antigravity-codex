#!/usr/bin/env bash
set -euo pipefail

# Ensure Homebrew, npm global bin, and ChatGPT desktop codex-cli paths are available in GUI shells
export PATH="/opt/homebrew/bin:/usr/local/bin:${HOME}/.npm-global/bin:/Applications/ChatGPT.app/Contents/Resources/codex-cli/codex-path:/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS:${PATH}"

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
  run-codex.sh execute <workspace_dir> <plan_file> [output_last_message_file] [--model <name>] [--effort <level>] [--tier <priority|default|flex|fast>] [--worktree] [--no-isolate]
  run-codex.sh review  <workspace_dir> <spec_file> [output_last_message_file] [--model <name>] [--effort <level>] [--tier <priority|default|flex|fast>] [--no-isolate]
  run-codex.sh resume  <workspace_dir> <fix_file>  [output_last_message_file] [--model <name>] [--effort <level>] [--tier <priority|default|flex|fast>] [--no-isolate]

Environment variables (overridden by CLI flags):
  CODEX_MODEL       Override model name (defaults to ~/.codex/config.toml)
  CODEX_EFFORT      Override model_reasoning_effort (e.g. low | medium | high | xhigh | max | ultra)
  CODEX_TIER        Override service_tier (priority | default | flex | fast)
  CODEX_ISOLATE=0   Disable --ignore-user-config whitelist isolation (load full desktop config.toml)
  CODEX_VERBOSE=1   Stream full codex process output to stdout instead of quiet log-summary mode.
EOF
  exit 2
}

read_toml_str() {
  local key="$1"
  local file="$2"
  if [[ -f "$file" ]]; then
    grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" | head -n 1 | sed -E 's/^[^=]*=[[:space:]]*"([^"]*)".*/\1/' || true
  fi
}

emit_options() {
  local default_model default_effort default_tier
  default_model="$(read_toml_str "model" "$CONFIG_FILE")"
  default_effort="$(read_toml_str "model_reasoning_effort" "$CONFIG_FILE")"
  default_tier="$(read_toml_str "service_tier" "$CONFIG_FILE")"

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
  local out_tmp="${target_skill}.sync.tmp"
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

if [[ $# -lt 2 ]]; then
  usage
fi

WORKSPACE_DIR="$1"
INPUT_FILE="$2"
shift 2

OUTPUT_FILE=""
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

CLEANUP_TMP_OUT=0
if [[ -n "$OUTPUT_FILE" ]]; then
  mkdir -p "$(dirname "$OUTPUT_FILE")"
  LOG_FILE="${OUTPUT_FILE%.*}.log"
else
  OUTPUT_FILE="$(mktemp "${TMPDIR:-/tmp}/codex-last-message.XXXXXX.md")"
  LOG_FILE="${OUTPUT_FILE%.md}.log"
  CLEANUP_TMP_OUT=1
fi
OUT_FLAGS=(-o "$OUTPUT_FILE")

cleanup() {
  if [[ "$CLEANUP_TMP_OUT" -eq 1 ]]; then
    rm -f "$OUTPUT_FILE"
  fi
}
trap cleanup EXIT

cd "$WORKSPACE_DIR"

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  GIT_FLAGS=()
else
  GIT_FLAGS=(--skip-git-repo-check)
fi

EXEC_HELP="$(codex exec --help 2>&1 || true)"

# Approval / sandbox flags based on mode
if [[ "$MODE" == "review" ]]; then
  APPROVAL_FLAGS=(-s read-only)
elif echo "$EXEC_HELP" | grep -q -- '--approve-for-me'; then
  APPROVAL_FLAGS=(--approve-for-me -s workspace-write)
else
  APPROVAL_FLAGS=(--full-auto)
fi

WORKTREE_FLAGS=()
if [[ "$USE_WORKTREE" == "1" ]] && [[ "$MODE" == "execute" ]]; then
  if echo "$EXEC_HELP" | grep -q -- '--worktree'; then
    WORKTREE_FLAGS=(--worktree)
  else
    echo "WARN: Current codex CLI does not support --worktree; running in current workspace." >&2
  fi
fi

# Whitelist isolation (--ignore-user-config): skip heavy desktop plugins & MCPs to save ~45% Codex tokens
ISOLATE_FLAGS=()
CFG_PROVIDER="$(read_toml_str "model_provider" "$CONFIG_FILE")"
if [[ "$ISOLATE" == "1" ]] && echo "$EXEC_HELP" | grep -q -- '--ignore-user-config'; then
  # Only isolate automatically when using default/openai provider so custom provider blocks remain intact
  if [[ -z "$CFG_PROVIDER" ]] || [[ "$CFG_PROVIDER" == "openai" ]]; then
    ISOLATE_FLAGS=(--ignore-user-config)
    [[ -z "$MODEL" ]]  && MODEL="$(read_toml_str "model" "$CONFIG_FILE")"
    [[ -z "$EFFORT" ]] && EFFORT="$(read_toml_str "model_reasoning_effort" "$CONFIG_FILE")"
    [[ -z "$TIER" ]]   && TIER="$(read_toml_str "service_tier" "$CONFIG_FILE")"
    if [[ -f "$CONFIG_FILE" ]] && grep -qE '^[[:space:]]*respect_system_proxy[[:space:]]*=[[:space:]]*true' "$CONFIG_FILE"; then
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
  if [[ "$VERBOSE" == "1" ]]; then
    "$@" || exit_code=$?
  else
    "$@" >"$LOG_FILE" 2>&1 || exit_code=$?
  fi

  # Silently refresh embedded live model catalog in SKILL.md for instant next-turn picker
  sync_options_into_skill "$SKILL_MD_PATH" 2>/dev/null || true

  if [[ "$exit_code" -ne 0 ]]; then
    echo "" >&2
    echo "ERROR: codex exited with code $exit_code." >&2
    if [[ "$VERBOSE" != "1" ]] && [[ -f "$LOG_FILE" ]]; then
      echo "Full process log: $LOG_FILE" >&2
      echo "--- Last 60 lines of log ---" >&2
      tail -n 60 "$LOG_FILE" >&2 || true
      echo "----------------------------" >&2
    fi
    echo "Hint: If this is an authentication error, run 'codex login' in your terminal once to sign in." >&2
    exit "$exit_code"
  fi

  if [[ "$VERBOSE" != "1" ]]; then
    echo "==> [Codex Engineer] Completed cleanly. Full process log: $LOG_FILE"
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
    PROMPT_HEADER="You are the Principal Software Engineer in a Google Antigravity + OpenAI Codex workflow. <stdin> contains the user-approved specification defining the goal, UX/business behavior, edge cases, scope boundaries, and acceptance criteria inside $(pwd). You own the 'How': inspect the relevant code, design clean and idiomatic engineering implementations matching existing codebase conventions, and strictly respect scope boundaries. Keep command outputs concise: never dump full large files or raw multi-hundred-line logs to stdout; prefer targeted line ranges or summarized checks. Do not run git commit or git push. Before finishing, run the relevant build, typecheck, lint, and test commands yourself inside the workspace and fix any failures on the spot so you deliver working, verified code in one pass. End with a concise technical summary of files changed and verification commands executed."
    echo "==> [Codex Engineer] Starting implementation & self-test in: $WORKSPACE_DIR"
    echo "==> [Codex Engineer] Spec file: $INPUT_FILE"
    run_codex_cmd codex exec \
      "${APPROVAL_FLAGS[@]}" \
      --color never \
      ${ISOLATE_FLAGS[@]+"${ISOLATE_FLAGS[@]}"} \
      ${WORKTREE_FLAGS[@]+"${WORKTREE_FLAGS[@]}"} \
      ${OVERRIDE_FLAGS[@]+"${OVERRIDE_FLAGS[@]}"} \
      ${GIT_FLAGS[@]+"${GIT_FLAGS[@]}"} \
      ${OUT_FLAGS[@]+"${OUT_FLAGS[@]}"} \
      "$PROMPT_HEADER" < "$INPUT_FILE"
    ;;

  review)
    PROMPT_HEADER="You are a Principal Code Reviewer & Architecture Auditor in a Google Antigravity + OpenAI Codex workflow. You are running in strict read-only mode inside $(pwd) — do not attempt to modify any files. Read the audit scope in <stdin>, inspect the relevant source files or git diff concisely (never dump full large files to stdout), and report concrete findings grouped by severity (Critical / Warning / Suggestion) with exact file:line references and actionable recommendations."
    echo "==> [Codex Reviewer] Starting read-only audit in: $WORKSPACE_DIR"
    echo "==> [Codex Reviewer] Audit spec: $INPUT_FILE"
    run_codex_cmd codex exec \
      "${APPROVAL_FLAGS[@]}" \
      --color never \
      ${ISOLATE_FLAGS[@]+"${ISOLATE_FLAGS[@]}"} \
      ${OVERRIDE_FLAGS[@]+"${OVERRIDE_FLAGS[@]}"} \
      ${GIT_FLAGS[@]+"${GIT_FLAGS[@]}"} \
      ${OUT_FLAGS[@]+"${OUT_FLAGS[@]}"} \
      "$PROMPT_HEADER" < "$INPUT_FILE"
    ;;

  resume)
    echo "==> [Codex Engineer] Resuming latest Codex session in: $WORKSPACE_DIR"
    echo "==> [Codex Engineer] Follow-up review feedback: $INPUT_FILE"
    run_codex_cmd codex exec \
      "${APPROVAL_FLAGS[@]}" \
      --color never \
      resume \
      --last \
      ${ISOLATE_FLAGS[@]+"${ISOLATE_FLAGS[@]}"} \
      ${OVERRIDE_FLAGS[@]+"${OVERRIDE_FLAGS[@]}"} \
      ${GIT_FLAGS[@]+"${GIT_FLAGS[@]}"} \
      ${OUT_FLAGS[@]+"${OUT_FLAGS[@]}"} \
      - < "$INPUT_FILE"
    ;;

  *)
    echo "ERROR: Unknown subcommand '$MODE' (expected 'list-options', 'sync-options', 'execute', 'review', or 'resume')." >&2
    usage
    ;;
esac
