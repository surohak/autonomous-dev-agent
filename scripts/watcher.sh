#!/bin/bash
# Autonomous Dev Agent — Watcher
# Cheap periodic polling (no tokens) for:
#   1. CI pipeline status on user's open MRs          → [Auto-fix] [Open] [Snooze]
#   2. New reviewer comments on user's open MRs       → [Auto-fix] [Open] [Seen]
#   3. Newly assigned Jira tickets + status changes   → [Start now] [Later] [Skip]
#
# Runs every 2 minutes via launchd. Stateless re-runs — state is in
# cache/watcher-state.json. Respects watcher-snoozed.until for notification
# suppression (state is still updated so we don't re-fire everything on resume).

set -uo pipefail

# --- Shared bootstrap ------------------------------------------------------
SKILL_DIR="${SKILL_DIR:-$HOME/.cursor/skills/autonomous-dev-agent}"
source "$SKILL_DIR/scripts/lib/env.sh"
source "$SKILL_DIR/scripts/lib/cfg.sh"
source "$SKILL_DIR/scripts/lib/telegram.sh"
source "$SKILL_DIR/scripts/lib/jira.sh"
source "$SKILL_DIR/scripts/lib/workflow.sh"
source "$SKILL_DIR/scripts/lib/log-rotate.sh"
source "$SKILL_DIR/scripts/lib/timegate.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/active-run.sh"
# Tempo suggestion helpers — loaded so the Code-Review STATUS_CHANGE branch
# can fire an immediate "log dev time?" card right after the status-change
# notification. Both libs are defensive (early return if env missing), so
# sourcing them here has no side effects if Tempo isn't configured.
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/tempo.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/handlers/tempo.sh"
# ---------------------------------------------------------------------------

# STATE_FILE is rebound per project inside the tick loop below (cfg.sh exports
# $WATCHER_STATE_FILE under $PROJECT_CACHE_DIR after each cfg_project_activate).
LOG_FILE="$LOG_DIR/watcher.log"
mkdir -p "$(dirname "$LOG_FILE")"

# --- Single-instance lock (macOS has no flock the shell tool) --------------
# The lock is process-wide (not per-project) so one watcher tick owns the
# isolate even when iterating multiple projects sequentially.
LOCK_FILE="${WATCHER_LOCK_FILE:-$CACHE_DIR/watcher.pid}"
mkdir -p "$(dirname "$LOCK_FILE")"
if [ -f "$LOCK_FILE" ]; then
  OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null)
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    # Stale-lock guard: kill if older than 10 min (a normal tick is <30s).
    if [ -n "$(find "$LOCK_FILE" -mmin +10 2>/dev/null)" ]; then
      kill -9 "$OLD_PID" 2>/dev/null
      rm -f "$LOCK_FILE"
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Killed stale watcher PID $OLD_PID" >> "$LOG_FILE"
    else
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Previous watcher (PID $OLD_PID) still running, skipping" >> "$LOG_FILE"
      exit 0
    fi
  fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT INT TERM

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${ATLASSIAN_API_TOKEN:-}" ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] missing secrets (TELEGRAM_BOT_TOKEN / ATLASSIAN_API_TOKEN) — bailing" >> "$LOG_FILE"
  exit 1
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Watcher tick" >> "$LOG_FILE"

# Self-heal: prune any active-runs entries whose PID is no longer alive.
active_run_prune >/dev/null 2>&1 || true

# --- Notification gate: quiet hours + snooze ------------------------------
NOTIFY_OK=1
in_work_hours || NOTIFY_OK=0
snoozed_now   && NOTIFY_OK=0

# Thin wrapper over tg_inline that honours NOTIFY_OK. Callers should only
# persist "already notified" state when this returns 0.
#
# Prepends a "[<project-id>]" tag on multi-project installs so the user can
# tell which project the notification is about without reading the ticket/MR
# prefix. Single-project installs (one "default" project) get no tag so
# upgraders see zero churn. We cache the project count once per tick for speed.
_multi_project_cached=""
_is_multi_project() {
  if [[ -z "$_multi_project_cached" ]]; then
    local n; n=$(cfg_project_list | wc -l | tr -d ' ')
    if (( n > 1 )); then _multi_project_cached=1; else _multi_project_cached=0; fi
  fi
  [[ "$_multi_project_cached" == "1" ]]
}
tg_send_maybe() {
  local text="$1" kb="${2:-}"
  if [ "$NOTIFY_OK" = "0" ]; then
    echo "  [skip notify: quiet hours/snoozed]" >> "$LOG_FILE"
    return 0
  fi
  if _is_multi_project && [[ -n "${AGENT_PROJECT:-}" ]]; then
    text="[${AGENT_PROJECT}] ${text}"
  fi
  if [ -n "$kb" ]; then
    tg_inline "$text" "$kb"
  else
    tg_send "$text"
  fi
}

# ===========================================================================
# Outer per-project loop. Each iteration re-binds env vars via
# cfg_project_activate so all state-file references ($STATE_FILE,
# $ACTIVE_RUNS_FILE, $ESTIMATES_FILE, $REVIEWS_DIR, $PENDING_DM_DIR,
# $WORKFLOW_FILE, $TG_OFFSET_FILE, …) + $JIRA_PROJECT / $TELEGRAM_CHAT_ID /
# $AGENT_MODEL pivot onto the current project automatically.
#
# Single-project installs still work transparently — cfg_project_list emits
# exactly one id ("default"), so the loop runs once.
# ===========================================================================
for AGENT_PROJECT in $(cfg_project_list); do
  cfg_project_activate "$AGENT_PROJECT" >/dev/null 2>&1 || {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] cfg_project_activate($AGENT_PROJECT) failed — skipping" >> "$LOG_FILE"
    continue
  }

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] --- project: $AGENT_PROJECT ($JIRA_PROJECT @ $JIRA_SITE) ---" >> "$LOG_FILE"

  STATE_FILE="$WATCHER_STATE_FILE"
  mkdir -p "$(dirname "$STATE_FILE")"
  if [ ! -s "$STATE_FILE" ]; then
    echo '{"pipelines":{},"mr_notes":{},"jira_tickets":{}}' > "$STATE_FILE"
  fi

  # v0.3.1 — project-scoped error isolation. The body below is ~400 lines of
  # CI/MR/Jira polling. Any uncaught error (Jira 500, GitLab rate limit,
  # jq parse fail, python exit 1, …) would otherwise kill the watcher for
  # every subsequent project in the iteration. We open a subshell + trap
  # so a crash in project A reports via Telegram + logs but still falls
  # through to project B.
  _project_error_reported() {
    local rc=$1 proj="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] !! project '$proj' body exited $rc — continuing with remaining projects" >> "$LOG_FILE"
    # Best-effort Telegram warning — at most once per hour per project, so
    # an ongoing outage doesn't spam the chat. State file lives under the
    # global cache so it survives per-project env rebinds.
    local warn_stamp="${GLOBAL_CACHE_DIR:-$CACHE_DIR}/watcher-crash-${proj}.ts"
    local now; now=$(date +%s)
    local last=0
    [[ -f "$warn_stamp" ]] && last=$(cat "$warn_stamp" 2>/dev/null || echo 0)
    if (( now - last >= 3600 )) && [[ "$NOTIFY_OK" = "1" ]]; then
      tg_send "⚠️ Watcher crashed on project \`$proj\` (exit $rc). See \`logs/watcher.log\` — next ticks will retry." >/dev/null 2>&1 || true
      echo "$now" > "$warn_stamp"
    fi
  }

  # Subshell trick: open with `(`, close with `)` at the matching marker.
  # We execute the body in a subshell so `return`, `exit`, and fatal
  # signals only abort THIS iteration, not the whole watcher.
  (

# =============================================================================
# 1. CI pipeline watcher — user's open MRs in both repos
# =============================================================================

for REPO in "$SSR_REPO" "$BLOG_REPO"; do
  if [ ! -d "$REPO" ]; then
    echo "  [skip] repo not found: $REPO" >> "$LOG_FILE"
    continue
  fi
  REPO_NAME=$(basename "$REPO")

  MR_LIST=$(cd "$REPO" && glab mr list --assignee=@me --output=json 2>>"$LOG_FILE" || echo "[]")
  MY_MR_LIST=$(cd "$REPO" && glab mr list --author=@me --output=json 2>>"$LOG_FILE" || echo "[]")
  MY_COUNT=$(echo "$MY_MR_LIST" | python3 -c "import sys,json
try: print(len(json.load(sys.stdin)))
except: print(0)")
  ASG_COUNT=$(echo "$MR_LIST" | python3 -c "import sys,json
try: print(len(json.load(sys.stdin)))
except: print(0)")
  echo "  [$REPO_NAME] glab: author=$MY_COUNT assignee=$ASG_COUNT" >> "$LOG_FILE"
  # Merge both lists + dedupe (author: pipeline + feedback; assignee: feedback).
  MR_LIST=$(MR_LIST="$MR_LIST" MY_MR_LIST="$MY_MR_LIST" python3 -c "
import json, os
a = json.loads(os.environ['MR_LIST'] or '[]')
b = json.loads(os.environ['MY_MR_LIST'] or '[]')
seen = {}
for m in a + b:
    iid = m.get('iid')
    if iid and iid not in seen:
        seen[iid] = m
print(json.dumps(list(seen.values())))
")

  # --- 1a. Pipeline status per MR (only for MRs I authored) ---
  for MR_IID in $(cd "$REPO" && glab mr list --author=@me --output=json 2>/dev/null | python3 -c "
import sys, json
for m in json.load(sys.stdin): print(m.get('iid'))
" 2>/dev/null); do
    [ -z "$MR_IID" ] && continue

    MR_META=$(cd "$REPO" && glab api "projects/:fullpath/merge_requests/$MR_IID" 2>/dev/null || echo "{}")
    HEAD_SHA=$(echo "$MR_META" | python3 -c "import sys,json;print(json.load(sys.stdin).get('sha','')[:10])" 2>/dev/null)
    PIPELINE=$(echo "$MR_META" | python3 -c "
import sys, json
m = json.load(sys.stdin)
p = m.get('head_pipeline') or {}
print(f\"{p.get('id','')}|{p.get('status','')}|{p.get('web_url','')}\")
" 2>/dev/null)

    PIPE_ID=$(echo "$PIPELINE" | cut -d'|' -f1)
    PIPE_STATUS=$(echo "$PIPELINE" | cut -d'|' -f2)
    PIPE_URL=$(echo "$PIPELINE" | cut -d'|' -f3)

    [ -z "$PIPE_ID" ] && continue

    LAST=$(python3 -c "
import json
s = json.load(open('$STATE_FILE'))
k = '${REPO_NAME}-${MR_IID}'
p = s.get('pipelines', {}).get(k, {})
print(f\"{p.get('last_pipeline_id','')}|{p.get('last_status','')}\")
")
    LAST_PID=$(echo "$LAST" | cut -d'|' -f1)
    LAST_STATUS=$(echo "$LAST" | cut -d'|' -f2)

    # Only notify on transition → failed (avoid spam) for new pipeline_id or flip to failed.
    NOTIFY_FAILED=0
    if [ "$PIPE_STATUS" = "failed" ] && [ "${PIPE_ID}|${PIPE_STATUS}" != "${LAST_PID}|${LAST_STATUS}" ]; then
      FAIL_JOBS=$(cd "$REPO" && glab api "projects/:fullpath/pipelines/$PIPE_ID/jobs?scope=failed" 2>/dev/null | python3 -c "
import sys, json
try:
    jobs = json.load(sys.stdin)
    names = [j['name'] for j in jobs[:3]]
    print(', '.join(names))
except Exception: print('')
" 2>/dev/null)

      TICKET_KEY=$(echo "$MR_META" | python3 -c "
import sys, json, re
m = json.load(sys.stdin)
for src in (m.get('source_branch',''), m.get('title','')):
    mm = re.search(os.environ['TICKET_KEY_PATTERN'], src or '')
    if mm: print(mm.group(0)); break
" 2>/dev/null)

      MR_URL=$(echo "$MR_META" | python3 -c "import sys,json;print(json.load(sys.stdin).get('web_url',''))")
      TEXT="Pipeline FAILED on !$MR_IID ($TICKET_KEY)
Repo: $REPO_NAME
SHA: $HEAD_SHA
Failed jobs: ${FAIL_JOBS:-(unknown)}"

      KB=$(REPO_NAME="$REPO_NAME" MR_IID="$MR_IID" PIPE_URL="$PIPE_URL" MR_URL="$MR_URL" python3 -c "
import json, os
kb = [
    [{'text':'Auto-fix','callback_data':f\"ci_fix:{os.environ['REPO_NAME']}:{os.environ['MR_IID']}\"},
     {'text':'Open pipeline','url':os.environ['PIPE_URL']}],
    [{'text':'Open MR','url':os.environ['MR_URL']},
     {'text':'Snooze 1h','callback_data':'snooze:3600'}]
]
print(json.dumps(kb))
")
      if tg_send_maybe "$TEXT" "$KB"; then
        echo "  [ci fail] $REPO_NAME !$MR_IID pipeline $PIPE_ID (notified)" >> "$LOG_FILE"
        NOTIFY_FAILED=0
      else
        echo "  [ci fail] $REPO_NAME !$MR_IID pipeline $PIPE_ID (notify FAILED, state not advanced)" >> "$LOG_FILE"
        NOTIFY_FAILED=1
      fi
    fi

    # Save state only on success, so a failed notify is retried next tick.
    if [ "$NOTIFY_FAILED" = "0" ]; then
      python3 -c "
import json, tempfile, os
sf = '$STATE_FILE'
s = json.load(open(sf))
s.setdefault('pipelines', {})['${REPO_NAME}-${MR_IID}'] = {
    'last_pipeline_id': '$PIPE_ID',
    'last_status': '$PIPE_STATUS',
    'updated_at': __import__('datetime').datetime.utcnow().isoformat()+'Z'
}
fd, tp = tempfile.mkstemp(dir=os.path.dirname(sf), suffix='.tmp')
with os.fdopen(fd, 'w') as f: json.dump(s, f, indent=2)
os.replace(tp, sf)
"
    fi
  done

  # --- 1b. New comments on open MRs (mine + assigned for review) ---
  echo "$MR_LIST" | python3 -c "
import sys, json
for m in json.load(sys.stdin):
    print(m.get('iid'))
" | while read -r MR_IID; do
    [ -z "$MR_IID" ] && continue

    NOTES=$(cd "$REPO" && glab api "projects/:fullpath/merge_requests/$MR_IID/notes?sort=desc&per_page=20" 2>/dev/null || echo "[]")

    MR_META_CACHE=$(cd "$REPO" && glab api "projects/:fullpath/merge_requests/$MR_IID" 2>/dev/null || echo "{}")
    MR_AUTHOR=$(echo "$MR_META_CACHE" | python3 -c "import sys,json;print(json.load(sys.stdin).get('author',{}).get('username',''))" 2>/dev/null)
    MR_URL_C=$(echo "$MR_META_CACHE" | python3 -c "import sys,json;print(json.load(sys.stdin).get('web_url',''))" 2>/dev/null)
    TITLE=$(echo "$MR_META_CACHE" | python3 -c "import sys,json;print(json.load(sys.stdin).get('title','')[:80])" 2>/dev/null)

    # Only notify for MRs authored by me (i.e., new comments on my MRs)
    [ "$MR_AUTHOR" != "$GITLAB_USER" ] && continue

    LAST_NOTE_ID=$(python3 -c "
import json
s = json.load(open('$STATE_FILE'))
k = '${REPO_NAME}-${MR_IID}'
print(s.get('mr_notes', {}).get(k, {}).get('last_note_id', 0))
")

    NEW_NOTES=$(NOTES="$NOTES" LAST="$LAST_NOTE_ID" ME="$GITLAB_USER" python3 -c "
import os, json
notes = json.loads(os.environ['NOTES'] or '[]')
last = int(os.environ['LAST'] or 0)
me = os.environ['ME']
# System notes (assignment, label) aren't comments — skip them
new = [n for n in notes if n.get('id',0) > last and not n.get('system', False) and n.get('author',{}).get('username') != me]
new.reverse()  # oldest first
print(json.dumps([{
    'id': n['id'],
    'author': n['author']['username'],
    'body': (n.get('body','') or '')[:400],
    'type': n.get('type') or 'discussion',
    'created_at': n.get('created_at','')
} for n in new]))
")

    NEW_COUNT=$(echo "$NEW_NOTES" | python3 -c "import sys,json;print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)

    NOTE_NOTIFY_OK=1
    if [ "$NEW_COUNT" -gt 0 ]; then
      TICKET_KEY=$(echo "$MR_META_CACHE" | python3 -c "
import sys, json, re
m = json.load(sys.stdin)
for src in (m.get('source_branch',''), m.get('title','')):
    mm = re.search(os.environ['TICKET_KEY_PATTERN'], src or '')
    if mm: print(mm.group(0)); break
" 2>/dev/null)

      SUMMARY=$(echo "$NEW_NOTES" | python3 -c "
import sys, json
notes = json.load(sys.stdin)[:3]
lines = []
for n in notes:
    body = n['body'].replace('\n',' ')[:200]
    lines.append(f\"@{n['author']}: {body}\")
print('\n\n'.join(lines))
")

      TEXT="New review feedback on !$MR_IID ($TICKET_KEY)
$TITLE

$SUMMARY"

      KB=$(MR_IID="$MR_IID" REPO_NAME="$REPO_NAME" MR_URL="$MR_URL_C" python3 -c "
import json, os
kb = [
    [{'text':'Auto-fix all','callback_data':f\"fb_fix:{os.environ['REPO_NAME']}:{os.environ['MR_IID']}\"},
     {'text':'Open MR','url':os.environ['MR_URL']}],
    [{'text':'Mark seen','callback_data':f\"fb_seen:{os.environ['REPO_NAME']}:{os.environ['MR_IID']}\"},
     {'text':'Snooze 1h','callback_data':'snooze:3600'}]
]
print(json.dumps(kb))
")
      if tg_send_maybe "$TEXT" "$KB"; then
        echo "  [mr note] $REPO_NAME !$MR_IID +$NEW_COUNT notes (notified)" >> "$LOG_FILE"
      else
        echo "  [mr note] $REPO_NAME !$MR_IID +$NEW_COUNT notes (notify FAILED, state not advanced)" >> "$LOG_FILE"
        NOTE_NOTIFY_OK=0
      fi
    fi

    if [ "$NOTE_NOTIFY_OK" = "1" ]; then
      LATEST_NOTE_ID=$(echo "$NOTES" | python3 -c "
import sys, json
notes = json.load(sys.stdin) or []
print(max([n.get('id',0) for n in notes] or [0]))
")
      python3 -c "
import json, tempfile, os
sf = '$STATE_FILE'
s = json.load(open(sf))
s.setdefault('mr_notes', {})['${REPO_NAME}-${MR_IID}'] = {
    'last_note_id': int('$LATEST_NOTE_ID' or 0),
    'updated_at': __import__('datetime').datetime.utcnow().isoformat()+'Z'
}
fd, tp = tempfile.mkstemp(dir=os.path.dirname(sf), suffix='.tmp')
with os.fdopen(fd, 'w') as f: json.dump(s, f, indent=2)
os.replace(tp, sf)
"
    fi
  done
done

# =============================================================================
# 2. Jira assignment / status watcher
# =============================================================================
#
# Track ALL non-Done tickets assigned to me. Even tickets in "Needs Clarification"
# or "Blocked" should surface — the user decides whether to [Proceed], [Later], or [Snooze].
JIRA=$(jira_search \
  "assignee = '${JIRA_ACCOUNT_ID}' AND statusCategory != Done ORDER BY updated DESC" \
  50 "summary,status,priority,issuetype" 2>>"$LOG_FILE")

JIRA_COUNT=$(echo "$JIRA" | python3 -c "
import sys,json
try: d=json.load(sys.stdin); print(len(d.get('issues',[])))
except: print('parse-fail')
")
echo "  [jira] actionable tickets: $JIRA_COUNT" >> "$LOG_FILE"

if [ "$JIRA_COUNT" = "parse-fail" ]; then
  echo "  [jira] SKIP: Jira response is not valid JSON" >> "$LOG_FILE"
  continue
fi

# Diff against last snapshot
RESULT=$(JIRA="$JIRA" STATE="$STATE_FILE" python3 <<'PY'
import os, json, datetime

jira = json.loads(os.environ["JIRA"] or '{"issues":[]}')
try:
    state = json.load(open(os.environ["STATE"]))
except (json.JSONDecodeError, FileNotFoundError):
    state = {}
tickets_state = state.get("jira_tickets", {})
old_keys = set(tickets_state.get("assigned", {}).keys())
old_status = tickets_state.get("assigned", {})

new_state = {}
new_assignments = []
status_changes = []

for issue in jira.get("issues", []):
    key = issue["key"]
    summary = issue["fields"].get("summary", "")
    status = issue["fields"].get("status", {}).get("name", "")
    priority = (issue["fields"].get("priority") or {}).get("name", "?")
    itype = (issue["fields"].get("issuetype") or {}).get("name", "")
    new_state[key] = {"summary": summary, "status": status, "priority": priority, "type": itype}

    if key not in old_keys:
        new_assignments.append({"key": key, "summary": summary, "status": status, "priority": priority, "type": itype})
    elif old_status.get(key, {}).get("status") != status:
        status_changes.append({"key": key, "summary": summary, "old": old_status[key]["status"], "new": status})

state.setdefault("jira_tickets", {})["assigned"] = new_state
state["jira_tickets"]["updated_at"] = datetime.datetime.utcnow().isoformat()+"Z"
import tempfile as _tf
_sf = os.environ["STATE"]
_fd, _tp = _tf.mkstemp(dir=os.path.dirname(_sf), suffix='.tmp')
with os.fdopen(_fd, 'w') as _f: json.dump(state, _f, indent=2)
os.replace(_tp, _sf)

print(json.dumps({"new": new_assignments, "changes": status_changes}))
PY
)

# v0.5.0 — queue snapshot for SwiftBar + /status all + /queue quick reads.
# Cheap: reuses the JIRA JSON we already fetched; no extra network calls.
# Location is global so SwiftBar can load "all projects queue" in one read
# without traversing per-project cache directories.
QUEUE_SNAP_FILE="${GLOBAL_CACHE_DIR:-$CACHE_DIR}/queue-snapshot.json"
mkdir -p "$(dirname "$QUEUE_SNAP_FILE")"
JIRA="$JIRA" PROJECT="$AGENT_PROJECT" SNAP="$QUEUE_SNAP_FILE" python3 <<'PY' 2>>"$LOG_FILE" || true
import os, json, time
jira = json.loads(os.environ.get("JIRA") or '{"issues":[]}')
pid = os.environ["PROJECT"]
snap_path = os.environ["SNAP"]

# Load-or-init the cross-project map: { "<pid>": {...}, "_updated": ts }
try:
    data = json.load(open(snap_path))
    if not isinstance(data, dict): data = {}
except Exception:
    data = {}

todo = []
for issue in jira.get("issues", []):
    status = (issue["fields"].get("status") or {}).get("name","").lower()
    if status not in ("new","to do","open","backlog","todo"):
        continue
    todo.append({
        "key":     issue["key"],
        "summary": (issue["fields"].get("summary","") or "")[:200],
        "priority":(issue["fields"].get("priority") or {}).get("name","?"),
        "status":  (issue["fields"].get("status") or {}).get("name",""),
        "type":    (issue["fields"].get("issuetype") or {}).get("name",""),
    })

data[pid] = {"todo": todo, "updated_at": int(time.time())}
data["_updated"] = int(time.time())
import tempfile as _tf
_fd, _tp = _tf.mkstemp(dir=os.path.dirname(snap_path), suffix='.tmp')
with os.fdopen(_fd, 'w') as _f: json.dump(data, _f, indent=2)
os.replace(_tp, snap_path)
PY

echo "$RESULT" | python3 -c "
import sys, json, os
d = json.load(sys.stdin)
for n in d['new']:
    key = n['key']
    status = n['status']
    status_l = status.lower()
    is_todo = status_l in ('new','to do')
    is_ready_qa = 'ready for qa' in status_l or 'ready to qa' in status_l
    text = f\"New Jira assignment: {key} ({status}, {n['priority']})\n{n['summary'][:150]}\"

    if is_ready_qa:
        kb = [
            [{'text':'Merge & ship','callback_data':f'tk_ship:{key}'},
             {'text':'Open in Jira','url':f'{os.environ[\"JIRA_SITE\"]}/browse/{key}'}],
            [{'text':'Later','callback_data':f'tk_later:{key}'},
             {'text':'Snooze 1h','callback_data':'snooze:3600'}]
        ]
    else:
        proceed_label = 'Start now' if is_todo else 'Proceed anyway'
        kb = [
            [{'text': proceed_label, 'callback_data': f'tk_start:{key}'},
             {'text':'Later','callback_data':f'tk_later:{key}'}],
            [{'text':'Open in Jira','url':f'{os.environ[\"JIRA_SITE\"]}/browse/{key}'},
             {'text':'Snooze 1h','callback_data':'snooze:3600'}]
        ]
        if is_todo:
            kb.insert(1, [{'text':'Skip to backlog','callback_data':f'skip:{key}'}])
    print('NEW_ASSIGN\t' + text.replace('\t',' ').replace('\n','\\\\n') + '\t' + json.dumps(kb))

import glob as _glob, json as _json, re as _re
reviews_dir = os.environ.get('REVIEWS_DIR') or os.path.expanduser('~/.cursor/skills/autonomous-dev-agent/cache/reviews')
# Only files named <MR_IID>-<8 hex>.json count as a prior review round.
# Positively excludes -discussions.json, -stub.json, .posted.json, etc.
_REVIEW_FILE_RX = _re.compile(r'^\\d+-[0-9a-f]{8}\\.json$')
def _prior_review_count(tk):
    n = 0
    for p in _glob.glob(os.path.join(reviews_dir, '*.json')):
        name = os.path.basename(p)
        if not _REVIEW_FILE_RX.match(name):
            continue
        try:
            if _json.load(open(p)).get('ticket_key') == tk:
                n += 1
        except Exception:
            continue
    return n
for c in d['changes']:
    key = c['key']
    new_l = c['new'].lower()
    is_code_review = 'code review' in new_l
    prior_rounds = _prior_review_count(key) if is_code_review else 0
    is_rereview = is_code_review and prior_rounds > 0

    if is_rereview:
        next_round = prior_rounds + 1
        text = (f\"Re-review needed: {key} (round {next_round}) — {c['old']} → {c['new']}\\n\"
                f\"{c['summary'][:120]}\\n(dev addressed prior comments; delta review only)\")
    else:
        text = f\"Status change: {key} — {c['old']} → {c['new']}\\n{c['summary'][:120]}\"

    if 'ready for qa' in new_l or 'ready to qa' in new_l:
        kb = [
            [{'text':'Merge & ship','callback_data':f'tk_ship:{key}'},
             {'text':'Open in Jira','url':f'{os.environ[\"JIRA_SITE\"]}/browse/{key}'}]
        ]
    elif new_l == 'done':
        kb = [
            [{'text':'Cherry-pick to main','callback_data':f'tk_cherry:{key}'},
             {'text':'Open in Jira','url':f'{os.environ[\"JIRA_SITE\"]}/browse/{key}'}]
        ]
    elif is_rereview:
        kb = [
            [{'text':f'Re-review (round {next_round})','callback_data':f'tk_start:{key}'},
             {'text':'Open in Jira','url':f'{os.environ[\"JIRA_SITE\"]}/browse/{key}'}],
            [{'text':'Later','callback_data':f'tk_later:{key}'},
             {'text':'Snooze 1h','callback_data':'snooze:3600'}]
        ]
    elif is_code_review:
        kb = [
            [{'text':'Review now','callback_data':f'tk_start:{key}'},
             {'text':'Open in Jira','url':f'{os.environ[\"JIRA_SITE\"]}/browse/{key}'}],
            [{'text':'Later','callback_data':f'tk_later:{key}'}]
        ]
    else:
        kb = [
            [{'text':'Proceed','callback_data':f'tk_start:{key}'},
             {'text':'Open in Jira','url':f'{os.environ[\"JIRA_SITE\"]}/browse/{key}'}]
        ]
    # EXTRA carries the ticket key and the new status (lower-cased) so the
    # bash side can route follow-up actions — specifically: fire an immediate
    # Tempo suggestion when the transition landed in Code Review (dev work
    # just finished on this ticket). Format: '<key>|<new_lower>'.
    extra = f\"{key}|{new_l}\"
    print('STATUS_CHANGE\t' + text.replace('\t',' ').replace('\n','\\\\n') + '\t' + json.dumps(kb) + '\t' + extra)
" 2>>"$LOG_FILE" | while IFS=$'\t' read -r KIND TEXT KB EXTRA; do
  [ -z "$TEXT" ] && continue
  TEXT_DEC=$(printf '%b' "$TEXT")
  tg_send_maybe "$TEXT_DEC" "$KB"
  echo "  [$KIND]" >> "$LOG_FILE"

  # Immediate Tempo suggestion on dev-done (Code Review) transition. Only
  # fires when (a) Telegram notify is allowed (so we don't ambush during
  # quiet hours), (b) tempo_suggest_now is loaded, (c) the new status
  # string contains 'code review'. All three checks are cheap and defensive.
  if [ "$KIND" = "STATUS_CHANGE" ] && [ "$NOTIFY_OK" = "1" ] \
     && type tempo_suggest_now >/dev/null 2>&1 && [ -n "$EXTRA" ]; then
    SC_KEY="${EXTRA%%|*}"
    SC_NEW="${EXTRA#*|}"
    case "$SC_NEW" in
      *"code review"*)
        tempo_suggest_now "$SC_KEY" "Dev done on $SC_KEY — moved to Code Review. Log dev time?" \
          >> "$LOG_FILE" 2>&1 || true
        ;;
    esac
  fi
done   # STATUS_CHANGE / NEEDS_CLARIFICATION loop

  )  # end per-project subshell
  _project_rc=$?
  if (( _project_rc != 0 )); then
    _project_error_reported "$_project_rc" "$AGENT_PROJECT"
  fi
done   # outer per-project loop

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Watcher done" >> "$LOG_FILE"

# v0.3.1 — rotate any log that has grown past LOG_ROTATE_THRESHOLD_BYTES
# (default 50 MB). Cheap: a stat per log, no-op if under threshold. Runs
# after every tick so archives stay bounded even on busy days.
rotate_all "$LOG_DIR" 2>/dev/null || true
