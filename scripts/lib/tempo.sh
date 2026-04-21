#!/bin/bash
# scripts/lib/tempo.sh
#
# Thin wrapper over the Tempo Cloud REST API (v4). Lives at api.tempo.io and
# authenticates with a Tempo-specific bearer token — completely separate from
# the Atlassian API token used for Jira REST.
#
# Public functions:
#   tempo_api    <METHOD> <path> [<body>]        — low-level
#   tempo_get    <path>                          — GET
#   tempo_post   <path> <body>                   — POST
#   tempo_delete <path>                          — DELETE
#   tempo_ping                                   — quick auth + scope check
#                                                  prints "OK" on success,
#                                                  a diagnostic on failure.
#   tempo_list_worklogs <accountId> <from> <to>  — list my worklogs in [from,to]
#                                                  (dates ISO yyyy-mm-dd,
#                                                  inclusive both sides)
#   tempo_post_worklog <body_json>               — create one worklog;
#                                                  echoes tempoWorklogId on OK
#   tempo_delete_worklog <worklogId>             — delete by id
#
# Required env (loaded from secrets.env via env.sh):
#   TEMPO_API_TOKEN      — Tempo → Settings → API Integration
#   JIRA_ACCOUNT_ID      — Atlassian accountId; used as authorAccountId
#
# On auth/network failure, api calls echo the raw response body to stderr and
# return non-zero so callers can surface a WARN rather than crash.

[[ -n "${_DEV_AGENT_TEMPO_LOADED:-}" ]] && return 0
_DEV_AGENT_TEMPO_LOADED=1

_tempo_base() { echo "${TEMPO_API_BASE:-https://api.tempo.io/4}"; }

tempo_api() {
  local method="$1" path="$2" body="${3:-}"
  if [[ -z "${TEMPO_API_TOKEN:-}" ]]; then
    echo "tempo_api: TEMPO_API_TOKEN not set" >&2
    return 1
  fi
  local url; url="$(_tempo_base)${path}"
  # --max-time gives us a hard ceiling; Tempo is usually <500ms but we've seen
  # 10s+ cold starts from their edge.
  if [[ -n "$body" ]]; then
    curl -s --max-time 20 -X "$method" "$url" \
      -H "Authorization: Bearer ${TEMPO_API_TOKEN}" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      -d "$body"
  else
    curl -s --max-time 20 -X "$method" "$url" \
      -H "Authorization: Bearer ${TEMPO_API_TOKEN}" \
      -H "Accept: application/json"
  fi
}

tempo_get()    { tempo_api GET    "$1"; }
tempo_post()   { tempo_api POST   "$1" "$2"; }
tempo_delete() { tempo_api DELETE "$1"; }

# Quick auth + reachability probe. Echoes one line:
#   OK: <N> worklog(s) readable           — token is valid + has View scope
#   ERR auth: 401 ...                     — invalid / revoked token
#   ERR scope: 403 ...                    — token missing View Worklogs
#   ERR network: ...                      — curl failed
# Exit code is 0 on OK, 1 otherwise.
tempo_ping() {
  local raw http
  # Use -w to split body from status so we can distinguish auth vs. scope.
  raw=$(TEMPO_API_TOKEN="${TEMPO_API_TOKEN:-}" curl -s --max-time 20 \
    -w $'\n__HTTP__%{http_code}' \
    -H "Authorization: Bearer ${TEMPO_API_TOKEN:-}" \
    -H "Accept: application/json" \
    "$(_tempo_base)/worklogs?limit=1" 2>&1)
  http="${raw##*__HTTP__}"
  local body="${raw%$'\n__HTTP__'*}"
  case "$http" in
    200)
      local n; n=$(printf '%s' "$body" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("metadata", {}).get("count", len(d.get("results", []))))
except Exception:
    print("?")
')
      echo "OK: $n worklog(s) readable"
      return 0 ;;
    401) echo "ERR auth: 401 — token invalid/expired. Regenerate at Tempo → Settings → API Integration."; return 1 ;;
    403) echo "ERR scope: 403 — token missing 'View Worklogs' scope. Recreate the token with scopes: Manage Worklogs + View Worklogs."; return 1 ;;
    000|"") echo "ERR network: could not reach api.tempo.io (curl rc/body: $body)"; return 1 ;;
    *) echo "ERR http $http: $(printf '%s' "$body" | head -c 200)"; return 1 ;;
  esac
}

# List worklogs by author in an inclusive date window. Echoes the raw JSON
# body — caller parses. Pagination is handled by callers that need >5000
# results (we don't).
tempo_list_worklogs() {
  local account_id="$1" from="$2" to="$3"
  local body
  body=$(python3 -c '
import json, sys
print(json.dumps({
    "authorIds": [sys.argv[1]],
    "from":      sys.argv[2],
    "to":        sys.argv[3],
}))' "$account_id" "$from" "$to")
  tempo_post "/worklogs/search" "$body"
}

# Create one worklog. The body must already be a valid JSON object following
# Tempo's schema:
#   {
#     "authorAccountId":  "<jira accountId>",
#     "issueId":          <numeric issue id>  OR  "issueKey": "PROJ-997",
#     "startDate":        "YYYY-MM-DD",
#     "startTime":        "HH:MM:SS",
#     "timeSpentSeconds": 1800,
#     "description":      "..."
#   }
# Echoes the created worklog's tempoWorklogId on success; non-zero exit + raw
# response on failure.
tempo_post_worklog() {
  local body="$1"
  local resp; resp=$(tempo_post "/worklogs" "$body")
  local id; id=$(printf '%s' "$resp" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("tempoWorklogId", ""))
except Exception:
    pass
')
  if [[ -n "$id" ]]; then
    echo "$id"
    return 0
  fi
  echo "$resp" >&2
  return 1
}

tempo_delete_worklog() {
  local id="$1"
  tempo_delete "/worklogs/$id" >/dev/null
}
