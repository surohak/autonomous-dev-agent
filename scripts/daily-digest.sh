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

DIGEST="Daily Summary ($TODAY_DISPLAY)

Processed: $PROCESSED tickets
MRs opened: $MRS_OPENED
Skipped: $SKIPPED
Failed: $FAILED
$MR_SECTION

Queue (New/To Do): $QUEUE_COUNT tickets
$QUEUE_LIST"

tg_send "$DIGEST"

echo "Digest sent at $(date)"
