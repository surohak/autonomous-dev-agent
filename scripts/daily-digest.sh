#!/bin/bash
# Daily Digest — sends end-of-day summary to Telegram
# Runs at 20:00 GMT+4 via launchd. No Cursor agent needed, no tokens spent.

set -euo pipefail

# --- Shared bootstrap ------------------------------------------------------
SKILL_DIR="${SKILL_DIR:-$HOME/.cursor/skills/autonomous-dev-agent}"
source "$SKILL_DIR/scripts/lib/env.sh"
source "$SKILL_DIR/scripts/lib/cfg.sh"
source "$SKILL_DIR/scripts/lib/telegram.sh"
source "$SKILL_DIR/scripts/lib/jira.sh"
source "$SKILL_DIR/scripts/lib/workflow.sh"
# Tempo is optional — source only if configured so installs without Tempo
# still get a clean digest.
[[ -f "$SKILL_DIR/scripts/lib/tempo.sh" ]] && source "$SKILL_DIR/scripts/lib/tempo.sh"
# ---------------------------------------------------------------------------

TODAY=$(date +%Y-%m-%d)
TODAY_DISPLAY=$(date +"%b %d")

PROCESSED=0
MRS_OPENED=0
SKIPPED=0
FAILED=0

for LOG_FILE in "$LOG_DIR"/${TODAY}_*.log; do
  [ -f "$LOG_FILE" ] || continue

  CONTENT=$(cat "$LOG_FILE")

  if echo "$CONTENT" | grep -qi "MR opened\|merge_requests\|MR !"; then
    MRS_OPENED=$((MRS_OPENED + 1))
    PROCESSED=$((PROCESSED + 1))
  fi

  if echo "$CONTENT" | grep -qi "Skipped\|clarification needed\|large scope"; then
    SKIPPED=$((SKIPPED + 1))
    PROCESSED=$((PROCESSED + 1))
  fi

  if echo "$CONTENT" | grep -qi "failed\|error\|exit code: 1"; then
    FAILED=$((FAILED + 1))
  fi
done

# --- Jira queue via shared lib --------------------------------------------
JIRA_QUEUE=$(jira_search \
  "assignee = '${JIRA_ACCOUNT_ID}' AND status IN ('New', 'To Do') ORDER BY priority ASC" \
  10 "summary")

QUEUE_COUNT=$(echo "$JIRA_QUEUE" | python3 -c "
import sys, json
try: print(len(json.load(sys.stdin).get('issues', [])))
except: print(0)
" 2>/dev/null || echo "0")

QUEUE_LIST=$(echo "$JIRA_QUEUE" | python3 -c "
import sys, json
try: issues = json.load(sys.stdin).get('issues', [])
except: issues = []
for i in issues:
    print(f'  - {i[\"key\"]}: {i[\"fields\"][\"summary\"]}')
" 2>/dev/null || echo "  None")

# --- GitLab MRs ------------------------------------------------------------
SSR_MR_LIST=""
cd "$SSR_REPO" 2>/dev/null && SSR_MRS=$(glab mr list --author=@me --per-page=10 2>/dev/null || echo "")
[ -n "${SSR_MRS:-}" ] && SSR_MR_LIST=$(echo "$SSR_MRS" | head -10)

BLOG_MR_LIST=""
cd "$BLOG_REPO" 2>/dev/null && BLOG_MRS=$(glab mr list --author=@me --per-page=10 2>/dev/null || echo "")
[ -n "${BLOG_MRS:-}" ] && BLOG_MR_LIST=$(echo "$BLOG_MRS" | head -10)

MR_SECTION=""
if [ -n "$SSR_MR_LIST" ] || [ -n "$BLOG_MR_LIST" ]; then
  MR_SECTION="
Open MRs:"
  [ -n "$SSR_MR_LIST" ] && MR_SECTION="$MR_SECTION
SSR:
$SSR_MR_LIST"
  [ -n "$BLOG_MR_LIST" ] && MR_SECTION="$MR_SECTION
Blog:
$BLOG_MR_LIST"
else
  MR_SECTION="
Open MRs: None"
fi

# --- v0.5.0 — Tempo total-vs-tracked delta ---------------------------------
# Reads today's worklogs (if Tempo is configured) and compares against the
# daily target (owner.dailyWorkSeconds, default 8h = 28800). Emits a delta
# line + a separate inline card with a [Backfill <delta>] button when the
# user is under target. One tap triggers tempo_post_worklog against the
# last ticket they were on.
TEMPO_SECTION=""
TEMPO_BACKFILL_DELTA=0
TEMPO_BACKFILL_TICKET=""
if [[ -n "${TEMPO_API_TOKEN:-}" ]] && [[ -n "${JIRA_ACCOUNT_ID:-}" ]] && type tempo_list_worklogs >/dev/null 2>&1; then
  _tempo_raw=$(tempo_list_worklogs "$JIRA_ACCOUNT_ID" "$TODAY" "$TODAY" 2>/dev/null || echo '{"results":[]}')
  _tempo_parsed=$(TARGET="${OWNER_DAILY_WORK_SECONDS:-28800}" RAW="$_tempo_raw" python3 <<'PY'
import json, os
try:
    d = json.loads(os.environ["RAW"] or "{}")
except Exception:
    d = {}
rows = d.get("results") or d.get("worklogs") or []
total = 0
last_ticket = ""
last_ts = 0
for r in rows:
    secs = int(r.get("timeSpentSeconds") or 0)
    total += secs
    # Track the most recently updated worklog so the backfill button can
    # default to that ticket.
    key = ((r.get("issue") or {}).get("key")
           or (r.get("issue") or {}).get("issueKey") or "")
    started = r.get("startDate","") + " " + (r.get("startTime","") or "00:00:00")
    # Rough ordering by started timestamp as fallback.
    if key and started >= str(last_ts):
        last_ts = started
        last_ticket = key
target = int(os.environ.get("TARGET","28800") or 28800)
delta = target - total
def fmt(s):
    h, m = divmod(max(0, s)//60, 60)
    if h == 0: return f"{m}m"
    return f"{h}h{m}m" if m else f"{h}h"
print(f"{total}\t{target}\t{delta}\t{fmt(total)}\t{fmt(target)}\t{fmt(delta)}\t{last_ticket}")
PY
)
  IFS=$'\t' read -r _tt_total _tt_target _tt_delta _tt_total_h _tt_target_h _tt_delta_h _tt_last <<<"$_tempo_parsed"
  if [[ -n "${_tt_total:-}" ]]; then
    if (( _tt_delta > 0 )); then
      TEMPO_SECTION="
Tempo today: ${_tt_total_h} / ${_tt_target_h} (short by ${_tt_delta_h})"
      TEMPO_BACKFILL_DELTA="${_tt_delta}"
      TEMPO_BACKFILL_TICKET="${_tt_last}"
    else
      TEMPO_SECTION="
Tempo today: ${_tt_total_h} / ${_tt_target_h} (on target)"
    fi
  fi
fi

DIGEST="Daily Summary ($TODAY_DISPLAY)

Processed: $PROCESSED tickets
MRs opened: $MRS_OPENED
Skipped: $SKIPPED
Failed: $FAILED
$MR_SECTION${TEMPO_SECTION}

Queue (New/To Do): $QUEUE_COUNT tickets
$QUEUE_LIST"

tg_send "$DIGEST"

# If under-logged, send a follow-up inline card so the backfill is one tap
# away. The callback (`tm_log:<ticket>:<date>:<secs>`) is already wired to
# handler_tm_log via the existing tempo handler.
if [[ -n "$TEMPO_BACKFILL_TICKET" ]] && (( TEMPO_BACKFILL_DELTA > 0 )); then
  _delta_h=$(python3 -c "s=int($TEMPO_BACKFILL_DELTA); h,m=divmod(s//60,60); print(f'{h}h{m}m' if h and m else (f'{h}h' if h else f'{m}m'))")
  _kb="[[{\"text\":\"Log ${_delta_h} → ${TEMPO_BACKFILL_TICKET}\",\"callback_data\":\"tm_log:${TEMPO_BACKFILL_TICKET}:${TODAY}:${TEMPO_BACKFILL_DELTA}\"},{\"text\":\"Pick ticket\",\"callback_data\":\"tm_pick:${TODAY}:${TEMPO_BACKFILL_DELTA}\"}]]"
  tg_inline "Backfill ${_delta_h}? Last ticket was *${TEMPO_BACKFILL_TICKET}*." "$_kb" >/dev/null 2>&1 || true
fi

echo "Digest sent at $(date)"
