#!/bin/bash
# scripts/drivers/host/github.sh
#
# Host driver for GitHub (PRs). Uses `gh` CLI for everything — the same
# authenticated session tracker/github-issues.sh relies on.
#
# Canonical `project_id` for GitHub is "owner/repo" (string), NOT a numeric
# id. The host_* API accepts it unchanged because we pass it straight to
# `gh --repo`.
#
# Env vars:
#   HOST_KIND=github
#   HOST_GROUP   "owner" slug (for host_repo_slug_for_alias fallback)

[[ -n "${_DEV_AGENT_HOST_GITHUB_LOADED:-}" ]] && return 0
_DEV_AGENT_HOST_GITHUB_LOADED=1

_gh_host_require() {
  command -v gh >/dev/null 2>&1 || { echo "github: gh CLI missing" >&2; return 2; }
}

host_probe() {
  _gh_host_require || return 3
  gh auth status >/dev/null 2>&1 && return 0
  return 1
}

host_current_user() {
  _gh_host_require || return 2
  gh api user --jq '.login' 2>/dev/null
}

# scope ∈ self|reviewer
host_mr_list() {
  local scope="${1:-self}"
  _gh_host_require || return 2
  local me; me=$(host_current_user)
  [[ -z "$me" ]] && return 1

  local q
  case "$scope" in
    self)     q="is:pr is:open author:${me}" ;;
    reviewer) q="is:pr is:open review-requested:${me}" ;;
    *)        q="is:pr is:open author:${me}" ;;
  esac

  # `gh search prs` returns a JSON stream suited to our normalisation.
  local raw
  raw=$(gh search prs \
        --json number,url,title,state,isDraft,repository \
        --limit 50 \
        -- "$q" 2>/dev/null) || return 1

  printf '%s' "$raw" | python3 -c '
import json, sys
try:
    rows = json.load(sys.stdin) or []
except Exception:
    rows = []
out = []
for r in rows:
    repo_obj = r.get("repository") or {}
    repo = ""
    # shape: {"nameWithOwner":"owner/repo"}
    repo = repo_obj.get("nameWithOwner","") or repo_obj.get("name","")
    out.append({
        "iid":        r.get("number"),
        "project_id": repo,
        "url":        r.get("url","") or "",
        "title":      r.get("title","") or "",
        "state":      (r.get("state") or "").lower(),
        "draft":      bool(r.get("isDraft")),
    })
print(json.dumps(out))
'
}

host_mr_get() {
  local project="$1" iid="$2"
  _gh_host_require || return 2
  local raw
  raw=$(gh pr view "$iid" --repo "$project" \
         --json number,title,state,isDraft,url,headRefName,baseRefName,reviewDecision,statusCheckRollup 2>/dev/null) || return 1

  printf '%s' "$raw" | python3 -c '
import json, sys
try:
    m = json.load(sys.stdin)
except Exception:
    sys.exit(1)
# Reduce statusCheckRollup to a single status.
rollup = m.get("statusCheckRollup") or []
status = "success"
if any((c.get("conclusion") or "").upper() in ("FAILURE","TIMED_OUT") for c in rollup):
    status = "failed"
elif any((c.get("status") or "").upper() in ("IN_PROGRESS","QUEUED","PENDING") for c in rollup):
    status = "running"
elif not rollup:
    status = "pending"
out = {
    "iid":             m.get("number"),
    "title":           m.get("title") or "",
    "state":           (m.get("state") or "").lower(),
    "draft":           bool(m.get("isDraft")),
    "url":             m.get("url") or "",
    "pipeline_status": status,
    "approvals":       [],
    "source_branch":   m.get("headRefName") or "",
    "target_branch":   m.get("baseRefName") or "",
    "review_decision": (m.get("reviewDecision") or "").lower(),
}
print(json.dumps(out))
'
}

host_mr_create() {
  local project="$1" source="$2" target="$3" title="$4" body="${5:-}"
  _gh_host_require || return 2
  local body_arg=()
  [[ -n "$body" ]] && body_arg=(--body "$body")
  gh pr create --repo "$project" \
    --head "$source" --base "$target" \
    --title "$title" "${body_arg[@]}" 2>/dev/null \
    | tail -n1
}

host_mr_update() {
  local project="$1" iid="$2" field="$3" value="$4"
  _gh_host_require || return 2
  case "$field" in
    ready)
      if [[ "$value" == "true" ]]; then
        gh pr ready "$iid" --repo "$project" >/dev/null 2>&1
      else
        gh pr ready "$iid" --repo "$project" --undo >/dev/null 2>&1
      fi
      ;;
    assignees)
      IFS=',' read -r -a users <<< "$value"
      for u in "${users[@]}"; do
        [[ -n "$u" ]] && gh pr edit "$iid" --repo "$project" --add-assignee "$u" >/dev/null 2>&1 || true
      done
      ;;
    reviewers)
      IFS=',' read -r -a users <<< "$value"
      for u in "${users[@]}"; do
        [[ -n "$u" ]] && gh pr edit "$iid" --repo "$project" --add-reviewer "$u" >/dev/null 2>&1 || true
      done
      ;;
    *) echo "github: unknown field '$field'" >&2; return 1 ;;
  esac
}

host_mr_merge() {
  local project="$1" iid="$2" strategy="${3:-squash}"
  _gh_host_require || return 2
  local flag="--squash"
  case "$strategy" in
    squash) flag="--squash" ;;
    merge)  flag="--merge" ;;
    rebase) flag="--rebase" ;;
  esac
  gh pr merge "$iid" --repo "$project" "$flag" --delete-branch --auto >/dev/null 2>&1
}

host_ci_status() {
  local project="$1" iid="$2"
  local info
  info=$(host_mr_get "$project" "$iid") || return 1
  printf '%s' "$info" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("pipeline_status","pending"))'
}

host_notes() {
  local project="$1" iid="$2" since="${3:-0}"
  _gh_host_require || return 2
  local raw
  raw=$(gh api "repos/${project}/issues/${iid}/comments" --paginate 2>/dev/null) || return 1
  printf '%s' "$raw" | SINCE="$since" python3 -c '
import json, os, sys, datetime
since = int(os.environ.get("SINCE","0") or 0)
try:
    d = json.load(sys.stdin)
except Exception:
    print("[]"); sys.exit(0)
if not isinstance(d, list): d = []
out = []
for n in d:
    ts_raw = n.get("created_at","") or ""
    try:
        ts = int(datetime.datetime.fromisoformat(ts_raw.replace("Z","+00:00")).timestamp())
    except Exception:
        ts = 0
    if since and ts < since: continue
    out.append({
        "id":      n.get("id"),
        "author":  ((n.get("user") or {}).get("login") or ""),
        "body":    n.get("body") or "",
        "created": ts,
    })
print(json.dumps(out))
'
}

host_branch_exists() {
  local project="$1" branch="$2"
  _gh_host_require || return 2
  gh api "repos/${project}/branches/${branch}" >/dev/null 2>&1
}

host_repo_slug_for_alias() {
  local alias="$1"
  if type cfg_repo_slug_for_alias >/dev/null 2>&1; then
    cfg_repo_slug_for_alias "$alias"
    return $?
  fi
  local group="${HOST_GROUP:-}"
  [[ -n "$group" ]] && printf '%s/%s\n' "$group" "$alias"
}
