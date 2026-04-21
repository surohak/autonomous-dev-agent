#!/bin/bash
# scripts/drivers/host/gitlab.sh
#
# Reference host driver for GitLab. Wraps scripts/lib/gitlab.sh + glab CLI
# behind the canonical host_* contract. See _interface.md for the full
# signature reference.
#
# Env vars (populated by cfg_project_activate):
#   HOST_BASE_URL   e.g. https://gitlab.com/api/v4 (optional — glab uses ~/.glab-cli)
#   HOST_TOKEN      glab session is preferred; GITLAB_TOKEN is the fallback
#   HOST_GROUP      e.g. mycompany (used for host_repo_slug_for_alias)

[[ -n "${_DEV_AGENT_HOST_GITLAB_LOADED:-}" ]] && return 0
_DEV_AGENT_HOST_GITLAB_LOADED=1

# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/gitlab.sh"

# --- probe -----------------------------------------------------------------
host_probe() {
  command -v glab >/dev/null 2>&1 || return 3
  glab auth status >/dev/null 2>&1 && return 0
  # Fall back to REST probe if glab isn't logged in but a token is set.
  if [[ -n "${GITLAB_TOKEN:-}" ]]; then
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" \
      -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
      "https://gitlab.com/api/v4/user" 2>/dev/null || echo "000")
    [[ "$code" == "200" ]] && return 0
  fi
  return 1
}

host_current_user() {
  # Cheap: `glab api user` returns {"username":…}.
  gl_api GET "user" 2>/dev/null | python3 -c 'import json,sys;
try:
  print(json.load(sys.stdin).get("username",""))
except Exception:
  pass' 2>/dev/null
}

# --- MR operations --------------------------------------------------------
# host_mr_list <scope>       scope ∈ self|reviewer
host_mr_list() {
  local scope="${1:-self}"
  local me; me=$(host_current_user)
  [[ -z "$me" ]] && return 1

  local filter
  case "$scope" in
    self)     filter="scope=created_by_me&state=opened" ;;
    reviewer) filter="scope=assigned_to_me&state=opened" ;;
    *)        filter="scope=created_by_me&state=opened" ;;
  esac

  # Raw list from GitLab API.
  local raw
  raw=$(gl_api GET "merge_requests?${filter}&per_page=50") || return 1

  printf '%s' "$raw" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("[]"); sys.exit(0)
out = []
for m in d:
    out.append({
        "iid":        m.get("iid"),
        "project_id": m.get("project_id"),
        "url":        m.get("web_url") or "",
        "title":      m.get("title") or "",
        "state":      m.get("state") or "",
        "draft":      bool(m.get("draft") or m.get("work_in_progress")),
    })
print(json.dumps(out))
'
}

host_mr_get() {
  local project="$1" iid="$2"
  local raw
  raw=$(gl_mr_get "$project" "$iid") || return 1

  printf '%s' "$raw" | python3 -c '
import json, sys
try:
    m = json.load(sys.stdin)
except Exception:
    sys.exit(1)
out = {
    "iid":             m.get("iid"),
    "title":           m.get("title") or "",
    "state":           m.get("state") or "",
    "draft":           bool(m.get("draft") or m.get("work_in_progress")),
    "url":             m.get("web_url") or "",
    "pipeline_status": ((m.get("pipeline") or {}).get("status") or ""),
    "approvals":       [],
    "source_branch":   m.get("source_branch") or "",
    "target_branch":   m.get("target_branch") or "",
}
print(json.dumps(out))
'
}

host_mr_merge() {
  local project="$1" iid="$2" strategy="${3:-}"
  local enc; enc=$(gl_encode "$project")
  local body='{}'
  case "$strategy" in
    squash) body='{"squash":true}' ;;
  esac
  gl_api PUT "projects/${enc}/merge_requests/${iid}/merge" "$body" >/dev/null
}

host_ci_status() {
  local project="$1" iid="$2"
  local raw
  raw=$(gl_mr_get "$project" "$iid") || return 1
  printf '%s' "$raw" | python3 -c '
import json, sys
try:
    m = json.load(sys.stdin)
except Exception:
    sys.exit(1)
s = ((m.get("pipeline") or {}).get("status") or "").lower()
mapping = {
    "success":  "success",
    "failed":   "failed",
    "running":  "running",
    "pending":  "pending",
    "canceled": "canceled",
    "skipped":  "skipped",
    "manual":   "pending",
}
print(mapping.get(s, "pending"))
'
}

host_notes() {
  local project="$1" iid="$2" since="${3:-0}"
  local enc; enc=$(gl_encode "$project")
  local raw
  raw=$(gl_api GET "projects/${enc}/merge_requests/${iid}/notes?sort=asc&per_page=50") || return 1

  printf '%s' "$raw" | SINCE="$since" python3 -c '
import json, os, sys, datetime
since = int(os.environ.get("SINCE","0") or 0)
try:
    d = json.load(sys.stdin)
except Exception:
    print("[]"); sys.exit(0)
out = []
for n in d:
    ts_raw = n.get("created_at") or ""
    try:
        ts = int(datetime.datetime.fromisoformat(ts_raw.replace("Z","+00:00")).timestamp())
    except Exception:
        ts = 0
    if since and ts < since: continue
    out.append({
        "id":      n.get("id"),
        "author":  ((n.get("author") or {}).get("username") or ""),
        "body":    n.get("body") or "",
        "created": ts,
    })
print(json.dumps(out))
'
}

host_branch_exists() {
  local project="$1" branch="$2"
  local enc; enc=$(gl_encode "$project")
  local enc_branch
  enc_branch=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$branch")
  local code
  code=$(gl_api GET "projects/${enc}/repository/branches/${enc_branch}" 2>/dev/null | head -n1)
  [[ -n "$code" && "$code" != *"404"* ]]
}

host_repo_slug_for_alias() {
  local alias="$1"
  # Delegate to cfg helper if it exists (Phase 2 pattern).
  if type cfg_repo_slug_for_alias >/dev/null 2>&1; then
    cfg_repo_slug_for_alias "$alias"
    return $?
  fi
  # Best-effort fallback: assume group/alias.
  local group="${HOST_GROUP:-}"
  [[ -n "$group" ]] && printf '%s/%s\n' "$group" "$alias"
}
