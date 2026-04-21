#!/bin/bash
# Autonomous Dev Agent — Triggers agent inside Cursor IDE
# Runs via launchd on a schedule. Uses Cursor CLI to run the agent
# inside the IDE workspace. Uses Telegram for notifications and
# curl for Jira REST API.

set -euo pipefail

# --- Shared bootstrap ------------------------------------------------------
SKILL_DIR="${SKILL_DIR:-$HOME/.cursor/skills/autonomous-dev-agent}"
source "$SKILL_DIR/scripts/lib/env.sh"
source "$SKILL_DIR/scripts/lib/cfg.sh"
source "$SKILL_DIR/scripts/lib/telegram.sh"
source "$SKILL_DIR/scripts/lib/jira.sh"
source "$SKILL_DIR/scripts/lib/workflow.sh"
source "$SKILL_DIR/scripts/lib/timegate.sh"
source "$SKILL_DIR/scripts/lib/timelog.sh"
source "$SKILL_DIR/scripts/lib/prompt.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/active-run.sh"
# ---------------------------------------------------------------------------

# Include PID so two runs spawned in the same second don't share a log file.
LOG_FILE="$LOG_DIR/$(date +%Y-%m-%d_%H-%M-%S)-$$.log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== Autonomous Dev Agent Run: $(date) ==="

if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "ERROR: secrets.env not found"
  exit 1
fi

RUN_PID="$$"
RUN_STARTED_AT=$(date +%s)

# Manual = the user explicitly triggered this run via Telegram (tk_start, ci_fix,
# fb_fix, ask, retry, cherry, etc). Scheduled runs have none of FORCE_* set.
# Manual runs:
#   1. Bypass the work-hours guard (user explicitly asked for it)
#   2. Always ping Telegram on exit (success, failure, or skip) so you're never
#      left wondering what happened after tapping a button.
IS_MANUAL=0
MANUAL_CTX=""
if [[ -n "${FORCE_TICKET:-}" ]]; then
  IS_MANUAL=1
  MANUAL_CTX="${FORCE_TICKET}"
  [[ "${RETRY_MODE:-}" == "true" ]] && MANUAL_CTX="${MANUAL_CTX} (retry)"
elif [[ -n "${FORCE_MR:-}" ]]; then
  IS_MANUAL=1
  MANUAL_CTX="!${FORCE_MR} (${FORCE_REPO:-ssr}/${FORCE_MODE:-ci-fix})"
elif [[ -n "${FORCE_PROMPT:-}" ]]; then
  IS_MANUAL=1
  MANUAL_CTX="chat"
fi

# Exit handler: unregister live-run entry, prune stale ones, and send a Telegram
# ping when appropriate.
_on_exit() {
  local code="${1:-0}"
  # Stop the phase-tailer if we started one
  if [[ -n "${PHASE_TAIL_PID:-}" ]]; then
    kill "$PHASE_TAIL_PID" >/dev/null 2>&1 || true
  fi
  # Only unregister if we actually registered — otherwise every early-exit
  # (missing creds / outside hours / cursor not running) would try to pop a
  # non-existent entry. Harmless but noisy in strace.
  if active_run_is_registered "$RUN_PID" >/dev/null 2>&1; then
    active_run_unregister "$RUN_PID" >/dev/null 2>&1 || true
  fi
  active_run_prune >/dev/null 2>&1 || true
  # Log housekeeping always runs (not just on success)
  ls -t "$LOG_DIR"/*.log 2>/dev/null | tail -n +51 | xargs rm -f 2>/dev/null || true

  # Elapsed time (human-readable)
  local end
  end=$(date +%s)
  local secs=$(( end - RUN_STARTED_AT ))
  local dur
  if   (( secs < 60 ));   then dur="${secs}s"
  elif (( secs < 3600 )); then dur="$((secs/60))m$((secs%60))s"
  else                          dur="$((secs/3600))h$(( (secs%3600)/60 ))m"
  fi

  # Tempo capture: agent_end. Only emitted when we actually opened an
  # agent_start event (i.e. got past active_run_register and set RUN_ID).
  if [[ -n "${RUN_ID:-}" ]]; then
    local exit_kind="ok"
    if [[ "${RUN_SKIPPED:-0}" == "1" ]]; then
      exit_kind="skipped"
    elif [[ "$code" != "0" ]]; then
      exit_kind="fail"
    fi
    tl_emit agent_end \
      ticket="${RUN_TICKET:---}" \
      mr_iid="${RUN_MR_IID:---}" \
      mode="${RUN_MODE:-unknown}" \
      run_id="$RUN_ID" \
      exit="$exit_kind" \
      exit_code="$code" \
      seconds="$secs"
  fi

  # Notify:
  #   • Manual run → always (Done / Failed / Skipped)
  #   • Scheduled run → only on failure (keeps old behaviour; no spam on clean idle)
  local should_notify=0
  local verdict=""
  if [[ "$IS_MANUAL" == "1" ]]; then
    should_notify=1
    if [[ "$code" == "0" ]]; then
      if [[ "${RUN_SKIPPED:-0}" == "1" ]]; then
        verdict="Skipped — ${RUN_SKIP_REASON:-no work}"
      else
        verdict="Done"
      fi
    else
      verdict="Failed (exit $code)"
    fi
  elif [[ "$code" != "0" ]]; then
    should_notify=1
    verdict="Failed (exit $code)"
  fi

  if [[ "$should_notify" == "1" ]] \
     && [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] \
     && [[ -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    local body="Agent run — ${MANUAL_CTX:-scheduled}
${verdict}
Duration: ${dur}
Log: $(basename "${LOG_FILE:-?}")"
    tg_send "$body" >/dev/null 2>&1 || true
  fi
}
trap '_on_exit $?' EXIT INT TERM

# --- Time guard: only run during work hours (owner's configured window) ---
# Manual runs bypass the guard — you asked for it, so we run it. Scheduled
# (launchd) runs still respect active hours (shared timegate.sh).
if [[ "$IS_MANUAL" != "1" ]]; then
  if ! in_work_hours; then
    cur_h=$(TZ="$WORK_TZ" date +%H | sed 's/^0*//'); cur_h="${cur_h:-0}"
    echo "Outside work hours (${cur_h}:xx ${WORK_TZ}). Active: ${WORK_HOURS_START}:00–${WORK_HOURS_END}:00. Skipping."
    RUN_SKIPPED=1; RUN_SKIP_REASON="outside work hours (${cur_h}:xx, active ${WORK_HOURS_START}–${WORK_HOURS_END} ${WORK_TZ})"
    exit 0
  fi
else
  echo "Manual run (${MANUAL_CTX}) — bypassing work-hour guard."
fi

if [[ -z "${ATLASSIAN_API_TOKEN:-}" ]]; then
  echo "ERROR: ATLASSIAN_API_TOKEN not set"
  exit 1
fi

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
  echo "ERROR: TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set"
  exit 1
fi

# Check if Cursor is running
if ! pgrep -x "Cursor" > /dev/null 2>&1; then
  echo "Cursor IDE is not running. Skipping this run."
  RUN_SKIPPED=1; RUN_SKIP_REASON="Cursor IDE not running"
  exit 0
fi

echo "Cursor is running. Checking for work..."

# --- Pre-flight: check Jira + Telegram BEFORE launching the agent (saves tokens) ---

# 1a. Check Jira for implementation tickets (New / To Do assigned to me)
JIRA_RESPONSE=$(jira_search \
  "assignee = '${JIRA_ACCOUNT_ID}' AND status IN ('New', 'To Do') ORDER BY priority ASC, created ASC" \
  1 "summary" 2>/dev/null)

TICKET_COUNT=$(echo "$JIRA_RESPONSE" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('issues',[])))" 2>/dev/null || echo "0")

# 1b. Check Jira for code-review tickets (Code Review status assigned to me, MR author != me)
REVIEW_RESPONSE=$(jira_search \
  "assignee = '${JIRA_ACCOUNT_ID}' AND status = 'Code Review' ORDER BY updated DESC" \
  10 "summary" 2>/dev/null)

REVIEW_COUNT=$(echo "$REVIEW_RESPONSE" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('issues',[])))" 2>/dev/null || echo "0")

# 1c. Check for pending review discussion questions from user (via Telegram)
DISCUSSION_COUNT=$(ls "$REVIEWS_DIR/"*-discussions.json 2>/dev/null | wc -l | tr -d ' ' || echo "0")

# 2. Check Telegram for pending button clicks or review commands
TELEGRAM_UPDATES=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?offset=-20" 2>/dev/null)
HAS_CALLBACKS=$(echo "$TELEGRAM_UPDATES" | python3 -c "
import sys,json
data = json.load(sys.stdin)
results = data.get('result',[])
has_work = any(r.get('callback_query') for r in results)
# Only check for commands that need the Cursor agent (review, fix, approve, etc.)
# Commands handled by telegram-handler.sh are excluded: status, tickets, mrs, logs, digest, run, stop, start
AGENT_KEYWORDS = ['review ','fix ','approve ','skip ','go ahead','retry ']
HANDLER_KEYWORDS = ['status','tickets','mrs','reviews','logs','digest','run','stop','start','menu','hide','help','watch','snooze','unsnooze','ask ','cherry ','cherries','?','rv_','ci_','fb_','tk_','rel_','/']
has_text = False
for r in results:
    msg = r.get('message',{})
    if msg.get('chat',{}).get('id') != ${TELEGRAM_CHAT_ID}:
        continue
    text = (msg.get('text','') or '').lower().strip()
    if not text:
        continue
    if any(text.startswith(h) for h in HANDLER_KEYWORDS):
        continue
    if any(kw in text for kw in AGENT_KEYWORDS):
        has_text = True
        break
print('yes' if (has_work or has_text) else 'no')
" 2>/dev/null || echo "no")

if [[ -n "${FORCE_TICKET:-}" ]]; then
  echo "Forced ticket: ${FORCE_TICKET} (retry: ${RETRY_MODE:-false}). Skipping pre-flight."
elif [[ -n "${FORCE_MR:-}" ]]; then
  echo "Forced MR: !${FORCE_MR} repo=${FORCE_REPO:-ssr} mode=${FORCE_MODE:-ci-fix}. Skipping pre-flight."
elif [[ -n "${FORCE_PROMPT:-}" ]]; then
  echo "Chat mode: ${FORCE_PROMPT:0:120}…"
elif [[ "$TICKET_COUNT" == "0" && "$REVIEW_COUNT" == "0" && "$DISCUSSION_COUNT" == "0" && "$HAS_CALLBACKS" == "no" ]]; then
  echo "Nothing to do: 0 impl tickets, 0 review tickets, 0 discussions, 0 Telegram actions. Skipping."
  echo "=== Skipped (nothing to do) at $(date) ==="
  RUN_SKIPPED=1; RUN_SKIP_REASON="nothing to do (0 tickets / 0 reviews / 0 callbacks)"
  exit 0
else
  echo "Found: impl=$TICKET_COUNT review=$REVIEW_COUNT discussions=$DISCUSSION_COUNT telegram=$HAS_CALLBACKS. Launching agent..."
fi

# Use Cursor CLI to run the agent inside the IDE workspace
export PATH="$HOME/.local/bin:$PATH"

# Prompts are tokenized templates ({{JIRA_SITE}}, {{TICKET_PREFIX}}, etc) so the
# same files ship to every fork. prompt_render substitutes identity tokens at
# read time using values exported by cfg.sh. SKILL.md is rendered at install
# time into a concrete file (the Cursor skill system reads it directly), so
# here we just cat it.
PROMPT_TEMPLATE=$(cat "$SKILL_DIR/SKILL.md")
CONFIG=$(cat "$CONFIG_FILE")
CODE_REVIEW_PROMPT=$(prompt_render "$SKILL_DIR/prompts/phase-codereview.md")
CI_FIX_PROMPT=$(prompt_render "$SKILL_DIR/prompts/phase-cifix.md" 2>/dev/null || echo "")

# Build context for forced ticket / MR / retry mode
EXTRA_CONTEXT=""
FORCE_SECTION=""
if [[ -n "${FORCE_TICKET:-}" ]]; then
  EXTRA_CONTEXT="IMPORTANT: Process ONLY ticket ${FORCE_TICKET}. Skip discovery — go directly to analysis."
  if [[ "${RETRY_MODE:-}" == "true" ]]; then
    FAILURES=$(cat "${FAILURES_FILE:-$CACHE_DIR/failures.json}" 2>/dev/null || echo "{}")
    EXTRA_CONTEXT="$EXTRA_CONTEXT
This is a RETRY. Read the failure context from cache/failures.json for ${FORCE_TICKET}.
If the branch already exists, check it out and fix the previous error instead of starting fresh.
Failure context: $FAILURES"
  fi
elif [[ -n "${FORCE_PROMPT:-}" ]]; then
  # Chat mode — user asked a free-form question via Telegram /ask
  EXTRA_CONTEXT="CHAT MODE.
The user sent this prompt via Telegram:

\"${FORCE_PROMPT}\"

Instructions:
1. Answer the prompt using available tools (Jira, glab, filesystem, shell).
2. Be concise. If it's a question, answer in 1-3 short paragraphs.
3. If it's a task (e.g. 'list my MRs', 'summarize UA-972', 'show tests failing on 1920'),
   gather the data and respond with the result.
4. Send your reply via Telegram sendMessage to chat ${TELEGRAM_CHAT_ID}.
   - Format: prefix each message with 'Agent: ' so reply-to-message works.
   - Max 4000 chars per message (split if needed).
5. DO NOT run phase-1 discovery, phase-2 implementation, phase-8 review, or phase-9
   auto-fix unless the user's prompt explicitly asks for those actions.
6. DO NOT modify files, commit, or push unless the prompt explicitly asks.
7. When done, stop. Do not loop or keep watching for more work."
elif [[ -n "${FORCE_MR:-}" ]]; then
  FORCE_REPO="${FORCE_REPO:-ssr}"
  FORCE_MODE="${FORCE_MODE:-ci-fix}"
  # Use shared cfg accessor instead of re-reading config.json.
  REPO_LOCAL=$(cfg_get "['repositories']['${FORCE_REPO}']['localPath']" 2>/dev/null)
  REPO_PROJECT=$(cfg_get "['repositories']['${FORCE_REPO}']['gitlabProject']" 2>/dev/null)

  if [[ "$FORCE_MODE" == "ci-fix" ]]; then
    EXTRA_CONTEXT="IMPORTANT: CI Auto-Fix Mode.
You are fixing a FAILED pipeline on an existing MR. Follow Phase 9 (CI Auto-Fix) exactly.
DO NOT run Phase 1 (discover), Phase 2 (implement), or Phase 8 (review).
Inputs:
- FORCE_MR = ${FORCE_MR}
- FORCE_REPO = ${FORCE_REPO}
- REPO local path = ${REPO_LOCAL}
- Repo project path = ${REPO_PROJECT}"
    FORCE_SECTION="
## CI Auto-Fix Mode (Phase 9) — detailed spec:

$CI_FIX_PROMPT
"
  elif [[ "$FORCE_MODE" == "feedback" ]]; then
    EXTRA_CONTEXT="IMPORTANT: Feedback Fix Mode.
You are applying reviewer feedback to your OWN existing MR.
DO NOT run discovery or review mode.
Follow Phase 3 (feedback), but instead of reading Telegram text, fetch the NEW
reviewer comments since the last seen note_id from:
  glab api projects/:fullpath/merge_requests/${FORCE_MR}/notes?sort=desc&per_page=20

Only process notes whose author is NOT ${GITLAB_USER} and created_at > last-seen.
Address each comment in a separate commit (same branch), push, and reply in each
thread confirming the change with 1 short sentence. Mark threads resolved when
the change fully addresses the comment.

Inputs:
- FORCE_MR = ${FORCE_MR}
- FORCE_REPO = ${FORCE_REPO}
- REPO local path = ${REPO_LOCAL}
- Repo project path = ${REPO_PROJECT}"
  fi
fi

if [[ -n "${FORCE_PROMPT:-}" ]]; then
  # Chat / tool-dispatch mode — keep the prompt small and focused. No phase specs.
  AGENT_PROMPT="You are a single-task assistant. Execute ONLY the task below. Do not load or run any workflow, discovery, review, implementation, or auto-fix phase.

${EXTRA_CONTEXT}

## Minimal credentials (use only if the task explicitly needs them):

Telegram bot token: ${TELEGRAM_BOT_TOKEN}
Telegram chat ID: ${TELEGRAM_CHAT_ID}
Atlassian email: ${ATLASSIAN_EMAIL}
Atlassian API token: ${ATLASSIAN_API_TOKEN}
Jira base URL: ${JIRA_SITE}

Complete the task and stop. Do not start any other work."
else
  AGENT_PROMPT="You are ${OWNER_FIRST_NAME}'s autonomous development agent. Run the full workflow now.

${EXTRA_CONTEXT}

## Skill Document (follow this exactly):

$PROMPT_TEMPLATE

## Code Review Mode (Phase 8) — detailed spec:

$CODE_REVIEW_PROMPT
$FORCE_SECTION
## Configuration:

$CONFIG

## API Credentials:

Atlassian email: ${ATLASSIAN_EMAIL}
Atlassian API token: ${ATLASSIAN_API_TOKEN}
Jira base URL: ${JIRA_SITE}

Telegram bot token: ${TELEGRAM_BOT_TOKEN}
Telegram chat ID: ${TELEGRAM_CHAT_ID}

Use curl with Basic Auth (-u email:token) for all Jira REST API calls.
Use curl with Telegram Bot API for all notifications.
Use glab CLI for all GitLab operations.

## Work queue discovered:
- Implementation tickets (New/To Do): ${TICKET_COUNT}
- Code Review tickets (assigned to me): ${REVIEW_COUNT}
- Pending review discussion questions: ${DISCUSSION_COUNT}

ORDER OF EXECUTION:
1. First, handle any pending discussion questions in cache/reviews/*-discussions.json (Phase 8, Step 7).
2. Then, review each Code Review ticket (Phase 8) — write results to cache/reviews/, do NOT post to GitLab yourself.
3. Finally, implement each New/To Do ticket (Phases 1-7).

Start now."
fi

echo "Launching agent..."

# --- Determine what this run is about for /status reporting ---
if [[ -n "${FORCE_PROMPT:-}" ]]; then
  RUN_MODE="chat"
  RUN_TICKET="${FORCE_TICKET:---}"
  RUN_MR_IID="${FORCE_MR:---}"
  RUN_REPO="${FORCE_REPO:---}"
elif [[ -n "${FORCE_MR:-}" ]]; then
  RUN_MODE="${FORCE_MODE:-ci-fix}"
  RUN_TICKET="${FORCE_TICKET:---}"
  RUN_MR_IID="${FORCE_MR}"
  RUN_REPO="${FORCE_REPO:-ssr}"
elif [[ -n "${FORCE_TICKET:-}" ]]; then
  if [[ "${RETRY_MODE:-}" == "true" ]]; then
    RUN_MODE="retry"
  else
    RUN_MODE="implementation"
  fi
  RUN_TICKET="${FORCE_TICKET}"
  RUN_MR_IID="--"
  RUN_REPO="--"
else
  RUN_MODE="full"
  RUN_TICKET="--"
  RUN_MR_IID="--"
  RUN_REPO="--"
fi

active_run_register "$RUN_PID" "$RUN_MODE" "$RUN_TICKET" "$LOG_FILE" "$RUN_MR_IID" "$RUN_REPO" "launching" \
  "${FORCE_ROUND:-1}" >/dev/null 2>&1 || true

# Tempo capture: agent_start. Paired with agent_end in _on_exit via $RUN_ID.
RUN_ID=$(tl_run_id)
tl_emit agent_start \
  ticket="$RUN_TICKET" \
  mr_iid="$RUN_MR_IID" \
  repo="$RUN_REPO" \
  mode="$RUN_MODE" \
  run_id="$RUN_ID" \
  manual="${IS_MANUAL}" \
  pid="$RUN_PID"

# Phase hint before the blocking CLI call — /status will show this while agent runs.
case "$RUN_MODE" in
  chat)           active_run_set_phase "$RUN_PID" "chat";;
  ci-fix)         active_run_set_phase "$RUN_PID" "ci-fix";;
  feedback)       active_run_set_phase "$RUN_PID" "applying-feedback";;
  implementation) active_run_set_phase "$RUN_PID" "implementing";;
  retry)          active_run_set_phase "$RUN_PID" "retrying";;
  *)              active_run_set_phase "$RUN_PID" "working";;
esac

# Live phase tracking: tail the log for 'PHASE: <name>' markers the agent emits
# during its workflow. The last seen marker becomes the current phase for
# /status. This replaces the static hint above as soon as the agent writes its
# first PHASE: line.
(
  last=""
  while sleep 5; do
    p=$(tail -n 200 "$LOG_FILE" 2>/dev/null | grep -Eo 'PHASE:[[:space:]]*[A-Za-z0-9._/-]+' | tail -1 | sed -E 's/^PHASE:[[:space:]]*//')
    if [[ -n "$p" && "$p" != "$last" ]]; then
      active_run_set_phase "$RUN_PID" "$p" >/dev/null 2>&1 || true
      last="$p"
    fi
  done
) &
PHASE_TAIL_PID=$!

# Model selection: config.agent.model (root) or projects[].agent.model
# (per-project), with optional per-phase overrides under agent.perPhase.*.
# cfg.sh exports $AGENT_MODEL as the effective default; specific phases
# can pick AGENT_MODEL_CODEREVIEW / _CIFIX / _PLANNER / _EXECUTOR.
RUN_MODEL="$AGENT_MODEL"
if [[ "${RETRY_MODE:-}" == "true" ]]; then
  RUN_MODEL="${AGENT_MODEL_CIFIX:-$AGENT_MODEL}"
fi

set +e
agent -p --force --trust --approve-mcps \
  --model "$RUN_MODEL" \
  --workspace "$SSR_REPO" \
  --output-format text \
  "$AGENT_PROMPT" \
  >> "$LOG_FILE" 2>&1
EXIT_CODE=$?
set -e

echo "=== Agent finished with exit code: $EXIT_CODE at $(date) ==="

# Telegram notification + log cleanup are handled by the EXIT trap (_on_exit).

# Preserve the agent's exit code so the trap reports it accurately.
exit "$EXIT_CODE"
