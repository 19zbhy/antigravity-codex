#!/usr/bin/env bash
set -euo pipefail

# One-command installer for antigravity-codex (macOS / Linux)
# Copies the codex-collaborator plugin into ~/.gemini/config/plugins/codex-collaborator
# and replaces <USER_HOME> with the literal absolute home directory path.

export PATH="/opt/homebrew/bin:/usr/local/bin:${HOME}/.npm-global/bin:/Applications/ChatGPT.app/Contents/Resources/codex-cli/codex-path:/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS:${PATH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_PLUGIN_DIR="${SCRIPT_DIR}/plugin"
USER_HOME="${TARGET_HOME:-${HOME}}"
DEST_PLUGIN_DIR="${USER_HOME}/.gemini/config/plugins/codex-collaborator"

if [[ ! -d "$SRC_PLUGIN_DIR" ]]; then
  echo "ERROR: Plugin template directory not found at: $SRC_PLUGIN_DIR" >&2
  exit 1
fi

echo "==> Installing antigravity-codex (codex-collaborator)..."
echo "    Target directory: $DEST_PLUGIN_DIR"

mkdir -p "$DEST_PLUGIN_DIR"

# Clean up legacy rules/ or old skill directories if upgrading from an older version
rm -rf "${DEST_PLUGIN_DIR}/rules" "${DEST_PLUGIN_DIR}/skills/codex-executor"

# Copy plugin bundle files
cp -R "${SRC_PLUGIN_DIR}/." "$DEST_PLUGIN_DIR/"

# Replace <USER_HOME> placeholder with literal absolute path in SKILL.md and rules/AGENTS.md
ESCAPED_HOME="$(printf '%s\n' "$USER_HOME" | sed 's/[&/\]/\\&/g')"
for TARGET_MD in "${DEST_PLUGIN_DIR}/skills/codex/SKILL.md" "${DEST_PLUGIN_DIR}/rules/AGENTS.md"; do
  if [[ -f "$TARGET_MD" ]]; then
    TMP_MD="${TARGET_MD}.tmp"
    sed "s|<USER_HOME>|${ESCAPED_HOME}|g" "$TARGET_MD" > "$TMP_MD"
    mv "$TMP_MD" "$TARGET_MD"
  fi
done

# Make runner script executable, verify syntax, and sync live Codex model & project catalog
RUNNER_SCRIPT="${DEST_PLUGIN_DIR}/skills/codex/scripts/run-codex.sh"
chmod +x "$RUNNER_SCRIPT"
bash -n "$RUNNER_SCRIPT"
"$RUNNER_SCRIPT" sync-options || true

echo "==> Plugin files installed and validated successfully!"
echo ""

# Check OpenAI Codex CLI status
if command -v codex >/dev/null 2>&1; then
  CODEX_PATH="$(command -v codex)"
  CODEX_VER="$(codex --version 2>/dev/null || echo 'unknown')"
  echo "==> Detected Codex CLI: ${CODEX_VER} (${CODEX_PATH})"
  if CODEX_AUTH="$(codex login status 2>&1)"; then
    echo "==> Codex auth status: ${CODEX_AUTH}"
  else
    echo "!!  Codex CLI is not logged in yet. Run 'codex login' once in your terminal."
  fi
else
  echo "!!  'codex' CLI was not found in PATH."
  echo "    Install it via: npm install -g @openai/codex   (or: brew install codex)"
  echo "    Then run:       codex login"
fi

echo ""
echo "Done! Next steps:"
echo "  1. In Antigravity, normal messages still run directly with Gemini."
echo "  2. Type '/codex <your request>' whenever you want to invoke the Gemini x Codex workflow."
echo "  3. On the first run of run-codex.sh, click 'Always Allow' for seamless future runs."
