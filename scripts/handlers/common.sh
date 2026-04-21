#!/bin/bash
# scripts/handlers/common.sh — helpers shared by every Telegram command handler.
#
# Sourced once by telegram-handler.sh (which itself sources the lib/* files).
# Requires: env.sh, cfg.sh, telegram.sh, jira.sh, timegate.sh, active-run.sh
#
# Public:
#   _spawn_agent <label> <success_msg>   — wrapper around spawn-agent.sh
#   _active_runs_file                     — absolute path to active-runs.json
#
# Guarded so multiple sourcings are no-op.

[[ -n "${_DEV_AGENT_HANDLER_COMMON_LOADED:-}" ]] && return 0
_DEV_AGENT_HANDLER_COMMON_LOADED=1

_active_runs_file() {
  # cfg.sh exports ACTIVE_RUNS_FILE under the active project's cache namespace.
  # Fall back to the legacy flat path if cfg wasn't loaded (e.g. in isolated tests).
  printf '%s\n' "${ACTIVE_RUNS_FILE:-$CACHE_DIR/active-runs.json}"
}

# Launch an agent run via spawn-agent.sh and translate the structured verdict
# into a user-facing Telegram message. Caller must have `export`ed the right
# FORCE_* env vars beforehand.
#
# Args:
#   $1 = short label (e.g. "UA-123" or "!2019 ci-fix") — used in messages
#   $2 = success text to send on OK (e.g. "Starting agent for UA-123...")
_spawn_agent() {
  local label="$1" success_msg="$2"
  local verdict kind detail
  verdict=$(bash "$SKILL_DIR/scripts/spawn-agent.sh" 2>/dev/null || echo "")
  # verdict format: "<KIND>\t<detail>\t<extra>"  (tab-separated)
  kind=$(printf '%s' "$verdict" | cut -f1)
  detail=$(printf '%s' "$verdict" | cut -f2)
  case "$kind" in
    OK)
      tg_send "$success_msg"
      ;;
    DUPLICATE)
      tg_send "$label is already running (pid $detail). Use /status to see all runs, /stopall to stop everything, or the ticket's [Stop run] button."
      ;;
    OVER_CAP)
      tg_send "At capacity ($detail active runs). Stop one with /stopall or wait, then try again."
      ;;
    *)
      # Fallback — shouldn't normally happen; don't block the user
      tg_send "$success_msg"
      ;;
  esac
}
