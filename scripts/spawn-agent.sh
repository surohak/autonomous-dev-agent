#!/bin/bash
# Centralized launcher for run-agent.sh.
#
# Every Telegram button / typed command that starts an agent goes through this
# helper, which enforces:
#   1. Per-resource dedup (same ticket or same MR not started twice concurrently).
#   2. Global concurrency cap (ACTIVE_RUNS_MAX, default 10).
#   3. Early Jira transition (New/To Do → In Progress) for ticket-scoped runs
#      so /tickets reflects reality immediately.
#   4. Spawns run-agent.sh in the background and echoes a verdict to stdout.
#
# Stdout verdicts (one line, tab-separated):
#   OK\tspawned\t<ignored>         — run started
#   DUPLICATE\t<pid>\t<kind>:<id>  — same ticket/MR already running
#   OVER_CAP\t<count>/<max>\t-     — too many parallel runs
#
# Environment variables the caller sets (just like before):
#   FORCE_TICKET=PROJ-123                     — single ticket
#   FORCE_MR=2046  FORCE_REPO=ssr  FORCE_MODE=ci-fix|feedback
#   FORCE_PROMPT="..."                      — free-form chat
#   RETRY_MODE=true                         — retry with saved context
#   FORCE_ROUND=<N>                         — re-review round hint (optional)

# --- Shared bootstrap (env / cfg / jira for idempotent transition) ---------
SKILL_DIR="${SKILL_DIR:-$HOME/.cursor/skills/autonomous-dev-agent}"
source "$SKILL_DIR/scripts/lib/env.sh"
source "$SKILL_DIR/scripts/lib/jira.sh"
source "$SKILL_DIR/scripts/lib/workflow.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/active-run.sh"
# ---------------------------------------------------------------------------

ADMIT_KIND=""
ADMIT_ID=""
if [[ -n "${FORCE_TICKET:-}" ]]; then
  ADMIT_KIND="ticket"; ADMIT_ID="$FORCE_TICKET"
elif [[ -n "${FORCE_MR:-}" ]]; then
  ADMIT_KIND="mr"; ADMIT_ID="$FORCE_MR"
fi

if [[ -n "$ADMIT_KIND" ]]; then
  VERDICT=$(active_run_admit "$ADMIT_KIND" "$ADMIT_ID")
  case "$VERDICT" in
    DUPLICATE:*)
      PID="${VERDICT#DUPLICATE:}"
      printf 'DUPLICATE\t%s\t%s:%s\n' "$PID" "$ADMIT_KIND" "$ADMIT_ID"
      exit 0
      ;;
    OVER_CAP:*)
      COUNT="${VERDICT#OVER_CAP:}"
      printf 'OVER_CAP\t%s\t-\n' "$COUNT"
      exit 0
      ;;
    OK:*)
      : # fallthrough to launch
      ;;
    *)
      # Unknown — be safe and don't block the user
      ;;
  esac
else
  # No admit-id → still apply the global cap
  VERDICT=$(active_run_admit "any" "--")
  case "$VERDICT" in
    OVER_CAP:*)
      COUNT="${VERDICT#OVER_CAP:}"
      printf 'OVER_CAP\t%s\t-\n' "$COUNT"
      exit 0
      ;;
  esac
fi

# --- Early Jira transition for ticket-scoped runs --------------------------
# If the ticket is in New / To Do, move it to "Work In Progress" so /tickets
# (which only shows New/To Do) no longer hides an actively-worked ticket.
# Runs in the background so it doesn't delay spawning the agent.
if [[ "$ADMIT_KIND" == "ticket" ]] \
   && [[ -n "${ATLASSIAN_EMAIL:-}" ]] \
   && [[ -n "${ATLASSIAN_API_TOKEN:-}" ]]; then
  (
    # workflow_transition uses the per-project workflow cache to find the
    # right transition id; it falls through to jira_transition_to on a miss,
    # which is itself idempotent (no-op when already past "To Do").
    workflow_transition "$ADMIT_ID" start >/dev/null 2>&1 || true
  ) &
fi

# --- Launch ---
# nohup so parent shell death doesn't kill the agent. Detach from TTY.
nohup bash "$SKILL_DIR/scripts/run-agent.sh" >> "$LOG_DIR/launchd-triggered.log" 2>&1 &
printf 'OK\tspawned\t-\n'
