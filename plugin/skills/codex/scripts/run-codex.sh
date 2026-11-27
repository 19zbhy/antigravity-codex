#!/usr/bin/env bash
set -euo pipefail

# Ensure Homebrew, npm global bin, and ChatGPT desktop codex-cli paths are available in GUI shells
export PATH="/opt/homebrew/bin:/usr/local/bin:${HOME}/.npm-global/bin:/Applications/ChatGPT.app/Contents/Resources/codex-cli/codex-path:/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS:${PATH}"

usage() {
  cat <<'EOF' >&2
Usage:
  run-codex.sh execute <workspace_dir> <plan_file> [output_last_message_file] [--model <name>] [--effort <low|medium|high|xhigh>] [--tier <priority|default|flex|fast>]
  run-codex.sh resume  <workspace_dir> <fix_file>  [output_last_message_file] [--model <name>] [--effort <low|medium|high|xhigh>] [--tier <priority|default|flex|fast>]

Environment variables (overridden by CLI flags):
  CODEX_MODEL       Override model name (defaults to ~/.codex/config.toml)
  CODEX_EFFORT      Override model_reasoning_effort (low | medium | high | xhigh)
  CODEX_TIER        Override service_tier (priority | default | flex | fast)
  CODEX_VERBOSE=1   Stream full codex process output to stdout instead of quiet log-summary mode.
EOF
  exit 2
}

if [[ $# -lt 3 ]]; then
  usage
fi

MODE="$1"
WORKSPACE_DIR="$2"
INPUT_FILE="$3"
shift 3

OUTPUT_FILE=""
MODEL="${CODEX_MODEL:-}"
EFFORT="${CODEX_EFFORT:-}"
TIER="${CODEX_TIER:-}"
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

# Auto-detect approval flag across codex-cli versions
if codex exec --help 2>&1 | grep -q -- '--approve-for-me'; then
  APPROVAL_FLAGS=(--approve-for-me -s workspace-write)
else
  APPROVAL_FLAGS=(--full-auto)
fi

# Build optional model / reasoning effort / service tier overrides
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

run_codex_cmd() {
  local exit_code=0
  if [[ "$VERBOSE" == "1" ]]; then
    "$@" || exit_code=$?
  else
    "$@" >"$LOG_FILE" 2>&1 || exit_code=$?
  fi

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
  echo "==> [Codex Engineer] Runtime overrides: ${OVERRIDE_DESC[*]}"
else
  echo "==> [Codex Engineer] Runtime config: using ~/.codex/config.toml defaults"
fi

case "$MODE" in
  execute)
    PROMPT_HEADER="You are the Principal Software Engineer in a Google Antigravity + OpenAI Codex workflow. <stdin> contains the user-approved specification defining the goal, UX/business behavior, edge cases, scope boundaries, and acceptance criteria inside $(pwd). You own the 'How': inspect the relevant code, design clean and idiomatic engineering implementations matching existing codebase conventions, and strictly respect scope boundaries. Keep command outputs concise: never dump full large files or raw multi-hundred-line logs to stdout; prefer targeted line ranges or summarized checks. Before finishing, run the relevant build, typecheck, lint, and test commands yourself inside the workspace and fix any failures on the spot so you deliver working, verified code in one pass. End with a concise technical summary of files changed and verification commands executed."
    echo "==> [Codex Engineer] Starting implementation & self-test in: $WORKSPACE_DIR"
    echo "==> [Codex Engineer] Spec file: $INPUT_FILE"
    run_codex_cmd codex exec \
      "${APPROVAL_FLAGS[@]}" \
      --color never \
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
      ${OVERRIDE_FLAGS[@]+"${OVERRIDE_FLAGS[@]}"} \
      ${GIT_FLAGS[@]+"${GIT_FLAGS[@]}"} \
      ${OUT_FLAGS[@]+"${OUT_FLAGS[@]}"} \
      - < "$INPUT_FILE"
    ;;

  *)
    echo "ERROR: Unknown subcommand '$MODE' (expected 'execute' or 'resume')." >&2
    usage
    ;;
esac
