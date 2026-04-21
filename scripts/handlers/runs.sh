#!/bin/bash
# scripts/handlers/runs.sh — per-run (pid-scoped) Telegram commands:
#   cmd_stopall            — SIGTERM every registered active run
#   handler_rn_log <pid>   — tail the log file for a specific run
#   handler_rn_stop <pid>  — SIGTERM a specific run

[[ -n "${_DEV_AGENT_HANDLER_RUNS_LOADED:-}" ]] && return 0
_DEV_AGENT_HANDLER_RUNS_LOADED=1

cmd_stopall() {
  active_run_prune >/dev/null 2>&1 || true
  local killed
  killed=$(ACTIVE_RUNS_FILE="$(_active_runs_file)" python3 <<'PYEOF' 2>/dev/null
import json, os, signal
try:
    d = json.load(open(os.environ['ACTIVE_RUNS_FILE']))
    if not isinstance(d, dict): d = {}
except Exception:
    d = {}
killed = []
for pid in list(d.keys()):
    try:
        os.kill(int(pid), signal.SIGTERM)
        killed.append(pid)
    except Exception:
        pass
print(' '.join(killed))
PYEOF
)
  if [ -n "$killed" ]; then
    tg_send "SIGTERM sent to: $killed"
  else
    tg_send "No active runs."
  fi
}

handler_rn_log() {
  local raw="$1"
  local pid log tail_out
  pid=$(echo "$raw" | awk '{print $2}')
  log=$(RN_PID="$pid" ACTIVE_RUNS_FILE="$(_active_runs_file)" python3 -c "
import json, os
try:
    d = json.load(open(os.environ['ACTIVE_RUNS_FILE']))
    if not isinstance(d, dict): d = {}
except Exception:
    d = {}
r = d.get(os.environ['RN_PID']) or {}
print(r.get('log_path') or '')
" 2>/dev/null)
  if [ -z "$log" ] || [ ! -f "$log" ]; then
    tg_send "No log found for pid $pid (maybe run already finished)."
  else
    tail_out=$(tail -n 40 "$log" 2>/dev/null | tail -c 3500)
    tg_send "Log for pid $pid (last 40 lines):
$tail_out"
  fi
}

handler_rn_stop() {
  local raw="$1"
  local pid
  pid=$(echo "$raw" | awk '{print $2}')
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    tg_send "SIGTERM sent to pid $pid."
  else
    tg_send "pid $pid is not alive."
  fi
}
