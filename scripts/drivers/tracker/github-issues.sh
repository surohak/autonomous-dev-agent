#!/bin/bash
# scripts/drivers/tracker/github-issues.sh
#
# Tracker driver for GitHub Issues. Uses `gh` CLI — the authenticated
# session handles auth, rate-limit retries, and the REST/GraphQL split
# transparently.
#
# Labels are the workflow. We treat a well-known label namespace as the
# "status" slot, with `status:*` as the default convention:
#
#     status:todo          → semantic intent domain: "backlog"
#     status:in-progress    → maps to intent `start` target
#     status:code-review   → `push_review` target
#     status:ready-for-qa  → `after_approve` target
#     status:done          → `done` target
#     status:blocked       → `block` target
#
# Users can override the mapping via projects[].workflow.aliases. If no
# alias overrides are set, the defaults above are used.
#
# Env vars:
#   TRACKER_KIND=github-issues
#   TRACKER_PROJECT   "owner/repo" (the repo whose issues are tracked)
#   GITHUB_TOKEN      PAT/gh token (or rely on gh auth login)

[[ -n "${_DEV_AGENT_TRACKER_GH_LOADED:-}" ]] && return 0
_DEV_AGENT_TRACKER_GH_LOADED=1

_gh_repo() {
  printf '%s\n' "${TRACKER_PROJECT:-}"
}

_gh_require() {
  command -v gh >/dev/null 2>&1 || { echo "github-issues: gh CLI missing" >&2; return 2; }
  local repo; repo=$(_gh_repo)
  [[ -z "$repo" ]] && { echo "github-issues: TRACKER_PROJECT empty (expected owner/repo)" >&2; return 2; }
}

tracker_probe() {
  _gh_require || return 3
  gh auth status >/dev/null 2>&1 || return 3
  local repo; repo=$(_gh_repo)
  gh api "repos/${repo}" >/dev/null 2>&1 && return 0
  return 1
}

# Intent → status-label mapping. Defaults mirror the comment header. Users
# can override via projects[].workflow.aliases → the alias patterns are
# matched as regex against the repo's existing labels; first hit wins.
_gh_intent_to_label() {
  local intent="$1"
  case "$intent" in
    start)          echo "status:in-progress" ;;
    push_review)    echo "status:code-review" ;;
    after_approve)  echo "status:ready-for-qa" ;;
    done)           echo "status:done" ;;
    block)          echo "status:blocked" ;;
    unblock)        echo "status:in-progress" ;;
    *) return 1 ;;
  esac
}

_gh_status_label_for_issue() {
  local issue_number="$1"
  local repo; repo=$(_gh_repo)
  gh api "repos/${repo}/issues/${issue_number}" --jq '.labels[]?.name' 2>/dev/null \
    | grep -E '^status:' | head -n1
}

# --- search ----------------------------------------------------------------
# tracker_search "is:open label:status:todo" 10 "ignored"
tracker_search() {
  local q="$1" max="${2:-50}"
  _gh_require || return 2
  local repo; repo=$(_gh_repo)
  # `gh issue list --search …` is the ergonomic API. We emit JSON fields
  # that map 1:1 onto the canonical shape.
  local raw
  raw=$(gh issue list --repo "$repo" \
        --search "$q" \
        --limit "$max" \
        --json number,title,url,state,labels,assignees,updatedAt 2>/dev/null) || return 1

  printf '%s' "$raw" | REPO="$repo" python3 -c '
import json, sys, os
repo = os.environ.get("REPO","")
try:
    rows = json.load(sys.stdin) or []
except Exception:
    rows = []
out = []
for r in rows:
    labels = [ (l.get("name") or "") for l in (r.get("labels") or []) ]
    status = ""
    for l in labels:
        if l.startswith("status:"):
            status = l[len("status:"):].replace("-"," ").lower()
            break
    assignees = [ a.get("login","") for a in (r.get("assignees") or []) ]
    out.append({
        "key":      f"{repo}#{r.get(\"number\")}",
        "url":      r.get("url","") or "",
        "summary":  r.get("title","") or "",
        "status":   status,
        "assignee": (assignees[0] if assignees else ""),
        "updated":  r.get("updatedAt","") or "",
    })
print(json.dumps(out))
'
}

# --- get -------------------------------------------------------------------
# <key> is "owner/repo#N" or plain N if TRACKER_PROJECT is set.
tracker_get() {
  local key="$1"
  _gh_require || return 2
  local number="${key##*#}"
  local repo; repo=$(_gh_repo)
  gh api "repos/${repo}/issues/${number}" 2>/dev/null \
    || return 2
}

# --- transition ------------------------------------------------------------
tracker_transition() {
  local key="$1" intent="$2"
  _gh_require || return 2
  local number="${key##*#}"
  local repo; repo=$(_gh_repo)
  local target_label
  target_label=$(_gh_intent_to_label "$intent") || {
    echo "github-issues: unknown intent '$intent'" >&2
    return 1
  }

  # Strip any existing status:* label, add the new one. `--remove-label`
  # with a non-existent label is a no-op, so we're generous.
  local current
  current=$(_gh_status_label_for_issue "$number")
  if [[ -n "$current" && "$current" != "$target_label" ]]; then
    gh issue edit "$number" --repo "$repo" --remove-label "$current" >/dev/null 2>&1 || true
  fi
  gh issue edit "$number" --repo "$repo" --add-label "$target_label" >/dev/null 2>&1 || return 1

  # Close the issue when transitioning to `done`. Conversely, reopen when
  # leaving `done`.
  if [[ "$intent" == "done" ]]; then
    gh issue close "$number" --repo "$repo" >/dev/null 2>&1 || true
  elif [[ "$current" == "status:done" ]]; then
    gh issue reopen "$number" --repo "$repo" >/dev/null 2>&1 || true
  fi
}

# --- comment ---------------------------------------------------------------
tracker_comment() {
  local key="$1"; shift
  _gh_require || return 2
  local number="${key##*#}"
  local repo; repo=$(_gh_repo)
  local body="$*"
  printf '%s' "$body" | gh issue comment "$number" --repo "$repo" --body-file - >/dev/null 2>&1
}

# --- assign ----------------------------------------------------------------
tracker_assign() {
  local key="$1" who="$2"
  _gh_require || return 2
  local number="${key##*#}"
  local repo; repo=$(_gh_repo)
  if [[ "$who" == "unset" || "$who" == "unassigned" ]]; then
    # Strip every current assignee via gh issue edit.
    local current
    current=$(gh api "repos/${repo}/issues/${number}" --jq '.assignees[]?.login' 2>/dev/null)
    local u
    for u in $current; do
      gh issue edit "$number" --repo "$repo" --remove-assignee "$u" >/dev/null 2>&1 || true
    done
    return 0
  fi
  gh issue edit "$number" --repo "$repo" --add-assignee "$who" >/dev/null 2>&1
}
