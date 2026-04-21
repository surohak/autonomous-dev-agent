#!/bin/bash
# scripts/drivers/tracker/jira-cloud.sh
#
# Reference tracker driver for Jira Cloud. Wraps scripts/lib/jira.sh +
# scripts/lib/workflow.sh behind the canonical tracker_* contract defined
# in _interface.md. Every public function is a thin adapter — the heavy
# lifting still lives in lib/ so all existing call sites keep working
# through v0.4.x.
#
# Env vars (populated by cfg_project_activate):
#   JIRA_SITE          e.g. https://x.atlassian.net
#   JIRA_PROJECT       e.g. AL
#   ATLASSIAN_EMAIL    e.g. you@example.com
#   ATLASSIAN_API_TOKEN
#
# These are preserved from the pre-driver era; cfg.sh will also export the
# canonical TRACKER_* aliases in v0.4 so new drivers can avoid the legacy
# names.

[[ -n "${_DEV_AGENT_TRACKER_JIRA_LOADED:-}" ]] && return 0
_DEV_AGENT_TRACKER_JIRA_LOADED=1

# Guarantee the libs are loaded. They're idempotent via _LOADED guards.
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/jira.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/workflow.sh"

# --- probe -----------------------------------------------------------------
tracker_probe() {
  [[ -z "${JIRA_SITE:-}" || -z "${ATLASSIAN_API_TOKEN:-}" ]] && return 3
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" \
    -u "${ATLASSIAN_EMAIL}:${ATLASSIAN_API_TOKEN}" \
    "${JIRA_SITE}/rest/api/3/myself" 2>/dev/null || echo "000")
  case "$code" in
    200) return 0 ;;
    401|403) return 3 ;;
    000|5??) return 1 ;;
    *) return 1 ;;
  esac
}

# --- search ----------------------------------------------------------------
# Normalises Jira's search response into the canonical shape. jira_search
# already returns the raw JSON; we post-process with python3.
tracker_search() {
  local jql="$1" max="${2:-50}" fields="${3:-summary,status,assignee,updated}"
  local raw
  raw=$(jira_search "$jql" "$max" "$fields") || return 1
  [[ -z "$raw" ]] && { echo "[]"; return 0; }

  printf '%s' "$raw" | SITE="$JIRA_SITE" python3 -c '
import json, os, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("[]"); sys.exit(0)
site = os.environ.get("SITE","").rstrip("/")
out = []
for i in (d.get("issues") or []):
    f = i.get("fields") or {}
    status = ((f.get("status") or {}).get("name") or "").strip().lower()
    a = (f.get("assignee") or {})
    assignee = a.get("emailAddress") or a.get("displayName") or ""
    out.append({
        "key":      i.get("key",""),
        "url":      (site + "/browse/" + i.get("key","")) if site else "",
        "summary":  f.get("summary",""),
        "status":   status,
        "assignee": assignee,
        "updated":  f.get("updated",""),
    })
print(json.dumps(out))
'
}

# --- get -------------------------------------------------------------------
tracker_get() {
  local key="$1"
  local raw
  raw=$(jira_get "/issue/$key") || return 1
  [[ -z "$raw" ]] && return 2
  printf '%s\n' "$raw"
}

# --- transition ------------------------------------------------------------
tracker_transition() {
  workflow_transition "$@"
}

# --- comment ---------------------------------------------------------------
tracker_comment() {
  local key="$1"; shift
  local body="$*"
  local payload
  payload=$(python3 -c 'import json,sys; print(json.dumps({"body":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":sys.argv[1]}]}]}}))' "$body")
  jira_post "/issue/$key/comment" "$payload" >/dev/null
}

# --- assign ----------------------------------------------------------------
tracker_assign() {
  local key="$1" who="$2"
  if [[ "$who" == "unset" || "$who" == "unassigned" ]]; then
    jira_unassign "$key"
    return $?
  fi
  # jira_assign expects an accountId. Callers that only know an email should
  # pass through jira_accountid_for_email (added when the first real consumer
  # needs it — today jira_assign is only called with accountIds).
  jira_assign "$key" "$who"
}
