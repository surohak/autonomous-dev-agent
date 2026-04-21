#!/bin/bash
# test_timelog.sh — tl_emit appends well-formed JSONL, survives concurrency,
# and honours the TIME_LOG_ENABLED kill switch.

set -euo pipefail
source "$HOME/.cursor/skills/autonomous-dev-agent/scripts/lib/env.sh"

# Isolate the log file in the test tmp so we don't touch real state.
export TIME_LOG_FILE="$TEST_TMP/time-log.jsonl"
export TIME_LOG_ENABLED=1

source "$HOME/.cursor/skills/autonomous-dev-agent/scripts/lib/timelog.sh"

# 1) Basic shape — event has ts+type and caller-supplied keys, types coerced.
tl_emit agent_start ticket=UA-100 run_id=r_abc mode=dev pid=42 manual=1
[[ -s "$TIME_LOG_FILE" ]] || { echo "log file not created"; exit 1; }

python3 - <<PY
import json, sys
with open("$TIME_LOG_FILE") as fh:
    lines = [json.loads(l) for l in fh if l.strip()]
assert len(lines) == 1, lines
e = lines[0]
assert e["type"] == "agent_start", e
assert e["ticket"] == "UA-100", e
assert e["run_id"] == "r_abc", e
assert e["mode"] == "dev", e
assert e["pid"] == 42, e              # int coerced
assert e["manual"] == 1, e            # int, not bool — value "1"
assert e["ts"].endswith("Z"), e       # ISO 8601 UTC
assert len(e["ts"]) == 20, e
PY

# 2) Boolean coercion.
tl_emit review_posted ticket=UA-100 mr_iid=2022 author_is_me=true round=1

python3 - <<PY
import json
with open("$TIME_LOG_FILE") as fh:
    lines = [json.loads(l) for l in fh if l.strip()]
assert len(lines) == 2
e = lines[-1]
assert e["author_is_me"] is True, e   # bool coerced
assert e["round"] == 1, e
assert e["mr_iid"] == 2022, e
PY

# 3) Values with spaces (shell-quoted) survive round trip.
tl_emit jira_transition ticket=UA-100 from="In Progress" to="Code Review" source=agent

python3 - <<PY
import json
with open("$TIME_LOG_FILE") as fh:
    lines = [json.loads(l) for l in fh if l.strip()]
assert len(lines) == 3
e = lines[-1]
assert e["from"] == "In Progress", e
assert e["to"] == "Code Review", e
assert e["source"] == "agent", e
PY

# 4) Concurrent appenders don't corrupt the file (we rely on O_APPEND + flock).
N=20
for i in $(seq 1 $N); do
  tl_emit concurrent_test idx=$i &
done
wait

python3 - <<PY
import json
with open("$TIME_LOG_FILE") as fh:
    raw = fh.readlines()
# Every line must parse — no torn writes.
events = [json.loads(l) for l in raw if l.strip()]
# Original 3 + 20 concurrent = 23 total.
assert len(events) == 23, f"expected 23, got {len(events)}"
ct = [e for e in events if e["type"] == "concurrent_test"]
idxs = sorted(e["idx"] for e in ct)
assert idxs == list(range(1, 21)), idxs
PY

# 5) Kill switch — TIME_LOG_ENABLED=0 is a no-op.
BEFORE=$(wc -l < "$TIME_LOG_FILE")
TIME_LOG_ENABLED=0 tl_emit should_not_appear foo=bar
AFTER=$(wc -l < "$TIME_LOG_FILE")
[[ "$BEFORE" == "$AFTER" ]] || { echo "kill switch leaked: $BEFORE vs $AFTER"; exit 1; }

# 6) Event type is a required first arg — calling with nothing is a no-op,
#    not a crash. (We use `|| true` + rc check to verify.)
tl_emit >/dev/null 2>&1 || { echo "tl_emit with no args should not fail"; exit 1; }

echo "all checks passed"
