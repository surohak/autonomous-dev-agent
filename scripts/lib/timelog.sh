#!/bin/bash
# scripts/lib/timelog.sh
#
# Append-only event log driving the Tempo suggestion engine.
#
# Design: dumb, crash-safe, zero-API. Every event is one JSON object on its
# own line in $CACHE_DIR/time-log.jsonl. That file is the single source of
# truth for Phase 2 (suggestions) and Phase 3 (worklog posting). If it grows
# unbounded we rotate by date later — for now appends are fine (<1MB/month).
#
# Usage:
#   tl_emit <event_type> key=value key=value ...
#
# Examples:
#   tl_emit agent_start ticket=UA-997 run_id=r_8f2a mode=implementation pid=$$
#   tl_emit agent_end   ticket=UA-997 run_id=r_8f2a exit=ok seconds=1008
#   tl_emit jira_transition ticket=UA-997 from="In Progress" to="Code Review" source=agent
#   tl_emit mr_opened   ticket=UA-997 mr_iid=2022 project=ssr
#   tl_emit mr_approved ticket=UA-997 mr_iid=2022
#   tl_emit review_posted ticket=UA-997 mr_iid=2022 verdict=lgtm round=1 author_is_me=true
#
# `ts` is auto-added (UTC, ISO 8601 with Z). If TIME_LOG_ENABLED=0, this is a
# no-op — so you can kill capture instantly without redeploying.

[[ -n "${_DEV_AGENT_TIMELOG_LOADED:-}" ]] && return 0
_DEV_AGENT_TIMELOG_LOADED=1

# Default: capture on. Set TIME_LOG_ENABLED=0 in secrets.env to disable.
: "${TIME_LOG_ENABLED:=1}"
: "${TIME_LOG_FILE:=${CACHE_DIR:-$HOME/.cursor/skills/autonomous-dev-agent/cache}/time-log.jsonl}"

tl_emit() {
  [[ "${TIME_LOG_ENABLED}" != "1" ]] && return 0
  local event_type="${1:-}"; shift || return 0
  [[ -z "$event_type" ]] && return 0
  # Pass each k=v as its own env var so values with spaces ("In Progress")
  # survive intact — joining on $* and splitting in Python would lose quoting.
  local -a env_args=()
  local i=0
  for kv in "$@"; do
    env_args+=("TL_KV_$i=$kv")
    i=$((i + 1))
  done
  env_args+=("TL_KV_COUNT=$i" "EVENT_TYPE=$event_type" "TL_FILE=$TIME_LOG_FILE")
  env "${env_args[@]}" python3 - <<'PY' 2>/dev/null || true
import json, os, datetime, pathlib, fcntl
event = {
    "ts":   datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "type": os.environ["EVENT_TYPE"],
}
for i in range(int(os.environ.get("TL_KV_COUNT", "0"))):
    tok = os.environ.get(f"TL_KV_{i}", "")
    if "=" not in tok:
        continue
    k, v = tok.split("=", 1)
    # Coerce obvious types so downstream consumers don't need to guess.
    if v.lower() in ("true", "false"):
        event[k] = (v.lower() == "true")
    elif v.lstrip("-").isdigit():
        try: event[k] = int(v)
        except ValueError: event[k] = v
    else:
        event[k] = v

path = pathlib.Path(os.environ["TL_FILE"])
path.parent.mkdir(parents=True, exist_ok=True)
# Append with an fcntl lock so concurrent agent runs can't interleave partial
# lines. O_APPEND is atomic on POSIX for writes < PIPE_BUF (4096 bytes on
# macOS) but we belt-and-brace with flock anyway.
line = json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n"
with open(path, "a", encoding="utf-8") as fh:
    fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
    try:
        fh.write(line)
    finally:
        fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
PY
}

# Helper: stable run_id for a single process. Call once at agent_start and
# reuse on agent_end so the pair is joinable.
tl_run_id() {
  # 8 hex chars = 4 bytes of randomness + pid, enough to be unique across
  # parallel runs on the same day.
  printf 'r_%s' "$(openssl rand -hex 4 2>/dev/null || printf '%08x' $$)"
}
