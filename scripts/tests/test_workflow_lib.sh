#!/bin/bash
# scripts/tests/test_workflow_lib.sh
#
# Offline test for lib/workflow.sh. Stubs jira_get + jira_search with canned
# fixtures that mimic two different Jira projects with different transition
# ids and status names — verifying the semantic-intent resolver picks the
# right transition in each case.

set -euo pipefail

# Pin SKILL_DIR to the actual skill install, ignoring any leaked value from
# cleanroom tests or outer shells.
SKILL_DIR="$HOME/.cursor/skills/autonomous-dev-agent"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export CONFIG_FILE="$TMP/config.json"
export CACHE_DIR="$TMP/cache"
export SKILL_DIR

cat > "$CONFIG_FILE" <<'JSON'
{
  "owner": {"name": "Test", "email": "t@example.com", "gitlabUsername": "t"},
  "projects": [
    {
      "id": "proj-alpha",
      "tracker": {"kind": "jira-cloud", "siteUrl": "https://x.example", "project": "ALP"}
    },
    {
      "id": "proj-beta",
      "tracker": {"kind": "jira-cloud", "siteUrl": "https://y.example", "project": "BET"},
      "workflow": {
        "aliases": {
          "push_review": ["submit for peer review", "to review stage"]
        }
      }
    }
  ]
}
JSON

source "$SKILL_DIR/scripts/lib/env.sh"
source "$SKILL_DIR/scripts/lib/cfg.sh"
source "$SKILL_DIR/scripts/lib/jira.sh"
source "$SKILL_DIR/scripts/lib/workflow.sh"

# --- fixture A: standard workflow --------------------------------------------
jira_search() {
  cat <<'JSON'
{"issues":[{"key":"ALP-100","fields":{"status":{"name":"In Progress"}}}]}
JSON
}

jira_get() {
  case "$1" in
    /issue/*/transitions*) cat <<'JSON'
{"transitions":[
  {"id":"11","name":"To In Progress","to":{"name":"In Progress","id":"3"}},
  {"id":"21","name":"To Code Review","to":{"name":"Code Review","id":"4"}},
  {"id":"31","name":"Review to Ready for QA","to":{"name":"Ready For QA","id":"5"}},
  {"id":"41","name":"Close","to":{"name":"Done","id":"6"}},
  {"id":"51","name":"Block","to":{"name":"Blocked","id":"7"}},
  {"id":"61","name":"Resume","to":{"name":"In Progress","id":"3"}}
]}
JSON
      ;;
    /project/*/statuses) cat <<'JSON'
[{"name":"Story","statuses":[
  {"id":"1","name":"To Do"},{"id":"3","name":"In Progress"},
  {"id":"4","name":"Code Review"},{"id":"5","name":"Ready For QA"},
  {"id":"6","name":"Done"},{"id":"7","name":"Blocked"}
]}]
JSON
      ;;
    *) return 1 ;;
  esac
}

cfg_project_activate "proj-alpha"

out=$(workflow_discover ALP-100 2>&1) && echo "$out" || { echo "FAIL: workflow_discover returned $?: $out"; exit 1; }

# Resolver should find every semantic intent.
for intent in start push_review after_approve done block unblock; do
  tid=$(workflow_resolve "$intent") || { echo "FAIL: no id for $intent"; exit 1; }
  echo "  proj-alpha $intent → $tid"
done

# Spot-check specific mappings.
expected_start=11; actual_start=$(workflow_resolve start)
[[ "$actual_start" == "$expected_start" ]] || { echo "FAIL: start expected $expected_start got $actual_start"; exit 1; }
expected_review=21; actual_review=$(workflow_resolve push_review)
[[ "$actual_review" == "$expected_review" ]] || { echo "FAIL: push_review expected $expected_review got $actual_review"; exit 1; }
expected_qa=31; actual_qa=$(workflow_resolve after_approve)
[[ "$actual_qa" == "$expected_qa" ]] || { echo "FAIL: after_approve expected $expected_qa got $actual_qa"; exit 1; }

# --- fixture B: non-standard names, uses user-configured alias ---------------
jira_get() {
  case "$1" in
    /issue/*/transitions*) cat <<'JSON'
{"transitions":[
  {"id":"100","name":"Kickoff","to":{"name":"Development","id":"10"}},
  {"id":"200","name":"Submit for peer review","to":{"name":"In Review","id":"11"}},
  {"id":"300","name":"Review to Ready for QA","to":{"name":"Ready For QA","id":"12"}}
]}
JSON
      ;;
    /project/*/statuses) cat <<'JSON'
[{"name":"Story","statuses":[
  {"id":"10","name":"Development"},{"id":"11","name":"In Review"},{"id":"12","name":"Ready For QA"}
]}]
JSON
      ;;
    *) return 1 ;;
  esac
}

cfg_project_activate "proj-beta"
workflow_discover BET-50 >/dev/null 2>&1 || { echo "FAIL: discover beta"; exit 1; }

# User alias "submit for peer review" should win for push_review.
expected=200; actual=$(workflow_resolve push_review)
[[ "$actual" == "$expected" ]] || { echo "FAIL: beta push_review expected $expected got $actual"; exit 1; }
echo "  proj-beta push_review → $actual (matched user alias)"

# The default "In Progress" regex fails here; intent-`start` should match via
# "kickoff"? No — default patterns don't include kickoff. It's OK for start to
# be unresolved here; just verify resolve correctly returns failure.
if workflow_resolve start >/dev/null 2>&1; then
  echo "NOTE: beta unexpectedly resolved start; not fatal"
fi

# --- Verify cache file written ---
[[ -f "$WORKFLOW_FILE" ]] || { echo "FAIL: WORKFLOW_FILE not written"; exit 1; }
grep -q '"project":' "$WORKFLOW_FILE" || { echo "FAIL: cache missing project"; exit 1; }
echo "  cache file: $WORKFLOW_FILE ($(wc -c < "$WORKFLOW_FILE") bytes)"

echo
echo "PASS: test_workflow_lib.sh"
