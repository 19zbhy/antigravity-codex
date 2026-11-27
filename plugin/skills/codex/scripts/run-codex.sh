#!/usr/bin/env bash
set -euo pipefail

# Ensure Homebrew, npm global bin, and ChatGPT desktop codex-cli paths are available in GUI shells
export PATH="/opt/homebrew/bin:/usr/local/bin:${HOME}/.npm-global/bin:/Applications/ChatGPT.app/Contents/Resources/codex-cli/codex-path:/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS:${PATH}"

usage() {
  cat <<'EOF' >&2
Usage:
  run-codex.sh execute <workspace_dir> <plan_file> [output_last_message_file]
  run-codex.sh resume  <workspace_dir> <fix_file>  [output_last_message_file]
EOF
  exit 2
}

if [[ $# -lt 3 ]]; then
  usage
fi

MODE="$1"
WORKSPACE_DIR="$2"
INPUT_FILE="$3"
OUTPUT_FILE="${4:-}"

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

if [[ -n "$OUTPUT_FILE" ]]; then
  mkdir -p "$(dirname "$OUTPUT_FILE")"
  OUT_FLAGS=(-o "$OUTPUT_FILE")
else
  OUT_FLAGS=()
fi

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

case "$MODE" in
  execute)
    PROMPT_HEADER="You are the Principal Software Engineer in a Gemini (Product & Architecture) + Codex (Engineering) workflow. <stdin> contains the user-approved specification defining the goal, UX/business behavior, edge cases, scope boundaries, and acceptance criteria inside $(pwd). You own the 'How': inspect the relevant code, design clean and idiomatic engineering implementations matching existing codebase conventions, and strictly respect scope boundaries. Before finishing, run the relevant build, typecheck, lint, and test commands yourself inside the workspace and fix any failures on the spot so you deliver working, verified code in one pass. End with a concise technical summary of files changed and verification commands executed."
    echo "==> [Codex Engineer] Starting implementation & self-test in: $WORKSPACE_DIR"
    echo "==> [Codex Engineer] Spec file: $INPUT_FILE"
    if ! codex exec \
      "${APPROVAL_FLAGS[@]}" \
      --color never \
      ${GIT_FLAGS[@]+"${GIT_FLAGS[@]}"} \
      ${OUT_FLAGS[@]+"${OUT_FLAGS[@]}"} \
      "$PROMPT_HEADER" < "$INPUT_FILE"; then
      EXIT_CODE=$?
      echo "" >&2
      echo "ERROR: 'codex exec' exited with code $EXIT_CODE." >&2
      echo "Hint: If this is an authentication error, run 'codex login' in your terminal once to sign in." >&2
      exit "$EXIT_CODE"
    fi
    ;;

  resume)
    echo "==> [Codex Engineer] Resuming latest Codex session in: $WORKSPACE_DIR"
    echo "==> [Codex Engineer] Follow-up review feedback: $INPUT_FILE"
    if ! codex exec \
      "${APPROVAL_FLAGS[@]}" \
      --color never \
      resume \
      --last \
      ${GIT_FLAGS[@]+"${GIT_FLAGS[@]}"} \
      ${OUT_FLAGS[@]+"${OUT_FLAGS[@]}"} \
      - < "$INPUT_FILE"; then
      EXIT_CODE=$?
      echo "" >&2
      echo "ERROR: 'codex exec resume --last' exited with code $EXIT_CODE." >&2
      exit "$EXIT_CODE"
    fi
    ;;

  *)
    echo "ERROR: Unknown subcommand '$MODE' (expected 'execute' or 'resume')." >&2
    usage
    ;;
esac
