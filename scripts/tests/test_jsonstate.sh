#!/bin/bash
# test_jsonstate.sh — locked_json read-modify-write round trip + crash safety.
set -euo pipefail
source "$HOME/.cursor/skills/autonomous-dev-agent/scripts/lib/env.sh"

F="$TEST_TMP/state.json"

# 1. Write from scratch
python3 -c "
from jsonstate import locked_json
with locked_json('$F', {}) as ref:
    ref[0]['a'] = 1
    ref[0]['b'] = 'two'
"

# 2. Read it back
python3 -c "
from jsonstate import read_json
d = read_json('$F')
assert d == {'a': 1, 'b': 'two'}, d
print('round-trip OK')
"

# 3. Tolerant of corrupt file
echo '{not json' > "$F"
python3 -c "
from jsonstate import read_json
d = read_json('$F', {'fallback': True})
assert d == {'fallback': True}, d
"

# 4. locked_json recovers corrupt into default
python3 -c "
from jsonstate import locked_json
with locked_json('$F', {}) as ref:
    assert ref[0] == {}, ref[0]
    ref[0]['recovered'] = True
"
python3 -c "
from jsonstate import read_json
assert read_json('$F') == {'recovered': True}
"
echo "all jsonstate assertions passed"
