#!/bin/bash
# scripts/tests/test_multi_project.sh
#
# End-to-end sanity test for the v0.3 multi-project shape:
#   1. cfg_project_list emits every id from projects[] in order.
#   2. cfg_project_activate <id> rebinds JIRA_PROJECT, TELEGRAM_CHAT_ID,
#      PROJECT_CACHE_DIR, GLOBAL_CACHE_DIR, WATCHER_STATE_FILE, ACTIVE_RUNS_FILE
#      and friends each time — i.e. re-activating really switches contexts.
#   3. Per-project overrides win over root-level defaults.
#   4. cfg_project_field <id> <path> reads from the right project block.
#
# Runs offline (no Jira/Telegram/GitLab network calls).

set -euo pipefail

SKILL_DIR="$HOME/.cursor/skills/autonomous-dev-agent"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

export CONFIG_FILE="$TMP/config.json"
export CACHE_DIR="$TMP/cache"
export SKILL_DIR

# Two projects: "alpha" inherits chat from root, "beta" overrides both
# the chat id AND the agent model.
cat > "$CONFIG_FILE" <<'JSON'
{
  "owner":   {"name": "Test User", "email": "t@example.com", "gitlabUsername": "tuser"},
  "chat":    {"kind": "telegram", "chatId": "root-chat-111"},
  "agent":   {"model": "root-model-x"},
  "defaultProject": "alpha",
  "projects": [
    {
      "id":   "alpha",
      "name": "Alpha Project",
      "tracker":      {"kind": "jira-cloud", "siteUrl": "https://a.example", "project": "ALP"},
      "repositories": ["alpha/web"]
    },
    {
      "id":   "beta",
      "name": "Beta Project",
      "tracker":      {"kind": "jira-cloud", "siteUrl": "https://b.example", "project": "BET"},
      "repositories": ["beta/api"],
      "chat":         {"chatId": "beta-chat-222", "tokenEnv": "BETA_BOT_TOKEN"},
      "agent":        {"model": "beta-model-y"}
    }
  ]
}
JSON

pass=0; fail=0
assert_eq() {
  local label="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then
    echo "  PASS $label"; pass=$((pass+1))
  else
    echo "  FAIL $label: want='$want' got='$got'"; fail=$((fail+1))
  fi
}

# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/env.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/cfg.sh"

# --- 1. project listing ---------------------------------------------------
# cfg_project_list emits ids on one line, space-separated.
ids=$(cfg_project_list)
assert_eq "cfg_project_list order" "alpha beta" "$ids"

# --- 2. activate alpha, snapshot env --------------------------------------
cfg_project_activate "alpha" >/dev/null
assert_eq "alpha JIRA_PROJECT"      "ALP"                        "$JIRA_PROJECT"
assert_eq "alpha TELEGRAM_CHAT_ID"  "root-chat-111"              "$TELEGRAM_CHAT_ID"
assert_eq "alpha AGENT_MODEL"       "root-model-x"               "$AGENT_MODEL"
assert_eq "alpha PROJECT_ID"        "alpha"                      "$PROJECT_ID"

alpha_state="$WATCHER_STATE_FILE"
alpha_runs="$ACTIVE_RUNS_FILE"
alpha_cache="$PROJECT_CACHE_DIR"

# --- 3. activate beta, confirm full rebind --------------------------------
cfg_project_activate "beta" >/dev/null
assert_eq "beta JIRA_PROJECT"       "BET"                        "$JIRA_PROJECT"
assert_eq "beta TELEGRAM_CHAT_ID"   "beta-chat-222"              "$TELEGRAM_CHAT_ID"
assert_eq "beta TELEGRAM_TOKEN_ENV" "BETA_BOT_TOKEN"             "$TELEGRAM_TOKEN_ENV"
assert_eq "beta AGENT_MODEL"        "beta-model-y"               "$AGENT_MODEL"
assert_eq "beta PROJECT_ID"         "beta"                       "$PROJECT_ID"

# Paths must have switched — if not, alpha's state files would be re-used
# for beta and ticket/pipeline state would leak across projects.
[[ "$WATCHER_STATE_FILE" != "$alpha_state" ]] \
  && echo "  PASS WATCHER_STATE_FILE pivoted" && pass=$((pass+1)) \
  || { echo "  FAIL WATCHER_STATE_FILE still '$WATCHER_STATE_FILE'"; fail=$((fail+1)); }

[[ "$ACTIVE_RUNS_FILE"   != "$alpha_runs"  ]] \
  && echo "  PASS ACTIVE_RUNS_FILE pivoted"  && pass=$((pass+1)) \
  || { echo "  FAIL ACTIVE_RUNS_FILE  still '$ACTIVE_RUNS_FILE'";  fail=$((fail+1)); }

[[ "$PROJECT_CACHE_DIR"  != "$alpha_cache" ]] \
  && echo "  PASS PROJECT_CACHE_DIR pivoted" && pass=$((pass+1)) \
  || { echo "  FAIL PROJECT_CACHE_DIR still '$PROJECT_CACHE_DIR'"; fail=$((fail+1)); }

# --- 4. re-activate alpha — ensure re-export actually happens -------------
cfg_project_activate "alpha" >/dev/null
assert_eq "alpha rebind JIRA_PROJECT"     "ALP"           "$JIRA_PROJECT"
assert_eq "alpha rebind TELEGRAM_CHAT_ID" "root-chat-111" "$TELEGRAM_CHAT_ID"
assert_eq "alpha rebind AGENT_MODEL"      "root-model-x"  "$AGENT_MODEL"
assert_eq "alpha rebind WATCHER_STATE"    "$alpha_state"  "$WATCHER_STATE_FILE"

# --- 5. cfg_project_field reads from the right block ----------------------
assert_eq "field alpha name"     "Alpha Project" "$(cfg_project_field alpha name)"
assert_eq "field beta  name"     "Beta Project"  "$(cfg_project_field beta  name)"
assert_eq "field alpha tracker"  "ALP"           "$(cfg_project_field alpha 'tracker.project')"
assert_eq "field beta  tracker"  "BET"           "$(cfg_project_field beta  'tracker.project')"
assert_eq "field beta  chat"     "beta-chat-222" "$(cfg_project_field beta  'chat.chatId')"

# --- 6. default project is the one marked in config -----------------------
assert_eq "cfg_project_default"  "alpha"         "$(cfg_project_default)"

echo
echo "multi-project: $pass passed, $fail failed"
[[ $fail -eq 0 ]] || exit 1
