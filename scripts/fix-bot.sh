#!/bin/bash
# fix-bot.sh — single-shot resolver for "handler alive but not answering".
#
# Diagnoses and fixes the two conditions that make getUpdates silently return
# empty results forever:
#   1) A webhook is set on the bot token (steals updates from polling)
#   2) A competing getUpdates consumer is holding the stream (Telegram 409)
#
# Always ends by bouncing the launchd job so the handler picks up any
# code changes (e.g. the new API-error logging).
#
# Safe to run from ANY shell (outside the Cursor sandbox). No arguments.

set -uo pipefail

SKILL_DIR="${SKILL_DIR:-$HOME/.cursor/skills/autonomous-dev-agent}"
LABEL="com.sh.dev-agent-telegram"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG="$SKILL_DIR/logs/telegram-handler.log"
ERR_LOG="$SKILL_DIR/logs/telegram-handler-error.log"
OFFSET_FILE="$SKILL_DIR/cache/telegram-offset.txt"

# shellcheck disable=SC1090
source "$SKILL_DIR/secrets.env" 2>/dev/null

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
  echo "FATAL: TELEGRAM_BOT_TOKEN not set (expected in $SKILL_DIR/secrets.env)" >&2
  exit 1
fi
if [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
  echo "FATAL: TELEGRAM_CHAT_ID not set (expected in $SKILL_DIR/secrets.env)" >&2
  exit 1
fi

API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"

hr() { printf '%.0s─' {1..68}; echo; }
step() { echo; hr; echo "▸ $1"; hr; }

step "1. Who does Telegram think the bot is? (token valid?)"
curl -s --max-time 8 "$API/getMe" | python3 -m json.tool || {
  echo "ERROR: getMe failed — check TELEGRAM_BOT_TOKEN or network" >&2
  exit 2
}

step "2. Is a webhook stealing updates?"
WH_JSON=$(curl -s --max-time 8 "$API/getWebhookInfo")
echo "$WH_JSON" | python3 -m json.tool
WH_URL=$(echo "$WH_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("result") or {}).get("url",""))')
if [ -n "$WH_URL" ]; then
  echo
  echo "→ Webhook is SET to: $WH_URL"
  echo "→ This PREVENTS polling. Deleting it now (keeping pending updates)..."
  DEL=$(curl -s --max-time 8 "$API/deleteWebhook?drop_pending_updates=false")
  echo "$DEL" | python3 -m json.tool
else
  echo
  echo "✓ No webhook set. (That's what we want for polling.)"
fi

step "3. Drain check: how many updates are queued for our bot RIGHT NOW?"
PENDING=$(curl -s --max-time 10 "$API/getUpdates?timeout=0&limit=100")
echo "$PENDING" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if d.get("ok") is False:
    print(f"  API error: code={d.get(\"error_code\")} desc={d.get(\"description\")}")
    print("  ↑ If 409, another process is competing for this bot token.")
    sys.exit(0)
r = d.get("result") or []
print(f"  count = {len(r)}")
ids = [u.get("update_id") for u in r]
if ids:
    print(f"  first_update_id = {min(ids)}")
    print(f"  last_update_id  = {max(ids)}")
for u in r[:5]:
    cq = u.get("callback_query") or {}
    msg = u.get("message") or {}
    txt = msg.get("text") or cq.get("data") or "(non-text)"
    print(f"    update_id={u.get(\"update_id\")} → {txt[:100]!r}")
'

step "4. Current offset state"
CUR_OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)
echo "  stored offset: $CUR_OFFSET"
echo "  offset file mtime: $(stat -f '%Sm' "$OFFSET_FILE" 2>/dev/null || echo '(missing)')"

step "5. Restart the launchd handler so the new code loads and the loop resumes fresh"
# Bootout may fail if not loaded — that's fine.
/bin/launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null
sleep 1
# Reap any orphaned handler processes that slipped past launchd (belt-and-braces)
for pid in $(pgrep -f 'scripts/telegram-handler\.sh' 2>/dev/null); do
  echo "  reaping orphan handler pid=$pid"
  kill -TERM "$pid" 2>/dev/null
done
sleep 1
for pid in $(pgrep -f 'scripts/telegram-handler\.sh' 2>/dev/null); do
  echo "  force-killing stubborn handler pid=$pid"
  kill -KILL "$pid" 2>/dev/null
done

if /bin/launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/tmp/fix-bot-boot.err; then
  echo "  ✓ bootstrapped $LABEL"
else
  echo "  ! bootstrap first attempt failed — launchd may be in limbo, retrying in 3s"
  cat /tmp/fix-bot-boot.err
  sleep 3
  /bin/launchctl bootstrap "gui/$(id -u)" "$PLIST" && echo "  ✓ bootstrapped on retry" \
    || { echo "  ✗ bootstrap still failing — reboot may be required"; exit 3; }
fi

step "6. Verify handler is running and actually processing"
sleep 3
STATE=$(/bin/launchctl print "gui/$(id -u)/${LABEL}" 2>/dev/null | grep -E 'state|pid|runs' | head -5)
echo "$STATE"
echo
echo "  latest log lines:"
tail -10 "$LOG" 2>/dev/null | sed 's/^/    /'
echo
echo "  latest stderr (last 5 lines, if any):"
tail -5 "$ERR_LOG" 2>/dev/null | sed 's/^/    /'

step "7. End-to-end: send yourself a test ping"
PING=$(curl -s --max-time 8 -X POST "$API/sendMessage" \
  --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text=fix-bot.sh: outbound works. Now send /status to verify inbound." )
OK=$(echo "$PING" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ok"))')
if [ "$OK" = "True" ]; then
  echo "  ✓ Sent. Check Telegram — the ping should appear."
  echo "  ▸ Now reply with /status in Telegram. If you see a reply, the bot is fully working."
  echo "  ▸ If no reply within 30s, tail -f $LOG and watch for 'WARN: Telegram API error' lines."
else
  echo "  ✗ sendMessage failed:"
  echo "$PING" | python3 -m json.tool
  exit 4
fi
