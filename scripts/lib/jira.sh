#!/bin/bash
# scripts/lib/jira.sh
#
# Thin, consistent wrapper over the Jira REST API (v3). All calls use basic
# auth with (ATLASSIAN_EMAIL, ATLASSIAN_API_TOKEN) from secrets.env.
#
# Public functions:
#   jira_api    <METHOD> <path> [<json_body>]          — low-level
#   jira_get    <path>                                 — GET
#   jira_post   <path> <json_body>                     — POST
#   jira_search <jql> [<max=20>] [<fields=summary,status>]
#   jira_current_status <issueKey>                     — echoes status name
#   jira_transition_to  <issueKey> <target_name>       — idempotent transition
#   jira_transition_exact <issueKey> <transition_name> — by transition name
#
# All paths are the suffix AFTER /rest/api/3, e.g. "/issue/PROJ-123".
# On network / auth failure, functions echo nothing and return non-zero where
# meaningful (current_status / transition_to). Body-returning functions still
# echo raw stdout for callers that want to parse with their own python/jq.

[[ -n "${_DEV_AGENT_JIRA_LOADED:-}" ]] && return 0
_DEV_AGENT_JIRA_LOADED=1

_jira_site() {
  # $JIRA_SITE is exported by cfg.sh from config.json's tracker.siteUrl.
  # We deliberately do NOT hardcode a default — making every fork declare
  # its own site surfaces misconfiguration early instead of silently
  # pointing at someone else's Jira.
  if [[ -z "${JIRA_SITE:-}" ]]; then
    echo "jira.sh: JIRA_SITE is empty — check config.json tracker.siteUrl" >&2
    return 1
  fi
  echo "$JIRA_SITE"
}

jira_api() {
  local method="$1" path="$2" body="${3:-}"
  [[ -z "${ATLASSIAN_EMAIL:-}" || -z "${ATLASSIAN_API_TOKEN:-}" ]] && return 1
  local url; url="$(_jira_site)/rest/api/3${path}"
  if [[ -n "$body" ]]; then
    curl -s --max-time 20 -u "${ATLASSIAN_EMAIL}:${ATLASSIAN_API_TOKEN}" \
      -X "$method" "$url" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      -d "$body"
  else
    curl -s --max-time 20 -u "${ATLASSIAN_EMAIL}:${ATLASSIAN_API_TOKEN}" \
      -X "$method" "$url" \
      -H "Accept: application/json"
  fi
}

jira_get()  { jira_api GET  "$1"; }
jira_post() { jira_api POST "$1" "$2"; }
jira_put()  { jira_api PUT  "$1" "$2"; }

jira_search() {
  local jql="$1" max="${2:-20}" fields="${3:-summary,status,priority,assignee}"
  local body
  body=$(JQL="$jql" MAX="$max" FIELDS="$fields" python3 -c '
import json, os
print(json.dumps({
    "jql":        os.environ["JQL"],
    "maxResults": int(os.environ["MAX"]),
    "fields":     os.environ["FIELDS"].split(","),
}))')
  jira_post "/search/jql" "$body"
}

jira_current_status() {
  local key="$1"
  local raw; raw=$(jira_get "/issue/$key?fields=status")
  [[ -z "$raw" ]] && return 1
  printf '%s' "$raw" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print((d.get("fields",{}) or {}).get("status",{}).get("name",""))
except Exception:
    pass
'
}

# Move a ticket to a target status (substring match, case-insensitive), by
# discovering the appropriate transition id. Idempotent: no-op if already in
# the target status. Returns 0 on success or no-op, 1 on failure.
jira_transition_to() {
  local key="$1" target="$2"
  local cur; cur=$(jira_current_status "$key" 2>/dev/null)
  [[ -z "$cur" ]] && return 1
  local cur_low target_low
  cur_low=$(printf '%s' "$cur" | tr '[:upper:]' '[:lower:]')
  target_low=$(printf '%s' "$target" | tr '[:upper:]' '[:lower:]')
  if [[ "$cur_low" == *"$target_low"* ]]; then
    return 0  # already there
  fi
  local trs; trs=$(jira_get "/issue/$key/transitions")
  [[ -z "$trs" ]] && return 1
  local tid
  tid=$(printf '%s' "$trs" | TARGET="$target_low" python3 -c '
import json, os, sys
t = os.environ["TARGET"]
d = json.load(sys.stdin)
for x in d.get("transitions", []) or []:
    to   = ((x.get("to") or {}).get("name") or "").lower()
    name = (x.get("name") or "").lower()
    if t in to or t in name:
        print(x.get("id", ""))
        break
')
  [[ -z "$tid" ]] && return 1
  if jira_post "/issue/$key/transitions" "{\"transition\":{\"id\":\"$tid\"}}" >/dev/null; then
    # Capture for Tempo (Phase 1). `tl_emit` is defined in lib/timelog.sh when
    # loaded; `type` keeps jira.sh usable in contexts that don't load it.
    if type tl_emit >/dev/null 2>&1; then
      tl_emit jira_transition ticket="$key" from="$cur" to="$target" source="agent"
    fi
    return 0
  fi
  return 1
}

# Clear the assignee on a ticket (equivalent to "Unassigned" in the UI).
# Returns 0 on success, 1 on failure. Idempotent — already-unassigned tickets
# still get a 204 back from Jira.
jira_unassign() {
  local key="$1"
  jira_put "/issue/$key/assignee" '{"accountId":null}' >/dev/null
}

# Assign a ticket to a specific accountId. Pass "" or "-1" to route via the
# project's default-assignee rule. Returns 0/1.
jira_assign() {
  local key="$1" account_id="$2"
  local body
  if [[ -z "$account_id" || "$account_id" == "-1" ]]; then
    body='{"accountId":"-1"}'
  else
    body=$(printf '{"accountId":"%s"}' "$account_id")
  fi
  jira_put "/issue/$key/assignee" "$body" >/dev/null
}

# Move via an exact transition name (when substring match is unsafe).
jira_transition_exact() {
  local key="$1" name="$2"
  local trs; trs=$(jira_get "/issue/$key/transitions")
  [[ -z "$trs" ]] && return 1
  local tid
  tid=$(printf '%s' "$trs" | TARGET="$name" python3 -c '
import json, os, sys
t = os.environ["TARGET"].lower()
d = json.load(sys.stdin)
for x in d.get("transitions", []) or []:
    if (x.get("name") or "").lower() == t:
        print(x.get("id", "")); break
')
  [[ -z "$tid" ]] && return 1
  jira_post "/issue/$key/transitions" "{\"transition\":{\"id\":\"$tid\"}}" >/dev/null
}
