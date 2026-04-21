#!/bin/bash
# trace-click.sh — watch the Telegram handler while you click a button.
#
# Unlike trace-bot.sh this does NOT restart the handler or reset the offset —
# we just tail the logs with a prefix so you can see exactly how far a
# callback_query tap makes it through the pipeline:
#
#   [out] TRACE: iter_start offset=N
#   [out] TRACE: curl getUpdates offset=N timeout=30
#   [out] TRACE: curl returned bytes=N            ← N>4 means Telegram sent us something
#   [out] TRACE: parsed msg_count=M next_offset=K ← M==1 → parser saw the click
#   [out] TRACE: dispatch cb_id=123 msg_id=456 cmd=tk_cherry PROJ-942   ← case enters here
#
# If you see "msg_count=1" but no "dispatch" line → the second python3 (the
# JSON→TSV serializer) is crashing. We dump the raw MESSAGES JSON in that case.
#
# If you see "dispatch" but no follow-up `send_telegram` output → the case
# statement didn't match the CMD_LOWER and the default *) silently swallowed
# it. In that case we'll know which command string reached dispatch.

set -uo pipefail

SKILL_DIR="${SKILL_DIR:-$HOME/.cursor/skills/autonomous-dev-agent}"
LOG="$SKILL_DIR/logs/telegram-handler.log"
ERR="$SKILL_DIR/logs/telegram-handler-error.log"

hr() { printf '%.0s─' {1..68}; echo; }

echo
hr
echo "Tailing the handler logs. Click any button in Telegram now."
echo "(Ctrl-C any time to stop — the handler keeps running regardless.)"
hr
echo

# Tag each stream so we can tell them apart in the mixed output.
( /usr/bin/tail -F -n 0 "$LOG" 2>/dev/null | /usr/bin/sed 's/^/[out] /' ) &
TAIL_OUT=$!
( /usr/bin/tail -F -n 0 "$ERR" 2>/dev/null | /usr/bin/sed 's/^/[err] /' ) &
TAIL_ERR=$!

trap 'kill $TAIL_OUT $TAIL_ERR 2>/dev/null' INT TERM EXIT
# Cap the session at 2 minutes so this script doesn't become a zombie tail.
sleep 120
echo
hr
echo "Trace session ended. Handler is still running."
hr
