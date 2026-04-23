#!/bin/bash
# handlers/standup.sh — Generate daily standup summary from Tempo + Jira + GitLab
#
# Usage: handler_standup
#
# Pulls yesterday's Tempo worklogs, today's Jira tickets in progress,
# and open MRs to compose a standup-ready message.

handler_standup() {
  local tz="${WORK_TZ:-Europe/Berlin}"
  local yesterday today
  yesterday=$(TZ="$tz" python3 -c 'from datetime import date, timedelta; print(date.today() - timedelta(days=1))')
  today=$(TZ="$tz" date +%F)

  local account_id="${JIRA_ACCOUNT_ID:-}"
  if [[ -z "$account_id" ]]; then
    tg_send "Cannot generate standup — JIRA_ACCOUNT_ID not set."
    return 1
  fi

  tg_send "Generating standup summary…"

  local standup
  standup=$(
    JIRA_SITE="${JIRA_SITE:-}" \
    JIRA_ACCOUNT_ID="$account_id" \
    ATLASSIAN_EMAIL="${ATLASSIAN_EMAIL:-}" \
    ATLASSIAN_API_TOKEN="${ATLASSIAN_API_TOKEN:-}" \
    TEMPO_API_TOKEN="${TEMPO_API_TOKEN:-}" \
    YESTERDAY="$yesterday" \
    TODAY="$today" \
    WORK_TZ="$tz" \
    CONFIG_PATH="${CONFIG_FILE:-$SKILL_DIR/config.json}" \
    python3 <<'PYEOF'
import os, json, subprocess, urllib.request, base64, datetime

jira_site = os.environ.get("JIRA_SITE", "")
jira_aid = os.environ["JIRA_ACCOUNT_ID"]
email = os.environ.get("ATLASSIAN_EMAIL", "")
token = os.environ.get("ATLASSIAN_API_TOKEN", "")
tempo_token = os.environ.get("TEMPO_API_TOKEN", "")
yesterday = os.environ["YESTERDAY"]
today = os.environ["TODAY"]
config = json.load(open(os.environ["CONFIG_PATH"]))
_proj0 = (config.get("projects") or [{}])[0] if isinstance(config.get("projects"), list) else {}
repos = config.get("repositories") or _proj0.get("repositories") or {}

auth_b64 = base64.b64encode(f"{email}:{token}".encode()).decode()
jira_hdrs = {"Authorization": f"Basic {auth_b64}", "Content-Type": "application/json"}

def jira_search(jql, fields, max_results=20):
    body = json.dumps({"jql": jql, "maxResults": max_results, "fields": fields}).encode()
    req = urllib.request.Request(f"{jira_site}/rest/api/3/search/jql", data=body, headers=jira_hdrs)
    try:
        resp = urllib.request.urlopen(req, timeout=15)
        return json.loads(resp.read())
    except Exception:
        return {"issues": []}

# --- Yesterday: Tempo worklogs ---
yesterday_lines = []
total_seconds = 0
if tempo_token:
    body = json.dumps({"authorAccountIds": [jira_aid], "from": yesterday, "to": yesterday}).encode()
    req = urllib.request.Request("https://api.tempo.io/4/worklogs/search",
        data=body, headers={"Authorization": f"Bearer {tempo_token}", "Content-Type": "application/json"})
    try:
        resp = urllib.request.urlopen(req, timeout=15)
        wl = json.loads(resp.read())
        results = wl.get("results") or []
        for w in results:
            key = w.get("issue", {}).get("key", "?")
            secs = w.get("timeSpentSeconds", 0)
            total_seconds += secs
            desc = w.get("description") or ""
            h, m = divmod(secs // 60, 60)
            dur = f"{h}h{m:02d}m" if h and m else (f"{h}h" if h else f"{m}m")
            # Fetch Jira summary for the ticket
            summary = ""
            try:
                req2 = urllib.request.Request(f"{jira_site}/rest/api/3/issue/{key}?fields=summary", headers=jira_hdrs)
                r2 = urllib.request.urlopen(req2, timeout=10)
                summary = json.loads(r2.read()).get("fields", {}).get("summary", "")
            except Exception:
                pass
            line = f"  • {key} — {summary or desc or 'work'} ({dur})"
            yesterday_lines.append(line)
    except Exception:
        yesterday_lines.append("  (Tempo unavailable)")

th, tm = divmod(total_seconds // 60, 60)
total_fmt = f"{th}h{tm:02d}m" if th and tm else (f"{th}h" if th else f"{tm}m")

# --- Today: tickets in progress ---
today_lines = []
wip = jira_search(
    f"assignee = '{jira_aid}' AND status IN ('Work In Progress', 'Code Review') ORDER BY updated DESC",
    ["summary", "status"])
for iss in (wip.get("issues") or []):
    key = iss["key"]
    summary = iss.get("fields", {}).get("summary", "")
    status = iss.get("fields", {}).get("status", {}).get("name", "")
    today_lines.append(f"  • {key} — {summary} ({status.lower()})")

# --- Blockers: tickets with blocker signals ---
blocker_lines = []
blocked = jira_search(
    f"assignee = '{jira_aid}' AND status IN ('needs clarification', 'Blocked') ORDER BY updated DESC",
    ["summary", "status"])
for iss in (blocked.get("issues") or []):
    key = iss["key"]
    summary = iss.get("fields", {}).get("summary", "")
    status = iss.get("fields", {}).get("status", {}).get("name", "")
    blocker_lines.append(f"  • {key} — {summary} ({status.lower()})")

# --- Open MRs awaiting review ---
mr_lines = []
for slug, meta in repos.items():
    local = meta.get("localPath")
    if not local or not os.path.isdir(local):
        continue
    try:
        r = subprocess.run(["glab", "mr", "list", "--author=@me", "--state=opened", "--output=json"],
                           cwd=local, capture_output=True, text=True, timeout=15)
        mrs = json.loads(r.stdout or "[]")
        for m in mrs:
            title = (m.get("title") or "")[:60]
            iid = m.get("iid")
            mr_lines.append(f"  • !{iid} — {title}")
    except Exception:
        pass

# --- Compose ---
parts = []
parts.append(f"Standup — {today}")
parts.append("")
parts.append(f"Yesterday ({yesterday}, {total_fmt}):")
if yesterday_lines:
    parts.extend(yesterday_lines)
else:
    parts.append("  (no worklogs)")
parts.append("")
parts.append("Today:")
if today_lines:
    parts.extend(today_lines)
else:
    parts.append("  (no tickets in progress)")
if blocker_lines:
    parts.append("")
    parts.append("Blocked:")
    parts.extend(blocker_lines)
if mr_lines:
    parts.append("")
    parts.append(f"Open MRs ({len(mr_lines)}):")
    parts.extend(mr_lines)

print("\n".join(parts))
PYEOF
  )

  if [[ -n "$standup" ]]; then
    tg_send "$standup"
  else
    tg_send "Failed to generate standup summary."
  fi
}
