#!/bin/bash
# test_admit.sh — active_run_admit enforces dedup + global cap.
set -euo pipefail
source "$HOME/.cursor/skills/autonomous-dev-agent/scripts/lib/env.sh"

# Redirect active-runs.json to the test tmp dir
export ACTIVE_RUNS_FILE="$TEST_TMP/active-runs.json"
source "$HOME/.cursor/skills/autonomous-dev-agent/scripts/active-run.sh"

# --- 1. fresh file → OK ---
res=$(active_run_admit ticket PROJ-TEST1)
[[ "$res" == OK:* ]] || { echo "expected OK, got: $res"; exit 1; }

# --- 2. register a fake run under PID 1 (always alive), then re-admit same ticket → DUPLICATE ---
python3 -c "
from jsonstate import locked_json
with locked_json('$ACTIVE_RUNS_FILE', {}) as ref:
    ref[0]['1'] = {'pid': 1, 'ticket': 'PROJ-TEST1', 'mode': 'test',
                    'started_at': 'now', 'phase': 'starting'}
"
res=$(active_run_admit ticket PROJ-TEST1)
[[ "$res" == DUPLICATE:1 ]] || { echo "expected DUPLICATE:1, got: $res"; exit 1; }

# Case-insensitive dedup (lowercase version of the same key)
res=$(active_run_admit ticket proj-test1)
[[ "$res" == DUPLICATE:1 ]] || { echo "case-insensitive dedup broken: $res"; exit 1; }

# --- 3. different ticket still admits ---
res=$(active_run_admit ticket PROJ-TEST2)
[[ "$res" == OK:* ]] || { echo "expected OK for new ticket, got: $res"; exit 1; }

# --- 4. cap enforced ---
export ACTIVE_RUNS_MAX=1
res=$(active_run_admit ticket PROJ-TEST9)
[[ "$res" == OVER_CAP:* ]] || { echo "expected OVER_CAP with cap=1, got: $res"; exit 1; }

# --- 5. mr-kind dedup on mr_iid ---
# Use the current shell's PID (guaranteed alive) so prune() doesn't remove it.
export ACTIVE_RUNS_MAX=10
ALIVE_PID=$$
python3 -c "
from jsonstate import locked_json
with locked_json('$ACTIVE_RUNS_FILE', {}) as ref:
    ref[0]['$ALIVE_PID'] = {'pid': $ALIVE_PID, 'mr_iid': '4242', 'mode': 'feedback',
                    'started_at': 'now', 'phase': 'starting'}
"
res=$(active_run_admit mr 4242)
[[ "$res" == "DUPLICATE:$ALIVE_PID" ]] || { echo "expected DUPLICATE:$ALIVE_PID for MR, got: $res"; exit 1; }

res=$(active_run_admit mr 9999)
[[ "$res" == OK:* ]] || { echo "expected OK for new MR, got: $res"; exit 1; }

echo "all admit assertions passed"
