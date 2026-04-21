#!/bin/bash
# test_prompt_lib.sh — prompt_render substitutes tokens, leaves non-token
# text untouched, computes derived tokens (encoded project paths, example
# ticket key), and fails loudly on missing files.

set -euo pipefail
source "$HOME/.cursor/skills/autonomous-dev-agent/scripts/lib/env.sh"

# We source cfg.sh indirectly so the real config exports flow through; that's
# the same behaviour prompt_render sees at runtime.
source "$HOME/.cursor/skills/autonomous-dev-agent/scripts/lib/cfg.sh"
source "$HOME/.cursor/skills/autonomous-dev-agent/scripts/lib/prompt.sh"

# 1) Token substitution on a controlled fixture — zero tokens should leak.
TPL="$TEST_TMP/fixture.md"
cat > "$TPL" <<'TPL'
owner: {{OWNER_NAME}} <{{OWNER_EMAIL}}>
jira: {{JIRA_SITE}}/browse/{{TICKET_EXAMPLE_KEY}}
project encoded: {{SSR_GITLAB_PROJECT_ENCODED}}
regex: {{TICKET_KEY_PATTERN}}
non-token: plain {not-a-token} text
TPL

out="$(prompt_render "$TPL")"
echo "$out" | grep -q "{{" && { echo "FAIL: unrendered tokens in output"; echo "$out"; exit 1; }
echo "$out" | grep -q "plain {not-a-token} text" || { echo "FAIL: non-token text mangled"; echo "$out"; exit 1; }
# Ticket example key must include a number, i.e. not just "-123"
echo "$out" | grep -qE "browse/[A-Z]+-123" || { echo "FAIL: TICKET_EXAMPLE_KEY didn't render"; echo "$out"; exit 1; }
# Encoded project path should have %2F somewhere (a GitLab path has at least one /)
if [[ -n "$SSR_PROJECT" ]]; then
  echo "$out" | grep -q "%2F" || { echo "FAIL: SSR_GITLAB_PROJECT_ENCODED not URL-encoded"; echo "$out"; exit 1; }
fi

# 2) Missing file returns non-zero.
if prompt_render "$TEST_TMP/does-not-exist.md" >/dev/null 2>&1; then
  echo "FAIL: prompt_render returned 0 on missing file"; exit 1
fi

# 3) All real prompts render with zero token leaks — guards against adding new
#    tokens to a prompt without teaching prompt_render about them.
for f in "$HOME/.cursor/skills/autonomous-dev-agent/prompts"/*.md; do
  leaks=$(prompt_render "$f" | grep -oE "\{\{[A-Z_]+\}\}" || true)
  if [[ -n "$leaks" ]]; then
    echo "FAIL: unrendered tokens in $f: $leaks"; exit 1
  fi
done

echo "PASS test_prompt_lib.sh"
