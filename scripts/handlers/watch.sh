#!/bin/bash
# scripts/handlers/watch.sh — watcher / notification-gate commands:
#   cmd_watch          — show watcher + snooze status
#   handler_snooze <arg> — snooze for N seconds / "1h" / "30m"
#   cmd_unsnooze       — clear snooze
#   cmd_hide_menu      — remove the legacy reply keyboard

[[ -n "${_DEV_AGENT_HANDLER_WATCH_LOADED:-}" ]] && return 0
_DEV_AGENT_HANDLER_WATCH_LOADED=1

cmd_watch() {
  local watcher_status="Stopped"
  if launchctl list 2>/dev/null | grep -q "${LAUNCHD_LABEL_PREFIX}.dev-agent-watcher"; then
    watcher_status="Running (every 2 min)"
  fi
  local snooze_status="active"
  if [ -f "$CACHE_DIR/watcher-snoozed.until" ]; then
    local until now left
    until=$(cat "$CACHE_DIR/watcher-snoozed.until")
    now=$(date +%s)
    if [ "$now" -lt "$until" ]; then
      left=$(( (until - now) / 60 ))
      snooze_status="snoozed (${left} min left)"
    fi
  fi
  local last_tick
  last_tick=$(tail -1 "$SKILL_DIR/logs/watcher.log" 2>/dev/null || echo "never")
  tg_send "Watcher: $watcher_status
Notifications: $snooze_status
Last tick: $last_tick"
}

handler_snooze() {
  local raw="$1"
  local arg secs until min
  arg=$(echo "$raw" | awk '{print $2}')
  if [[ "$arg" =~ ^[0-9]+$ ]]; then
    secs="$arg"
  elif [[ "$arg" =~ ^([0-9]+)h$ ]]; then
    secs=$(( ${BASH_REMATCH[1]} * 3600 ))
  elif [[ "$arg" =~ ^([0-9]+)m$ ]]; then
    secs=$(( ${BASH_REMATCH[1]} * 60 ))
  else
    secs=3600
  fi
  until=$(( $(date +%s) + secs ))
  echo "$until" > "$CACHE_DIR/watcher-snoozed.until"
  min=$(( secs / 60 ))
  tg_send "Watcher snoozed for ${min} min."
}

cmd_unsnooze() {
  rm -f "$CACHE_DIR/watcher-snoozed.until"
  tg_send "Watcher resumed."
}

cmd_hide_menu() {
  # Reply keyboard removed — use Telegram's native "/" slash-command menu instead.
  tg_send_raw "$(python3 -c "
import json, os
print(json.dumps({
    'chat_id': os.environ['TELEGRAM_CHAT_ID'],
    'text': 'Use the / menu in Telegram for all commands.',
    'reply_markup': {'remove_keyboard': True},
}))")"
}
