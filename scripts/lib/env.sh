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

# Secrets (optional — scripts that need them check the var explicitly).
# `set -a` auto-exports every var defined in secrets.env so child processes
# (python3 subprocesses in cfg.sh, curl, etc.) actually inherit them.
# Without this, `FOO=bar` in a dotenv file becomes a shell var but is NOT in
# os.environ for subprocesses, which breaks _cfg_resolve.py's token lookup.
if [[ -f "$SECRETS_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
  set +a
fi

# --- Derived identity from config.json ------------------------------------
# Several scripts (handlers/tempo.sh, watcher digest, notify-mr-opened) need
# the *owner's* own Jira account ID to call the Tempo API on their behalf.
# That value already lives in config.json under projects[0].owner.jiraAccountId
# but was never promoted to the environment — which silently disabled every
# tempo_suggest_now call path (it guards on `JIRA_ACCOUNT_ID` being set).
#
# We derive it here rather than baking it into secrets.env because:
#   - config.json is the single source of truth for team identity data.
#   - Users who edit owner.jiraAccountId don't also remember to regenerate
#     secrets.env.
#   - Everything else in this file is derived / defaulted, not authored.
#
# Only set values the user didn't already provide manually — an explicit
# export in secrets.env wins. `python3 -c` with try/except keeps this a
# total no-op on any misparsed / missing config.
if [[ -f "$CONFIG_FILE" ]]; then
  _derived=$(python3 - "$CONFIG_FILE" 2>/dev/null <<'PY'
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
projs = cfg.get("projects") or [cfg]
proj = projs[0] if projs else {}
owner = proj.get("owner") or cfg.get("owner") or {}
jid = owner.get("jiraAccountId") or ""
tz  = proj.get("workTz") or cfg.get("workTz") or ""
# Emit one line per var so bash can export them individually. Empty values
# are just blanks — the consumer uses `: ${VAR:=$x}` so it won't clobber.
print(f"JIRA_ACCOUNT_ID={jid}")
print(f"WORK_TZ={tz}")
PY
  )
  if [[ -n "$_derived" ]]; then
    while IFS='=' read -r _k _v; do
      [[ -z "$_k" || -z "$_v" ]] && continue
      # Only export if unset/empty — user-set values win. Use eval-indirect
      # instead of bash's ${!var} because this file is also sourced from zsh
      # via interactive shells, and zsh parses ${!name} as history expansion
      # ("bad substitution"), which would abort the loop mid-iteration.
      _cur=""; eval "_cur=\${$_k:-}"
      if [[ -z "$_cur" ]]; then
        export "$_k=$_v"
      fi
    done <<< "$_derived"
  fi
  unset _derived _k _v _cur
fi
