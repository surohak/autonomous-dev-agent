#!/bin/bash
# scripts/lib/log.sh
#
# Minimal structured logger used by non-Nuxt scripts. Writes to $LOG_FILE if
# set, otherwise to stderr. Keeps format uniform so `tail -f` across different
# scripts looks consistent.
#
# Public:
#   log_info "msg"
#   log_warn "msg"
#   log_error "msg"

[[ -n "${_DEV_AGENT_LOG_LOADED:-}" ]] && return 0
_DEV_AGENT_LOG_LOADED=1

_log_write() {
  local level="$1"; shift
  local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
  local line; line="[$ts] $level $*"
  if [[ -n "${LOG_FILE:-}" ]]; then
    printf '%s\n' "$line" >> "$LOG_FILE"
  else
    printf '%s\n' "$line" >&2
  fi
}
log_info()  { _log_write "INFO"  "$@"; }
log_warn()  { _log_write "WARN"  "$@"; }
log_error() { _log_write "ERROR" "$@"; }
