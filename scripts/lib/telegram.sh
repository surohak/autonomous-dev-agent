#!/bin/bash
# scripts/lib/telegram.sh
#
# Unified Telegram Bot API helpers. All functions accept raw text (any bytes:
# quotes, backslashes, newlines, backticks) and JSON-encode safely via Python.
#
# Required env (from secrets.env, loaded by env.sh):
#   TELEGRAM_BOT_TOKEN
#   TELEGRAM_CHAT_ID
#
# Public functions:
#   tg_send          <text>                       — plain message
#   tg_inline        <text> <inline_keyboard_json>— message with inline buttons
#   tg_force_reply   <text>                       — message that opens reply box
#   tg_answer        <callback_id> [<toast_text>] — dismiss spinner on a button tap
#   tg_edit_text     <message_id> <new_text>      — edit message in place
#   tg_send_raw      <json_payload>               — escape hatch; sendMessage
#
# All functions return 0 on success (HTTP 200) and 1 on any error so callers
# can persist "already-notified" state only on success.

[[ -n "${_DEV_AGENT_TG_LOADED:-}" ]] && return 0
_DEV_AGENT_TG_LOADED=1

# --- private: low-level POST with optional JSON payload on stdin ----------
_tg_call() {
  local method="$1"
  [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]] && { echo "tg: TELEGRAM_BOT_TOKEN unset" >&2; return 1; }
  curl -s --max-time 15 -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/${method}" \
    -H "Content-Type: application/json" \
    --data-binary @- > /dev/null 2>&1
}

# --- private: build + post {"chat_id","text",...} via Python JSON encoding --
_tg_post_json() {
  # $1 = python expression producing the payload dict (has access to os.environ)
  local expr="$1"
  TG_CHAT="$TELEGRAM_CHAT_ID" python3 -c "
import json, os
payload = $expr
print(json.dumps(payload))
" | _tg_call sendMessage
}

# ---------------------------------------------------------------------------

tg_send() {
  local text="$1"
  TG_TEXT="$text" _tg_post_json '{
    "chat_id": int(os.environ["TG_CHAT"]),
    "text":    os.environ["TG_TEXT"],
  }'
}

tg_send_raw() {
  printf '%s' "$1" | _tg_call sendMessage
}

tg_inline() {
  local text="$1" keyboard="$2"
  TG_TEXT="$text" TG_KB="$keyboard" _tg_post_json '{
    "chat_id":      int(os.environ["TG_CHAT"]),
    "text":         os.environ["TG_TEXT"],
    "reply_markup": {"inline_keyboard": json.loads(os.environ["TG_KB"])},
  }'
}

tg_force_reply() {
  local text="$1"
  TG_TEXT="$text" _tg_post_json '{
    "chat_id":      int(os.environ["TG_CHAT"]),
    "text":         os.environ["TG_TEXT"],
    "reply_markup": {"force_reply": True, "selective": False},
  }'
}

tg_answer() {
  local cb_id="$1" toast="${2:-}"
  [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]] && return 1
  local payload
  if [[ -n "$toast" ]]; then
    payload=$(TG_CB="$cb_id" TG_TX="$toast" python3 -c '
import json, os
print(json.dumps({"callback_query_id": os.environ["TG_CB"],
                  "text": os.environ["TG_TX"]}))')
  else
    payload=$(TG_CB="$cb_id" python3 -c '
import json, os
print(json.dumps({"callback_query_id": os.environ["TG_CB"]}))')
  fi
  printf '%s' "$payload" | _tg_call answerCallbackQuery
}

tg_edit_text() {
  local mid="$1" text="$2"
  TG_MID="$mid" TG_TEXT="$text" python3 -c '
import json, os
print(json.dumps({
    "chat_id":    int(os.environ["TG_CHAT"]) if "TG_CHAT" in os.environ else int(os.environ.get("TELEGRAM_CHAT_ID","0")),
    "message_id": int(os.environ["TG_MID"]),
    "text":       os.environ["TG_TEXT"],
}))' | TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN" TG_CHAT="$TELEGRAM_CHAT_ID" _tg_call editMessageText
}

# --- Back-compat aliases used by existing scripts --------------------------
# Keep the old names alive so retrofits are mechanical (rename, don't rewrite).
send_telegram()        { tg_send "$@"; }
send_telegram_raw()    { tg_send_raw "$@"; }
send_telegram_inline() { tg_inline "$@"; }
send_force_reply()     { tg_force_reply "$@"; }
answer_callback()      { tg_answer "$@"; }
tg_send_inline()       { tg_inline "$@"; }   # matches `notify-review-ready.sh` style
