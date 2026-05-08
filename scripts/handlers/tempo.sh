#!/bin/bash
# scripts/handlers/tempo.sh
#
# Telegram handlers for Tempo worklog suggestions.
#
# UX shape:
#   /tempo          → cmd_tempo, emits one card per pending suggestion
#   /tempo week     → same but 7 days back
#   /tempo today    → today's partial (only useful late in the day)
#
# Per-card buttons:
#   [Log <Xh Ym>]   → tm_log:<ticket>:<date>:<seconds>
#   [Edit]          → tm_edit:<ticket>:<date>:<seconds>   (force-reply)
#   [Skip]          → tm_skip:<ticket>:<date>
# After logging:
#   [Undo]          → tm_undo:<worklogId>
#
# Invariants: NEVER post a worklog without an explicit button tap. NEVER
# auto-delete. Existing-log dedup happens in tempo-suggest.py before a card
# is shown, so re-runs of /tempo are idempotent.
#
# Requires: lib/env.sh, lib/telegram.sh, lib/tempo.sh, lib/timelog.sh,
#           scripts/tempo-suggest.py

[[ -n "${_DEV_AGENT_HANDLERS_TEMPO_LOADED:-}" ]] && return 0
_DEV_AGENT_HANDLERS_TEMPO_LOADED=1

# State files the tempo handlers own.
: "${TEMPO_SKIPPED_FILE:=$CACHE_DIR/tempo-skipped.json}"
: "${TEMPO_LOGGED_FILE:=$CACHE_DIR/tempo-logged.jsonl}"

# ---------- duration parsing ----------------------------------------------

# Parse a human-friendly duration string into seconds, rounded to 15 min.
# Accepts: "45m", "2h", "1h30m", "1h 30m", "1.5h", "90", "90m".
# Echoes the rounded seconds, or nothing on parse failure (caller must check).
_tempo_parse_duration() {
  local text="$1"
  python3 - <<PY "$text"
import re, sys
t = sys.argv[1].strip().lower()
# Plain integer → interpret as minutes.
if re.fullmatch(r"\d+", t):
    secs = int(t) * 60
else:
    m = re.fullmatch(r"(?:(\d+(?:\.\d+)?)\s*h)?\s*(?:(\d+)\s*m)?", t)
    if not m or not (m.group(1) or m.group(2)):
        sys.exit(1)
    h = float(m.group(1) or 0)
    mm = int(m.group(2) or 0)
    secs = int(h * 3600 + mm * 60)
if secs <= 0:
    sys.exit(1)
# Round to nearest 15 min but keep at least 15 min on any positive input.
q = 15 * 60
rounded = round(secs / q) * q
if rounded < q:
    rounded = q
print(rounded)
PY
}

_tempo_fmt_hm() {
  local secs="$1"
  python3 -c "
s = int($secs)
h, m = divmod(s // 60, 60)
print(f'{h}h{m:02d}m' if h and m else (f'{h}h' if h else f'{m}m'))
"
}

# ---------- skipped state --------------------------------------------------

# Mark a (ticket, date) as user-skipped so the next /tempo / daily digest
# doesn't resurface it. Stored as JSON object { "PROJ-123:2026-04-15": "..." }.
_tempo_skip_add() {
  local ticket="$1" date="$2"
  KEY="${ticket}:${date}" STATE="$TEMPO_SKIPPED_FILE" python3 <<'PY'
from jsonstate import locked_json
import datetime, os
with locked_json(os.environ["STATE"], {}) as ref:
    ref[0][os.environ["KEY"]] = datetime.datetime.utcnow().isoformat(timespec="seconds") + "Z"
PY
}

_tempo_is_skipped() {
  local ticket="$1" date="$2"
  KEY="${ticket}:${date}" STATE="$TEMPO_SKIPPED_FILE" python3 <<'PY' 2>/dev/null
from jsonstate import read_json
import os, sys
d = read_json(os.environ["STATE"], {})
sys.exit(0 if os.environ["KEY"] in d else 1)
PY
}

# ---------- logged state (for undo) ---------------------------------------

_tempo_logged_append() {
  local worklog_id="$1" ticket="$2" date="$3" seconds="$4" message_id="${5:-}"
  FILE="$TEMPO_LOGGED_FILE" WID="$worklog_id" TICKET="$ticket" \
  DATE="$date" SECS="$seconds" MID="$message_id" python3 <<'PY'
import json, os, datetime, fcntl, pathlib
line = json.dumps({
    "ts":          datetime.datetime.utcnow().isoformat(timespec="seconds") + "Z",
    "worklog_id":  os.environ["WID"],
    "ticket":      os.environ["TICKET"],
    "date":        os.environ["DATE"],
    "seconds":     int(os.environ["SECS"]),
    "message_id":  os.environ.get("MID", ""),
}) + "\n"
p = pathlib.Path(os.environ["FILE"])
p.parent.mkdir(parents=True, exist_ok=True)
with open(p, "a", encoding="utf-8") as fh:
    fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
    try: fh.write(line)
    finally: fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
PY
}

# ---------- card rendering -------------------------------------------------

# Print the JSON keyboard for a fresh suggestion card.
_tempo_card_kb() {
  local ticket="$1" date="$2" seconds="$3"
  local fmt; fmt=$(_tempo_fmt_hm "$seconds")
  python3 -c '
import json, sys
ticket, date, seconds, fmt = sys.argv[1:5]
kb = [
    [
        {"text": f"Log {fmt}",  "callback_data": f"tm_log:{ticket}:{date}:{seconds}"},
        {"text": "Edit",         "callback_data": f"tm_edit:{ticket}:{date}:{seconds}"},
        {"text": "Skip",         "callback_data": f"tm_skip:{ticket}:{date}"},
    ],
]
print(json.dumps(kb))
' "$ticket" "$date" "$seconds" "$fmt"
}

# Build the body text for a suggestion card.
_tempo_card_text() {
  local s="$1"   # the full JSON object from tempo-suggest.py
  python3 - <<'PY' "$s"
import json, sys
s = json.loads(sys.argv[1])
def fmt(x):
    x = int(x); h,m = divmod(x//60, 60)
    return f"{h}h{m:02d}m" if h and m else (f"{h}h" if h else f"{m}m")
dedup = "" if s["tempo_dedup"] else " (Tempo unreachable, dedup skipped)"
parts = [f"{s['date']}  {s['ticket']}"]
parts.append(f"  Suggest: {fmt(s['suggested_seconds'])}{dedup}")
parts.append(f"  Breakdown: dev {fmt(s['dev_seconds'])}, review {fmt(s['review_seconds'])}")
if s.get("already_logged_seconds", 0) > 0:
    parts.append(f"  Already logged today: {fmt(s['already_logged_seconds'])}")
runs = s.get("dev_runs", []) or []
revs = s.get("review_rounds", []) or []
if runs:
    parts.append(f"  Dev runs: " + ", ".join(f"{r['mode']}+{fmt(r['seconds'])}" for r in runs))
if revs:
    parts.append(f"  Review rounds: " + ", ".join(f"!{r['mr_iid']}+{fmt(r['seconds'])}" for r in revs))
print("\n".join(parts))
PY
}

# ---------- shared card emission ------------------------------------------

# Render one Telegram card per non-skipped suggestion in the given JSON array.
# Used by both the interactive /tempo command and the "fire immediately after
# a natural trigger moment" path (tempo_suggest_now). Kept here so there's one
# place that knows how to turn a tempo-suggest.py record into a card.
#
# Args:
#   $1 = raw JSON (array of suggestion objects, as emitted by --json)
#   $2 = optional header text sent via tg_send before the cards
#
# Returns 0 if at least one card was sent, 1 if nothing qualified. Never
# echoes to stdout — all output goes through tg_send / tg_inline.
_tempo_emit_cards() {
  local raw="$1" header="${2:-}"
  [[ -z "$raw" || "$raw" == "[]" ]] && return 1
  # Quick pre-filter: is there at least one non-skipped suggestion?
  local count
  count=$(printf '%s' "$raw" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin) or []
except Exception:
    data = []
print(sum(1 for s in data if not s.get("skip")))
' 2>/dev/null)
  [[ -z "$count" || "$count" == "0" ]] && return 1

  [[ -n "$header" ]] && tg_send "$header"

  TEMPO_RAW="$raw" python3 <<'PY' | while IFS=$'\t' read -r ticket date seconds text_enc; do
import json, os
data = json.loads(os.environ.get("TEMPO_RAW", "[]"))
for s in data:
    if s.get("skip"):
        continue
    def fmt(x):
        x = int(x); h,m = divmod(x//60, 60)
        return f"{h}h{m:02d}m" if h and m else (f"{h}h" if h else f"{m}m")
    dedup = "" if s["tempo_dedup"] else "  (Tempo dedup skipped)"
    lines = [
        f"{s['date']}  {s['ticket']}",
        f"  Suggest: {fmt(s['suggested_seconds'])}{dedup}",
        f"  Breakdown: dev {fmt(s['dev_seconds'])}, review {fmt(s['review_seconds'])}",
    ]
    if s.get("already_logged_seconds", 0) > 0:
        lines.append(f"  Already logged: {fmt(s['already_logged_seconds'])}")
    runs = s.get("dev_runs", []) or []
    revs = s.get("review_rounds", []) or []
    if runs:
        lines.append("  Dev: " + ", ".join(f"{r['mode']}+{fmt(r['seconds'])}" for r in runs))
    if revs:
        lines.append("  Review: " + ", ".join(f"!{r['mr_iid']}+{fmt(r['seconds'])}" for r in revs))
    text = "\n".join(lines).replace("\t", " ")
    text_enc = text.replace("\n", "\\n")
    print(f"{s['ticket']}\t{s['date']}\t{s['suggested_seconds']}\t{text_enc}")
PY
    [[ -z "$ticket" ]] && continue
    text=$(printf '%b' "$text_enc")
    kb=$(_tempo_card_kb "$ticket" "$date" "$seconds")
    tg_inline "$text" "$kb"
  done
  return 0
}

# ---------- summary (read-only view of already-logged worklogs) -----------

# cmd_tempo_summary [window]
#   window = "" (yesterday, default) | "today" | "week"
#
# Pulls existing Tempo worklogs and formats them as a concise summary with
# ticket keys, durations, descriptions, and a total.
cmd_tempo_summary() {
  local window="${1:-}"
  local from_date to_date label
  local tz="${WORK_TZ:-Europe/Berlin}"
  case "$window" in
    ""|yesterday)
      label="yesterday"
      from_date=$(TZ="$tz" python3 -c 'from datetime import date, timedelta; print(date.today() - timedelta(days=1))')
      to_date="$from_date"
      ;;
    today)
      label="today"
      from_date=$(TZ="$tz" date +%F)
      to_date="$from_date"
      ;;
    week)
      label="last 7 days"
      to_date=$(TZ="$tz" date +%F)
      from_date=$(TZ="$tz" python3 -c 'from datetime import date, timedelta; print(date.today() - timedelta(days=6))')
      ;;
    *)
      tg_send "Unknown /tempo summary window: $window. Use: today, yesterday, week."
      return 0
      ;;
  esac

  local account_id="${JIRA_ACCOUNT_ID:-}"
  if [[ -z "$account_id" ]]; then
    tg_send "Cannot fetch summary — JIRA_ACCOUNT_ID not set."
    return 1
  fi

  local ping; ping=$(tempo_ping 2>&1)
  if [[ "$ping" != OK:* ]]; then
    tg_send "Tempo not reachable: $ping"
    return 1
  fi

  tg_send "Fetching Tempo worklogs ($label)…"

  local raw
  raw=$(tempo_list_worklogs "$account_id" "$from_date" "$to_date" 2>/dev/null)
  if [[ -z "$raw" ]]; then
    tg_send "No response from Tempo API."
    return 1
  fi

  local summary
  summary=$(JIRA_SITE="${JIRA_SITE:-}" \
            ATLASSIAN_EMAIL="${ATLASSIAN_EMAIL:-}" \
            ATLASSIAN_API_TOKEN="${ATLASSIAN_API_TOKEN:-}" \
            python3 - <<'PY' "$raw" "$label"
import json, sys, os, urllib.request, base64, ssl

raw_json = sys.argv[1]
label = sys.argv[2]

try:
    data = json.loads(raw_json)
except (json.JSONDecodeError, TypeError):
    print("Failed to parse Tempo response.")
    sys.exit(0)

results = data.get("results", [])
if not results:
    print(f"No worklogs found for {label}.")
    sys.exit(0)

issue_ids = {str(w["issue"]["id"]) for w in results if w.get("issue", {}).get("id")}
id_to_info = {}

jira_site = os.environ.get("JIRA_SITE", "")
email = os.environ.get("ATLASSIAN_EMAIL", "")
token = os.environ.get("ATLASSIAN_API_TOKEN", "")

if jira_site and email and token:
    ctx = ssl.create_default_context()
    auth = base64.b64encode(f"{email}:{token}".encode()).decode()
    for iid in issue_ids:
        try:
            url = f"{jira_site}/rest/api/3/issue/{iid}?fields=summary,status"
            req = urllib.request.Request(url, headers={
                "Authorization": f"Basic {auth}",
                "Accept": "application/json",
            })
            with urllib.request.urlopen(req, timeout=10, context=ctx) as resp:
                d = json.loads(resp.read())
                key = d.get("key", "")
                summary_text = (d.get("fields", {}).get("summary") or "")
                status = (d.get("fields", {}).get("status", {}).get("name") or "")
                id_to_info[iid] = {"key": key, "summary": summary_text, "status": status}
        except Exception:
            pass

def fmt_dur(secs):
    h, m = divmod(secs // 60, 60)
    return f"{h}h {m:02d}m" if h and m else (f"{h}h" if h else f"{m}m")

entries = []
total_secs = 0
for w in sorted(results, key=lambda x: x.get("startDate", "") + x.get("startTime", "")):
    secs = w.get("timeSpentSeconds", 0)
    total_secs += secs
    iid = str(w.get("issue", {}).get("id", ""))
    info = id_to_info.get(iid, {})
    key = info.get("key") or w.get("issue", {}).get("key", f"#{iid}")
    jira_summary = info.get("summary", "")
    status = (info.get("status") or "").lower()
    desc = (w.get("description", "") or "").strip()

    # Prefer worklog description; fall back to Jira summary when
    # Tempo only has the generic "Working on issue XXX" placeholder.
    if desc and not desc.lower().startswith("working on issue"):
        text = desc
    elif jira_summary:
        text = jira_summary
    else:
        text = desc or ""

    dur = fmt_dur(secs)
    meta = f"{dur}, {status}" if status else dur
    line = f"{key} -- {text} ({meta})" if text else f"{key} ({meta})"
    entries.append(line)

by_date = {}
for w in results:
    d = w.get("startDate", "?")
    by_date.setdefault(d, 0)
    by_date[d] += w.get("timeSpentSeconds", 0)

if len(by_date) == 1:
    from datetime import datetime
    d = list(by_date.keys())[0]
    try:
        dt = datetime.strptime(d, "%Y-%m-%d")
        header = f"{dt.strftime('%B %d, %Y')} -- {fmt_dur(total_secs)}"
    except ValueError:
        header = f"{d} -- {fmt_dur(total_secs)}"
else:
    date_parts = []
    for d in sorted(by_date):
        date_parts.append(f"{d}: {fmt_dur(by_date[d])}")
    header = f"{label} -- {fmt_dur(total_secs)}\n" + " | ".join(date_parts)

print(header + "\n\n" + "\n".join(entries))
PY
  )

  if [[ -n "$summary" ]]; then
    tg_send "$summary"
  else
    tg_send "No worklogs found for $label."
  fi
}

# ---------- commands -------------------------------------------------------

# cmd_tempo [window]
#   window = "" (yesterday, default) | "today" | "week" | "summary [window]"
cmd_tempo() {
  local window="${1:-}"
  local flags=()
  local label

  # Route /tempo summary [window] to the read-only summary command.
  if [[ "$window" == "summary" ]]; then
    local summary_window="${2:-}"
    cmd_tempo_summary "$summary_window"
    return $?
  fi

  case "$window" in
    ""|yesterday) label="yesterday"; flags=();;
    today)        label="today";     flags=(--date "$(TZ="${WORK_TZ:-Europe/Berlin}" date +%F)");;
    week)         label="last 7 days"; flags=(--week);;
    *)            tg_send "Unknown /tempo window: $window. Use: today, yesterday, week, summary."; return 0;;
  esac

  if ! type tempo_ping >/dev/null 2>&1; then
    tg_send "Tempo library not loaded. Is lib/tempo.sh sourced in the daemon?"
    return 1
  fi

  # Fast-fail on a bad token so we don't spam cards we can't act on.
  local ping; ping=$(tempo_ping 2>&1)
  if [[ "$ping" != OK:* ]]; then
    tg_send "Tempo not reachable: $ping"
    return 1
  fi

  local raw
  raw=$(TIME_LOG_FILE="${TIME_LOG_FILE:-$CACHE_DIR/time-log.jsonl}" \
        TEMPO_API_TOKEN="${TEMPO_API_TOKEN:-}" \
        JIRA_ACCOUNT_ID="${JIRA_ACCOUNT_ID:-}" \
        WORK_TZ="${WORK_TZ:-Europe/Berlin}" \
        CACHE_DIR="${CACHE_DIR:-}" \
        python3 "$SKILL_DIR/scripts/tempo-suggest.py" --json --respect-user-skips "${flags[@]}" 2>/dev/null)
  if [[ -z "$raw" || "$raw" == "[]" ]]; then
    tg_send "No Tempo suggestions for $label. Either nothing captured, already logged, or below 15-min floor."
    return 0
  fi

  local count; count=$(printf '%s' "$raw" | python3 -c 'import json,sys
try: print(sum(1 for s in (json.load(sys.stdin) or []) if not s.get("skip")))
except Exception: print(0)')
  if [[ "$count" == "0" ]]; then
    tg_send "No Tempo suggestions for $label."
    return 0
  fi

  local header="Tempo suggestions — $label ($count ticket"
  [[ "$count" -gt 1 ]] && header="${header}s"
  header="${header})"
  _tempo_emit_cards "$raw" "$header" || tg_send "No Tempo suggestions for $label."
}

# ---------- immediate single-ticket suggestion ----------------------------

# tempo_suggest_now <ticket> [header]
#
# Fire-and-forget: silently sends a single Tempo suggestion card for the
# given ticket on *today* (WORK_TZ). Intended to be called at natural
# "phase done" moments — right after the agent moves a ticket to Code Review
# or right after rv_approve moves it to Ready For QA — so the suggestion
# arrives while the work is fresh instead of the end-of-day digest.
#
# Guarantees — this function is allergic to user-visible failure:
#   * Never writes to stderr or stdout on the caller's path.
#   * Any missing config (TEMPO_API_TOKEN / JIRA_ACCOUNT_ID / SKILL_DIR) →
#     silent return 0.
#   * Below the 15-min floor or fully-logged ticket → silent return 0.
#   * TEMPO_AUTO_SUGGEST=0 kill switch → silent return 0.
#   * Uses --respect-user-skips so a prior /tempo Skip tap sticks.
#   * Uses --ticket filter so we only ever render a card for THIS ticket —
#     no accidental avalanche of other pending suggestions.
tempo_suggest_now() {
  local ticket="$1" header="${2:-}"
  [[ -z "$ticket" ]] && return 0
  [[ "${TEMPO_AUTO_SUGGEST:-1}" == "0" ]] && return 0
  [[ -z "${TEMPO_API_TOKEN:-}" || -z "${JIRA_ACCOUNT_ID:-}" ]] && return 0
  [[ -z "${SKILL_DIR:-}" || ! -f "$SKILL_DIR/scripts/tempo-suggest.py" ]] && return 0

  local today; today=$(TZ="${WORK_TZ:-Europe/Berlin}" date +%F 2>/dev/null)
  [[ -z "$today" ]] && return 0

  local raw
  raw=$(TIME_LOG_FILE="${TIME_LOG_FILE:-$CACHE_DIR/time-log.jsonl}" \
        TEMPO_API_TOKEN="${TEMPO_API_TOKEN:-}" \
        JIRA_ACCOUNT_ID="${JIRA_ACCOUNT_ID:-}" \
        WORK_TZ="${WORK_TZ:-Europe/Berlin}" \
        CACHE_DIR="${CACHE_DIR:-}" \
        python3 "$SKILL_DIR/scripts/tempo-suggest.py" --json \
          --ticket "$ticket" --date "$today" --respect-user-skips \
          2>/dev/null)

  _tempo_emit_cards "$raw" "$header" >/dev/null 2>&1 || true
  return 0
}

# ---------- callback handlers ---------------------------------------------

# Dispatcher sends us the raw CMD string: "tm_log PROJ-997 2026-04-15 5400"
# plus an optional Telegram message_id of the card being tapped (so we can
# edit it in place). Missing message_id is fine — we fall back to a new msg.
handler_tm_log() {
  local cmd="$1" message_id="${2:-}"
  local ticket date seconds
  ticket=$(awk '{print $2}' <<< "$cmd")
  date=$(awk '{print $3}' <<< "$cmd")
  seconds=$(awk '{print $4}' <<< "$cmd")
  if [[ -z "$ticket" || -z "$date" || -z "$seconds" ]]; then
    tg_send "tm_log: malformed payload '$cmd'"
    return 0
  fi

  local author_id="${JIRA_ACCOUNT_ID:-}"
  if [[ -z "$author_id" ]]; then
    tg_send "Cannot log — JIRA_ACCOUNT_ID not set."
    return 0
  fi

  # Tempo wants startTime HH:MM:SS. We don't really know when during the day
  # the work happened, so we use 09:00:00 local — matches a typical workday
  # start and won't clash with other worklogs you might add manually.
  local start_time="09:00:00"
  local description="Agent-assisted work (auto-suggested)"

  local body
  body=$(python3 -c '
import json, sys
print(json.dumps({
    "authorAccountId":  sys.argv[1],
    "issueKey":         sys.argv[2],
    "startDate":        sys.argv[3],
    "startTime":        sys.argv[4],
    "timeSpentSeconds": int(sys.argv[5]),
    "description":      sys.argv[6],
}))' "$author_id" "$ticket" "$date" "$start_time" "$seconds" "$description")

  local resp worklog_id
  resp=$(tempo_post_worklog "$body" 2>&1)
  if [[ -z "$resp" ]] || ! printf '%s' "$resp" | grep -qE '^[0-9]+$'; then
    tg_send "Log failed for $ticket $date: $(printf '%s' "$resp" | head -c 300)"
    return 0
  fi
  worklog_id="$resp"
  _tempo_logged_append "$worklog_id" "$ticket" "$date" "$seconds" "$message_id"

  local fmt; fmt=$(_tempo_fmt_hm "$seconds")
  # Edit the original card in place: mark as logged, swap to [Undo].
  local new_text="Logged ${fmt} on ${ticket} (${date})
Worklog #${worklog_id}"
  local kb; kb=$(python3 -c '
import json, sys
print(json.dumps([[{"text":"Undo","callback_data":f"tm_undo:{sys.argv[1]}"}]]))
' "$worklog_id")
  if [[ -n "$message_id" ]]; then
    tg_edit_text "$message_id" "$new_text" "$kb" >/dev/null 2>&1 || tg_inline "$new_text" "$kb"
  else
    tg_inline "$new_text" "$kb"
  fi
}

# "tm_skip PROJ-997 2026-04-15"
handler_tm_skip() {
  local cmd="$1" message_id="${2:-}"
  local ticket date
  ticket=$(awk '{print $2}' <<< "$cmd")
  date=$(awk '{print $3}' <<< "$cmd")
  if [[ -z "$ticket" || -z "$date" ]]; then
    tg_send "tm_skip: malformed '$cmd'"; return 0
  fi
  _tempo_skip_add "$ticket" "$date"
  local new_text="Skipped ${ticket} on ${date}. /tempo won't resurface it."
  if [[ -n "$message_id" ]]; then
    tg_edit_text "$message_id" "$new_text" "[]" >/dev/null 2>&1 || tg_send "$new_text"
  else
    tg_send "$new_text"
  fi
}

# "tm_edit PROJ-997 2026-04-15 5400" — opens a force-reply
handler_tm_edit() {
  local cmd="$1"
  local ticket date seconds
  ticket=$(awk '{print $2}' <<< "$cmd")
  date=$(awk '{print $3}' <<< "$cmd")
  seconds=$(awk '{print $4}' <<< "$cmd")
  local cur; cur=$(_tempo_fmt_hm "$seconds")
  tg_force_reply "How long for ${ticket} on ${date}? (currently ${cur})
Format: 45m, 1h, 1h30m, 2h, 1.5h. Reply with your duration."
}

# When the user replies to a force-reply started by handler_tm_edit, the
# daemon routes here with (replied_to_text, user_text).
handler_tm_edit_reply() {
  local replied_to="$1" user_text="$2"
  # Parse ticket + date from the prompt we sent.
  local ticket date
  ticket=$(printf '%s' "$replied_to" | grep -oE "${TICKET_KEY_PATTERN}" | head -1)
  date=$(printf '%s' "$replied_to" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
  if [[ -z "$ticket" || -z "$date" ]]; then
    tg_send "Couldn't parse ticket/date from edit prompt — log manually in Tempo."
    return 0
  fi
  local secs; secs=$(_tempo_parse_duration "$user_text")
  if [[ -z "$secs" ]]; then
    tg_send "Couldn't parse '$user_text'. Try: 45m, 1h, 1h30m, 2h."
    return 0
  fi
  handler_tm_log "tm_log ${ticket} ${date} ${secs}"
}

# "tm_undo <worklog_id>"
handler_tm_undo() {
  local cmd="$1" message_id="${2:-}"
  local worklog_id; worklog_id=$(awk '{print $2}' <<< "$cmd")
  if [[ -z "$worklog_id" ]]; then
    tg_send "tm_undo: missing worklog id"; return 0
  fi
  if tempo_delete_worklog "$worklog_id" 2>/dev/null; then
    local new_text="Undone — worklog #${worklog_id} deleted."
    if [[ -n "$message_id" ]]; then
      tg_edit_text "$message_id" "$new_text" "[]" >/dev/null 2>&1 || tg_send "$new_text"
    else
      tg_send "$new_text"
    fi
  else
    tg_send "Undo failed for worklog #${worklog_id}. Delete it manually in Tempo."
  fi
}
