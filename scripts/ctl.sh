#!/bin/bash
# Control script for the autonomous dev agent
# Usage: ./ctl.sh [start|stop|status|run|logs|digest|handler-start|handler-stop|all-start|all-stop]

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
    launchctl load "$PLIST" 2>/dev/null
    launchctl start "$LABEL"
    launchctl load "$TELEGRAM_PLIST" 2>/dev/null
    launchctl load "$DIGEST_PLIST" 2>/dev/null
    echo "All services started:"
    echo "  - Agent: every 30 min"
    echo "  - Telegram handler: every 60s"
    echo "  - Daily digest: 20:00 GMT+4"
    start_caffeinate
    ;;

  all-stop)
    echo "Stopping all services..."
    launchctl unload "$PLIST" 2>/dev/null
    launchctl unload "$TELEGRAM_PLIST" 2>/dev/null
    launchctl unload "$DIGEST_PLIST" 2>/dev/null
    stop_caffeinate
    echo "All services stopped."
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
