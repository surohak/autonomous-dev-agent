#!/bin/bash
# scripts/tests/test_chat_override.sh
#
# Verifies per-project Telegram bot-token + chat-id override behaviour.
#
# Scenarios:
#   1. Project omits chat → inherits root-level chatId + tokenEnv.
#   2. Project sets chat.chatId   → override wins, tokenEnv still inherited.
#   3. Project sets chat.tokenEnv → TELEGRAM_BOT_TOKEN resolves to that env var.
#   4. Two projects pointing at the same tokenEnv share ONE telegram daemon;
#      projects with distinct tokenEnv trigger distinct daemons. We check this
#      by counting distinct values of TELEGRAM_TOKEN_ENV across all projects.
#   5. TG_OFFSET_FILE is scoped per-tokenEnv (hashed suffix) so offsets don't race.

set -euo pipefail

SKILL_DIR="$HOME/.cursor/skills/autonomous-dev-agent"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

export CONFIG_FILE="$TMP/config.json"
export CACHE_DIR="$TMP/cache"
export SKILL_DIR
# Neutralise the real install's secrets.env so it can't overwrite the test
# tokens we export below.
export SECRETS_FILE="$TMP/secrets.env"
: > "$SECRETS_FILE"

# Three projects:
#  - "a" inherits everything
#  - "b" overrides chatId only
#  - "c" overrides tokenEnv (distinct bot)
#  - "d" reuses tokenEnv from "c" (should NOT cause a second daemon)
cat > "$CONFIG_FILE" <<'JSON'
{
  "owner": {"name": "Test", "email": "t@example.com", "gitlabUsername": "t"},
  "chat":  {"kind": "telegram", "chatId": "root-chat", "tokenEnv": "TELEGRAM_BOT_TOKEN"},
  "projects": [
    {"id": "a", "tracker": {"project": "A"}},
    {"id": "b", "tracker": {"project": "B"},
                "chat":    {"chatId": "b-chat"}},
    {"id": "c", "tracker": {"project": "C"},
                "chat":    {"chatId": "c-chat", "tokenEnv": "SIDE_BOT_TOKEN"}},
    {"id": "d", "tracker": {"project": "D"},
                "chat":    {"chatId": "d-chat", "tokenEnv": "SIDE_BOT_TOKEN"}}
  ]
}
JSON

# Seed the "side" bot token so TELEGRAM_BOT_TOKEN resolves to it on c/d.
export TELEGRAM_BOT_TOKEN="main-bot-000"
export SIDE_BOT_TOKEN="side-bot-999"

pass=0; fail=0
assert_eq() {
  local label="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then echo "  PASS $label"; pass=$((pass+1)); else echo "  FAIL $label: want='$want' got='$got'"; fail=$((fail+1)); fi
}

# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/env.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/cfg.sh"

# --- 1. inherit ----------------------------------------------------------
cfg_project_activate a >/dev/null
assert_eq "a inherits chatId"       "root-chat"          "$TELEGRAM_CHAT_ID"
assert_eq "a inherits tokenEnv"     "TELEGRAM_BOT_TOKEN" "$TELEGRAM_TOKEN_ENV"
assert_eq "a resolves token"        "main-bot-000"       "$TELEGRAM_BOT_TOKEN"
a_offset="$TG_OFFSET_FILE"

# --- 2. chatId override only ---------------------------------------------
cfg_project_activate b >/dev/null
assert_eq "b overrides chatId"      "b-chat"             "$TELEGRAM_CHAT_ID"
assert_eq "b still inherits tokenEnv" "TELEGRAM_BOT_TOKEN" "$TELEGRAM_TOKEN_ENV"
assert_eq "b shares token w/ a"     "main-bot-000"       "$TELEGRAM_BOT_TOKEN"
# a + b share tokenEnv so they share offset file.
assert_eq "b shares offset w/ a"    "$a_offset"          "$TG_OFFSET_FILE"

# --- 3. distinct tokenEnv -> distinct bot + distinct offset --------------
cfg_project_activate c >/dev/null
assert_eq "c overrides tokenEnv"    "SIDE_BOT_TOKEN"     "$TELEGRAM_TOKEN_ENV"
assert_eq "c resolves side token"   "side-bot-999"       "$TELEGRAM_BOT_TOKEN"
assert_eq "c overrides chatId"      "c-chat"             "$TELEGRAM_CHAT_ID"
[[ "$TG_OFFSET_FILE" != "$a_offset" ]] \
  && { echo "  PASS c has distinct offset file"; pass=$((pass+1)); } \
  || { echo "  FAIL c offset file did not pivot"; fail=$((fail+1)); }
c_offset="$TG_OFFSET_FILE"

# --- 4. project d shares c's tokenEnv -> same offset ---------------------
cfg_project_activate d >/dev/null
assert_eq "d shares tokenEnv w/ c"  "SIDE_BOT_TOKEN"     "$TELEGRAM_TOKEN_ENV"
assert_eq "d shares offset file w/ c" "$c_offset"        "$TG_OFFSET_FILE"
assert_eq "d overrides chatId"      "d-chat"             "$TELEGRAM_CHAT_ID"

# --- 5. distinct daemon count ---------------------------------------------
# install.sh groups by tokenEnv and generates one LaunchAgent per group; count
# distinct values across the 4 projects — should be 2 (main + side).
distinct=$(python3 - "$CONFIG_FILE" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
root_env = (cfg.get("chat") or {}).get("tokenEnv", "TELEGRAM_BOT_TOKEN")
envs = set()
for p in cfg["projects"]:
    envs.add(((p.get("chat") or {}).get("tokenEnv")) or root_env)
print(len(envs))
PY
)
assert_eq "distinct bot daemons"    "2"                  "$distinct"

echo
echo "chat override: $pass passed, $fail failed"
[[ $fail -eq 0 ]] || exit 1
