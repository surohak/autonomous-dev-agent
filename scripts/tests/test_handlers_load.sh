#!/bin/bash
# test_handlers_load.sh
# Smoke-test that every handler module sources cleanly alongside the full
# lib/* chain and exposes the functions the big telegram-handler case
# statement calls. Does not invoke anything that touches the network.

set -uo pipefail

SKILL_DIR="${SKILL_DIR:-$HOME/.cursor/skills/autonomous-dev-agent}"
# Hermetic sandbox for any side-effects.
export CACHE_DIR="${TEST_TMP:-/tmp}/handlers-load/cache"
export LOG_DIR="${TEST_TMP:-/tmp}/handlers-load/logs"
mkdir -p "$CACHE_DIR" "$LOG_DIR"
# Stub secrets so lib/jira.sh etc. don't bail out.
export TELEGRAM_BOT_TOKEN="stub"
export TELEGRAM_CHAT_ID="1"
export ATLASSIAN_EMAIL="x"
export ATLASSIAN_API_TOKEN="y"

# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/env.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/cfg.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/telegram.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/jira.sh"
source "$SKILL_DIR/scripts/lib/workflow.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/gitlab.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/timelog.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/active-run.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/handlers/common.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/handlers/help.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/handlers/basic.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/handlers/runs.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/handlers/queue.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/handlers/watch.sh"

# Every function referenced from telegram-handler.sh's case statement.
REQUIRED_FUNCTIONS=(
  # common
  _spawn_agent _active_runs_file
  # help + basic
  cmd_help cmd_status cmd_logs cmd_digest cmd_run
  cmd_stop_scheduled cmd_start_scheduled
  handler_run_ticket handler_approve handler_skip
  handler_review_prompt handler_retry handler_ask
  # runs
  cmd_stopall handler_rn_log handler_rn_stop
  # queue
  cmd_tickets cmd_mrs
  # watch
  cmd_watch handler_snooze cmd_unsnooze cmd_hide_menu
)

missing=0
for fn in "${REQUIRED_FUNCTIONS[@]}"; do
  if ! declare -F "$fn" >/dev/null 2>&1; then
    echo "MISSING handler function: $fn" >&2
    missing=$((missing + 1))
  fi
done

if [[ "$missing" -ne 0 ]]; then
  echo "FAIL: $missing required handler functions are not defined" >&2
  exit 1
fi

# Double-check: telegram-handler.sh still parses with all libs preloaded.
if ! bash -n "$SKILL_DIR/scripts/telegram-handler.sh"; then
  echo "FAIL: telegram-handler.sh does not parse" >&2
  exit 1
fi

echo "OK: all $(( ${#REQUIRED_FUNCTIONS[@]} )) handler functions defined; telegram-handler.sh parses"
