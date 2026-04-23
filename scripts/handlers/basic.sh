#!/bin/bash
# scripts/handlers/basic.sh — simple Telegram commands.
#
# Each function takes no args (unless noted), uses the ambient lib/* helpers,
# and returns nothing meaningful. Keep them side-effect-only so they are trivial
# to unit-test by mocking tg_send / jira_* / active_run_*.

[[ -n "${_DEV_AGENT_HANDLER_BASIC_LOADED:-}" ]] && return 0
_DEV_AGENT_HANDLER_BASIC_LOADED=1

# ----- /status ---------------------------------------------------------------
cmd_status() {
  # LAUNCHD_LABEL_PREFIX is exported by lib/cfg.sh as `com.$USER` — matches the
  # labels bin/install.sh writes into the plist files for this user.
  local label="${LAUNCHD_LABEL_PREFIX}.autonomous-dev-agent"
  local watcher_label="${LAUNCHD_LABEL_PREFIX}.dev-agent-watcher"
  local agent_status watcher_status

  if launchctl list 2>/dev/null | grep -q "$label"; then
    agent_status="Scheduled (every 30 min)"
  else
    agent_status="Stopped"
  fi
  if launchctl list 2>/dev/null | grep -q "$watcher_label"; then
    watcher_status="Watching (every 2 min)"
  else
    watcher_status="Stopped"
  fi

  active_run_prune >/dev/null 2>&1 || true
  local run_lines
  run_lines=$(active_run_summary 2>/dev/null || echo "")

  # If there are active runs, the agent is running regardless of launchd state
  # (the launchd entry disappears between scheduled triggers but spawned
  # agent processes persist).
  if [ -n "$run_lines" ] && [[ "$agent_status" != *"Running"* ]]; then
    agent_status="Running"
  fi

  if [ -n "$run_lines" ]; then
    local run_count
    run_count=$(printf '%s\n' "$run_lines" | wc -l | tr -d ' ')
    tg_send "Agent: $agent_status
Watcher: $watcher_status
Active runs: $run_count

$run_lines"

    ACTIVE_RUNS_FILE="$(_active_runs_file)" python3 -c "
import json, os, time
try:
    d = json.load(open(os.environ['ACTIVE_RUNS_FILE']))
    if not isinstance(d, dict): d = {}
except Exception:
    d = {}
now = int(time.time())
def fmt(s):
    s = max(0, int(s))
    if s < 60: return f'{s}s'
    if s < 3600: return f'{s//60}m'
    h, m = divmod(s, 3600)
    return f'{h}h{m//60:02d}m'
for pid, r in sorted(d.items(), key=lambda kv: kv[1].get('started_at', 0)):
    tk = r.get('ticket','--')
    mr = r.get('mr_iid','--')
    mode = r.get('mode','?')
    phase = r.get('phase','?')
    rnd = int(r.get('round') or 1)
    age = fmt(now - int(r.get('started_at', now)))
    title_bits = []
    if tk != '--': title_bits.append(f'{tk}' + (f' (round {rnd})' if rnd > 1 else ''))
    if mr != '--': title_bits.append(f'!{mr}')
    title_bits.append(f'{mode} · {phase}')
    title_bits.append(f'for {age}')
    line = '  —  '.join(title_bits)
    print(f'{pid}\t{line}\t{tk}')
" 2>/dev/null | while IFS=$'\t' read -r PID LINE TK; do
      [ -z "$PID" ] && continue
      local kb
      if [ "$TK" != "--" ]; then
        kb="[[{\"text\":\"View log\",\"callback_data\":\"rn_log:$PID\"},{\"text\":\"Stop\",\"callback_data\":\"rn_stop:$PID\"}],[{\"text\":\"Ticket status\",\"callback_data\":\"tk_status:$TK\"}]]"
      else
        kb="[[{\"text\":\"View log\",\"callback_data\":\"rn_log:$PID\"},{\"text\":\"Stop\",\"callback_data\":\"rn_stop:$PID\"}]]"
      fi
      tg_inline "pid $PID — $LINE" "$kb"
    done
    return 0
  fi

  local latest_log last_run last_result last_exit
  latest_log=$(ls -t "$LOG_DIR"/*.log 2>/dev/null | grep -Ev 'telegram-handler|launchd-|watcher' | head -1)
  if [ -n "$latest_log" ]; then
    last_run=$(head -1 "$latest_log" | sed 's/=== Autonomous Dev Agent Run: //' | sed 's/ ===//')
    last_exit=$(grep -o 'exit code: [0-9]*' "$latest_log" | tail -1 | grep -o '[0-9]*')
    if [ -n "$last_exit" ]; then
      if [ "$last_exit" = "0" ]; then
        last_result="Success (exit 0)"
      else
        last_result="Failed (exit $last_exit)"
      fi
    else
      last_result=$(tail -1 "$latest_log" | head -c 120)
    fi
  else
    last_run="No runs yet"
    last_result="N/A"
  fi
  tg_send "Agent: $agent_status
Watcher: $watcher_status
Active runs: 0 (idle)
Last run: $last_run
Result: $last_result"
}

# ----- /logs -----------------------------------------------------------------
cmd_logs() {
  local latest
  latest=$(ls -t "$LOG_DIR"/*.log 2>/dev/null | grep -Ev 'telegram-handler|launchd-' | head -1)
  if [ -n "$latest" ]; then
    local content name
    content=$(head -50 "$latest")
    name=$(basename "$latest")
    tg_send "Log: $name

$content"
  else
    tg_send "No logs found"
  fi
}

# ----- /digest ---------------------------------------------------------------
cmd_digest() {
  bash "$SKILL_DIR/scripts/daily-digest.sh"
}

# ----- /run (no ticket) ------------------------------------------------------
cmd_run() {
  _spawn_agent "full run" "Starting agent run..."
}

# ----- /stop + /start (scheduled-run control) --------------------------------
cmd_stop_scheduled() {
  local plist="$HOME/Library/LaunchAgents/${LAUNCHD_LABEL_PREFIX}.autonomous-dev-agent.plist"
  launchctl unload "$plist" 2>/dev/null || true
  tg_send "Agent stopped and unscheduled."
}

cmd_start_scheduled() {
  local plist="$HOME/Library/LaunchAgents/${LAUNCHD_LABEL_PREFIX}.autonomous-dev-agent.plist"
  launchctl load "$plist" 2>/dev/null || true
  launchctl start "${LAUNCHD_LABEL_PREFIX}.autonomous-dev-agent" 2>/dev/null || true
  tg_send "Agent started. Scheduled every 30 minutes."
}

# ----- run <ticket> ----------------------------------------------------------
handler_run_ticket() {
  local raw="$1"  # full command, e.g. "run ua-1003"
  local ticket
  ticket=$(echo "$raw" | sed 's/^run //i' | tr '[:lower:]' '[:upper:]')
  export FORCE_TICKET="$ticket"
  _spawn_agent "$ticket" "Starting agent for $ticket..."
  unset FORCE_TICKET
}

# ----- approve <ticket> -----------------------------------------------------
handler_approve() {
  local raw="$1"
  local ticket estimates_file
  ticket=$(echo "$raw" | sed 's/^approve //i' | tr '[:lower:]' '[:upper:]' | awk '{print $1}')
  estimates_file="${ESTIMATES_FILE:-$CACHE_DIR/estimates.json}"
  TICKET="$ticket" ESTIMATES_FILE="$estimates_file" python3 -c "
import json, os
p = os.environ['ESTIMATES_FILE']
t = os.environ['TICKET']
data = json.load(open(p)) if os.path.exists(p) else {}
if t in data:
    data[t]['classified'] = 'approved'
    with open(p, 'w') as f:
        json.dump(data, f, indent=2)
" 2>/dev/null
  tg_send "Approved $ticket. Will proceed on next agent run."
}

# ----- skip <ticket> ---------------------------------------------------------
handler_skip() {
  local raw="$1"
  local ticket killed=""
  ticket=$(echo "$raw" | sed 's/^skip //i' | tr '[:lower:]' '[:upper:]' | awk '{print $1}')
  local pid
  for pid in $(active_run_pids_for_ticket "$ticket"); do
    [ -z "$pid" ] && continue
    if kill -TERM "$pid" 2>/dev/null; then
      killed="${killed}${pid} "
    fi
  done
  jira_transition_to "$ticket" "backlog" >/dev/null 2>&1 || true
  if [ -n "$killed" ]; then
    tg_send "Skipped $ticket → stopped run(s) ${killed}and moved to Backlog."
  else
    tg_send "Skipped $ticket → moved to Backlog (if transition allowed)."
  fi
}

# ----- review <ticket> (no feedback) -----------------------------------------
handler_review_prompt() {
  local raw="$1"
  local ticket
  ticket=$(echo "$raw" | sed 's/^review //i' | tr '[:lower:]' '[:upper:]' | awk '{print $1}')
  tg_force_reply "Reply with review feedback for $ticket:"
}

# ----- retry <ticket> --------------------------------------------------------
handler_retry() {
  local raw="$1"
  local ticket failures has_ctx msg
  ticket=$(echo "$raw" | sed 's/^retry //i' | tr '[:lower:]' '[:upper:]')
  failures="${FAILURES_FILE:-$CACHE_DIR/failures.json}"
  has_ctx=$(TICKET="$ticket" FAILURES="$failures" python3 -c "
import json, os
try:
    data = json.load(open(os.environ['FAILURES']))
except Exception:
    data = {}
print('yes' if data.get(os.environ['TICKET']) else 'no')
" 2>/dev/null || echo "no")
  if [ "$has_ctx" = "yes" ]; then
    msg="Retrying $ticket with saved error context..."
  else
    msg="Retrying $ticket (no saved context — starting fresh)..."
  fi
  export FORCE_TICKET="$ticket"
  export RETRY_MODE="true"
  _spawn_agent "$ticket (retry)" "$msg"
  unset FORCE_TICKET RETRY_MODE
}

# ----- ask <prompt> ----------------------------------------------------------
handler_ask() {
  local raw="$1"
  local prompt
  prompt="${raw#ask }"
  if [ -z "$prompt" ] || [ "$prompt" = "$raw" ]; then
    tg_send "Usage: /ask <your question or task>"
    return 0
  fi
  export FORCE_PROMPT="$prompt"
  _spawn_agent "chat" "Thinking… (will reply when agent finishes)"
  unset FORCE_PROMPT
}
