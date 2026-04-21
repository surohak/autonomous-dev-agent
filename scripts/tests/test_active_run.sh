#!/bin/bash
# test_active_run.sh — register / set_phase / is_registered / unregister
# round trip using a dummy PID that is always alive (1 = launchd on macOS).
set -euo pipefail
source "$HOME/.cursor/skills/autonomous-dev-agent/scripts/lib/env.sh"

export ACTIVE_RUNS_FILE="$TEST_TMP/active-runs.json"
source "$HOME/.cursor/skills/autonomous-dev-agent/scripts/active-run.sh"

# Register manually via python (mimics active_run_register but without spawning).
python3 -c "
from jsonstate import locked_json
with locked_json('$ACTIVE_RUNS_FILE', {}) as ref:
    ref[0]['1'] = {'pid': 1, 'ticket': 'PROJ-TEST', 'mode': 'test',
                    'started_at': 'now', 'phase': 'starting'}
"

# Must be registered
active_run_is_registered 1 >/dev/null || { echo "expected PID 1 registered"; exit 1; }

# set_phase bumps phase
active_run_set_phase 1 "researching" >/dev/null
phase=$(python3 -c "
import json
d = json.load(open('$ACTIVE_RUNS_FILE'))
print(d['1']['phase'])
")
[[ "$phase" == "researching" ]] || { echo "phase did not update: $phase"; exit 1; }

# Unregister removes entry
active_run_unregister 1 >/dev/null
still=$(python3 -c "
import json
print('1' in json.load(open('$ACTIVE_RUNS_FILE')))
")
[[ "$still" == "False" ]] || { echo "unregister did not remove"; exit 1; }

# Not registered anymore
if active_run_is_registered 1 >/dev/null 2>&1; then
  echo "is_registered should be false after unregister"; exit 1
fi

echo "active_run round-trip OK"
