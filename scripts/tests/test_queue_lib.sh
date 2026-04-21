#!/bin/bash
# scripts/tests/test_queue_lib.sh
#
# Offline test for lib/queue.sh. Asserts priority weighting and age factor
# behaviour. Doesn't call any tracker — only queue_score_ticket is covered.

set -uo pipefail
SKILL_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export SKILL_DIR

# Stub cfg_get so queue_score_ticket's project-weight lookup resolves.
cfg_get() {
  # First arg: .projects[]|select(.id=="x")|.queueWeight
  # Second arg: default
  echo "${2:-1.0}"
}
export -f cfg_get

# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/queue.sh"

fail=0
report() { echo "FAIL: $1"; fail=1; }

# 1) Monotonicity across priorities (high > medium > low) for the same age.
s_high=$(queue_score_ticket "p" "high"   "2026-04-16T10:00:00Z")
s_med=$( queue_score_ticket "p" "medium" "2026-04-16T10:00:00Z")
s_low=$( queue_score_ticket "p" "low"    "2026-04-16T10:00:00Z")

is_gt() { python3 -c "import sys; sys.exit(0 if float(sys.argv[1])>float(sys.argv[2]) else 1)" "$1" "$2"; }
is_gt "$s_high" "$s_med" || report "expected high > medium, got $s_high vs $s_med"
is_gt "$s_med"  "$s_low" || report "expected medium > low, got $s_med vs $s_low"

# 2) Older ticket scores higher than newer at the same priority.
s_old=$(queue_score_ticket "p" "medium" "2026-03-16T10:00:00Z")  # ~1 month ago
s_new=$(queue_score_ticket "p" "medium" "2026-04-15T10:00:00Z")  # yesterday
is_gt "$s_old" "$s_new" || report "expected older score > newer, got $s_old vs $s_new"

# 3) Unknown priority name maps to medium.
s_unknown=$(queue_score_ticket "p" "FooBar" "2026-04-16T10:00:00Z")
[[ "$s_unknown" == "$s_med" ]] || report "unknown priority should be medium, got $s_unknown vs $s_med"

# 4) queue_fair_pick with empty input returns empty.
unset -f cfg_project_list 2>/dev/null || true
cfg_project_list() { :; }
export -f cfg_project_list
out=$(queue_fair_pick 5)
[[ -z "$out" ]] || report "fair_pick on no projects should emit nothing, got: $out"

if [[ $fail -eq 0 ]]; then
  echo "OK test_queue_lib"
  exit 0
fi
exit 1
