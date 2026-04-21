#!/bin/bash
# test_jira_lib.sh — verify the lib handles auth-missing cleanly and that
# jira_transition_to is idempotent when status already matches.
set -euo pipefail
source "$HOME/.cursor/skills/autonomous-dev-agent/scripts/lib/env.sh"

# Sub-shell to avoid leaking unset into the parent env.
(
  # Force unset credentials: lib should return 1 from jira_api cleanly.
  unset ATLASSIAN_EMAIL ATLASSIAN_API_TOKEN
  source "$HOME/.cursor/skills/autonomous-dev-agent/scripts/lib/jira.sh"

  if jira_get "/issue/PROJ-1" >/dev/null 2>&1; then
    echo "jira_api should fail without creds"; exit 1
  fi

  # current_status returns empty + non-zero
  if jira_current_status PROJ-1 2>/dev/null | grep -q .; then
    echo "current_status should be empty without creds"; exit 1
  fi
)

# Stubbed jira_get / jira_post to test idempotent transition logic.
(
  source "$HOME/.cursor/skills/autonomous-dev-agent/scripts/lib/jira.sh"

  # Simulate ticket already in the target status → transition_to returns 0
  # without issuing the POST.
  FAKE_STATUS="Work In Progress"
  POST_CALLED=0
  jira_get() {
    case "$1" in
      */issue/*?fields=status)
        printf '{"fields":{"status":{"name":"%s"}}}' "$FAKE_STATUS" ;;
      */issue/*/transitions)
        echo '{"transitions":[{"id":"11","name":"In Progress","to":{"name":"Work In Progress"}}]}' ;;
      *) echo "{}" ;;
    esac
  }
  jira_post() { POST_CALLED=1; echo '{}'; }

  if ! jira_transition_to PROJ-1 "in progress"; then
    echo "transition_to should succeed as no-op"; exit 1
  fi
  if (( POST_CALLED != 0 )); then
    echo "transition_to made a POST call even though already in target"; exit 1
  fi

  # Now simulate being in To Do → must POST.
  FAKE_STATUS="To Do"
  POST_CALLED=0
  if ! jira_transition_to PROJ-1 "in progress"; then
    echo "transition_to should succeed when moving"; exit 1
  fi
  if (( POST_CALLED != 1 )); then
    echo "transition_to did not POST when moving"; exit 1
  fi
)

echo "all jira_lib assertions passed"
