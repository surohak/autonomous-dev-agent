#!/bin/bash
# Helpers to register / unregister the currently-running agent job in
# cache/active-runs.json so /status and /tickets in Telegram can surface
# live progress instead of just "Idle / Running".
#
# Usage (from run-agent.sh):
#   source "$SKILL_DIR/scripts/active-run.sh"
#   active_run_register "<pid>" "<mode>" "<ticket_or_-->" "<log_path>" "<mr_iid_or_-->" "<repo_or_-->"
#   active_run_set_phase "<pid>" "<phase>"       # optional, mid-run
#   active_run_unregister "<pid>"                # on exit (via trap)
#
# File format:
#   {
#     "<pid>": {
#       "pid": 12345,
#       "mode": "implementation|review|ci-fix|feedback|chat|dm|full",
#       "ticket": "UA-832",
#       "mr_iid": "2046",
#       "repo": "ssr",
#       "phase": "launching",
#       "round": 1,
#       "started_at": 1761234567,
#       "updated_at": 1761234567,
#       "log_path": "/path/to/log"
#     }
#   }

# Bootstrap shared libs (env.sh exports SKILL_DIR, CACHE_DIR, PYTHONPATH etc.)
# Guarded with _ACTIVE_RUN_BOOTSTRAP_DONE so repeated sourcing is cheap.
if [[ -z "${_ACTIVE_RUN_BOOTSTRAP_DONE:-}" ]]; then
  _SKILL_DIR_BOOT="${SKILL_DIR:-$HOME/.cursor/skills/autonomous-dev-agent}"
  # shellcheck disable=SC1091
  source "$_SKILL_DIR_BOOT/scripts/lib/env.sh"
  _ACTIVE_RUN_BOOTSTRAP_DONE=1
fi

ACTIVE_RUNS_FILE="${ACTIVE_RUNS_FILE:-$CACHE_DIR/active-runs.json}"
ACTIVE_RUNS_MAX="${ACTIVE_RUNS_MAX:-10}"
mkdir -p "$(dirname "$ACTIVE_RUNS_FILE")"

# Atomic mutate via shared jsonstate.locked_json (flock + tempfile + os.replace).
# The `$script` arg is executed inside the `with locked_json(...) as ref:` block
# with the top-level name `data` bound to `ref[0]` for ergonomic read/write.
_active_run_mutate() {
  local script="$1"
  export ACTIVE_RUNS_FILE
  python3 -c "
import os
from jsonstate import locked_json
path = os.environ['ACTIVE_RUNS_FILE']
with locked_json(path, {}) as _ref:
    data = _ref[0]
    if not isinstance(data, dict):
        data = {}

$script

    _ref[0] = data
"
}

active_run_register() {
  local pid="$1"; local mode="${2:-full}"; local ticket="${3:---}"
  local log_path="${4:---}"; local mr_iid="${5:---}"; local repo="${6:---}"
  local phase="${7:-launching}"; local round="${8:-1}"
  ACTIVE_RUNS_PID="$pid" \
  ACTIVE_RUNS_MODE="$mode" \
  ACTIVE_RUNS_TICKET="$ticket" \
  ACTIVE_RUNS_LOG="$log_path" \
  ACTIVE_RUNS_MR="$mr_iid" \
  ACTIVE_RUNS_REPO="$repo" \
  ACTIVE_RUNS_PHASE="$phase" \
  ACTIVE_RUNS_ROUND="$round" \
  _active_run_mutate '
    import os, time
    pid = os.environ["ACTIVE_RUNS_PID"]
    now = int(time.time())
    try:    round_n = int(os.environ.get("ACTIVE_RUNS_ROUND", "1") or 1)
    except: round_n = 1
    data[pid] = {
        "pid":        int(pid) if pid.isdigit() else pid,
        "mode":       os.environ["ACTIVE_RUNS_MODE"],
        "ticket":     os.environ["ACTIVE_RUNS_TICKET"],
        "mr_iid":     os.environ["ACTIVE_RUNS_MR"],
        "repo":       os.environ["ACTIVE_RUNS_REPO"],
        "phase":      os.environ["ACTIVE_RUNS_PHASE"],
        "round":      round_n,
        "started_at": now,
        "updated_at": now,
        "log_path":   os.environ["ACTIVE_RUNS_LOG"],
    }
  '
}

# Mark that this pid is registered (used by run-agent trap so we don't try to
# unregister a pid that never registered — e.g. early-exit before pre-flight).
active_run_is_registered() {
  local pid="$1"
  export ACTIVE_RUNS_FILE
  python3 -c "
import os, sys
from jsonstate import read_json
data = read_json(os.environ['ACTIVE_RUNS_FILE'], {})
sys.exit(0 if (isinstance(data, dict) and '$pid' in data) else 1)
"
}

active_run_set_phase() {
  local pid="$1"; local phase="$2"
  ACTIVE_RUNS_PID="$pid" ACTIVE_RUNS_PHASE="$phase" _active_run_mutate '
    import os, time
    pid = os.environ["ACTIVE_RUNS_PID"]
    if pid in data:
        data[pid]["phase"] = os.environ["ACTIVE_RUNS_PHASE"]
        data[pid]["updated_at"] = int(time.time())
  '
}

active_run_unregister() {
  local pid="$1"
  ACTIVE_RUNS_PID="$pid" _active_run_mutate '
    import os
    data.pop(os.environ["ACTIVE_RUNS_PID"], None)
  '
}

# Prune entries whose PID is no longer alive — cheap self-healing for stale
# entries (e.g. if a run was killed with SIGKILL and never called unregister).
active_run_prune() {
  _active_run_mutate '
    import os
    stale = []
    for pid, _ in list(data.items()):
        try:
            p = int(pid)
        except Exception:
            continue
        try:
            os.kill(p, 0)
        except ProcessLookupError:
            stale.append(pid)
        except PermissionError:
            pass  # alive but not ours
    for s in stale:
        data.pop(s, None)
  '
}

# ---------------------------------------------------------------------------
# Spawn admission control
# ---------------------------------------------------------------------------
# Usage: active_run_admit <kind> <id>
#   kind = "ticket" | "mr"
#   id   = "UA-832" | "2046"
# Always prunes first (fresh view). Prints one of:
#   OK:<count>                 — ok to spawn, current count (post-spawn will be count+1)
#   DUPLICATE:<pid>            — same ticket/MR already running; pid printed
#   OVER_CAP:<count>/<max>     — too many active runs
# Exits 0 with the verdict on stdout so the caller can act.
active_run_admit() {
  local kind="$1"; local id="$2"
  local max="${ACTIVE_RUNS_MAX:-10}"
  active_run_prune >/dev/null 2>&1 || true
  ACTIVE_RUNS_FILE="$ACTIVE_RUNS_FILE" \
  ACTIVE_RUNS_MAX_V="$max" \
  ADMIT_KIND="$kind" ADMIT_ID="$id" python3 <<'PYEOF'
import os, sys
from jsonstate import read_json
path = os.environ["ACTIVE_RUNS_FILE"]
data = read_json(path, {})
if not isinstance(data, dict): data = {}
kind = os.environ["ADMIT_KIND"]
ident = (os.environ["ADMIT_ID"] or "").strip()
max_runs = int(os.environ["ACTIVE_RUNS_MAX_V"])
count = len(data)
# Duplicate check (case-insensitive for tickets)
if ident and ident != "--":
    for pid, r in data.items():
        if kind == "ticket":
            if (r.get("ticket") or "").upper() == ident.upper():
                print(f"DUPLICATE:{pid}")
                sys.exit(0)
        elif kind == "mr":
            if str(r.get("mr_iid") or "") == ident:
                print(f"DUPLICATE:{pid}")
                sys.exit(0)
if count >= max_runs:
    print(f"OVER_CAP:{count}/{max_runs}")
    sys.exit(0)
print(f"OK:{count}")
PYEOF
}

# Pretty-print all active runs as human-readable lines (used by /status).
active_run_summary() {
  active_run_prune >/dev/null 2>&1 || true
  ACTIVE_RUNS_FILE="$ACTIVE_RUNS_FILE" python3 <<'PYEOF'
import os, time
from jsonstate import read_json
data = read_json(os.environ["ACTIVE_RUNS_FILE"], {})
if not isinstance(data, dict): data = {}
now = int(time.time())
def fmt(s):
    s = max(0, int(s))
    if s < 60: return f"{s}s"
    if s < 3600: return f"{s//60}m"
    h, m = divmod(s, 3600)
    return f"{h}h{m//60:02d}m"
lines = []
for pid, r in sorted(data.items(), key=lambda kv: kv[1].get("started_at", 0)):
    tk = r.get("ticket") or "--"
    mr = r.get("mr_iid") or "--"
    mode = r.get("mode", "?")
    phase = r.get("phase", "?")
    age = fmt(now - int(r.get("started_at", now)))
    rnd = int(r.get("round") or 1)
    bits = [f"pid {pid}"]
    if tk != "--": bits.append(f"{tk}{' r'+str(rnd) if rnd > 1 else ''}")
    if mr != "--": bits.append(f"!{mr}")
    bits.append(f"{mode}/{phase}")
    bits.append(f"for {age}")
    lines.append("  • " + "  ".join(bits))
print("\n".join(lines))
PYEOF
}

# Return the PID(s) running for a given ticket, one per line (empty if none).
active_run_pids_for_ticket() {
  local tk="$1"
  ACTIVE_RUNS_FILE="$ACTIVE_RUNS_FILE" TK="$tk" python3 <<'PYEOF'
import os
from jsonstate import read_json
data = read_json(os.environ["ACTIVE_RUNS_FILE"], {})
if not isinstance(data, dict): data = {}
tk = (os.environ.get("TK") or "").upper()
for pid, r in data.items():
    if (r.get("ticket") or "").upper() == tk:
        print(pid)
PYEOF
}
