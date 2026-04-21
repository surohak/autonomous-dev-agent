#!/bin/bash
# Offline test for scripts/lib/_cfg_lint.py.
# Builds a handful of configs and checks that the linter flags the right
# issues with the right levels.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LINT="$SKILL_DIR/scripts/lib/_cfg_lint.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Helper: expect the given regex to match (or NOT match) against the linter's
# stdout for the given config snippet.
assert_match() {
  local label="$1" cfg_body="$2" expect="$3"
  local f="$TMP/$label.json"
  echo "$cfg_body" > "$f"
  local out
  out=$(CFG="$f" SECRETS_FILE="$TMP/nope.env" python3 "$LINT" 2>&1 || true)
  if echo "$out" | grep -qE "$expect"; then
    echo "PASS $label"
  else
    echo "FAIL $label"
    echo "--- config:"; cat "$f"
    echo "--- output:"; echo "$out"
    echo "--- expected match: $expect"
    exit 1
  fi
}

assert_no_match() {
  local label="$1" cfg_body="$2" forbid="$3"
  local f="$TMP/$label.json"
  echo "$cfg_body" > "$f"
  local out
  out=$(CFG="$f" SECRETS_FILE="$TMP/nope.env" python3 "$LINT" 2>&1 || true)
  if echo "$out" | grep -qE "$forbid"; then
    echo "FAIL $label (unexpected: $forbid)"
    echo "--- output:"; echo "$out"
    exit 1
  fi
  echo "PASS $label"
}

# 1. Valid minimal v0.3 config — no issues
assert_no_match "valid-minimal" '{
  "projects": [
    { "id": "alpha", "tracker": { "kind": "jira-cloud", "siteUrl": "https://x.atlassian.net", "project": "AL" } }
  ]
}' '^ERROR'

# 2. Duplicate id → ERROR
assert_match "duplicate-id" '{
  "projects": [
    { "id": "alpha" },
    { "id": "alpha" }
  ]
}' 'duplicate project id'

# 3. Invalid id → ERROR
assert_match "bad-id" '{
  "projects": [ { "id": "has spaces" } ]
}' "'has spaces' must match"

# 4. Unknown tracker kind → WARN
assert_match "unknown-tracker" '{
  "projects": [
    { "id": "a", "tracker": { "kind": "notion" } }
  ]
}' "tracker.kind='notion' is not a known driver"

# 5. Unknown host kind → WARN
assert_match "unknown-host" '{
  "projects": [
    { "id": "a", "host": { "kind": "gitea" } }
  ]
}' "host.kind='gitea' is not a known driver"

# 6. defaultProject points to non-existent project → ERROR
assert_match "bad-default" '{
  "defaultProject": "ghost",
  "projects": [ { "id": "a" } ]
}' 'defaultProject.*does not match'

# 7. Unknown workflow intent → WARN
assert_match "bad-intent" '{
  "projects": [
    { "id": "a", "workflow": { "aliases": { "teleport": ["^x$"] } } }
  ]
}' 'teleport.*unknown intent'

# 8. Aliases list with non-string → ERROR
assert_match "bad-alias-type" '{
  "projects": [
    { "id": "a", "workflow": { "aliases": { "start": [42] } } }
  ]
}' 'must be a list of regex strings'

# 9. Empty projects array → ERROR
assert_match "empty-projects" '{ "projects": [] }' 'projects is empty'

# 10. v0.2 shape → INFO (not ERROR)
assert_match "v02-fallback" '{
  "atlassian": { "siteUrl": "https://x.atlassian.net", "project": "AL" }
}' '^INFO'

# 11. Missing chat.tokenEnv reference → WARN (when secrets.env exists w/o token)
echo "export UNRELATED=1" > "$TMP/secrets.env"
cfg="$TMP/chat-missing.json"
echo '{
  "projects": [
    { "id": "a", "chat": { "tokenEnv": "BOT_THAT_DOES_NOT_EXIST" } }
  ]
}' > "$cfg"
out=$(CFG="$cfg" SECRETS_FILE="$TMP/secrets.env" python3 "$LINT" 2>&1 || true)
echo "$out" | grep -qE "chat.tokenEnv='BOT_THAT_DOES_NOT_EXIST' not found" \
  || { echo "FAIL chat-missing"; echo "$out"; exit 1; }
echo "PASS chat-missing-token"

# 12. Malformed JSON → ERROR not a crash
cfg="$TMP/bad.json"
echo '{ this is not json' > "$cfg"
out=$(CFG="$cfg" SECRETS_FILE="$TMP/nope.env" python3 "$LINT" 2>&1 || true)
echo "$out" | grep -qE '^ERROR.*invalid JSON' \
  || { echo "FAIL bad-json"; echo "$out"; exit 1; }
echo "PASS malformed-json"

echo "OK test_cfg_lint"
