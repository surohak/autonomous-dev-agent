#!/bin/bash
# Control script for the autonomous dev agent
# Usage: ./ctl.sh [start|stop|status|run|logs|digest|handler-start|handler-stop|all-start|all-stop|svc-start|svc-stop|svc-restart]
#
# svc-start/svc-stop/svc-restart <name>   — name ∈ {agent, watcher, telegram, digest}
#     Granular control over a single launchd service. Used by the SwiftBar
#     menu-bar plugin so each row in the dropdown can load/unload its own
#     service in-place, without requiring the user to drop to a terminal.
#     Modern `launchctl bootstrap` API is used first (same as install.sh);
#     falls back to the legacy `load`/`unload` pair on older macOS.

# All labels are derived from the current macOS username so multi-user Macs
# don't collide — this matches what bin/install.sh writes into the plist
# files. Override with AGENT_LABEL_PREFIX=com.foo ./ctl.sh ... if you need
# to manage a differently-owned installation.
SKILL_DIR="${SKILL_DIR:-$HOME/.cursor/skills/autonomous-dev-agent}"
LOG_DIR="$SKILL_DIR/logs"
CAFFEINATE_PID_FILE="$SKILL_DIR/cache/caffeinate.pid"
LABEL_PREFIX="${AGENT_LABEL_PREFIX:-com.$USER}"

PLIST="$HOME/Library/LaunchAgents/${LABEL_PREFIX}.autonomous-dev-agent.plist"
TELEGRAM_PLIST="$HOME/Library/LaunchAgents/${LABEL_PREFIX}.dev-agent-telegram.plist"
DIGEST_PLIST="$HOME/Library/LaunchAgents/${LABEL_PREFIX}.dev-agent-digest.plist"
WATCHER_PLIST="$HOME/Library/LaunchAgents/${LABEL_PREFIX}.dev-agent-watcher.plist"

LABEL="${LABEL_PREFIX}.autonomous-dev-agent"
TELEGRAM_LABEL="${LABEL_PREFIX}.dev-agent-telegram"
DIGEST_LABEL="${LABEL_PREFIX}.dev-agent-digest"
WATCHER_LABEL="${LABEL_PREFIX}.dev-agent-watcher"

start_caffeinate() {
  # Already running?
  if [ -f "$CAFFEINATE_PID_FILE" ]; then
    local old_pid=$(cat "$CAFFEINATE_PID_FILE" 2>/dev/null)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
      echo "  - Caffeinate already running (PID $old_pid)"
      return
    fi
  fi

  # -s: prevent system sleep ONLY when on AC power (battery-safe)
  # -i: prevent idle sleep
  nohup caffeinate -s -i > /dev/null 2>&1 &
  local pid=$!
  echo "$pid" > "$CAFFEINATE_PID_FILE"
  echo "  - Caffeinate started (PID $pid) — keeps Mac awake with lid closed ONLY on AC power"
}

stop_caffeinate() {
  if [ -f "$CAFFEINATE_PID_FILE" ]; then
    local pid=$(cat "$CAFFEINATE_PID_FILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null
      echo "  - Caffeinate stopped (PID $pid)"
    fi
    rm -f "$CAFFEINATE_PID_FILE"
  fi
}

is_caffeinate_running() {
  if [ -f "$CAFFEINATE_PID_FILE" ]; then
    local pid=$(cat "$CAFFEINATE_PID_FILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

# --- Generic per-service load/unload --------------------------------------
# Map the short friendly name to (label, plist) pair.
# Centralised here so svc-* subcommands, all-start, and future install.sh
# integrations can't drift out of sync.
_svc_lookup() {
  case "$1" in
    agent)    printf '%s\t%s\n' "$LABEL"          "$PLIST" ;;
    watcher)  printf '%s\t%s\n' "$WATCHER_LABEL"  "$WATCHER_PLIST" ;;
    telegram) printf '%s\t%s\n' "$TELEGRAM_LABEL" "$TELEGRAM_PLIST" ;;
    digest)   printf '%s\t%s\n' "$DIGEST_LABEL"   "$DIGEST_PLIST" ;;
    *)        return 1 ;;
  esac
}

# _svc_bootstrap <label> <plist>
# Idempotent "load this plist into the GUI launchd domain" using modern
# `bootstrap`, with a fallback to legacy `load`. Returns 0 if the service
# ends up loaded, 1 otherwise. Stderr is preserved so the caller can
# surface the real cause to the user (usually "plist not found" or
# sandboxed shell with no gui/$uid domain).
_svc_bootstrap() {
  local label="$1" path="$2"
  local uid domain; uid=$(id -u); domain="gui/$uid"
  [[ -f "$path" ]] || { echo "  missing plist: $path" >&2; return 1; }
  # Already loaded? launchctl print is the authoritative check.
  if launchctl print "$domain/$label" >/dev/null 2>&1; then
    echo "  already loaded: $label"
    return 0
  fi
  # Clean any half-state from a prior bootout/unload.
  launchctl bootout "$domain/$label" 2>/dev/null || true
  if launchctl bootstrap "$domain" "$path" 2>/tmp/adev-ctl.err; then
    echo "  loaded: $label"
    return 0
  fi
  # Legacy fallback for older macOS versions without bootstrap semantics.
  if launchctl load "$path" 2>>/tmp/adev-ctl.err; then
    echo "  loaded (legacy): $label"
    return 0
  fi
  echo "  FAILED to load $label" >&2
  cat /tmp/adev-ctl.err >&2 2>/dev/null || true
  rm -f /tmp/adev-ctl.err
  return 1
}

# Map a service short name (agent|watcher|telegram|digest) to the script
# filename launchd runs for it. Used by _svc_bootout to find and kill orphan
# processes that launchd either doesn't know about anymore (crossed sessions,
# mixed bootstrap/load history) or didn't manage to terminate cleanly during
# bootout. Matches exactly one script per service, so pkill -f is safe.
_svc_script_name() {
  case "$1" in
    agent)    echo "run-agent.sh" ;;
    watcher)  echo "watcher.sh" ;;
    telegram) echo "telegram-handler.sh" ;;
    digest)   echo "daily-digest.sh" ;;
    *)        return 1 ;;
  esac
}

# _svc_reap_orphans <svc_name>
# Kill any process running the service's script file that launchd lost track
# of. Sends SIGTERM, waits up to 3s, then SIGKILL on survivors. Prints a one-
# line summary of how many orphans were reaped (0 on clean state).
_svc_reap_orphans() {
  local svc="$1" script
  script=$(_svc_script_name "$svc") || return 0
  # Restrict to the installed path under the user's home to avoid nuking a
  # dev checkout running in another terminal. The sh's cwd is irrelevant —
  # launchd always invokes the plist's exact absolute path, which is under
  # $SKILL_DIR. If the user has a separate checkout running by hand, it'll
  # show under a different absolute path and be left alone.
  local pattern="$SKILL_DIR/scripts.*/${script}"
  # shellcheck disable=SC2009
  local pids
  pids=$(pgrep -f "$pattern" 2>/dev/null || true)
  [[ -z "$pids" ]] && { echo "  orphans: 0"; return 0; }
  local count; count=$(echo "$pids" | wc -l | tr -d ' ')
  echo "  orphans found ($count): $(echo "$pids" | tr '\n' ' ')"
  # TERM first, then escalate. Bash's own kill handles "operation not
  # permitted" cleanly (prints to stderr, returns non-zero, loop continues).
  for p in $pids; do kill -TERM "$p" 2>/dev/null || true; done
  local waited=0
  while [[ $waited -lt 3 ]]; do
    sleep 1
    waited=$((waited+1))
    pids=$(pgrep -f "$pattern" 2>/dev/null || true)
    [[ -z "$pids" ]] && { echo "  orphans: reaped cleanly"; return 0; }
  done
  echo "  orphans still alive after 3s — sending SIGKILL"
  for p in $pids; do kill -9 "$p" 2>/dev/null || true; done
  sleep 1
  pids=$(pgrep -f "$pattern" 2>/dev/null || true)
  if [[ -n "$pids" ]]; then
    echo "  WARN: could not kill pids: $pids — check with 'ps -p $pids'" >&2
    return 1
  fi
  echo "  orphans: killed"
  return 0
}

_svc_bootout() {
  local label="$1" path="$2"
  local uid domain; uid=$(id -u); domain="gui/$uid"
  # Try modern API first. `bootout` on a service that isn't loaded returns
  # non-zero — that's fine, we still want the reap pass afterwards.
  local booted_out=0
  if launchctl bootout "$domain/$label" 2>/dev/null; then
    echo "  unloaded: $label"
    booted_out=1
  else
    # Legacy fallback. Do NOT lie about success — check whether the service
    # actually ended up gone before claiming victory. The old implementation
    # printed "unloaded (legacy)" even when launchctl unload failed silently,
    # which masked duplicate-daemon drift.
    if launchctl unload "$path" 2>/dev/null; then
      echo "  unloaded (legacy): $label"
      booted_out=1
    elif ! launchctl list 2>/dev/null | grep -q -- "$label"; then
      # Already gone from launchd's view — nothing to do at the service level.
      echo "  not loaded: $label"
      booted_out=1
    else
      echo "  WARN: bootout+unload both failed for $label" >&2
    fi
  fi
  # Reap orphan processes regardless. launchd's bootout sends SIGTERM to the
  # process group but doesn't wait for it, and long-running bash daemons
  # (telegram-handler) sometimes outlive a crossed-session bootout because
  # they own child caffeinate/curl pids the group signal missed. Without
  # this pass, the next _svc_bootstrap creates a second instance alongside
  # the stale one and they race for the same Telegram long-poll queue.
  local svc
  case "$label" in
    *autonomous-dev-agent)  svc=agent ;;
    *dev-agent-watcher)     svc=watcher ;;
    *dev-agent-telegram)    svc=telegram ;;
    *dev-agent-digest)      svc=digest ;;
    *)                      svc="" ;;
  esac
  [[ -n "$svc" ]] && _svc_reap_orphans "$svc"
  return 0
}

case "${1:-help}" in
  start)
    echo "Loading agent (runs every 30 minutes)..."
    launchctl load "$PLIST" 2>/dev/null
    launchctl start "$LABEL"
    start_caffeinate
    echo "Agent scheduled. Use './ctl.sh status' to check."
    ;;

  stop)
    echo "Stopping agent..."
    launchctl unload "$PLIST" 2>/dev/null
    stop_caffeinate
    echo "Agent stopped and unscheduled."
    ;;

  status)
    echo "=== Agent ==="
    if launchctl list 2>/dev/null | grep -q "$LABEL"; then
      echo "  Scheduled (every 30 min)"
    else
      echo "  NOT loaded"
    fi

    echo "=== Telegram Handler ==="
    if launchctl list 2>/dev/null | grep -q "$TELEGRAM_LABEL"; then
      echo "  Running (long-polling, instant response)"
    else
      echo "  NOT loaded"
    fi

    echo "=== Daily Digest ==="
    if launchctl list 2>/dev/null | grep -q "$DIGEST_LABEL"; then
      echo "  Scheduled (20:00 GMT+4 daily)"
    else
      echo "  NOT loaded"
    fi

    echo "=== Keep Awake (caffeinate) ==="
    if is_caffeinate_running; then
      local caffeinate_pid=$(cat "$CAFFEINATE_PID_FILE" 2>/dev/null)
      local power_source=$(pmset -g ps | head -1 | grep -oE "AC Power|Battery Power" || echo "Unknown")
      echo "  Running (PID $caffeinate_pid) — effective only on AC Power"
      echo "  Current power: $power_source"
    else
      echo "  NOT running"
    fi

    echo "=== Last Run ==="
    LATEST=$(ls -t "$LOG_DIR"/*.log 2>/dev/null | grep -v telegram | grep -v digest | head -1)
    if [ -n "$LATEST" ]; then
      head -3 "$LATEST"
    else
      echo "  No runs yet"
    fi
    ;;

  run)
    echo "Running agent once (manually)..."
    bash "$SKILL_DIR/scripts/run-agent.sh"
    ;;

  logs)
    LATEST=$(ls -t "$LOG_DIR"/*.log 2>/dev/null | grep -v telegram | grep -v digest | head -1)
    if [ -n "$LATEST" ]; then
      echo "=== Latest log: $LATEST ==="
      cat "$LATEST"
    else
      echo "No logs found."
    fi
    ;;

  digest)
    echo "Sending daily digest..."
    bash "$SKILL_DIR/scripts/daily-digest.sh"
    ;;

  handler-start)
    echo "Starting Telegram handler (long-polling daemon)..."
    launchctl load "$TELEGRAM_PLIST" 2>/dev/null
    echo "Telegram handler started."
    ;;

  handler-stop)
    echo "Stopping Telegram handler..."
    launchctl unload "$TELEGRAM_PLIST" 2>/dev/null
    echo "Telegram handler stopped."
    ;;

  all-start)
    echo "Starting all services..."
    # Previously this path skipped the watcher, which is the service that
    # drives nearly every Telegram notification (CI status, new comments,
    # ticket transitions). The agent *run* is useful on its own, but without
    # the watcher there are no proactive notifications. Loading all four
    # also matches what the SwiftBar plugin expects when computing the
    # "Running (4/4)" green-state indicator.
    for svc in agent watcher telegram digest; do
      read -r L P < <(_svc_lookup "$svc")
      _svc_bootstrap "$L" "$P" || true
    done
    start_caffeinate
    ;;

  all-stop)
    echo "Stopping all services..."
    for svc in agent watcher telegram digest; do
      read -r L P < <(_svc_lookup "$svc")
      _svc_bootout "$L" "$P"
    done
    stop_caffeinate
    echo "All services stopped."
    ;;

  svc-start)
    # svc-start <name>: load exactly one service by short name.
    if ! read -r L P < <(_svc_lookup "${2:-}"); then
      echo "svc-start: unknown service '${2:-}' (expected agent|watcher|telegram|digest)" >&2
      exit 2
    fi
    _svc_bootstrap "$L" "$P"
    ;;

  svc-stop)
    if ! read -r L P < <(_svc_lookup "${2:-}"); then
      echo "svc-stop: unknown service '${2:-}'" >&2
      exit 2
    fi
    _svc_bootout "$L" "$P"
    ;;

  svc-restart)
    # Useful when a config/secrets change needs the daemon to re-read env.
    if ! read -r L P < <(_svc_lookup "${2:-}"); then
      echo "svc-restart: unknown service '${2:-}'" >&2
      exit 2
    fi
    _svc_bootout "$L" "$P"
    _svc_bootstrap "$L" "$P"
    ;;

  svc-killall)
    # Blunt-force: for each service, try bootout, then reap orphans by
    # script path. Useful when duplicate daemons have drifted (e.g. after
    # system sleep/wake cycles that confused launchd's bootstrap state).
    # After this runs, `svc-start <name>` or `all-start` brings a clean
    # set back up. Distinct from `all-stop` because it doesn't trust
    # launchd to know about every live process.
    echo "Killing all dev-agent daemons (bootout + process reap)..."
    for svc in agent watcher telegram digest; do
      echo "  [$svc]"
      read -r L P < <(_svc_lookup "$svc")
      _svc_bootout "$L" "$P" || true
    done
    stop_caffeinate
    echo "Done. Use 'ctl.sh all-start' to bring clean daemons back up."
    ;;

  doctor)
    # Diagnose common drift: duplicate daemons, plist/label mismatch,
    # stale caffeinate pidfile. Read-only — doesn't mutate anything.
    # No `local` keyword here; this block isn't inside a function.
    echo "=== dev-agent doctor ==="
    BAD=0
    for svc in agent watcher telegram digest; do
      SCRIPT=$(_svc_script_name "$svc")
      PATTERN="$SKILL_DIR/scripts.*/${SCRIPT}"
      # shellcheck disable=SC2009
      PIDS=$(pgrep -f "$PATTERN" 2>/dev/null || true)
      COUNT=0
      [[ -n "$PIDS" ]] && COUNT=$(echo "$PIDS" | wc -l | tr -d ' ')
      LOADED=no
      read -r L _ < <(_svc_lookup "$svc")
      launchctl print "gui/$(id -u)/$L" >/dev/null 2>&1 && LOADED=yes
      case "$svc:$LOADED:$COUNT" in
        *:yes:1)   VERDICT="ok" ;;
        *:yes:0)   VERDICT="BROKEN (service loaded but no process alive)" ; BAD=1 ;;
        *:no:0)    VERDICT="ok (not loaded)" ;;
        *:*)       VERDICT="BROKEN ($COUNT orphan process(es) alive, launchd loaded=$LOADED)"; BAD=1 ;;
      esac
      printf "  %-9s loaded=%s  processes=%d  %s\n" "$svc" "$LOADED" "$COUNT" "$VERDICT"
      [[ -n "$PIDS" ]] && echo "           pids: $(echo "$PIDS" | tr '\n' ' ')"
    done
    if [[ $BAD -ne 0 ]]; then
      echo
      echo "Fix with:   bash $0 svc-killall && bash $0 all-start"
      exit 1
    fi
    echo "All good."
    ;;

  *)
    echo "Usage: $0 {start|stop|status|run|logs|digest|handler-start|handler-stop|all-start|all-stop}"
    echo ""
    echo "  Agent (auto-manages Keep Awake on AC power):"
    echo "    start             — Schedule the agent to run every 30 minutes"
    echo "    stop              — Unschedule the agent"
    echo "    run               — Run the agent once right now"
    echo "    logs              — Show the latest run log"
    echo ""
    echo "  Telegram:"
    echo "    handler-start     — Start Telegram long-polling daemon"
    echo "    handler-stop      — Stop Telegram handler"
    echo ""
    echo "  Other:"
    echo "    status            — Check status of all services"
    echo "    digest            — Send daily digest now"
    echo "    all-start         — Start all services (agent + handler + digest)"
    echo "    all-stop          — Stop all services"
    ;;
esac
