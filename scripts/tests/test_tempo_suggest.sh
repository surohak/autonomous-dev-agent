#!/bin/bash
# test_tempo_suggest.sh — tempo-suggest.py produces correct per-day,
# per-ticket worklog suggestions from a time-log.jsonl fixture.
#
# This is a formula test — no network. We suppress TEMPO_API_TOKEN so
# _fetch_existing_totals short-circuits and returns ({}, False), which
# means existing-Tempo-log dedup is skipped (that path is covered in
# test_tempo_lib.sh via a curl-on-PATH mock).
#
# Scenarios covered:
#   1. Single manual dev run → rounded-to-quarter suggestion
#   2. Below-15-min run → dropped by default, visible with --include-skipped
#   3. Multiple runs on the same ticket → summed
#   4. DEV_CAP (8h) hit by a 10h run
#   5. Review round (review_ready → mr_approved) → review_time
#   6. Non-manual runs are ignored (they're scheduled noise, not work)
#   7. Unknown mode is ignored (we only count DEV_MODES)
#   8. --ticket filter narrows to one ticket
#   9. --respect-user-skips drops (ticket, date) pairs from tempo-skipped.json
#  10. --date selects a specific UTC day
#  11. Orphan agent_start (crashed run, no end) is tolerated, not counted
#  12. review_ready without a closer the same day is NOT counted (open window)

set -euo pipefail
source "$HOME/.cursor/skills/autonomous-dev-agent/scripts/lib/env.sh"

FIX="$TEST_TMP/tempo-suggest"
mkdir -p "$FIX/cache"
LOG="$FIX/cache/time-log.jsonl"

# Deterministic day so daylight-saving + TZ edges don't flap.
DAY="2026-04-15"
TZ_ARG="UTC"

# Canonical writer — we want readable fixtures, so one event per bash line.
log() {
  printf '%s\n' "$1" >> "$LOG"
}

# Scenario payload — intentionally colourful so every branch has evidence.
#
# UA-100:  1 manual impl run, 1h45m (rounded from 6300s)
#          + 1 manual impl run, 30m (rounded from 1800s) → summed → 2h15m
# UA-101:  1 manual impl run, 5m → below 15-min floor → dropped
# UA-102:  1 manual impl run, 10h → capped at 8h
# UA-103:  1 review round (ready → mr_approved) 45m
#          + 1 dev run 1h → total suggest 1h45m
# UA-104:  1 scheduled (manual=0) run 2h → ignored
# UA-105:  1 manual run with mode="ask" → ignored (not in DEV_MODES)
# UA-106:  orphan agent_start, no end → ignored, doesn't crash
# UA-107:  review_ready with no closer in-day → ignored
# UA-108:  manual impl run on a DIFFERENT day (2026-04-14) → not counted for 04-15

: > "$LOG"

# UA-100 — two runs summed
log '{"ts":"2026-04-15T08:00:00Z","type":"agent_start","run_id":"r100a","ticket":"UA-100","mode":"implementation","manual":1,"mr_iid":"--"}'
log '{"ts":"2026-04-15T09:45:00Z","type":"agent_end","run_id":"r100a","exit":"0"}'
log '{"ts":"2026-04-15T14:00:00Z","type":"agent_start","run_id":"r100b","ticket":"UA-100","mode":"implementation","manual":1,"mr_iid":"--"}'
log '{"ts":"2026-04-15T14:30:00Z","type":"agent_end","run_id":"r100b","exit":"0"}'

# UA-101 — below floor
log '{"ts":"2026-04-15T10:00:00Z","type":"agent_start","run_id":"r101","ticket":"UA-101","mode":"implementation","manual":1,"mr_iid":"--"}'
log '{"ts":"2026-04-15T10:05:00Z","type":"agent_end","run_id":"r101","exit":"0"}'

# UA-102 — hit DEV_CAP at 8h
log '{"ts":"2026-04-15T00:00:00Z","type":"agent_start","run_id":"r102","ticket":"UA-102","mode":"implementation","manual":1,"mr_iid":"--"}'
log '{"ts":"2026-04-15T10:00:00Z","type":"agent_end","run_id":"r102","exit":"0"}'

# UA-103 — review 45m + dev 1h
log '{"ts":"2026-04-15T09:00:00Z","type":"review_ready","ticket":"UA-103","mr_iid":"2100"}'
log '{"ts":"2026-04-15T09:45:00Z","type":"mr_approved","ticket":"UA-103","mr_iid":"2100"}'
log '{"ts":"2026-04-15T11:00:00Z","type":"agent_start","run_id":"r103","ticket":"UA-103","mode":"implementation","manual":1,"mr_iid":"2100"}'
log '{"ts":"2026-04-15T12:00:00Z","type":"agent_end","run_id":"r103","exit":"0"}'

# UA-104 — scheduled (manual=0) → ignored
log '{"ts":"2026-04-15T13:00:00Z","type":"agent_start","run_id":"r104","ticket":"UA-104","mode":"implementation","manual":0,"mr_iid":"--"}'
log '{"ts":"2026-04-15T15:00:00Z","type":"agent_end","run_id":"r104","exit":"0"}'

# UA-105 — ask mode → ignored
log '{"ts":"2026-04-15T16:00:00Z","type":"agent_start","run_id":"r105","ticket":"UA-105","mode":"ask","manual":1,"mr_iid":"--"}'
log '{"ts":"2026-04-15T16:30:00Z","type":"agent_end","run_id":"r105","exit":"0"}'

# UA-106 — orphan start
log '{"ts":"2026-04-15T17:00:00Z","type":"agent_start","run_id":"r106_orphan","ticket":"UA-106","mode":"implementation","manual":1,"mr_iid":"--"}'

# UA-107 — open review window
log '{"ts":"2026-04-15T18:00:00Z","type":"review_ready","ticket":"UA-107","mr_iid":"2200"}'

# UA-108 — different day
log '{"ts":"2026-04-14T08:00:00Z","type":"agent_start","run_id":"r108","ticket":"UA-108","mode":"implementation","manual":1,"mr_iid":"--"}'
log '{"ts":"2026-04-14T10:00:00Z","type":"agent_end","run_id":"r108","exit":"0"}'

# ---------------------------------------------------------------------------
# Helper — run tempo-suggest.py with the fixture isolated.
# ---------------------------------------------------------------------------
run_suggest() {
  TIME_LOG_FILE="$LOG" \
  CACHE_DIR="$FIX/cache" \
  TEMPO_API_TOKEN="" \
  JIRA_ACCOUNT_ID="" \
  WORK_TZ="$TZ_ARG" \
  python3 "$HOME/.cursor/skills/autonomous-dev-agent/scripts/tempo-suggest.py" \
    --date "$DAY" --json "$@"
}

# ---------------------------------------------------------------------------
# 1–7: default output — only meaningful tickets should surface.
# ---------------------------------------------------------------------------
OUT=$(run_suggest)

python3 - <<PY
import json, sys
d = json.loads(r'''$OUT''')
tickets = {s["ticket"]: s for s in d}

# Dropped: below-floor / non-manual / wrong-mode / orphan / open-review / other-day.
for t in ("UA-101", "UA-104", "UA-105", "UA-106", "UA-107", "UA-108"):
    assert t not in tickets, f"{t} should have been dropped, got {tickets.get(t)}"

# UA-100: 6300 + 1800 = 8100s → rounded to quarter → 8100 (already on quarter)
#         = 2h15m.
s = tickets["UA-100"]
assert s["suggested_seconds"] == 8100, s
assert s["dev_seconds"] == 8100, s
assert s["review_seconds"] == 0, s
assert len(s["dev_runs"]) == 2, s

# UA-102: 10h → DEV_CAP (8h = 28800s)
s = tickets["UA-102"]
assert s["suggested_seconds"] == 28800, s
assert s["dev_seconds"] == 28800, s

# UA-103: dev 3600 + review 2700 = 6300 → 1h45m suggestion
s = tickets["UA-103"]
assert s["dev_seconds"] == 3600, s
assert s["review_seconds"] == 2700, s
assert s["suggested_seconds"] == 6300, s
assert len(s["review_rounds"]) == 1, s
assert s["review_rounds"][0]["close"] == "mr_approved", s

# tempo_dedup must be False — we ran with an empty token.
assert all(s["tempo_dedup"] is False for s in d), d

# description includes human-friendly run/round counts
assert "dev run" in tickets["UA-100"]["description"], tickets["UA-100"]
assert "review" in tickets["UA-103"]["description"], tickets["UA-103"]

print("scenarios 1–7 OK")
PY

# ---------------------------------------------------------------------------
# 8: --ticket filter
# ---------------------------------------------------------------------------
OUT=$(run_suggest --ticket UA-100)
python3 - <<PY
import json
d = json.loads(r'''$OUT''')
assert len(d) == 1 and d[0]["ticket"] == "UA-100", d
print("scenario 8 OK")
PY

# Case-insensitive + whitespace-tolerant
OUT=$(run_suggest --ticket "  ua-102  ")
python3 - <<PY
import json
d = json.loads(r'''$OUT''')
assert len(d) == 1 and d[0]["ticket"] == "UA-102", d
print("scenario 8b (case/whitespace) OK")
PY

# ---------------------------------------------------------------------------
# 9: --respect-user-skips
# ---------------------------------------------------------------------------
cat > "$FIX/cache/tempo-skipped.json" <<EOF
{"UA-100:$DAY":"2026-04-16T08:00:00Z"}
EOF

OUT=$(run_suggest --respect-user-skips)
python3 - <<PY
import json
d = json.loads(r'''$OUT''')
tickets = {s["ticket"] for s in d}
assert "UA-100" not in tickets, f"UA-100 should be skipped, got {tickets}"
# UA-102 and UA-103 should still be present.
assert "UA-102" in tickets and "UA-103" in tickets, tickets
print("scenario 9 OK")
PY
rm -f "$FIX/cache/tempo-skipped.json"

# ---------------------------------------------------------------------------
# 10: --date selects a different day → UA-108 appears, UA-100 disappears.
# ---------------------------------------------------------------------------
OUT=$(TIME_LOG_FILE="$LOG" CACHE_DIR="$FIX/cache" TEMPO_API_TOKEN="" JIRA_ACCOUNT_ID="" WORK_TZ="$TZ_ARG" \
  python3 "$HOME/.cursor/skills/autonomous-dev-agent/scripts/tempo-suggest.py" \
  --date 2026-04-14 --json)

python3 - <<PY
import json
d = json.loads(r'''$OUT''')
tickets = {s["ticket"] for s in d}
assert tickets == {"UA-108"}, tickets
# 2h = 7200s → round to quarter → 7200s
assert d[0]["suggested_seconds"] == 7200, d[0]
print("scenario 10 OK")
PY

# ---------------------------------------------------------------------------
# 11 + 12 already covered implicitly by scenarios 1–7 (UA-106, UA-107).
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 13: --include-skipped surfaces below-floor + already-logged tickets.
# ---------------------------------------------------------------------------
OUT=$(run_suggest --include-skipped)
python3 - <<PY
import json
d = json.loads(r'''$OUT''')
# UA-101 had 5min → below floor → should now appear with skip reason set.
ua101 = [s for s in d if s["ticket"] == "UA-101"]
assert ua101, d
assert ua101[0]["skip"] == "below 15min", ua101[0]
# Its suggested_seconds is 0 (nothing to log).
assert ua101[0]["suggested_seconds"] == 0, ua101[0]
print("scenario 13 OK")
PY

# ---------------------------------------------------------------------------
# 14: zero events → exits 0 with empty JSON.
# ---------------------------------------------------------------------------
EMPTY_LOG="$FIX/empty.jsonl"
: > "$EMPTY_LOG"
OUT=$(TIME_LOG_FILE="$EMPTY_LOG" TEMPO_API_TOKEN="" JIRA_ACCOUNT_ID="" WORK_TZ="$TZ_ARG" \
  python3 "$HOME/.cursor/skills/autonomous-dev-agent/scripts/tempo-suggest.py" \
  --date "$DAY" --json)
[[ "$OUT" == "[]" ]] || { echo "expected [] for empty log, got: $OUT"; exit 1; }

# Missing log file entirely → still graceful.
OUT=$(TIME_LOG_FILE="$FIX/does-not-exist.jsonl" TEMPO_API_TOKEN="" JIRA_ACCOUNT_ID="" WORK_TZ="$TZ_ARG" \
  python3 "$HOME/.cursor/skills/autonomous-dev-agent/scripts/tempo-suggest.py" \
  --date "$DAY" --json)
[[ "$OUT" == "[]" ]] || { echo "expected [] for missing log, got: $OUT"; exit 1; }

echo "all checks passed"
