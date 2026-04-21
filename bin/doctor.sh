#!/bin/bash
# bin/doctor.sh — diagnoses an existing install.
#
# Checks (each prints PASS/FAIL/WARN + explanation):
#   - required binaries on PATH
#   - config.json/secrets.env exist, readable, not still placeholders
#   - Jira auth: curl /rest/api/3/myself
#   - Telegram auth: curl bot/getMe
#   - GitLab auth: glab auth status / curl /user
#   - Tempo auth (if token set): curl /4/worklogs?limit=1
#   - launchd: each of the 4 services loaded
#   - disk: cache/ and logs/ writable
#   - clock: warn if system clock is more than 5s off UTC
#
# Exit code: 0 if all hard-fail checks pass, 1 otherwise.

set -euo pipefail

SKILL_DIR="${SKILL_DIR:-$HOME/.cursor/skills/autonomous-dev-agent}"
LABEL_PREFIX="com.${USER:-user}"
cd "$SKILL_DIR" 2>/dev/null || { echo "doctor: SKILL_DIR $SKILL_DIR not found"; exit 1; }

# ANSI
BOLD="$(tput bold 2>/dev/null || true)"
GREEN="$(tput setaf 2 2>/dev/null || true)"
RED="$(tput setaf 1 2>/dev/null || true)"
YELLOW="$(tput setaf 3 2>/dev/null || true)"
DIM="$(tput dim 2>/dev/null || true)"
RST="$(tput sgr0 2>/dev/null || true)"

HARD_FAILS=0
WARNS=0

pass() { echo "  ${GREEN}PASS${RST} $1"; }
fail() { echo "  ${RED}FAIL${RST} $1"; HARD_FAILS=$((HARD_FAILS+1)); }
warn() { echo "  ${YELLOW}WARN${RST} $1"; WARNS=$((WARNS+1)); }
info() { echo "  ${DIM}$1${RST}"; }

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
    warn "secrets.env mode is $perms, recommended 600 — run: chmod 600 secrets.env"
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
  if [[ ! -f "${WORKFLOW_FILE:-}" ]]; then
    info "no workflow cache yet; discovering from live Jira…"
    out=$(workflow_discover 2>&1 || true)
    if [[ -f "$WORKFLOW_FILE" ]]; then
      pass "workflow discovered → $WORKFLOW_FILE"
      [[ "$out" == UNRESOLVED:* ]] && warn "unresolved intents: ${out#UNRESOLVED:} (add aliases in config.json projects[].workflow.aliases)"
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
  warn "SwiftBar detected but plugin not linked — re-run bin/install.sh"
elif [[ -L "$SWIFTBAR_LINK" && "$(readlink "$SWIFTBAR_LINK")" != "$SWIFTBAR_SRC" ]]; then
  warn "SwiftBar plugin symlink points elsewhere: $(readlink "$SWIFTBAR_LINK")"
else
  pass "SwiftBar plugin linked at $SWIFTBAR_LINK"
fi

# -- disk + clock -----------------------------------------------------------
section "[host]"
for d in cache logs; do
  if [[ -w "$d" ]]; then
    pass "$d/ writable"
  else
    fail "$d/ not writable"
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

# -- summary ----------------------------------------------------------------
section "[summary]"
if (( HARD_FAILS == 0 && WARNS == 0 )); then
  echo "  ${GREEN}${BOLD}All checks passed.${RST}"
  exit 0
fi
echo "  ${HARD_FAILS} fail(s), ${WARNS} warn(s)"
[[ $HARD_FAILS -gt 0 ]] && exit 1 || exit 0
