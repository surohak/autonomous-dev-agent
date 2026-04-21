#!/bin/bash
# trace-bot.sh — restart the handler with full tracing enabled and live-tail
# the log for 60 seconds. Send /status in Telegram while it runs; the TRACE
# lines will show exactly what the handler does with your command.
#
# What you'll see:
#   TRACE: iter_start offset=N            ← every loop iteration
#   TRACE: curl getUpdates offset=N ...   ← before the 30s long-poll
#   TRACE: curl returned bytes=N          ← after the long-poll
#   TRACE: parsed msg_count=N next_offset ← after python parsed the response
#   TRACE: saved_offset=N                 ← offset file updated
#   TRACE: dispatch cb_id=- msg_id=X cmd= ← message entering the case stmt
#   (various real work logs, e.g. from /status handler)
#
# If the /status trace DOES appear, your bot is working. If NOT, the trace
# will show the last successful step and we'll know exactly where it got
# stuck.

set -uo pipefail

SKILL_DIR="${SKILL_DIR:-$HOME/.cursor/skills/autonomous-dev-agent}"
LABEL="com.sh.dev-agent-telegram"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG="$SKILL_DIR/logs/telegram-handler.log"
ERR_LOG="$SKILL_DIR/logs/telegram-handler-error.log"
OFFSET_FILE="$SKILL_DIR/cache/telegram-offset.txt"

hr() { printf '%.0s─' {1..68}; echo; }

echo
hr
echo "▸ 1. Stopping the currently-running handler"
hr
/bin/launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null
sleep 1
for pid in $(pgrep -f 'scripts/telegram-handler\.sh' 2>/dev/null); do
  echo "  reaping orphan handler pid=$pid"
  kill -TERM "$pid" 2>/dev/null
done
sleep 1
for pid in $(pgrep -f 'scripts/telegram-handler\.sh' 2>/dev/null); do
  kill -KILL "$pid" 2>/dev/null
done

echo
hr
echo "▸ 2. Resetting offset so the 9 queued messages will be re-delivered"
hr
# Back up the current offset so we can restore it if needed later.
if [ -f "$OFFSET_FILE" ]; then
  cp "$OFFSET_FILE" "${OFFSET_FILE}.pre-trace"
  echo "  prior offset backed up to ${OFFSET_FILE}.pre-trace = $(cat "${OFFSET_FILE}.pre-trace")"
fi
# Telegram keeps updates for 24h; offset=0 → deliver everything still queued.
echo "0" > "$OFFSET_FILE"
echo "  offset reset to 0 (handler will pick up all queued messages on next poll)"

echo
hr
echo "▸ 3. Bootstrapping handler fresh (with HANDLER_DEBUG=1 trace lines)"
hr
if ! /bin/launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/tmp/trace-bot-boot.err; then
  echo "  bootstrap failed, retrying in 3s..."
  cat /tmp/trace-bot-boot.err
  sleep 3
  /bin/launchctl bootstrap "gui/$(id -u)" "$PLIST" || {
    echo "  FATAL: bootstrap still failing"; exit 1;
  }
fi
sleep 2
NEWPID=$(/bin/launchctl print "gui/$(id -u)/${LABEL}" 2>/dev/null | awk -F= '/^\tpid/{gsub(" ",""); print $2}')
echo "  handler pid = ${NEWPID:-unknown}"

echo
hr
echo "▸ 4. LIVE TAIL for 60 seconds"
hr
echo "  → Send /status in Telegram now. Watch the TRACE lines below."
echo "  → If you see 'dispatch cb_id=- msg_id=N cmd=/status' then the handler"
echo "    received your message. If you DON'T, the trace will show the last"
echo "    step it reached before silence."
echo "  → Press Ctrl-C any time to stop the tail (handler keeps running)."
echo

# Tail both logs at once, prefixed so we can tell them apart.
(
  /usr/bin/tail -F -n 5 "$LOG"      2>/dev/null | /usr/bin/sed 's/^/[out] /'
) &
TAIL_OUT=$!
(
  /usr/bin/tail -F -n 0 "$ERR_LOG"  2>/dev/null | /usr/bin/sed 's/^/[err] /'
) &
TAIL_ERR=$!

trap 'kill $TAIL_OUT $TAIL_ERR 2>/dev/null' INT TERM EXIT
sleep 60
kill $TAIL_OUT $TAIL_ERR 2>/dev/null

echo
hr
echo "▸ Trace session ended. Handler is still running."
hr
echo "  To see more, tail -f $LOG"
echo "  To restore previous offset: cp ${OFFSET_FILE}.pre-trace $OFFSET_FILE"
