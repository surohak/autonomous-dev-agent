#!/bin/bash
# scripts/lib/timegate.sh
#
# Shared time-window guards used by watcher.sh and run-agent.sh so they never
# drift out of sync (one says it's work hours, the other says it isn't).
#
# Public functions (all return 0 / 1 for use in `if`):
#   in_work_hours     — current hour falls inside [start, end) in owner's TZ
#   snoozed_now       — global snooze active (cache/watcher-snoozed.until)
#   should_notify     — in_work_hours && !snoozed_now
#
# Config (from config.json via cfg.sh):
#   timezone        (default "Asia/Tbilisi")
#   workHours.start (default 7)
#   workHours.end   (default 23)
#
# These can be overridden per-script by exporting WORK_HOURS_START / END / TZ
# before sourcing.

[[ -n "${_DEV_AGENT_TIMEGATE_LOADED:-}" ]] && return 0
_DEV_AGENT_TIMEGATE_LOADED=1

_timegate_load_config() {
  # Only load once per process
  [[ -n "${_TIMEGATE_CFG_LOADED:-}" ]] && return 0
  _TIMEGATE_CFG_LOADED=1
  if [[ -f "$CONFIG_FILE" ]] && [[ -z "${WORK_HOURS_START:-}" || -z "${WORK_HOURS_END:-}" || -z "${WORK_TZ:-}" ]]; then
    local _cfg
    _cfg=$(python3 -c "
import json
c = json.load(open('$CONFIG_FILE'))
wh = c.get('workHours', {}) or {}
print(wh.get('start', 7))
print(wh.get('end', 23))
print(c.get('timezone', 'Asia/Tbilisi'))
" 2>/dev/null)
    [[ -z "${WORK_HOURS_START:-}" ]] && WORK_HOURS_START=$(sed -n '1p' <<< "$_cfg")
    [[ -z "${WORK_HOURS_END:-}"   ]] && WORK_HOURS_END=$(sed -n '2p' <<< "$_cfg")
    [[ -z "${WORK_TZ:-}"          ]] && WORK_TZ=$(sed -n '3p' <<< "$_cfg")
  fi
  export WORK_HOURS_START="${WORK_HOURS_START:-7}"
  export WORK_HOURS_END="${WORK_HOURS_END:-23}"
  export WORK_TZ="${WORK_TZ:-Asia/Tbilisi}"
}

in_work_hours() {
  _timegate_load_config
  local h
  h=$(TZ="$WORK_TZ" date +%H | sed 's/^0*//')
  h="${h:-0}"
  (( h >= WORK_HOURS_START && h < WORK_HOURS_END ))
}

snoozed_now() {
  local f="${CACHE_DIR:-$HOME/.cursor/skills/autonomous-dev-agent/cache}/watcher-snoozed.until"
  [[ -f "$f" ]] || return 1
  local until; until=$(cat "$f" 2>/dev/null)
  [[ -z "$until" ]] && return 1
  (( $(date +%s) < until ))
}

should_notify() {
  in_work_hours && ! snoozed_now
}
