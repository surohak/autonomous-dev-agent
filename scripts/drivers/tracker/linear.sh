#!/bin/bash
# scripts/drivers/tracker/linear.sh
#
# Tracker driver for Linear. Hits the GraphQL endpoint at
# https://api.linear.app/graphql directly via curl — no SDK needed.
#
# Linear organises issues under Teams; each team has its own workflow
# states. We discover the team's workflow states once at probe time and
# cache the state-id map at $WORKFLOW_FILE (same file as the Jira driver
# — the cache is driver-scoped by TRACKER_KIND).
#
# Env vars:
#   TRACKER_KIND=linear
#   TRACKER_PROJECT   Linear team key (e.g. "ENG")
#   LINEAR_API_TOKEN  personal API key (linear.app → Settings → API)

[[ -n "${_DEV_AGENT_TRACKER_LINEAR_LOADED:-}" ]] && return 0
_DEV_AGENT_TRACKER_LINEAR_LOADED=1

_LINEAR_ENDPOINT="https://api.linear.app/graphql"

_linear_require() {
  [[ -z "${LINEAR_API_TOKEN:-}" ]] && { echo "linear: LINEAR_API_TOKEN missing" >&2; return 3; }
  [[ -z "${TRACKER_PROJECT:-}" ]]  && { echo "linear: TRACKER_PROJECT (team key) missing" >&2; return 2; }
}

_linear_query() {
  local query="$1"
  local vars="${2:-{\}}"
  local body
  body=$(printf '{"query":%s,"variables":%s}' \
           "$(printf '%s' "$query" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
           "$vars")
  curl -s -X POST "$_LINEAR_ENDPOINT" \
    -H "Authorization: ${LINEAR_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "$body" 2>/dev/null
}

tracker_probe() {
  _linear_require || return $?
  local out
  out=$(_linear_query '{ viewer { name email } }')
  printf '%s' "$out" | grep -q '"viewer"' && return 0 || return 1
}

# Map intents → Linear workflow state names (substring match, first hit).
_linear_intent_state_name() {
  case "$1" in
    start)          echo "In Progress|Started" ;;
    push_review)    echo "In Review|Code Review" ;;
    after_approve)  echo "Ready for QA|QA|Testing" ;;
    done)           echo "Done|Completed|Shipped" ;;
    block)          echo "Blocked|Waiting" ;;
    unblock)        echo "In Progress|Started" ;;
    *) return 1 ;;
  esac
}

_linear_state_id_for_intent() {
  local intent="$1"
  local patterns
  patterns=$(_linear_intent_state_name "$intent") || return 1

  # Fetch workflow states for the team, once.
  local team_key="$TRACKER_PROJECT"
  local out
  out=$(_linear_query '
query ($key: String!) {
  team(id: $key) {
    states { nodes { id name } }
  }
}' "{\"key\":\"$team_key\"}")

  printf '%s' "$out" | PATTERNS="$patterns" python3 -c '
import json, os, re, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
nodes = ((d.get("data") or {}).get("team") or {}).get("states", {}).get("nodes") or []
for pat in os.environ["PATTERNS"].split("|"):
    rx = re.compile(pat, re.IGNORECASE)
    for s in nodes:
        if rx.search(s.get("name","")):
            print(s.get("id",""))
            sys.exit(0)
sys.exit(1)
' 2>/dev/null
}

# --- search ----------------------------------------------------------------
# query is a simple filter string, we pass through to Linear's search API.
tracker_search() {
  local q="$1" max="${2:-50}"
  _linear_require || return $?
  # Linear has issueSearch(query) returning a paginated list.
  local out
  out=$(_linear_query '
query ($q: String!, $max: Int!) {
  issueSearch(query: $q, first: $max) {
    nodes {
      identifier title url updatedAt
      state   { name }
      assignee { email displayName }
    }
  }
}' "{\"q\":\"$q\",\"max\":$max}")

  printf '%s' "$out" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("[]"); sys.exit(0)
nodes = ((d.get("data") or {}).get("issueSearch") or {}).get("nodes") or []
out = []
for n in nodes:
    a = n.get("assignee") or {}
    out.append({
        "key":      n.get("identifier",""),
        "url":      n.get("url","") or "",
        "summary":  n.get("title","") or "",
        "status":   ((n.get("state") or {}).get("name") or "").lower(),
        "assignee": a.get("email") or a.get("displayName") or "",
        "updated":  n.get("updatedAt","") or "",
    })
print(json.dumps(out))
'
}

# --- get -------------------------------------------------------------------
tracker_get() {
  local key="$1"
  _linear_require || return $?
  local out
  out=$(_linear_query '
query ($id: String!) {
  issue(id: $id) {
    id identifier title description url state { name } assignee { email }
  }
}' "{\"id\":\"$key\"}")
  printf '%s' "$out" | grep -q '"issue"' || return 2
  printf '%s\n' "$out"
}

# --- transition ------------------------------------------------------------
tracker_transition() {
  local key="$1" intent="$2"
  _linear_require || return $?
  local state_id
  state_id=$(_linear_state_id_for_intent "$intent") \
    || { echo "linear: no state matches intent '$intent'" >&2; return 1; }

  local out
  out=$(_linear_query '
mutation ($id: String!, $state: String!) {
  issueUpdate(id: $id, input: { stateId: $state }) { success }
}' "{\"id\":\"$key\",\"state\":\"$state_id\"}")
  printf '%s' "$out" | grep -q '"success":true'
}

# --- comment ---------------------------------------------------------------
tracker_comment() {
  local key="$1"; shift
  _linear_require || return $?
  local body="$*"
  local esc
  esc=$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
  local out
  out=$(_linear_query "
mutation (\$id: String!, \$body: String!) {
  commentCreate(input: { issueId: \$id, body: \$body }) { success }
}" "{\"id\":\"$key\",\"body\":$esc}")
  printf '%s' "$out" | grep -q '"success":true'
}

# --- assign ----------------------------------------------------------------
tracker_assign() {
  local key="$1" who="$2"
  _linear_require || return $?
  local input
  if [[ "$who" == "unset" || "$who" == "unassigned" ]]; then
    input='{"assigneeId":null}'
  else
    # Resolve user id by email (best-effort — skip on not found).
    local out
    out=$(_linear_query '
query ($email: String!) {
  users(filter: { email: { eq: $email } }) { nodes { id } }
}' "{\"email\":\"$who\"}")
    local uid
    uid=$(printf '%s' "$out" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
nodes = ((d.get("data") or {}).get("users") or {}).get("nodes") or []
if nodes: print(nodes[0].get("id",""))
')
    [[ -z "$uid" ]] && return 1
    input="{\"assigneeId\":\"$uid\"}"
  fi
  local out
  out=$(_linear_query "
mutation (\$id: String!) {
  issueUpdate(id: \$id, input: $input) { success }
}" "{\"id\":\"$key\"}")
  printf '%s' "$out" | grep -q '"success":true'
}
