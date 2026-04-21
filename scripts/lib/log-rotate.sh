#!/bin/bash
# scripts/lib/log-rotate.sh — simple size-based log rotation.
#
# When a log file crosses the threshold (default 50 MB), move it to
# logs/archive/<name>-<YYYYMMDD-HHMMSS>.log.gz and start fresh. Archive gets
# pruned to LOG_ARCHIVE_KEEP (default 14) files per base name — enough to
# debug two weeks of weirdness without hoarding gigabytes.
#
# Used by:
#   - scripts/watcher.sh (called once per tick, after the outer project loop)
#   - bin/doctor.sh --fix (runs a one-shot pass)
#
# Safe to call concurrently: we use `mv` + gzip(1) which is atomic enough for
# a single host. Worst case: one log line lands in an archive file. Good
# enough for a personal tool.

[[ -n "${_DEV_AGENT_LOG_ROTATE_LOADED:-}" ]] && return 0
_DEV_AGENT_LOG_ROTATE_LOADED=1

# Threshold in bytes. Override via env. 50 MB is a sweet spot: enough for
# weeks of normal ops, small enough that grep stays fast.
: "${LOG_ROTATE_THRESHOLD_BYTES:=52428800}"
: "${LOG_ARCHIVE_KEEP:=14}"

# rotate_if_large <log-file>
# Returns 0 either way. Silent on no-op.
rotate_if_large() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local size
  size=$(stat -f "%z" "$f" 2>/dev/null || stat -c "%s" "$f" 2>/dev/null || echo 0)
  (( size < LOG_ROTATE_THRESHOLD_BYTES )) && return 0

  local dir base name ts archive_dir target
  dir=$(dirname "$f")
  base=$(basename "$f" .log)
  ts=$(date +%Y%m%d-%H%M%S)
  archive_dir="$dir/archive"
  mkdir -p "$archive_dir" || return 0
  target="$archive_dir/${base}-${ts}.log"

  # mv + touch fresh empty log. gzip in background so the caller isn't slowed.
  if mv "$f" "$target" 2>/dev/null; then
    : > "$f"
    (gzip -f "$target" 2>/dev/null &) 2>/dev/null || true
    echo "[log-rotate] $(date '+%Y-%m-%d %H:%M:%S') rotated $f → ${target}.gz (size=${size}B)" >> "$f"
  fi

  # Prune old archives for this base name. Use a stable sort so we keep the
  # newest N regardless of how the filesystem returns order.
  local -a old
  # shellcheck disable=SC2207
  old=($(ls -1t "$archive_dir"/"${base}"-*.log.gz 2>/dev/null))
  local count=${#old[@]}
  if (( count > LOG_ARCHIVE_KEEP )); then
    local i
    for (( i=LOG_ARCHIVE_KEEP; i<count; i++ )); do
      rm -f -- "${old[$i]}" 2>/dev/null || true
    done
  fi
}

# rotate_all <log-dir?>
# Walk every *.log in the directory and rotate each.
rotate_all() {
  local dir="${1:-${LOG_DIR:-logs}}"
  [[ -d "$dir" ]] || return 0
  local f
  for f in "$dir"/*.log; do
    [[ -f "$f" ]] || continue
    rotate_if_large "$f"
  done
}
