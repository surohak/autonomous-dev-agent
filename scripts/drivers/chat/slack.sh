#!/bin/bash
# scripts/drivers/chat/slack.sh
#
# Chat driver for Slack. Uses the Web API via curl.
#
# Telegram-style long-polling has no direct Slack analogue — Slack pushes
# events via Events API webhooks. For the polling architecture the agent
# uses, we emulate it by reading the app's Socket Mode firehose OR by
# polling `conversations.history` since the last event ts. The Socket Mode
# variant requires an `xapp-` token and a running websocket client —
# overkill for a personal tool. This driver uses the simpler
# `conversations.history` approach: we poll every N seconds for new
# messages and callback-payload `actions.respond` submissions. Interactive
# action routing is handled by a tiny webhook (not included) — the MVP
# of this driver supports send + edit + simple poll, and marks
# `chat_send_interactive` as "best-effort" until a Socket Mode driver
# lands.
#
# Env vars:
#   CHAT_KIND=slack
#   SLACK_BOT_TOKEN  xoxb-... (chat:write, reactions, channels:history)
#   CHAT_CHANNEL     a channel id (e.g. C12345678) or user id for DM

[[ -n "${_DEV_AGENT_CHAT_SLACK_LOADED:-}" ]] && return 0
_DEV_AGENT_CHAT_SLACK_LOADED=1

_SLACK_ENDPOINT="https://slack.com/api"

_slack_require() {
  [[ -z "${SLACK_BOT_TOKEN:-}" ]] && { echo "slack: SLACK_BOT_TOKEN missing" >&2; return 3; }
  [[ -z "${CHAT_CHANNEL:-}" ]]    && { echo "slack: CHAT_CHANNEL missing" >&2; return 2; }
}

_slack_api() {
  local method="$1" path="$2" body="${3:-}"
  if [[ "$method" == "GET" ]]; then
    curl -s -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
         "${_SLACK_ENDPOINT}/${path}" 2>/dev/null
  else
    curl -s -X "$method" \
         -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
         -H "Content-Type: application/json; charset=utf-8" \
         --data "$body" \
         "${_SLACK_ENDPOINT}/${path}" 2>/dev/null
  fi
}

chat_probe() {
  _slack_require || return $?
  local out
  out=$(_slack_api GET "auth.test")
  printf '%s' "$out" | grep -q '"ok":true'
}

chat_send() {
  _slack_require || return $?
  local text="$*"
  local body
  body=$(CH="$CHAT_CHANNEL" TEXT="$text" python3 -c '
import json, os
print(json.dumps({"channel": os.environ["CH"], "text": os.environ["TEXT"]}))
')
  local out
  out=$(_slack_api POST "chat.postMessage" "$body")
  printf '%s' "$out" | grep -q '"ok":true'
}

# Translate canonical actions JSON into Slack Block Kit:
#   section (text) + actions (buttons).
_slack_blocks_for() {
  local text="$1" actions_json="$2"
  TEXT="$text" ACTIONS="$actions_json" python3 -c '
import json, os
text = os.environ["TEXT"]
try:
    actions = json.loads(os.environ["ACTIONS"])
except Exception:
    actions = []
if not isinstance(actions, list): actions = []
elements = []
for a in actions:
    if not isinstance(a, dict): continue
    label = a.get("label") or ""
    cb    = a.get("id") or ""
    if not label or not cb: continue
    elem = {
        "type": "button",
        "text": {"type": "plain_text", "text": label},
        "value": cb,
        "action_id": cb,
    }
    if a.get("style") in ("primary","danger"):
        elem["style"] = a["style"]
    elements.append(elem)
blocks = [{"type":"section","text":{"type":"mrkdwn","text":text}}]
if elements:
    blocks.append({"type":"actions","elements":elements})
print(json.dumps(blocks))
'
}

chat_send_interactive() {
  local text="$1" actions_json="${2:-[]}"
  _slack_require || return $?
  local blocks
  blocks=$(_slack_blocks_for "$text" "$actions_json")
  local body
  body=$(CH="$CHAT_CHANNEL" TEXT="$text" BLOCKS="$blocks" python3 -c '
import json, os
print(json.dumps({
    "channel": os.environ["CH"],
    "text":    os.environ["TEXT"],
    "blocks":  json.loads(os.environ["BLOCKS"]),
}))
')
  local out
  out=$(_slack_api POST "chat.postMessage" "$body")
  # Emit the ts so the caller can edit/delete later.
  printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("ts","") if d.get("ok") else "")'
}

chat_edit() {
  local msg_id="$1" text="$2" actions_json="${3:-[]}"
  _slack_require || return $?
  local blocks
  blocks=$(_slack_blocks_for "$text" "$actions_json")
  local body
  body=$(CH="$CHAT_CHANNEL" TS="$msg_id" TEXT="$text" BLOCKS="$blocks" python3 -c '
import json, os
print(json.dumps({
    "channel": os.environ["CH"],
    "ts":      os.environ["TS"],
    "text":    os.environ["TEXT"],
    "blocks":  json.loads(os.environ["BLOCKS"]),
}))
')
  _slack_api POST "chat.update" "$body" | grep -q '"ok":true'
}

# chat_poll [<cursor>]
# Cursor is the latest Slack event ts. We fetch conversation history since
# it and emit canonical events. Button clicks are delivered via the Events
# API webhook — this poll-only driver won't see them, which is why
# chat_send_interactive is "best-effort" until a webhook bridge exists.
chat_poll() {
  local cursor="${1:-0}"
  _slack_require || return $?
  local params="channel=${CHAT_CHANNEL}&limit=20"
  [[ "$cursor" != "0" ]] && params="${params}&oldest=${cursor}"
  local raw
  raw=$(_slack_api GET "conversations.history?${params}") || return 1

  printf '%s' "$raw" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(json.dumps({"events":[],"next":"0"})); sys.exit(0)
msgs = d.get("messages") or []
events = []
next_ts = "0"
for m in msgs:
    ts = m.get("ts","0")
    if ts > next_ts: next_ts = ts
    text = m.get("text","") or ""
    if not text: continue
    events.append({
        "type": "message",
        "text": text,
        "user": m.get("user","") or "",
        "chat": m.get("channel","") or "",
        "msg_id": ts,
    })
# Reverse so oldest first (Slack returns newest first).
events.reverse()
print(json.dumps({"events": events, "next": next_ts}))
'
}
