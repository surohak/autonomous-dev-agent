#!/bin/bash
# test_timegate.sh — in_work_hours respects overrides, snooze file is honored.
set -euo pipefail
source "$HOME/.cursor/skills/autonomous-dev-agent/scripts/lib/env.sh"
export CACHE_DIR="$TEST_TMP/cache"
mkdir -p "$CACHE_DIR"

# Force overrides before sourcing
(
  export WORK_HOURS_START=0
  export WORK_HOURS_END=24
  export WORK_TZ="UTC"
  source "$HOME/.cursor/skills/autonomous-dev-agent/scripts/lib/timegate.sh"
  in_work_hours || { echo "expected YES with 0..24"; exit 1; }
)

(
  export WORK_HOURS_START=0
  export WORK_HOURS_END=0   # empty window
  export WORK_TZ="UTC"
  source "$HOME/.cursor/skills/autonomous-dev-agent/scripts/lib/timegate.sh"
  if in_work_hours; then
    echo "expected NO with 0..0 empty window"; exit 1
  fi
)

# snooze-until in the past → not snoozed
(
  echo "1" > "$CACHE_DIR/watcher-snoozed.until"
  source "$HOME/.cursor/skills/autonomous-dev-agent/scripts/lib/timegate.sh"
  if snoozed_now; then
    echo "expected NOT snoozed (until=1)"; exit 1
  fi
)

# snooze-until in the future → snoozed
(
  future=$(( $(date +%s) + 600 ))
  echo "$future" > "$CACHE_DIR/watcher-snoozed.until"
  source "$HOME/.cursor/skills/autonomous-dev-agent/scripts/lib/timegate.sh"
  snoozed_now || { echo "expected snoozed"; exit 1; }
)

echo "timegate OK"
