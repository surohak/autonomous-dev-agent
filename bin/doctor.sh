#!/bin/bash
# bin/doctor.sh — diagnoses an existing install.
#
# Checks (each prints PASS/FAIL/WARN + explanation):
#   - required binaries on PATH
#   - config.json/secrets.env exist, readable, not still placeholders
#   - config.json schema lint (shape, required fields, enum values)
#   - Jira auth: curl /rest/api/3/myself
#   - Telegram auth: curl bot/getMe
#   - GitLab auth: glab auth status / curl /user
#   - Tempo auth (if token set): curl /4/worklogs?limit=1
#   - launchd: each service loaded
#   - disk: cache/ and logs/ writable
#   - clock: warn if system clock is more than 5s off UTC
#
# Flags:
#   --fix      Apply safe, non-destructive fixes for remediable warnings:
#                • mkdir -p missing cache/ logs/ logs/archive/
#                • chmod 600 secrets.env
#                • re-run workflow_discover if the cache is missing
#                • re-link SwiftBar plugin when the link is broken/missing
#              Never mutates config.json or secrets.env contents.
#   --smoke    (v1.0.0) end-to-end ping for every integration: per-project
#              runs tracker_probe + tracker_search + host_probe +
#              host_current_user + chat_probe. Read-only by default.
#   --chat     Only in combination with --smoke — also sends a visible chat
#              heartbeat message to every configured chat. Off by default so
#              the health check is safe to run in cron.
#   --json     Emit the summary as JSON (CI-friendly).
#
# Exit code: 0 if all hard-fail checks pass, 1 otherwise.

set -euo pipefail

SKILL_DIR="${SKILL_DIR:-$HOME/.cursor/skills/autonomous-dev-agent}"
LABEL_PREFIX="com.${USER:-user}"
cd "$SKILL_DIR" 2>/dev/null || { echo "doctor: SKILL_DIR $SKILL_DIR not found"; exit 1; }

FIX=0
SMOKE=0
JSON_OUT=0
for arg in "$@"; do
  case "$arg" in
    --fix)   FIX=1 ;;
    --smoke) SMOKE=1 ;;
    --json)  JSON_OUT=1 ;;
    -h|--help)
      sed -n '1,30p' "$0" | sed 's/^# //; s/^#//'
      exit 0
      ;;
  esac
done

# ANSI
BOLD="$(tput bold 2>/dev/null || true)"
GREEN="$(tput setaf 2 2>/dev/null || true)"
RED="$(tput setaf 1 2>/dev/null || true)"
YELLOW="$(tput setaf 3 2>/dev/null || true)"
DIM="$(tput dim 2>/dev/null || true)"
RST="$(tput sgr0 2>/dev/null || true)"

HARD_FAILS=0
WARNS=0
FIXED=0

pass()  { echo "  ${GREEN}PASS${RST} $1"; }
fail()  { echo "  ${RED}FAIL${RST} $1"; HARD_FAILS=$((HARD_FAILS+1)); }
warn()  { echo "  ${YELLOW}WARN${RST} $1"; WARNS=$((WARNS+1)); }
info()  { echo "  ${DIM}$1${RST}"; }
fixed() { echo "  ${GREEN}FIXED${RST} $1"; FIXED=$((FIXED+1)); }

# warnfix <message> <shell-command>
# Emit a warning AND, when --fix is active, run the remediation and downgrade
# to FIXED. Command runs in the current shell so it can touch HARD_FAILS etc.
warnfix() {
  local msg="$1"; shift
  if [[ "$FIX" = "1" ]]; then
    if eval "$@" >/dev/null 2>&1; then
      fixed "$msg"
      return 0
    fi
  fi
  warn "$msg"
}

section() { echo; echo "${BOLD}$1${RST}"; }

# -- binaries ---------------------------------------------------------------
section "[binaries]"
for b in python3 jq curl glab cursor; do
  if command -v "$b" >/dev/null 2>&1; then
    pass "$b ($(command -v "$b"))"
  else
    fail "$b not on PATH"
  fi
done

# -- config + secrets -------------------------------------------------------
section "[config + secrets]"
if [[ -f config.json ]]; then
  pass "config.json present"
  # Basic placeholder detection
  if grep -qE '"(Your|your|example)' config.json; then
    warn "config.json still has example values — edit or re-run bin/init.sh"
  fi
else
  fail "config.json missing — run bin/init.sh"
fi

if [[ -f secrets.env ]]; then
  pass "secrets.env present"
  perms=$(stat -f "%Lp" secrets.env 2>/dev/null || stat -c "%a" secrets.env 2>/dev/null || echo "?")
  if [[ "$perms" != "600" ]]; then
    warnfix "secrets.env mode is $perms, recommended 600" "chmod 600 secrets.env"
  fi
else
  fail "secrets.env missing — run bin/init.sh"
fi

[[ ! -f config.json || ! -f secrets.env ]] && { section "[summary]"; echo "  $HARD_FAILS fail(s), $WARNS warn(s)"; exit 1; }

# shellcheck disable=SC1091
source scripts/lib/env.sh
# shellcheck disable=SC1091
source scripts/lib/cfg.sh
# shellcheck disable=SC1091
source scripts/lib/jira.sh
# shellcheck disable=SC1091
source scripts/lib/workflow.sh
# shellcheck disable=SC1091
source secrets.env

# -- schema lint (config.json shape) ---------------------------------------
# A minimal structural validator. Far from full JSON Schema but catches the
# mistakes we've actually seen in issues (typos, missing required fields,
# non-string ids, chat.tokenEnv not in secrets.env, …). The full schema lives
# at docs/CONFIG_SCHEMA.json for reference.
section "[schema]"
if [[ -f config.json ]]; then
  SCHEMA_OUT=$(CFG=config.json python3 "$SKILL_DIR/scripts/lib/_cfg_lint.py" 2>&1) || true
  if [[ -z "$SCHEMA_OUT" ]]; then
    pass "config.json conforms to v0.3 schema"
  else
    # One issue per line. Levels: ERROR (fail), WARN (warn), INFO (info).
    while IFS= read -r line; do
      case "$line" in
        ERROR*) fail "${line#ERROR: }" ;;
        WARN*)  warn "${line#WARN: }"  ;;
        INFO*)  info "${line#INFO: }"  ;;
        *)      info "$line"           ;;
      esac
    done <<< "$SCHEMA_OUT"
  fi
else
  info "skipped — config.json missing"
fi

# -- projects ---------------------------------------------------------------
section "[projects]"
projects_out=$(cfg_project_list || true)
if [[ -z "$projects_out" ]]; then
  fail "no projects resolved from config.json — check shape / run migrate-config-v0.3.py"
else
  info "configured: $projects_out"
  active_default=$(cfg_project_default)
  pass "active default: $active_default"
  # Sanity-check each project has a tracker siteUrl + project prefix.
  for pid in $projects_out; do
    site=$(cfg_project_field "$pid" '["tracker"]["siteUrl"]' 2>/dev/null)
    prj=$(cfg_project_field "$pid" '["tracker"]["project"]' 2>/dev/null)
    if [[ -z "$site" || -z "$prj" ]]; then
      warn "$pid: tracker.siteUrl or tracker.project missing"
    else
      info "  $pid → $site ($prj)"
    fi
  done
fi

# -- agent model ------------------------------------------------------------
section "[agent model]"
info "default:     $AGENT_MODEL"
info "codereview:  $AGENT_MODEL_CODEREVIEW"
info "cifix:       $AGENT_MODEL_CIFIX"
info "planner:     $AGENT_MODEL_PLANNER"
info "executor:    $AGENT_MODEL_EXECUTOR"
# Probe the Cursor CLI — this surfaces typos before the next scheduled run.
if command -v agent >/dev/null 2>&1; then
  # `agent --help` or similar — use a zero-side-effect check. We don't have a
  # `agent ls-models` subcommand, so just ensure the binary runs.
  if agent --version >/dev/null 2>&1 || agent -v >/dev/null 2>&1; then
    pass "Cursor CLI 'agent' runs"
  else
    warn "Cursor CLI 'agent' present but --version failed"
  fi
else
  fail "'agent' (Cursor CLI) not on PATH"
fi

# -- Jira auth --------------------------------------------------------------
section "[Jira]"
if [[ -z "${ATLASSIAN_API_TOKEN:-}" ]]; then
  fail "ATLASSIAN_API_TOKEN not set in secrets.env"
elif [[ -z "$JIRA_SITE" ]]; then
  fail "JIRA_SITE empty (config.atlassian.siteUrl)"
else
  # curl -w already prints "000" on DNS/connect errors; don't append more.
  code=$(curl -s -o /tmp/doctor-jira.$$ -w "%{http_code}" \
    -u "${ATLASSIAN_EMAIL}:${ATLASSIAN_API_TOKEN}" \
    "${JIRA_SITE}/rest/api/3/myself" 2>/dev/null || true)
  code=${code:-000}
  if [[ "$code" == "200" ]]; then
    who=$(jq -r '.displayName' /tmp/doctor-jira.$$ 2>/dev/null || echo "?")
    pass "Jira auth OK as ${who}"
  else
    fail "Jira returned HTTP $code — check email/token/siteUrl"
  fi
  rm -f /tmp/doctor-jira.$$
fi

# -- workflow (Jira status discovery) ---------------------------------------
section "[workflow]"
if [[ -z "${ATLASSIAN_API_TOKEN:-}" ]]; then
  info "skipped — Jira auth missing"
elif [[ -z "$JIRA_PROJECT" ]]; then
  info "skipped — tracker.project not set"
else
  # Discover once if we don't already have a cache. Cheap — 2 HTTP calls.
  # With --fix, force a refresh so users get a clean slate after aliases edits.
  if [[ ! -f "${WORKFLOW_FILE:-}" || "$FIX" = "1" ]]; then
    info "running workflow discovery…"
    out=$(workflow_refresh 2>&1 || true)
    if [[ -f "$WORKFLOW_FILE" ]]; then
      [[ "$FIX" = "1" ]] && fixed "workflow re-discovered → $WORKFLOW_FILE" || pass "workflow discovered → $WORKFLOW_FILE"
      [[ "$out" == UNRESOLVED:* ]] && warn "unresolved intents: ${out#UNRESOLVED:} (add aliases in config.json projects[].workflow.aliases, or use /workflow refresh)"
    else
      warn "workflow discovery failed — check Jira auth; falling back to name-match"
    fi
  else
    pass "workflow cache present: $WORKFLOW_FILE"
  fi
  # Show the resolved intents so users see the mapping.
  if [[ -f "$WORKFLOW_FILE" ]]; then
    while IFS= read -r line; do info "  $line"; done < <(workflow_dump 2>/dev/null | sed -n '/^resolved/,$p')
  fi
fi

# -- Telegram ---------------------------------------------------------------
section "[Telegram]"
if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  fail "TELEGRAM_BOT_TOKEN not set"
else
  out=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" || echo "")
  if [[ "$(jq -r '.ok' <<<"$out" 2>/dev/null)" == "true" ]]; then
    name=$(jq -r '.result.username' <<<"$out")
    pass "Telegram bot OK (@${name})"
  else
    fail "Telegram getMe failed — token invalid?"
  fi
fi
[[ -z "${TELEGRAM_CHAT_ID:-}" ]] && warn "TELEGRAM_CHAT_ID empty — bot can't reach you until set"

# -- GitLab -----------------------------------------------------------------
section "[GitLab]"
if [[ -z "${GITLAB_TOKEN:-}" ]]; then
  fail "GITLAB_TOKEN not set"
else
  # glab auth status exits non-zero if not logged in. Try API directly.
  code=$(curl -s -o /tmp/doctor-gl.$$ -w "%{http_code}" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "https://gitlab.com/api/v4/user" 2>/dev/null || true)
  code=${code:-000}
  if [[ "$code" == "200" ]]; then
    name=$(jq -r '.username' /tmp/doctor-gl.$$ 2>/dev/null || echo "?")
    pass "GitLab auth OK as ${name}"
  else
    warn "GitLab auth probe returned $code (ok if self-hosted on non-gitlab.com)"
  fi
  rm -f /tmp/doctor-gl.$$
fi

# -- Tempo (optional) -------------------------------------------------------
section "[Tempo]"
if [[ -z "${TEMPO_API_TOKEN:-}" ]]; then
  info "TEMPO_API_TOKEN not set — worklog suggestions disabled (optional)"
else
  code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${TEMPO_API_TOKEN}" \
    "https://api.tempo.io/4/worklogs?limit=1" 2>/dev/null || true)
  code=${code:-000}
  if [[ "$code" == "200" ]]; then
    pass "Tempo API OK"
  else
    warn "Tempo probe returned $code — token may be invalid (features still run, just without suggestions)"
  fi
fi

# -- launchd ----------------------------------------------------------------
section "[launchd]"
expected=(
  "${LABEL_PREFIX}.autonomous-dev-agent"
  "${LABEL_PREFIX}.dev-agent-watcher"
  "${LABEL_PREFIX}.dev-agent-telegram"
  "${LABEL_PREFIX}.dev-agent-digest"
)
for label in "${expected[@]}"; do
  if launchctl list | grep -q "^[0-9-]*[[:space:]].*${label}$"; then
    pass "$label loaded"
  else
    warn "$label not loaded — run bin/install.sh"
  fi
done

# -- SwiftBar (optional) ----------------------------------------------------
section "[SwiftBar]"
SWIFTBAR_PLUGINS="$HOME/Library/Application Support/SwiftBar/Plugins"
SWIFTBAR_LINK="$SWIFTBAR_PLUGINS/dev-agent.30s.sh"
SWIFTBAR_SRC="$SKILL_DIR/scripts/menubar/dev-agent.30s.sh"
if [[ ! -d "$SWIFTBAR_PLUGINS" ]]; then
  info "SwiftBar not installed — menu-bar icon disabled (optional; install from https://swiftbar.app)"
elif [[ ! -L "$SWIFTBAR_LINK" && ! -f "$SWIFTBAR_LINK" ]]; then
  warnfix "SwiftBar detected but plugin not linked" "ln -s '$SWIFTBAR_SRC' '$SWIFTBAR_LINK'"
elif [[ -L "$SWIFTBAR_LINK" && "$(readlink "$SWIFTBAR_LINK")" != "$SWIFTBAR_SRC" ]]; then
  warnfix "SwiftBar plugin symlink points elsewhere: $(readlink "$SWIFTBAR_LINK")" "rm -f '$SWIFTBAR_LINK' && ln -s '$SWIFTBAR_SRC' '$SWIFTBAR_LINK'"
else
  pass "SwiftBar plugin linked at $SWIFTBAR_LINK"
fi

# -- disk + clock -----------------------------------------------------------
section "[host]"
for d in cache logs logs/archive; do
  if [[ -d "$d" && -w "$d" ]]; then
    pass "$d/ writable"
  elif [[ ! -d "$d" ]]; then
    warnfix "$d/ missing" "mkdir -p '$d'"
  else
    fail "$d/ not writable"
  fi
done

# Log sizes. Any log > 50 MB gets rotated under --fix; otherwise just warn.
# shellcheck disable=SC1091
source scripts/lib/log-rotate.sh
for f in logs/*.log; do
  [[ -f "$f" ]] || continue
  sz=$(stat -f "%z" "$f" 2>/dev/null || stat -c "%s" "$f" 2>/dev/null || echo 0)
  if (( sz > LOG_ROTATE_THRESHOLD_BYTES )); then
    if [[ "$FIX" = "1" ]]; then
      rotate_if_large "$f" && fixed "$f: rotated (was ${sz} bytes)"
    else
      warn "$f: ${sz} bytes (> ${LOG_ROTATE_THRESHOLD_BYTES}) — run \`bin/doctor --fix\` to rotate"
    fi
  fi
done

# Clock drift: compare local to HTTP Date from Atlassian (we already call it).
local_epoch=$(date +%s)
remote_date=$(curl -s -I "${JIRA_SITE}/" 2>/dev/null | awk -F': ' 'tolower($1)=="date"{sub(/\r$/,"",$2);print $2;exit}')
if [[ -n "$remote_date" ]]; then
  remote_epoch=$(date -j -f "%a, %d %b %Y %H:%M:%S GMT" "$remote_date" +%s 2>/dev/null || echo "")
  if [[ -n "$remote_epoch" ]]; then
    drift=$(( local_epoch - remote_epoch )); drift=${drift#-}
    if (( drift > 5 )); then
      warn "clock drift: ${drift}s off Atlassian's server — webhooks/JWTs may misbehave"
    else
      pass "clock in sync (drift ${drift}s)"
    fi
  fi
fi

# -- smoke (v1.0.0) — end-to-end driver integration ping --------------------
# Goal: one command the user can cron / CI that exercises every driver path
# we depend on at runtime. Must be idempotent (no writes that survive the
# call) and cheap (a handful of HTTP GETs per project).
#
# For each project we ping:
#   tracker_probe → tracker_search (limit=1, empty-ish JQL)
#   host_probe    → host_current_user
#   chat_probe    (no chat_send to avoid spamming the user; smoke is safe
#                  by default. Use --smoke --chat to also send a heartbeat.)
SMOKE_CHAT=0
for arg in "$@"; do [[ "$arg" == "--chat" ]] && SMOKE_CHAT=1; done

if (( SMOKE == 1 )); then
  section "[smoke]"
  SMOKE_FAILS=0
  # shellcheck disable=SC1091
  source scripts/drivers/tracker/_dispatch.sh 2>/dev/null || {
    warn "tracker dispatcher not found — smoke limited to legacy paths"
  }
  # shellcheck disable=SC1091
  source scripts/drivers/host/_dispatch.sh 2>/dev/null || true
  # shellcheck disable=SC1091
  source scripts/drivers/chat/_dispatch.sh 2>/dev/null || true

  for pid in $(cfg_project_list); do
    info "─ project: $pid"
    cfg_project_activate "$pid" >/dev/null 2>&1 || {
      warn "  $pid: activate failed"
      SMOKE_FAILS=$((SMOKE_FAILS+1))
      continue
    }

    # tracker
    if type -t tracker_probe >/dev/null 2>&1; then
      if tracker_probe >/dev/null 2>&1; then
        # tracker_search with a minimal query — just prove the round-trip.
        if tracker_search "limit=1" 1 >/dev/null 2>&1; then
          pass "  tracker[$TRACKER_KIND]: probe + search"
        else
          fail "  tracker[$TRACKER_KIND]: search failed after probe"
          SMOKE_FAILS=$((SMOKE_FAILS+1))
        fi
      else
        fail "  tracker[$TRACKER_KIND]: probe failed"
        SMOKE_FAILS=$((SMOKE_FAILS+1))
      fi
    else
      info "  tracker: driver layer not loaded, skipped"
    fi

    # host
    if type -t host_probe >/dev/null 2>&1; then
      if host_probe >/dev/null 2>&1; then
        me=$(host_current_user 2>/dev/null || true)
        if [[ -n "$me" ]]; then
          pass "  host[$HOST_KIND]: probe OK as $me"
        else
          warn "  host[$HOST_KIND]: probe OK but current_user empty"
        fi
      else
        fail "  host[$HOST_KIND]: probe failed"
        SMOKE_FAILS=$((SMOKE_FAILS+1))
      fi
    else
      info "  host: driver layer not loaded, skipped"
    fi

    # chat
    if type -t chat_probe >/dev/null 2>&1; then
      if chat_probe >/dev/null 2>&1; then
        pass "  chat[$CHAT_KIND]: probe OK"
        if (( SMOKE_CHAT == 1 )) && type -t chat_send >/dev/null 2>&1; then
          if chat_send "🩺 doctor --smoke: $pid at $(date +%H:%M)" >/dev/null 2>&1; then
            pass "  chat[$CHAT_KIND]: heartbeat sent"
          else
            warn "  chat[$CHAT_KIND]: heartbeat failed"
          fi
        fi
      else
        fail "  chat[$CHAT_KIND]: probe failed"
        SMOKE_FAILS=$((SMOKE_FAILS+1))
      fi
    else
      info "  chat: driver layer not loaded, skipped"
    fi
  done

  if (( SMOKE_FAILS == 0 )); then
    pass "smoke: all integrations reachable across all projects"
  else
    fail "smoke: $SMOKE_FAILS integration(s) unreachable"
  fi
fi

# -- summary ----------------------------------------------------------------
section "[summary]"
if (( JSON_OUT == 1 )); then
  printf '{"fails":%d,"warns":%d,"fixed":%d}\n' "$HARD_FAILS" "$WARNS" "$FIXED"
elif (( HARD_FAILS == 0 && WARNS == 0 )); then
  echo "  ${GREEN}${BOLD}All checks passed.${RST}"
  (( FIXED > 0 )) && echo "  (${FIXED} fix(es) applied)"
  exit 0
else
  echo "  ${HARD_FAILS} fail(s), ${WARNS} warn(s), ${FIXED} fix(es) applied"
fi
[[ $HARD_FAILS -gt 0 ]] && exit 1 || exit 0
