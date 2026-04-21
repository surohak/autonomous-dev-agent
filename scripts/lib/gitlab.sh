#!/bin/bash
# scripts/lib/gitlab.sh
#
# Thin, consistent wrapper over `glab api` for the operations this project
# repeats across handlers and watchers. Keeping them in one place so:
#
#   1. We don't scatter URL-encoding / error-string matching across scripts.
#   2. Handlers stay readable (`gl_mr_approve "$project" "$iid"` vs. an
#      inline subprocess block with quoting).
#   3. Future retries / rate-limit backoff have one home.
#
# Public functions:
#   gl_encode <path>                               — URL-encode a project path
#   gl_api    <METHOD> <path> [<body>]             — low-level glab api call
#   gl_mr_get <project> <mr_iid>                   — GET merge_requests/<iid>
#   gl_mr_approve <project> <mr_iid>               — POST approve (idempotent)
#   gl_mr_resolve_discussion <project> <iid> <did> — PUT resolved=true
#   gl_user_id_by_username <username>              — resolve username → numeric id
#   gl_mr_set_reviewer <project> <iid> <username>  — replace reviewer list with one user
#
# All <project> args are the human-readable path ("group/repo"); we encode
# internally. All functions echo the raw JSON body for callers that want to
# parse with jq/python. Exit codes:
#   0 = success (incl. "already approved" for gl_mr_approve)
#   1 = transport/API failure
#   2 = glab binary missing
#
# Requires `glab` on PATH and a logged-in session (`glab auth status`).

[[ -n "${_DEV_AGENT_GITLAB_LOADED:-}" ]] && return 0
_DEV_AGENT_GITLAB_LOADED=1

_gl_require_glab() {
  command -v glab >/dev/null 2>&1 || { echo "gl_api: glab not found on PATH" >&2; return 2; }
}

gl_encode() {
  # URL-encode the full path (so `group/repo` → `group%2Frepo`). We shell
  # out to python because Bash has no built-in percent-encoder and we already
  # require python3 elsewhere.
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

gl_api() {
  local method="$1" path="$2" body="${3:-}"
  _gl_require_glab || return $?
  if [[ -n "$body" ]]; then
    # Pipe body via stdin — handles arbitrary JSON without shell-quoting hell.
    printf '%s' "$body" | glab api --method "$method" --input - "$path" 2>&1
  else
    glab api --method "$method" "$path" 2>&1
  fi
}

gl_mr_get() {
  local project="$1" iid="$2"
  local enc; enc=$(gl_encode "$project")
  gl_api GET "projects/${enc}/merge_requests/${iid}"
}

# Approve an MR. Tolerates the "already approved" case because GitLab returns
# 401/409 for repeat approvals, and from our flow's perspective that's still a
# success (we want the Jira transition + unassign to run regardless).
gl_mr_approve() {
  local project="$1" iid="$2"
  local enc out rc
  enc=$(gl_encode "$project")
  out=$(gl_api POST "projects/${enc}/merge_requests/${iid}/approve")
  rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "$out"
    return 0
  fi
  # Match both the human-readable error and the JSON variants GitLab uses.
  if printf '%s' "$out" | grep -qiE 'already approved|401 unauthorized'; then
    echo "$out"
    return 0
  fi
  echo "$out" >&2
  return 1
}

# Mark a discussion thread on an MR as resolved.
gl_mr_resolve_discussion() {
  local project="$1" iid="$2" discussion_id="$3"
  local enc; enc=$(gl_encode "$project")
  gl_api PUT "projects/${enc}/merge_requests/${iid}/discussions/${discussion_id}?resolved=true"
}

# Resolve a GitLab username → numeric user ID. Returns the ID on stdout, empty
# string (and rc=1) if the username doesn't exist or the search returns no hit.
# Callers use this for PUT endpoints that require reviewer_ids[]/assignee_ids[]
# (GitLab's API doesn't accept usernames for those fields).
gl_user_id_by_username() {
  local username="$1"
  [[ -z "$username" ]] && return 1
  local out
  out=$(gl_api GET "users?username=${username}") || return 1
  printf '%s' "$out" | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: d = []
print(d[0]["id"] if isinstance(d, list) and d else "")
'
}

# Replace the reviewer list on an MR with a single reviewer, identified by
# GitLab username. Does a username→id lookup internally. Returns 0 on success,
# 1 if the username is unknown or the PUT fails.
gl_mr_set_reviewer() {
  local project="$1" iid="$2" username="$3"
  local enc user_id
  enc=$(gl_encode "$project")
  user_id=$(gl_user_id_by_username "$username")
  if [[ -z "$user_id" ]]; then
    echo "gl_mr_set_reviewer: unknown user $username" >&2
    return 1
  fi
  # reviewer_ids is a GitLab array param. Using the query-string form keeps
  # the body empty so we don't need Content-Type / JSON encoding for a single
  # scalar update.
  gl_api PUT "projects/${enc}/merge_requests/${iid}?reviewer_ids[]=${user_id}"
}
