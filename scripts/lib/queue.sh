#!/bin/bash
# scripts/lib/queue.sh — priority queue + fair-share across projects.
#
# The watcher used to just pick the first eligible ticket per project.
# With multi-project installs that's unfair: the project listed first in
# config.json always got picked, starving the others. This library gives
# each project a weighted share and scores tickets inside that share by
# priority * age, so nobody is systematically neglected.
#
# Callers:
#   queue_score_ticket <project-id> <priority-name> <created-iso>
#       → emits a float score (larger = more urgent)
#   queue_collect_all
#       → walks cfg_project_list, calls the tracker driver per project,
#         and emits a TSV stream: <score>\t<project>\t<ticket>\t<summary>
#         sorted by score descending.
#   queue_fair_pick [<max>]
#       → consumes queue_collect_all and round-robins across projects so
#         no project's tickets dominate the top N.

[[ -n "${_DEV_AGENT_QUEUE_LOADED:-}" ]] && return 0
_DEV_AGENT_QUEUE_LOADED=1

# Priority weights — higher = more urgent. Accepts common Jira names as
# well as generic labels used by other trackers.
_queue_priority_weight() {
  local p
  p=$(printf '%s' "${1:-medium}" | tr '[:upper:]' '[:lower:]')
  case "$p" in
    highest|p0|critical|blocker|urgent) echo 5 ;;
    high|p1|major)                      echo 4 ;;
    medium|p2|normal|default)           echo 3 ;;
    low|p3|minor)                       echo 2 ;;
    lowest|p4|trivial)                  echo 1 ;;
    *)                                  echo 3 ;;
  esac
}

# Project weight — per-project priority bias. Set via
# projects[].queueWeight in config.json (default 1.0). Useful when one
# project is more urgent than the rest (e.g. prod bug project vs. docs).
_queue_project_weight() {
  local pid="$1"
  local w
  w=$(cfg_get ".projects[] | select(.id==\"${pid}\") | .queueWeight" "1.0")
  # Normalise anything weird to 1.0.
  case "$w" in
    ''|null) echo "1.0" ;;
    *)       echo "$w" ;;
  esac
}

# Score a single ticket.
#   score = priority_weight * project_weight * age_factor
#   age_factor = 1 + log2(days_old + 1)   (newer = 1, a week-old ≈ 3)
queue_score_ticket() {
  local pid="$1" priority="$2" created_iso="$3"
  local pw proj_w
  pw=$(_queue_priority_weight "$priority")
  proj_w=$(_queue_project_weight "$pid")

  # age_factor via python (bash can't do log2 portably).
  PY_PRIO="$pw" PY_PROJ="$proj_w" PY_ISO="$created_iso" python3 -c '
import os, math, datetime
prio = float(os.environ["PY_PRIO"])
proj = float(os.environ["PY_PROJ"])
iso = os.environ["PY_ISO"] or ""
try:
    if iso.endswith("Z"): iso = iso[:-1] + "+00:00"
    dt = datetime.datetime.fromisoformat(iso)
    now = datetime.datetime.now(dt.tzinfo or datetime.timezone.utc)
    days = max(0, (now - dt).days)
except Exception:
    days = 0
age_factor = 1.0 + math.log2(days + 1)
print(f"{prio * proj * age_factor:.4f}")
'
}

# Collect eligible "New"/"To Do"/"Open" tickets from every project using the
# tracker driver. Emits TSV: <score>\t<project>\t<ticket>\t<priority>\t<summary>
# sorted score desc. Requires the tracker dispatcher to be sourced — we do it
# on demand per project since each has its own KIND.
queue_collect_all() {
  local tmp
  tmp=$(mktemp -t queue-collect.XXXXXX)
  for pid in $(cfg_project_list); do
    (
      cfg_project_activate "$pid" >/dev/null 2>&1 || exit 0
      # shellcheck disable=SC1091
      source "$SKILL_DIR/scripts/drivers/tracker/_dispatch.sh" 2>/dev/null || exit 0
      # Use the generic search intent; drivers map it to their native query.
      local hits
      hits=$(tracker_search "status:open assignee:me" 2>/dev/null) || exit 0
      printf '%s' "$hits" | python3 -c '
import json, sys, os
try:
    arr = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(arr, list): sys.exit(0)
pid = os.environ["PID"]
for t in arr:
    key = t.get("key") or t.get("id") or ""
    if not key: continue
    summary = (t.get("summary") or t.get("title") or "").replace("\t"," ").replace("\n"," ")[:200]
    prio = t.get("priority") or "medium"
    created = t.get("created") or t.get("createdAt") or ""
    print(f"{pid}\t{key}\t{prio}\t{created}\t{summary}")
' PID="$pid"
    )
  done | while IFS=$'\t' read -r P K PR CR SM; do
    [[ -z "$K" ]] && continue
    local score
    score=$(queue_score_ticket "$P" "$PR" "$CR")
    printf '%s\t%s\t%s\t%s\t%s\n' "$score" "$P" "$K" "$PR" "$SM"
  done | sort -rn -k1,1 > "$tmp"
  cat "$tmp"
  rm -f "$tmp"
}

# Fair-share: feed queue_collect_all output through a per-project round-robin
# cap so no single project's tickets dominate the top N.
#   queue_fair_pick 10
queue_fair_pick() {
  local max="${1:-10}"
  local input
  input=$(queue_collect_all)
  [[ -z "$input" ]] && return 0

  # Determine fair share per project based on queueWeight.
  local weights total
  weights=$(printf '%s' "$input" | awk -F'\t' '{print $2}' | sort -u)
  total=$(awk 'BEGIN{t=0} /./ {t++} END{print t+0}' <<<"$weights")
  [[ $total -eq 0 ]] && { printf '%s\n' "$input"; return 0; }

  # Group per project, keep top-per-project = ceil(max / total_projects).
  local per_project=$(( (max + total - 1) / total ))
  (( per_project < 1 )) && per_project=1

  printf '%s\n' "$input" | awk -F'\t' -v cap="$per_project" '
    { proj = $2; cnt[proj] = (cnt[proj] || 0) + 1 }
    cnt[proj] <= cap
  ' | head -n "$max"
}
