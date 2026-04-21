#!/bin/bash
# scripts/lib/env.sh
#
# Canonical entry point sourced by every script in scripts/.
# Sets up:
#   - SKILL_DIR / CACHE_DIR / LOG_DIR / REVIEWS_DIR / SECRETS_FILE / CONFIG_FILE
#   - PYTHONPATH (so `import jsonstate` works in every heredoc)
#   - Loads secrets.env if present (idempotent)
#
# Usage (from any script):
#     source "${SKILL_DIR:-$HOME/.cursor/skills/autonomous-dev-agent}/scripts/lib/env.sh"
#
# Idempotent — safe to source more than once.

[[ -n "${_DEV_AGENT_ENV_LOADED:-}" ]] && return 0
_DEV_AGENT_ENV_LOADED=1

export SKILL_DIR="${SKILL_DIR:-$HOME/.cursor/skills/autonomous-dev-agent}"
export CACHE_DIR="${CACHE_DIR:-$SKILL_DIR/cache}"
export LOG_DIR="${LOG_DIR:-$SKILL_DIR/logs}"
export REVIEWS_DIR="${REVIEWS_DIR:-$CACHE_DIR/reviews}"
export SECRETS_FILE="${SECRETS_FILE:-$SKILL_DIR/secrets.env}"
export CONFIG_FILE="${CONFIG_FILE:-$SKILL_DIR/config.json}"
export SCRIPTS_DIR="${SCRIPTS_DIR:-$SKILL_DIR/scripts}"
export LIB_DIR="${LIB_DIR:-$SCRIPTS_DIR/lib}"

mkdir -p "$CACHE_DIR" "$LOG_DIR" "$REVIEWS_DIR"

# Make `import jsonstate` discoverable in any inline Python (`python3 -c`, heredoc).
if [[ ":${PYTHONPATH:-}:" != *":$LIB_DIR:"* ]]; then
  export PYTHONPATH="$LIB_DIR${PYTHONPATH:+:$PYTHONPATH}"
fi

# Secrets (optional — scripts that need them check the var explicitly)
if [[ -f "$SECRETS_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
fi
