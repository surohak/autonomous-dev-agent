#!/bin/bash
# scripts/tests/test_lessons.sh
#
# Verifies that prompt_render correctly reads lessons.md from
# PROJECT_CACHE_DIR and substitutes the last N into {{RECENT_LESSONS}}.

set -uo pipefail
SKILL_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export SKILL_DIR

# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/prompt.sh"

tmp=$(mktemp -d -t lessons-test.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

export PROJECT_CACHE_DIR="$tmp/cache"
mkdir -p "$PROJECT_CACHE_DIR"

# Seed a lessons.md with 12 bullets + a non-bullet line (should be ignored).
{
  for i in $(seq 1 12); do echo "- 2026-04-${i}: lesson number $i"; done
  echo "this is not a bullet"
} > "$PROJECT_CACHE_DIR/lessons.md"

tpl="$tmp/template.md"
cat > "$tpl" <<'TPL'
Past lessons:
{{RECENT_LESSONS}}
End.
TPL

fail=0
report() { echo "FAIL: $1"; fail=1; }

# Default LESSONS_MAX=8 → last 8 bullets.
out=$(LESSONS_MAX=8 prompt_render "$tpl")
count=$(printf '%s\n' "$out" | grep -c '^- 2026-04-' || echo 0)
[[ "$count" == "8" ]] || report "expected 8 lessons, got $count; output:
$out"

# Last one should be the newest (lesson number 12).
printf '%s' "$out" | grep -q 'lesson number 12' || report "newest bullet missing"
# First shown should be lesson 5 (12-8+1).
printf '%s' "$out" | grep -q 'lesson number 5' || report "oldest kept bullet (5) missing"

# Non-bullet line should not leak through.
printf '%s' "$out" | grep -q 'this is not a bullet' && report "non-bullet line leaked"

# LESSONS_MAX=2 → only last 2.
out2=$(LESSONS_MAX=2 prompt_render "$tpl")
count2=$(printf '%s\n' "$out2" | grep -c '^- 2026-04-' || echo 0)
[[ "$count2" == "2" ]] || report "expected 2 lessons with LESSONS_MAX=2, got $count2"

# No lessons.md → RECENT_LESSONS renders empty.
rm -f "$PROJECT_CACHE_DIR/lessons.md"
out3=$(prompt_render "$tpl")
printf '%s' "$out3" | grep -q '^- ' && report "no lessons.md should produce empty list"

if [[ $fail -eq 0 ]]; then
  echo "OK test_lessons"
  exit 0
fi
exit 1
