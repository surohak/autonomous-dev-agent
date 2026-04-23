#!/bin/bash
# scripts/notify-mr-opened.sh — post the "MR opened" Telegram card with
# inline reviewer-assignment buttons.
#
# Why this exists:
#   Phase 2 of an agent run ends with a Telegram notification so the owner
#   knows an MR is waiting. Historically the LLM composed this message text
#   itself, which produced two recurring problems:
#     1. Malformed GitLab URLs (underscores collapsed, path slugs invented).
#     2. No interactive keyboard → the owner had to leave Telegram, open
#        GitLab, pick a reviewer, then open Jira and re-assign the ticket.
#   This helper owns the canonical text + reviewer picker, so the LLM just
#   hands off facts (ticket, MR IID, URL, branch, target, repo id) and the
#   shell renders the message deterministically.
#
# Usage:
#   notify-mr-opened.sh \
#     --repo-id <repo-slug> \
#     --ticket <KEY> \
#     --mr-iid <N> \
#     --mr-url <url> \
#     --branch <branch> \
#     --target <base-branch> \
#     [--summary "<free-text one-liner or markdown>"] \
#     [--auto-reviewer <gitlab-username>]
#
#   --repo-id        must match a key under projects[].repositories in
#                    config.json (e.g. "app", "blog", "infra").
#                    The handler uses it to look up the GitLab project path
#                    and, via the project's reviewers[] list, to render the
#                    keyboard.
#   --auto-reviewer  if the agent already set a reviewer (e.g. Blog's
#                    defaultReviewer), pass the username so the rendered
#                    message says "Reviewer: <name>" AND the keyboard still
#                    lets the owner reassign with one tap.
#
# Callback data format emitted on each button:
#   mr_assign:<repo-id>:<KEY>:<MR_IID>:<gitlab-username>
# Handled in scripts/telegram-handler.sh (case mr_assign\ *).

set -uo pipefail

SKILL_DIR="${SKILL_DIR:-$HOME/.cursor/skills/autonomous-dev-agent}"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/env.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/telegram.sh"

REPO_ID=""
TICKET=""
MR_IID=""
MR_URL=""
BRANCH=""
TARGET=""
SUMMARY=""
AUTO_REVIEWER=""

while (( $# > 0 )); do
  case "$1" in
    --repo-id)       REPO_ID="$2"; shift 2 ;;
    --ticket)        TICKET="$2"; shift 2 ;;
    --mr-iid)        MR_IID="$2"; shift 2 ;;
    --mr-url)        MR_URL="$2"; shift 2 ;;
    --branch)        BRANCH="$2"; shift 2 ;;
    --target)        TARGET="$2"; shift 2 ;;
    --summary)       SUMMARY="$2"; shift 2 ;;
    --auto-reviewer) AUTO_REVIEWER="$2"; shift 2 ;;
    -h|--help)
      sed -n '1,40p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "notify-mr-opened: unknown arg: $1" >&2; exit 2 ;;
  esac
done

_missing=""
for req in REPO_ID TICKET MR_IID MR_URL BRANCH TARGET; do
  if [[ -z "${!req}" ]]; then
    # Bash 3.2 on macOS lacks ${var,,} + string replacement, so tr+sed it.
    flag=$(printf '%s' "$req" | tr '[:upper:]_' '[:lower:]-')
    _missing="$_missing --$flag"
  fi
done
if [[ -n "$_missing" ]]; then
  echo "notify-mr-opened: missing required args:$_missing" >&2
  exit 2
fi

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
  echo "notify-mr-opened: TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID unset" >&2
  exit 1
fi

# --- Compose text + keyboard in one Python pass ---------------------------
# We emit two base64-encoded blobs on separate lines so bash can pull them
# out without running afoul of multiline text, JSON quoting, or emoji.
#
# Implementation note: this uses $(...) command substitution rather than the
# more natural `read -r X Y < <(python3 <<'PY' ...)` pattern. macOS ships
# bash 3.2, which has a bug where braces inside a heredoc fed to process
# substitution are brace-expanded (producing "ambiguous redirect" errors
# and mangled Python source). $() doesn't trigger that path.
#
# The keyboard is a list of inline_keyboard rows:
#   - Reviewer buttons, 2 per row (keeps labels legible on mobile).
#   - Final row: "Open in GitLab" (url button) + "Dismiss" (no-op).
#
# The reviewer list comes from projects[].reviewers[]. Anyone with an empty
# gitlabUsername is skipped (they can't be set as MR reviewer anyway).

_render_out=$(
  CONFIG_FILE="${CONFIG_FILE:-$SKILL_DIR/config.json}" \
  REPO_ID="$REPO_ID" TICKET="$TICKET" MR_IID="$MR_IID" \
  MR_URL="$MR_URL" BRANCH="$BRANCH" TARGET="$TARGET" \
  SUMMARY="$SUMMARY" AUTO_REVIEWER="$AUTO_REVIEWER" \
  WORK_TZ="${WORK_TZ:-Europe/Berlin}" \
  python3 <<'PY'
import base64, json, os, sys

cfg = json.load(open(os.environ["CONFIG_FILE"]))
# v0.2 flat configs normalise to a single "default" project. Using .update()
# instead of {**cfg} because a literal {"id": "default", **cfg} inside a bash
# heredoc on bash 3.2 triggers an "ambiguous redirect" on the enclosing read.
if "projects" not in cfg:
    default_proj = {"id": "default"}
    default_proj.update(cfg)
    cfg = {"projects": [default_proj]}
proj = cfg["projects"][0]

repo_id   = os.environ["REPO_ID"]
ticket    = os.environ["TICKET"]
mr_iid    = os.environ["MR_IID"]
mr_url    = os.environ["MR_URL"]
branch    = os.environ["BRANCH"]
target    = os.environ["TARGET"]
summary   = os.environ.get("SUMMARY") or ""
auto_rev  = os.environ.get("AUTO_REVIEWER") or ""

reviewers = [r for r in (proj.get("reviewers") or []) if r.get("gitlabUsername")]
auto_name = ""
if auto_rev:
    for r in reviewers:
        if r.get("gitlabUsername") == auto_rev:
            auto_name = r.get("name") or auto_rev
            break
    auto_name = auto_name or auto_rev

# --- Text -----------------------------------------------------------------
lines = [f"MR opened: {ticket}"]
if summary.strip():
    lines.append(f"Summary: {summary.strip()}")
lines.append(f"MR: {mr_url}")
if auto_name:
    lines.append(f"Reviewer: {auto_name} (auto-assigned — tap below to reassign)")
else:
    lines.append("Reviewer: not set — pick below")
lines.append(f"Branch: {branch}")
lines.append(f"Target: {target}")
lines.append(f"Jira: moved to Code Review")
text = "\n".join(lines)

# --- Keyboard -------------------------------------------------------------
# callback_data must be ≤64 bytes. "mr_assign:<repo>:<KEY>:<iid>:<user>"
# typically lands around 45 bytes; assert to catch pathological configs.
def cb(user):
    data = f"mr_assign:{repo_id}:{ticket}:{mr_iid}:{user}"
    if len(data.encode()) > 64:
        # Fallback: drop repo_id so the handler falls back on project lookup.
        data = f"mr_assign::{ticket}:{mr_iid}:{user}"
    return data

rows = []
row = []
for r in reviewers:
    label = r.get("name") or r["gitlabUsername"]
    # Short first-name-only label saves horizontal space on phones.
    short = label.split()[0]
    row.append({"text": f"👤 {short}", "callback_data": cb(r["gitlabUsername"])})
    if len(row) == 2:
        rows.append(row); row = []
if row:
    rows.append(row)

import datetime as _dt, subprocess as _sp
try:
    _today = _sp.check_output(
        ["date", "+%F"], env={**os.environ, "TZ": os.environ.get("WORK_TZ", "Europe/Berlin")}
    ).decode().strip()
except Exception:
    _today = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%d")
rows.append([
    {"text": "Log 30m", "callback_data": f"tm_log:{ticket}:{_today}:1800"},
    {"text": "Log 1h",  "callback_data": f"tm_log:{ticket}:{_today}:3600"},
    {"text": "Log 2h",  "callback_data": f"tm_log:{ticket}:{_today}:7200"},
    {"text": "Log 4h",  "callback_data": f"tm_log:{ticket}:{_today}:14400"},
])

rows.append([
    {"text": "Open in GitLab", "url": mr_url},
    {"text": "Dismiss", "callback_data": f"mr_dismiss:{mr_iid}"},
])

# Emit each base64 payload on its own line so bash can pull them out with
# sed -n '1p' / '2p'. Keeping them separate lines (instead of a shared
# space-delimited line) also sidesteps the "read only gets one token"
# gotcha when the second token is also base64.
b64 = lambda s: base64.b64encode(s.encode()).decode()
print(b64(text))
print(b64(json.dumps(rows)))
PY
)

TEXT_B64=$(printf '%s\n' "$_render_out" | sed -n '1p')
KB_B64=$(printf   '%s\n' "$_render_out" | sed -n '2p')

TEXT=$(printf '%s' "$TEXT_B64" | base64 -D 2>/dev/null || printf '%s' "$TEXT_B64" | base64 -d)
KB=$(printf   '%s' "$KB_B64"   | base64 -D 2>/dev/null || printf '%s' "$KB_B64"   | base64 -d)

if [[ -z "$TEXT" || -z "$KB" ]]; then
  echo "notify-mr-opened: failed to render text/keyboard (check config.json reviewers)" >&2
  exit 1
fi

tg_inline "$TEXT" "$KB"

# --- Immediate Tempo suggestion -------------------------------------------
# Historically the Tempo "Log dev time?" card only appeared on two paths:
#   a) Scheduled watcher run that observed a status transition into Code
#      Review (via watcher.sh → tempo_suggest_now).
#   b) Manual /start-style runs where run-agent.sh's _on_exit saw a non-empty
#      FORCE_TICKET.
# That left a gap: autonomous scheduled runs (no FORCE_TICKET, and the
# transition often happened *inside* the run rather than being observed as
# a delta by the watcher) posted the MR-opened card without the Tempo
# follow-up. The user has to remember to /tempo manually — exactly the
# friction we're trying to eliminate.
#
# Since we now know the ticket key at THIS exact moment, fire the Tempo
# suggestion here. tempo_suggest_now is idempotent (dedupes on
# time-log.jsonl), kill-switched by TEMPO_AUTO_SUGGEST=0, and completely
# silent if Tempo creds are absent — so worst-case this is a no-op.
if [[ "${TEMPO_AUTO_SUGGEST:-1}" != "0" ]] \
   && [[ -f "$SKILL_DIR/scripts/handlers/tempo.sh" ]]; then
  # shellcheck disable=SC1091
  source "$SKILL_DIR/scripts/handlers/tempo.sh" 2>/dev/null || true
  if declare -F tempo_suggest_now >/dev/null 2>&1; then
    tempo_suggest_now "$TICKET" \
      "Dev done on ${TICKET} — MR !${MR_IID} opened. Log dev time?" \
      >/dev/null 2>&1 || true
  fi
fi
