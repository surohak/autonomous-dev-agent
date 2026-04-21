#!/bin/bash
# scripts/lib/workflow.sh
#
# Dynamic Jira workflow discovery. Different projects use different status
# names ("To Do" vs "Open" vs "Backlog Ready") and transition ids. Instead of
# hardcoding them, the agent speaks in *semantic intents* and resolves them
# per project at runtime:
#
#   start         → move a New/To-Do ticket into active work
#   push_review   → send a completed ticket to Code Review
#   after_approve → advance from Code Review onwards (typically Ready for QA)
#   done          → mark closed / done
#   block         → mark blocked / needs-clarification
#   unblock       → move out of blocked
#
# Discovery happens once per (project, issueType) and caches the result at
# $WORKFLOW_FILE (set per-project by cfg.sh). Subsequent calls are free.
#
# Public functions:
#   workflow_discover      [issueKey]         populate cache for the project
#   workflow_resolve       <intent> [from]    echo transition id to use now
#   workflow_transition    <issueKey> <intent> transition a ticket by intent
#   workflow_refresh       [issueKey]         force-refresh the cache
#   workflow_dump                             print human-readable mapping
#
# All functions return 0/1 shell-style; nothing goes to stdout on failure.

[[ -n "${_DEV_AGENT_WORKFLOW_LOADED:-}" ]] && return 0
_DEV_AGENT_WORKFLOW_LOADED=1

# Default regex patterns per semantic intent. Matched case-insensitively
# against BOTH the transition name AND the target status name; whichever
# hits first wins. Per-project aliases in config.json workflow.aliases
# are prepended to this list so user overrides always win.
#
# Conservative patterns — they should match the common variants teams use
# without being so loose they collide.
_WORKFLOW_DEFAULTS='{
  "start":         ["^in[- ]?progress$", "^start$", "^work$", "in[- ]?progress", "development"],
  "push_review":   ["code[- ]?review", "^review$", "^peer[- ]?review$", "to code review", "submit.*review"],
  "after_approve": ["^ready for qa$", "ready.*qa", "^qa$", "testing", "code review to ready"],
  "done":          ["^done$", "^closed$", "^complete", "resolved", "ship"],
  "block":         ["blocked", "needs clarification", "on[- ]?hold", "waiting"],
  "unblock":       ["^reopen$", "back to in progress", "to in progress", "resume"]
}'

# Minimum time (seconds) between automatic workflow cache refreshes when a
# resolve miss happens. Prevents a tight loop from hammering Jira if the
# workflow genuinely doesn't contain the requested transition.
_WORKFLOW_MIN_REFRESH_SECS=3600

_workflow_file() {
  printf '%s\n' "${WORKFLOW_FILE:-$PROJECT_CACHE_DIR/workflow.json}"
}

# workflow_aliases — emit the merged aliases dict (user overrides + defaults).
_workflow_aliases_json() {
  local user_aliases
  user_aliases=$(cfg_project_field "${PROJECT_ID:-default}" '["workflow"]["aliases"]' 2>/dev/null)
  DEFAULTS="$_WORKFLOW_DEFAULTS" USER="${user_aliases:-{\}}" python3 -c '
import json, os, sys
d = json.loads(os.environ["DEFAULTS"])
try:
    u = json.loads(os.environ["USER"])
    if not isinstance(u, dict): u = {}
except Exception:
    u = {}
# User patterns prepended → higher priority
for k, v in u.items():
    if isinstance(v, list):
        d[k] = list(v) + d.get(k, [])
print(json.dumps(d))
'
}

# workflow_discover [issueKey]
# Probes Jira to collect the full transition graph for the project. If
# issueKey is omitted, picks the first ticket in the project (cheapest).
# Writes to $WORKFLOW_FILE. Returns 0 on success (cache written), 1 on fail.
workflow_discover() {
  local issue_key="${1:-}"
  [[ -z "${JIRA_SITE:-}" ]] && return 1
  [[ -z "${JIRA_PROJECT:-}" ]] && return 1

  # Find a sample issue if none given. We pick the most-recently-updated
  # so the discovered workflow reflects the one actually used today.
  if [[ -z "$issue_key" ]]; then
    local jql="project=$JIRA_PROJECT ORDER BY updated DESC"
    local search
    search=$(jira_search "$jql" 1 "summary,status") || return 1
    issue_key=$(printf '%s' "$search" | python3 -c '
import json, sys
d = json.load(sys.stdin)
issues = d.get("issues") or []
if issues: print(issues[0].get("key",""))
')
  fi
  [[ -z "$issue_key" ]] && return 1

  # Pull the transitions available from the sample ticket's CURRENT state,
  # then pull statuses for the whole project to enumerate every possible
  # target — we need both because transitions depend on source state.
  local trs statuses
  trs=$(jira_get "/issue/$issue_key/transitions?expand=transitions.fields") || return 1
  statuses=$(jira_get "/project/$JIRA_PROJECT/statuses") || return 1

  local aliases
  aliases=$(_workflow_aliases_json)

  local workflow_file
  workflow_file=$(_workflow_file)
  mkdir -p "$(dirname "$workflow_file")"

  TRS="$trs" STATUSES="$statuses" ALIASES="$aliases" \
    PROJECT="${JIRA_PROJECT}" SAMPLE="$issue_key" OUT="$workflow_file" \
    python3 - <<'PY'
import datetime, json, os, re

trs       = json.loads(os.environ["TRS"])
statuses  = json.loads(os.environ["STATUSES"])
aliases   = json.loads(os.environ["ALIASES"])

# Build { status_name -> status_id } from the project statuses endpoint.
# Response is a list of issuetype buckets; union them.
all_statuses = {}
for issuetype_bucket in statuses or []:
    for s in (issuetype_bucket.get("statuses") or []):
        name = s.get("name") or ""
        sid  = s.get("id")   or ""
        if name:
            all_statuses[name] = sid

# Build [{id, name, to_name, to_id}, ...] from the transitions endpoint.
transitions = []
for t in (trs.get("transitions") or []):
    to = t.get("to") or {}
    transitions.append({
        "id":      t.get("id", ""),
        "name":    t.get("name", ""),
        "to_name": to.get("name", ""),
        "to_id":   to.get("id", ""),
    })

# Try to resolve each intent to a (transition_id, target_name) pair using
# the merged aliases. Match case-insensitively against BOTH transition name
# and target status name.
def resolve(intent_patterns):
    for pat in intent_patterns:
        rx = re.compile(pat, re.IGNORECASE)
        for t in transitions:
            if rx.search(t["name"]) or rx.search(t["to_name"]):
                return t
    return None

resolved = {}
for intent, patterns in aliases.items():
    hit = resolve(patterns)
    if hit:
        resolved[intent] = hit

output = {
    "discovered_at":  datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "project":        os.environ["PROJECT"],
    "sample_issue":   os.environ["SAMPLE"],
    "statuses":       all_statuses,
    "transitions":    transitions,
    "intents":        resolved,
}
with open(os.environ["OUT"], "w") as f:
    json.dump(output, f, indent=2)
# Surface unresolved intents so the caller can log them.
unresolved = sorted(set(aliases.keys()) - set(resolved.keys()))
if unresolved:
    print("UNRESOLVED:" + ",".join(unresolved))
PY
}

# workflow_resolve <intent> [from_status]
# Echo the transition id that should be used NOW. If a cache miss happens and
# the cache is older than the rate-limit, re-discover lazily.
workflow_resolve() {
  local intent="$1" from="${2:-}"
  local wf
  wf=$(_workflow_file)

  # If cache missing, try to discover once.
  if [[ ! -f "$wf" ]]; then
    workflow_discover >/dev/null 2>&1 || return 1
  fi

  [[ ! -f "$wf" ]] && return 1

  INTENT="$intent" FROM="$from" WF="$wf" python3 -c '
import json, os, sys
d = json.load(open(os.environ["WF"]))
intent = os.environ["INTENT"]
t = (d.get("intents") or {}).get(intent)
if t and t.get("id"):
    print(t["id"])
    sys.exit(0)
sys.exit(1)
' 2>/dev/null
}

# workflow_refresh [issueKey]
# Alias for workflow_discover that clears the cache first.
workflow_refresh() {
  local wf
  wf=$(_workflow_file)
  rm -f "$wf"
  workflow_discover "$@"
}

# workflow_transition <issueKey> <intent>
# Move a ticket using the dynamically-resolved transition. If the resolve
# misses, fall back to jira_transition_to with a best-guess status name so
# existing call sites keep working during the rollout.
workflow_transition() {
  local key="$1" intent="$2"
  [[ -z "$key" || -z "$intent" ]] && return 1

  local tid
  tid=$(workflow_resolve "$intent" 2>/dev/null)
  if [[ -n "$tid" ]]; then
    jira_post "/issue/$key/transitions" "{\"transition\":{\"id\":\"$tid\"}}" >/dev/null && return 0
  fi

  # Cache miss or transition not available from current status. Try a
  # rediscovery (rate-limited) — the sample ticket might have been in a
  # different state than $key when we first cached.
  local wf; wf=$(_workflow_file)
  local mtime_now=0
  if [[ -f "$wf" ]]; then
    mtime_now=$(stat -f "%m" "$wf" 2>/dev/null || echo 0)
    local now; now=$(date +%s)
    if (( now - mtime_now > _WORKFLOW_MIN_REFRESH_SECS )); then
      workflow_refresh "$key" >/dev/null 2>&1 || true
      tid=$(workflow_resolve "$intent" 2>/dev/null)
      if [[ -n "$tid" ]]; then
        jira_post "/issue/$key/transitions" "{\"transition\":{\"id\":\"$tid\"}}" >/dev/null && return 0
      fi
    fi
  fi

  # Fallback: hand off to the legacy name-substring matcher in lib/jira.sh.
  # Target names are the human-readable defaults — they cover most teams.
  local target=""
  case "$intent" in
    start)         target="in progress" ;;
    push_review)   target="code review" ;;
    after_approve) target="ready for qa" ;;
    done)          target="done" ;;
    block)         target="blocked" ;;
    unblock)       target="in progress" ;;
    *)             return 1 ;;
  esac
  jira_transition_to "$key" "$target"
}

# workflow_dump — human-readable summary for doctor.sh and bin/project.
workflow_dump() {
  local wf; wf=$(_workflow_file)
  if [[ ! -f "$wf" ]]; then
    echo "(workflow cache not yet populated; run workflow_discover)"
    return 1
  fi
  WF="$wf" python3 <<'PY'
import json, os
d = json.load(open(os.environ["WF"]))
print("project:       " + d.get("project", ""))
print("discovered_at: " + d.get("discovered_at", ""))
print("sample_issue:  " + d.get("sample_issue", ""))
print("statuses:      " + str(len(d.get("statuses") or {})))
print("transitions:   " + str(len(d.get("transitions") or [])))
print("")
print("resolved intents:")
intents = d.get("intents") or {}
if not intents:
    print("  (none resolved yet)")
else:
    w = max(len(k) for k in intents) + 2
    for k, t in sorted(intents.items()):
        line = "  %s -> [%s] %s -> %s" % (
            k.ljust(w),
            t.get("id", ""),
            t.get("name", ""),
            t.get("to_name", ""),
        )
        print(line)
PY
}

# workflow_unresolved — emit the list of semantic intents that discovery could
# NOT map to a transition for this project. Used by doctor/telegram to give
# actionable guidance ("add an alias for X in config.json").
# Prints one intent per line, or nothing if everything resolved.
workflow_unresolved() {
  local wf; wf=$(_workflow_file)
  [[ ! -f "$wf" ]] && return 1
  local aliases; aliases=$(_workflow_aliases_json)
  WF="$wf" ALIASES="$aliases" python3 - <<'PY'
import json, os
d = json.load(open(os.environ["WF"]))
aliases = json.loads(os.environ["ALIASES"])
resolved = set((d.get("intents") or {}).keys())
for intent in sorted(aliases.keys()):
    if intent not in resolved:
        print(intent)
PY
}

# workflow_explain_unresolved <intent>
# Emit a Markdown block the user can read in Telegram. Lists:
#   - the intent name and what it means
#   - the available statuses and transitions on this project
#   - the exact snippet to paste into config.json to fix it
workflow_explain_unresolved() {
  local intent="$1"
  local wf; wf=$(_workflow_file)
  [[ ! -f "$wf" ]] && { echo "_(workflow cache empty — run \`/workflow refresh\` first)_"; return 1; }

  INTENT="$intent" WF="$wf" python3 - <<'PY'
import json, os
intent = os.environ["INTENT"]
d = json.load(open(os.environ["WF"]))

meanings = {
    "start":         "move a New/To-Do ticket into active work",
    "push_review":   "send a completed ticket to Code Review",
    "after_approve": "advance from Code Review onwards (typically Ready for QA)",
    "done":          "mark the ticket closed / done",
    "block":         "mark the ticket blocked / needs-clarification",
    "unblock":       "move the ticket out of blocked back to active",
}

print(f"*Unresolved intent: `{intent}`*")
print(f"_({meanings.get(intent, 'custom intent')})_")
print("")
print("*Available transitions on this project:*")
for t in (d.get("transitions") or []):
    print(f"• `{t.get('name','')}` → `{t.get('to_name','')}`")

print("")
print("*How to fix:* add an alias to `config.json`:")
print("```json")
print(json.dumps({
    "projects": [{
        "id": d.get("project", "YOUR-PROJECT"),
        "workflow": {
            "aliases": {
                intent: ["^YOUR TRANSITION NAME HERE$"]
            }
        }
    }]
}, indent=2))
print("```")
print("Then: `/workflow refresh`")
PY
}
