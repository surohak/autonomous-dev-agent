#!/usr/bin/env bash
# diagnose-telegram.sh — end-to-end diagnostic + targeted fix for the
# "Telegram not replying" class of issues. Runs every check in order, prints
# a clear verdict at each step, and only moves on if the previous step passed.
#
# Usage: bash "$HOME/.cursor/skills/autonomous-dev-agent/scripts/diagnose-telegram.sh"
#
# Exit codes:
#   0 — everything healthy, /cherries should work
#   1 — token invalid or bot revoked (need fresh token from @BotFather)
#   2 — network / DNS issue reaching api.telegram.org
#   3 — launchd state wedged (bootstrap limbo)
#   4 — handler crashing on startup (check stderr log)
#   5 — unknown state, output included

set -u

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS="$SKILL_DIR/secrets.env"
HANDLER="$SKILL_DIR/scripts/telegram-handler.sh"
LOG="$SKILL_DIR/logs/telegram-handler.log"
ERR="$SKILL_DIR/logs/telegram-handler-error.log"
LA_DIR="$HOME/Library/LaunchAgents"
UID_NUM="$(id -u)"

hdr() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; }
info(){ printf '    %s\n' "$*"; }

# Load secrets so TELEGRAM_BOT_TOKEN is available
if [ ! -f "$SECRETS" ]; then
  bad "secrets.env missing at $SECRETS"
  exit 1
fi
set -a; . "$SECRETS" 2>/dev/null; set +a
TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT="$(/usr/bin/python3 -c "import json; c=json.load(open('$SKILL_DIR/config.json')); print(c.get('chat',{}).get('chatId',''))" 2>/dev/null)"

# ===================================================================
hdr "1. credentials"
if [ -z "$TOKEN" ]; then bad "TELEGRAM_BOT_TOKEN is empty"; exit 1; fi
ok "token length: ${#TOKEN} (prefix: ${TOKEN:0:10}…)"
if [ -z "$CHAT" ]; then bad "chat id missing from config.json"; exit 1; fi
ok "chat id: $CHAT"

# ===================================================================
hdr "2. Telegram API reachability + token validity (getMe)"
RESP="$(/usr/bin/curl -s --max-time 10 "https://api.telegram.org/bot${TOKEN}/getMe")"
if [ -z "$RESP" ]; then
  bad "no response from api.telegram.org — network or DNS issue"
  info "try: curl -v https://api.telegram.org/"
  exit 2
fi
OK_FIELD="$(echo "$RESP" | /usr/bin/python3 -c 'import sys,json; d=json.load(sys.stdin); print("yes" if d.get("ok") else "no")' 2>/dev/null)"
if [ "$OK_FIELD" != "yes" ]; then
  bad "getMe returned an error — token is invalid / revoked / rate-limited"
  info "raw response: $RESP"
  info "fix: get a fresh token from @BotFather and put it in $SECRETS"
  exit 1
fi
BOT_NAME="$(echo "$RESP" | /usr/bin/python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["username"])' 2>/dev/null)"
ok "bot @$BOT_NAME is alive and the token is valid"

# ===================================================================
hdr "3. queued updates (what is Telegram holding for us?)"
/usr/bin/curl -s --max-time 10 "https://api.telegram.org/bot${TOKEN}/getUpdates?timeout=0&limit=100" \
  | /usr/bin/python3 -c "
import sys, json
from datetime import datetime
d = json.load(sys.stdin)
if not d.get('ok'):
    print('  ✗ getUpdates error:', d)
    sys.exit(0)
r = d.get('result', [])
print(f'  queued updates waiting for a handler: {len(r)}')
for u in r[:15]:
    msg = u.get('message') or u.get('callback_query', {}).get('message') or {}
    cb = u.get('callback_query')
    t = msg.get('text') or (cb.get('data') if cb else '(no text)')
    ts = msg.get('date')
    ts_s = datetime.fromtimestamp(ts).strftime('%H:%M:%S') if ts else '?'
    print(f'    uid={u.get(\"update_id\")} at {ts_s}: {t!r}')
"

# ===================================================================
hdr "4. handler process state"
PIDS="$(/usr/bin/pgrep -f "$HANDLER" 2>/dev/null || true)"
PCOUNT=0
[ -n "$PIDS" ] && PCOUNT=$(echo "$PIDS" | /usr/bin/wc -l | /usr/bin/tr -d ' ')
info "handler processes alive: $PCOUNT"
if [ "$PCOUNT" -gt 0 ]; then
  /usr/bin/pgrep -fla "$HANDLER" 2>/dev/null | /usr/bin/sed 's/^/    /'
fi
info "launchd jobs loaded:"
/bin/launchctl list 2>/dev/null | /usr/bin/grep -E 'dev-agent-telegram' | /usr/bin/sed 's/^/    /' || info "    (none)"

# ===================================================================
hdr "5. nuke any orphan handlers (SIGTERM → 3s → SIGKILL)"
if [ "$PCOUNT" -gt 0 ]; then
  /usr/bin/pkill -TERM -f "$HANDLER" 2>/dev/null || true
  /bin/sleep 3
  /usr/bin/pkill -KILL -f "$HANDLER" 2>/dev/null || true
  /bin/sleep 1
  STILL="$(/usr/bin/pgrep -f "$HANDLER" 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
  if [ "$STILL" != "0" ]; then
    for pid in $(/usr/bin/pgrep -f "$HANDLER"); do /bin/kill -9 "$pid" 2>/dev/null || true; done
    /bin/sleep 1
  fi
fi
AFTER="$(/usr/bin/pgrep -f "$HANDLER" 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
if [ "$AFTER" = "0" ]; then ok "no handlers running — clean slate"; else bad "$AFTER still alive — cannot proceed"; exit 5; fi

# ===================================================================
hdr "6. unload ALL telegram plists from launchd"
FOUND_PLIST=0
for plist in "$LA_DIR"/*dev-agent-telegram*.plist; do
  [ -f "$plist" ] || continue
  FOUND_PLIST=1
  label="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$plist" 2>/dev/null)"
  info "plist: $plist (label: $label)"
  /bin/launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null && info "  bootout ok" || \
  /bin/launchctl bootout "gui/$UID_NUM" "$plist" 2>/dev/null && info "  bootout (by path) ok" || \
  /bin/launchctl unload "$plist" 2>/dev/null && info "  legacy unload ok" || \
  info "  (already unloaded)"
done
if [ "$FOUND_PLIST" = "0" ]; then bad "no plists at $LA_DIR/*dev-agent-telegram*.plist"; exit 3; fi
/bin/sleep 3

# ===================================================================
hdr "7. bootstrap one fresh daemon"
LOADED=0
for plist in "$LA_DIR"/*dev-agent-telegram*.plist; do
  [ -f "$plist" ] || continue
  label="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$plist" 2>/dev/null)"
  info "bootstrap: $label"
  if /bin/launchctl bootstrap "gui/$UID_NUM" "$plist" 2>/tmp/tgdiag.$$; then
    ok "loaded"
    LOADED=$((LOADED+1))
  else
    ERRMSG="$(cat /tmp/tgdiag.$$)"
    bad "bootstrap failed: $ERRMSG"
    if echo "$ERRMSG" | /usr/bin/grep -qE 'Input/output error|File exists|already loaded|5:'; then
      info "limbo detected — retrying after extended cleanup"
      /bin/launchctl bootout "gui/$UID_NUM/$label"  2>/dev/null || true
      /bin/launchctl bootout "gui/$UID_NUM" "$plist" 2>/dev/null || true
      /bin/launchctl unload "$plist" 2>/dev/null || true
      /bin/sleep 5
      if /bin/launchctl bootstrap "gui/$UID_NUM" "$plist" 2>/tmp/tgdiag.$$; then
        ok "loaded (after limbo cleanup)"
        LOADED=$((LOADED+1))
      else
        bad "still failing: $(cat /tmp/tgdiag.$$)"
        bad "launchd is wedged — a full reboot is the standard fix for this state"
        /bin/rm -f /tmp/tgdiag.$$
        exit 3
      fi
    fi
  fi
  /bin/rm -f /tmp/tgdiag.$$
done

# ===================================================================
hdr "8. wait 5s for daemon to come up and log"
/bin/sleep 5
RUNNING="$(/usr/bin/pgrep -f "$HANDLER" 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
info "processes now alive: $RUNNING"
if [ "$RUNNING" = "0" ]; then
  bad "daemon did not start — it's crashing on startup"
  info "last 20 stderr lines:"
  /usr/bin/tail -20 "$ERR" 2>/dev/null | /usr/bin/sed 's/^/    /'
  exit 4
fi
if [ "$RUNNING" != "1" ]; then
  bad "unexpected: $RUNNING processes running (want exactly 1)"
  /usr/bin/pgrep -fla "$HANDLER" | /usr/bin/sed 's/^/    /'
fi
info "last 5 log lines:"
/usr/bin/tail -5 "$LOG" | /usr/bin/sed 's/^/    /'

# ===================================================================
hdr "9. end-to-end test: send a ping through the bot"
PING_ID=$RANDOM
PING_TEXT="🔧 Diagnostic ping #${PING_ID} at $(/bin/date '+%H:%M:%S') — if you see this in Telegram AND /cherries starts working, we're done."
RESP="$(/usr/bin/curl -s --max-time 10 -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${CHAT}" \
  --data-urlencode "text=${PING_TEXT}")"
SENT="$(echo "$RESP" | /usr/bin/python3 -c 'import sys,json; d=json.load(sys.stdin); print("yes" if d.get("ok") else "no")' 2>/dev/null)"
if [ "$SENT" = "yes" ]; then
  ok "test message delivered to chat $CHAT (ping #$PING_ID)"
else
  bad "sendMessage failed: $RESP"
  exit 5
fi

# ===================================================================
hdr "VERDICT"
ok "single clean handler running"
ok "token + network + chat routing all working"
ok "test ping delivered to Telegram"
echo ""
echo "Now in Telegram:"
echo "  1. You should see the ping message (#$PING_ID)."
echo "  2. Send /cherries — it should reply within ~1s."
echo ""
echo "If /cherries does NOT reply but you saw the ping, paste:"
echo "  tail -40 $LOG"
echo "— that will show whether the handler received and dispatched the command."
exit 0
