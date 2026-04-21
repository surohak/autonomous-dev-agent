#!/bin/bash
# scripts/handlers/queue.sh — queue / list-style Telegram commands:
#   cmd_tickets  — Active runs + New/To Do queue
#   cmd_mrs      — your open MRs across SSR + Blog

[[ -n "${_DEV_AGENT_HANDLER_QUEUE_LOADED:-}" ]] && return 0
_DEV_AGENT_HANDLER_QUEUE_LOADED=1

cmd_tickets() {
  active_run_prune >/dev/null 2>&1 || true
  local runs_file
  runs_file="$(_active_runs_file)"

  # --- Section 1: Active runs (any ticket regardless of Jira status) ---
  local active_rows
  active_rows=$(ACTIVE_RUNS_FILE="$runs_file" python3 -c "
import json, os, time
try:
    d = json.load(open(os.environ['ACTIVE_RUNS_FILE']))
    if not isinstance(d, dict): d = {}
except Exception:
    d = {}
now = int(time.time())
def fmt(s):
    s = max(0, int(s))
    if s < 60: return f'{s}s'
    if s < 3600: return f'{s//60}m'
    return f'{s//3600}h'
rows = []
for pid, r in sorted(d.items(), key=lambda kv: kv[1].get('started_at', 0)):
    tk = (r.get('ticket') or '').upper()
    if not tk or tk == '--':
        continue
    rnd = int(r.get('round') or 1)
    rows.append((tk, r.get('mode','?'), r.get('phase','?'), rnd, fmt(now - int(r.get('started_at', now))), pid))
for tk, mode, phase, rnd, age, pid in rows:
    print(f'{tk}\t{mode}\t{phase}\t{rnd}\t{age}\t{pid}')
" 2>/dev/null)

  local active_count=0
  if [ -n "$active_rows" ]; then
    active_count=$(printf '%s\n' "$active_rows" | wc -l | tr -d ' ')
    tg_send "Active runs: $active_count — tap a ticket for details:"
    printf '%s\n' "$active_rows" | while IFS=$'\t' read -r TKEY TMODE TPHASE TROUND TAGE TPID; do
      [ -z "$TKEY" ] && continue
      local round_tag=""
      [ "$TROUND" -gt 1 ] 2>/dev/null && round_tag=" r$TROUND"
      local tkb="[[{\"text\":\"Status\",\"callback_data\":\"tk_status:$TKEY\"},{\"text\":\"View log\",\"callback_data\":\"rn_log:$TPID\"},{\"text\":\"Stop\",\"callback_data\":\"rn_stop:$TPID\"}]]"
      tg_inline "$TKEY$round_tag — $TMODE · $TPHASE · for $TAGE" "$tkb"
    done
  fi

  # --- Section 2: New/To Do queue ---
  local jql jira_resp ticket_count
  jql="assignee = '${JIRA_ACCOUNT_ID}' AND status IN ('New', 'To Do') ORDER BY priority ASC, created ASC"
  jira_resp=$(jira_search "$jql" 10 "summary,status,priority" 2>/dev/null)
  ticket_count=$(echo "$jira_resp" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(len(data.get('issues', [])))
except Exception:
    print(0)
" 2>/dev/null || echo "0")

  if [ "$ticket_count" = "0" ]; then
    if [ -z "$active_rows" ]; then
      tg_send "No tickets in New/To Do, and no active runs."
    else
      tg_send "Queue empty (New/To Do = 0). $active_count active run(s) above."
    fi
    return 0
  fi

  tg_send "$ticket_count ticket(s) in queue — tap an action:"
  ACTIVE_RUNS_FILE="$runs_file" \
  ESTIMATES_FILE="${ESTIMATES_FILE:-$CACHE_DIR/estimates.json}" \
  JIRA_RESPONSE="$jira_resp" \
  python3 -c "
import sys, json, os, time
data = json.loads(os.environ['JIRA_RESPONSE'])
try:
    runs = json.load(open(os.environ['ACTIVE_RUNS_FILE']))
    if not isinstance(runs, dict): runs = {}
except Exception:
    runs = {}
try:
    est = json.load(open(os.environ['ESTIMATES_FILE']))
    if not isinstance(est, dict): est = {}
except Exception:
    est = {}
by_tk = {}
now = int(time.time())
for pid, r in runs.items():
    tk = (r.get('ticket') or '').upper()
    if tk and tk != '--':
        by_tk.setdefault(tk, []).append((pid, r))
def age(r):
    s = max(0, now - int(r.get('started_at', now)))
    if s < 60: return f'{s}s'
    if s < 3600: return f'{s//60}m'
    return f'{s//3600}h'
for i in data.get('issues', []):
    key = i['key']
    summary = i['fields']['summary']
    status = i['fields']['status']['name']
    priority = i['fields'].get('priority', {}).get('name', '?')
    running = key.upper() in by_tk
    # Sentinels: bash IFS=tab collapses consecutive tabs (tab is whitespace-IFS),
    # so an empty field would shift subsequent ones left. Always emit a non-empty
    # placeholder and filter in bash.
    pid = by_tk[key.upper()][0][0] if running else '-'
    if running:
        r = by_tk[key.upper()][0][1]
        badge = f'  [RUNNING · {r.get(\"mode\",\"?\")} · {age(r)}]'
    else:
        badge = '-'
    size_blocked = '1' if (est.get(key, {}) or {}).get('classified') == 'large' else '0'
    print(f'{key}\t{status}\t{priority}\t{summary}\t{badge}\t{pid}\t{size_blocked}')
" 2>/dev/null | while IFS=$'\t' read -r TKEY TSTATUS TPRIORITY TSUMMARY TBADGE TPID TSIZE; do
    [ -z "$TKEY" ] && continue
    [ "$TBADGE" = "-" ] && TBADGE=""
    [ "$TPID" = "-" ] && TPID=""
    local tkb
    if [ -n "$TBADGE" ]; then
      tkb="[[{\"text\":\"Status\",\"callback_data\":\"tk_status:$TKEY\"},{\"text\":\"View log\",\"callback_data\":\"rn_log:$TPID\"},{\"text\":\"Stop\",\"callback_data\":\"rn_stop:$TPID\"}]]"
    elif [ "$TSIZE" = "1" ]; then
      tkb="[[{\"text\":\"Run\",\"callback_data\":\"run:$TKEY\"},{\"text\":\"Force run (size)\",\"callback_data\":\"approve:$TKEY\"},{\"text\":\"Skip\",\"callback_data\":\"skip:$TKEY\"}]]"
    else
      tkb="[[{\"text\":\"Run\",\"callback_data\":\"run:$TKEY\"},{\"text\":\"Skip\",\"callback_data\":\"skip:$TKEY\"}]]"
    fi
    tg_inline "$TKEY [$TSTATUS] ($TPRIORITY)$TBADGE
$TSUMMARY" "$tkb"
  done
}

cmd_mrs() {
  if ! command -v glab >/dev/null 2>&1; then
    tg_send "Error: glab CLI not found in PATH. Install with: brew install glab"
    return 0
  fi

  _list_mrs_for() {
    local repo_path="$1" repo_label="$2"
    [ ! -d "$repo_path" ] && return
    ( cd "$repo_path" && glab mr list --author=@me --per-page=20 --output=json 2>/dev/null ) | \
      REPO="$repo_label" python3 -c "
import sys, json, os, re
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
repo = os.environ.get('REPO', '')
for mr in data:
    num = mr.get('iid') or mr.get('id') or '-'
    title = mr.get('title') or '(no title)'
    url = mr.get('web_url') or '-'
    branch = mr.get('source_branch', '') or ''
    ticket = '-'
    m = re.search(os.environ['TICKET_KEY_PATTERN'], branch + ' ' + title, re.IGNORECASE)
    if m:
        ticket = m.group(0).upper()
    print(f'{repo}\t{num}\t{title}\t{url}\t{ticket}')
"
  }

  local rows count
  rows=$(_list_mrs_for "$SSR_REPO" "SSR"; _list_mrs_for "$BLOG_REPO" "Blog")
  if [ -z "$rows" ]; then
    tg_send "No open MRs authored by you."
    return 0
  fi
  count=$(printf '%s\n' "$rows" | grep -c '	' || echo "0")
  tg_send "$count open MR(s) — tap an action:"
  printf '%s\n' "$rows" | while IFS=$'\t' read -r REPO NUM TITLE URL TICKET; do
    [ -z "$NUM" ] && continue
    local kb
    if [ "$TICKET" != "-" ]; then
      kb="[[{\"text\":\"Review $TICKET\",\"callback_data\":\"review:$TICKET\"},{\"text\":\"Open in GitLab\",\"url\":\"$URL\"}]]"
    else
      kb="[[{\"text\":\"Open in GitLab\",\"url\":\"$URL\"}]]"
    fi
    tg_inline "[$REPO] !$NUM — $TITLE" "$kb"
  done
}
