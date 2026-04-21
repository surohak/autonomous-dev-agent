#!/bin/bash
# scripts/drivers/chat/telegram.sh
#
# Reference chat driver for Telegram. Wraps scripts/lib/telegram.sh behind
# the canonical chat_* contract. See _interface.md.
#
# Env vars (populated by cfg_project_activate):
#   TELEGRAM_BOT_TOKEN    bot API token
#   TELEGRAM_CHAT_ID      target chat id
#   TG_OFFSET_FILE        cursor persistence path (per-bot)

[[ -n "${_DEV_AGENT_CHAT_TELEGRAM_LOADED:-}" ]] && return 0
_DEV_AGENT_CHAT_TELEGRAM_LOADED=1

# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/telegram.sh"

chat_probe() {
  [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]] && return 3
  local out
  out=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" 2>/dev/null || echo '{}')
  if printf '%s' "$out" | grep -q '"ok":true'; then
    return 0
  fi
  return 1
}

chat_send() {
  tg_send "$*"
}

# chat_send_interactive <text> <actions_json>
# Canonical actions are translated to Telegram inline-keyboard rows, 2
# buttons per row. Unknown fields on action objects are ignored.
chat_send_interactive() {
  local text="$1" actions_json="${2:-[]}"
  local kb
  kb=$(printf '%s' "$actions_json" | python3 -c '
import json, sys
try:
    actions = json.load(sys.stdin)
except Exception:
    actions = []
if not isinstance(actions, list):
    actions = []
buttons = []
for a in actions:
    if not isinstance(a, dict): continue
    label = a.get("label") or ""
    cb    = a.get("id") or ""
    if not label or not cb: continue
    buttons.append({"text": label, "callback_data": cb})
# Pack 2 per row
rows = [buttons[i:i+2] for i in range(0, len(buttons), 2)]
print(json.dumps({"inline_keyboard": rows}))
')
  tg_inline "$text" "$kb"
}

chat_edit() {
  local msg_id="$1" text="$2" actions_json="${3:-[]}"
  local kb
  kb=$(printf '%s' "$actions_json" | python3 -c '
import json, sys
try:
    actions = json.load(sys.stdin) or []
except Exception:
    actions = []
buttons = []
for a in actions:
    if not isinstance(a, dict): continue
    label = a.get("label") or ""
    cb    = a.get("id") or ""
    if label and cb:
        buttons.append({"text": label, "callback_data": cb})
rows = [buttons[i:i+2] for i in range(0, len(buttons), 2)]
print(json.dumps({"inline_keyboard": rows}))
')
  tg_edit_text "$msg_id" "$text" "$kb"
}

# chat_poll [<cursor>]
# Emits { "events": [...], "next": <offset> } JSON. `cursor` is a Telegram
# update_id; the poll fetches updates strictly greater than it.
chat_poll() {
  local cursor="${1:-0}"
  local url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates"
  local raw
  raw=$(curl -s "${url}?offset=$((cursor + 1))&timeout=0" 2>/dev/null || echo '{}')

  printf '%s' "$raw" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(json.dumps({"events": [], "next": 0})); sys.exit(0)
events = []
next_cursor = 0
for u in (d.get("result") or []):
    uid = u.get("update_id") or 0
    if uid > next_cursor: next_cursor = uid
    if "message" in u:
        m = u["message"]
        events.append({
            "type":    "message",
            "text":    m.get("text","") or "",
            "user":    str(((m.get("from") or {}).get("id","")) or ""),
            "chat":    str(((m.get("chat") or {}).get("id","")) or ""),
            "msg_id":  m.get("message_id"),
        })
    elif "callback_query" in u:
        q = u["callback_query"]
        events.append({
            "type": "action",
            "id":   q.get("data","") or "",
            "user": str(((q.get("from") or {}).get("id","")) or ""),
            "chat": str(((q.get("message") or {}).get("chat") or {}).get("id","") or ""),
            "msg":  ((q.get("message") or {}).get("message_id")),
        })
print(json.dumps({"events": events, "next": next_cursor}))
'
}
