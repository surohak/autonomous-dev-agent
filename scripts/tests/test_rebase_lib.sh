#!/bin/bash
# scripts/tests/test_rebase_lib.sh
#
# Offline test for lib/rebase.sh using temporary real git repos. Verifies:
#   1. rebase_check reports no drift on a fresh fork.
#   2. rebase_check reports drift + safe=true after adding a non-overlapping commit on main.
#   3. rebase_apply succeeds on that safe drift and pushes to origin.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export SKILL_DIR

# Stub cfg_get so the auto-resolve lookup works without config.json.
cfg_get() { echo "${2:-}"; }
export -f cfg_get

# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/rebase.sh"

fail=0
report() { echo "FAIL: $1"; fail=1; }

command -v git >/dev/null 2>&1 || { echo "skip: git missing"; exit 0; }

# --- set up a bare "origin" + two working clones --------------------------
# TEST_TMP is set by scripts/tests/run-tests.sh; honour it to avoid putting
# repo state in places that might be read-only on CI. Fall back to mktemp
# for ad-hoc local runs.
tmp="${TEST_TMP:-}"
if [[ -z "$tmp" ]]; then
  tmp=$(mktemp -d -t rebase-test.XXXXXX) || { echo "skip: cannot create tmp dir"; exit 0; }
else
  tmp="$tmp/rebase-$$"
  mkdir -p "$tmp"
fi
# Sandboxed environments (Cursor's runner) can't create .git/hooks here —
# skip rather than spam stderr with a hundred 'not a git repository' lines.
if ! ( git init --quiet "$tmp/probe" 2>/dev/null && rm -rf "$tmp/probe" ); then
  echo "skip: git init blocked in $tmp (sandboxed filesystem)"
  rm -rf "$tmp"
  exit 0
fi
trap 'rm -rf "$tmp"' EXIT
ORIGIN="$tmp/origin.git"
git init --quiet --bare "$ORIGIN"

WORK="$tmp/work"
git clone --quiet "$ORIGIN" "$WORK"
(
  cd "$WORK"
  git config user.email "t@t"
  git config user.name "Tester"
  echo "v1" > file.txt
  git add file.txt
  git commit -m "init" --quiet
  git push --quiet origin master >/dev/null 2>&1 || git push --quiet origin main >/dev/null 2>&1 || {
    git branch -M main
    git push --quiet origin main
  }
  # Make sure we're on main.
  git checkout -b feature --quiet
  echo "feature change" >> feature.txt
  git add feature.txt
  git commit -m "feature" --quiet
  git push --quiet -u origin feature
)

# 1) No drift initially.
out=$(rebase_check "$WORK" feature main)
drift=$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("drift"))')
[[ "$drift" == "False" ]] || report "expected no drift, got: $out"

# 2) Add a non-conflicting commit to main; expect drift=true safe=true.
(
  cd "$WORK"
  git checkout main --quiet
  echo "unrelated" > unrelated.txt
  git add unrelated.txt
  git commit -m "main change" --quiet
  git push --quiet origin main
)

out=$(rebase_check "$WORK" feature main)
drift=$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("drift"))')
safe=$( printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("safe",False))')
[[ "$drift" == "True" ]] || report "expected drift after main commit, got: $out"
[[ "$safe"  == "True" ]] || report "expected safe=true (no overlap), got: $out"

# 3) rebase_apply should succeed.
out=$(rebase_apply "$WORK" feature main)
applied=$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("applied"))')
[[ "$applied" == "True" ]] || report "expected applied=true, got: $out"

# 4) Introduce a HARD conflict — same line on both branches — expect safe=false.
(
  cd "$WORK"
  git fetch --quiet origin
  git checkout feature --quiet
  git reset --hard origin/feature --quiet
  echo "feature-edits-file" > file.txt
  git add file.txt
  git commit -m "feature edits file" --quiet
  git push --force --quiet origin feature

  git checkout main --quiet
  git reset --hard origin/main --quiet
  echo "main-edits-file"  > file.txt
  git add file.txt
  git commit -m "main edits file" --quiet
  git push --quiet origin main
)

out=$(rebase_check "$WORK" feature main)
safe=$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("safe",False))')
manual=$(printf '%s' "$out" | python3 -c 'import json,sys;print(len(json.load(sys.stdin).get("manual",[])))')
[[ "$safe" == "False" ]] || report "expected safe=false on file.txt overlap, got: $out"
[[ "$manual" -gt 0 ]]    || report "expected manual conflicts > 0, got: $out"

if [[ $fail -eq 0 ]]; then
  echo "OK test_rebase_lib"
  exit 0
fi
exit 1
