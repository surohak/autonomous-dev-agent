#!/bin/bash
# bin/init.sh — interactive first-run wizard.
#
# Walks a new user through:
#   1. Copying config.example.json → config.json and prompting for each value.
#   2. Copying secrets.env.example → secrets.env and prompting for tokens.
#   3. Rendering SKILL.md from the template.
#   4. Printing next-step instructions.
#
# Non-interactive mode: set $INIT_NONINTERACTIVE=1 and $INIT_USE_EXAMPLES=1 to
# just copy the example files without prompting. Useful for CI smoke tests.

set -euo pipefail

SKILL_DIR="${SKILL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$SKILL_DIR"

if [[ ! -f config.example.json ]]; then
  echo "init.sh: config.example.json missing — run bin/install.sh first." >&2
  exit 1
fi

BOLD="$(tput bold 2>/dev/null || true)"
DIM="$(tput dim  2>/dev/null || true)"
RST="$(tput sgr0 2>/dev/null || true)"

prompt() {
  # prompt <var> <message> [default]
  local varname="$1" msg="$2" default="${3:-}" reply
  if [[ "${INIT_NONINTERACTIVE:-0}" == "1" ]]; then
    eval "$varname=\"\${$varname:-$default}\""
    return 0
  fi
  if [[ -n "$default" ]]; then
    read -r -p "$msg [$default]: " reply
    reply="${reply:-$default}"
  else
    read -r -p "$msg: " reply
  fi
  eval "$varname=\$reply"
}

prompt_secret() {
  local varname="$1" msg="$2" reply
  if [[ "${INIT_NONINTERACTIVE:-0}" == "1" ]]; then
    eval "$varname=\"<set-me>\""
    return 0
  fi
  read -r -s -p "$msg: " reply
  echo
  eval "$varname=\$reply"
}

echo "${BOLD}=== autonomous-dev-agent setup ===${RST}"
echo
echo "I'll ask a handful of questions to write config.json and secrets.env."
echo "Nothing is transmitted anywhere — everything stays on this Mac."
echo

# -- config.json ------------------------------------------------------------
if [[ -f config.json ]]; then
  echo "${DIM}config.json already exists — keeping it; re-run 'bin/init.sh' after deleting it to start fresh.${RST}"
else
  echo "${BOLD}[1/3] Jira + GitLab + repos${RST}"
  prompt OWNER_NAME         "Your full name"                     "$(id -F 2>/dev/null || echo "")"
  prompt OWNER_FIRST_NAME   "Your first name"                    "${OWNER_NAME%% *}"
  prompt OWNER_EMAIL        "Atlassian email (for API auth)"     ""
  prompt GITLAB_USERNAME    "GitLab username"                    ""
  prompt COMPANY            "Company / org name (cosmetic)"      ""
  prompt JIRA_SITE          "Jira site URL"                      "https://example.atlassian.net"
  prompt JIRA_PROJECT       "Jira project key (e.g. ABC)"        ""
  prompt JIRA_ACCOUNT_ID    "Jira accountId (Profile -> ... -> Copy ID)" ""
  prompt SSR_LOCAL          "Primary repo local path"            "$HOME/projects/app"
  prompt SSR_PROJECT        "Primary repo GitLab project path"   "org/app"
  prompt SSR_BRANCH         "Primary repo default branch"        "main"
  prompt TG_CHAT_ID         "Telegram chat ID (numeric)"         ""
  prompt BRANCH_USER        "Branch-name user slug"              "${GITLAB_USERNAME%%.*}"

  python3 - "$SKILL_DIR" <<'PY'
import json, os, sys, pathlib
skill = pathlib.Path(sys.argv[1])
# config.example.json uses "_comment" fields (valid JSON) rather than // comments.
cfg = json.loads((skill / "config.example.json").read_text())
cfg["atlassian"]["siteUrl"]    = os.environ["JIRA_SITE"]
cfg["atlassian"]["project"]    = os.environ["JIRA_PROJECT"]
cfg["atlassian"]["cloudId"]    = ""  # doctor.sh fills this after a Jira probe
cfg["company"]                 = os.environ["COMPANY"]
cfg["owner"]["name"]           = os.environ["OWNER_NAME"]
cfg["owner"]["firstName"]      = os.environ["OWNER_FIRST_NAME"]
cfg["owner"]["email"]          = os.environ["OWNER_EMAIL"]
cfg["owner"]["jiraAccountId"]  = os.environ["JIRA_ACCOUNT_ID"]
cfg["owner"]["gitlabUsername"] = os.environ["GITLAB_USERNAME"]
cfg["chat"] = cfg.get("chat", {})
cfg["chat"]["telegramChatId"]  = os.environ["TG_CHAT_ID"]
cfg["conventions"]["branchUser"]= os.environ["BRANCH_USER"]
cfg["repositories"]["ssr"]["localPath"]      = os.environ["SSR_LOCAL"]
cfg["repositories"]["ssr"]["gitlabProject"]  = os.environ["SSR_PROJECT"]
cfg["repositories"]["ssr"]["defaultBranch"]  = os.environ["SSR_BRANCH"]
# Drop blog entry by default — user can add projects later.
cfg["repositories"].pop("blog", None)

open(skill / "config.json", "w").write(json.dumps(cfg, indent=2) + "\n")
print(f"  wrote {skill/'config.json'}")
PY
  chmod 600 config.json
fi
echo

# -- secrets.env ------------------------------------------------------------
if [[ -f secrets.env ]]; then
  echo "${DIM}secrets.env already exists — keeping it (delete to re-prompt).${RST}"
else
  echo "${BOLD}[2/3] API tokens${RST}"
  echo "  Paste tokens one at a time. Input is hidden. Leave blank to skip."
  prompt_secret ATLASSIAN_API_TOKEN "Atlassian API token (id.atlassian.com -> Security -> API tokens)"
  prompt_secret TELEGRAM_BOT_TOKEN  "Telegram bot token (@BotFather -> /newbot)"
  prompt_secret GITLAB_TOKEN        "GitLab PAT (Profile -> Access tokens; scopes: api)"
  prompt_secret TEMPO_API_TOKEN     "Tempo Cloud API token (optional — for worklog suggestions)"

  cat > secrets.env <<ENV
# secrets.env — generated by bin/init.sh on $(date)
# DO NOT COMMIT. This file is listed in .gitignore.

# Atlassian
export ATLASSIAN_EMAIL="${OWNER_EMAIL:-}"
export ATLASSIAN_API_TOKEN="${ATLASSIAN_API_TOKEN:-}"

# Telegram
export TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
export TELEGRAM_CHAT_ID="${TG_CHAT_ID:-}"

# GitLab
export GITLAB_TOKEN="${GITLAB_TOKEN:-}"

# Tempo Cloud (optional)
export TEMPO_API_TOKEN="${TEMPO_API_TOKEN:-}"
ENV
  chmod 600 secrets.env
  echo "  wrote secrets.env (mode 600)"
fi
echo

# -- SKILL.md ---------------------------------------------------------------
echo "${BOLD}[3/3] Rendering SKILL.md${RST}"
if [[ -f SKILL.md.template ]]; then
  # shellcheck disable=SC1091
  source scripts/lib/env.sh
  # shellcheck disable=SC1091
  source scripts/lib/cfg.sh
  # shellcheck disable=SC1091
  source scripts/lib/prompt.sh
  prompt_render SKILL.md.template > SKILL.md
  echo "  rendered SKILL.md"
else
  echo "  SKILL.md.template not found — skipping"
fi
echo

echo "${BOLD}Setup complete.${RST}"
echo "Next: run '${BOLD}bash bin/doctor.sh${RST}' to verify tokens + connectivity."
echo "Then: run '${BOLD}bash bin/install.sh${RST}' (without --skip-launchd) to load the services."
