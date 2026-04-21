#!/bin/bash
# scripts/tests/run-tests.sh
#
# Zero-dependency test runner. Each test_*.sh file is a bash script that
# returns 0 on pass, non-zero on fail. Output is aggregated.
#
# Usage:
#   bash scripts/tests/run-tests.sh [filter]
#
# If `filter` is given, only tests whose filename contains it are run.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
FILTER="${1:-}"

# Isolate tests from the real state — every test should use this prefix.
export TEST_TMP="$(mktemp -d -t devagent-tests.XXXXXX)"
trap 'rm -rf "$TEST_TMP"' EXIT

echo "=== autonomous-dev-agent tests ==="
echo "tmp: $TEST_TMP"
echo

pass=0; fail=0; failed=()
for t in "$TESTS_DIR"/test_*.sh; do
  name=$(basename "$t")
  if [[ -n "$FILTER" && "$name" != *"$FILTER"* ]]; then
    continue
  fi
  printf '  %s ... ' "$name"
  if bash "$t" >/tmp/test-$$.out 2>&1; then
    printf 'PASS\n'
    pass=$((pass+1))
  else
    printf 'FAIL\n'
    fail=$((fail+1))
    failed+=("$name")
    sed 's/^/      | /' /tmp/test-$$.out
  fi
  rm -f /tmp/test-$$.out
done

echo
echo "Passed: $pass   Failed: $fail"
if (( fail > 0 )); then
  for n in "${failed[@]}"; do echo "  - $n"; done
  exit 1
fi
