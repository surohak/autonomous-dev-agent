#!/bin/bash
# scripts/handlers/project.sh — /project command: list, switch, info.
#
# Multi-project installs need a way to see which project is active, switch
# between them, and confirm per-project settings (Jira key, chat id, agent
# model). This file exposes handler_project called from the big case in
# telegram-handler.sh.
#
# The "active" project is tracked per-user in a small state file under
# cache/global/ so a `/project use <id>` persists across daemon restarts.
# It's honoured by handlers that resolve the current project at run time
# (queue.sh, basic.sh, watch.sh) via $AGENT_PROJECT env pin OR by reading
# the state file if no pin is set.
#
# Requires: cfg.sh (cfg_project_list, cfg_project_activate, cfg_project_field).

[[ -n "${_DEV_AGENT_HANDLER_PROJECT_LOADED:-}" ]] && return 0
_DEV_AGENT_HANDLER_PROJECT_LOADED=1

_project_active_file() {
  printf '%s\n' "${GLOBAL_CACHE_DIR:-$CACHE_DIR}/active-project.txt"
}

# Read the currently-active project id: pinned ($AGENT_PROJECT) > state file
# > default. This is the single source of truth for "which project does
# /run, /status, /queue, etc. target?".
project_current() {
  if [[ -n "${AGENT_PROJECT:-}" ]]; then
    printf '%s\n' "$AGENT_PROJECT"; return 0
  fi
  local f; f=$(_project_active_file)
  if [[ -s "$f" ]]; then
    head -n1 "$f"; return 0
  fi
  # Fall back to whichever project cfg.sh activated at source time.
  printf '%s\n' "${PROJECT_ID:-default}"
}

# Persist the selected project so it survives daemon restarts.
project_set() {
  local pid="$1"
  local f; f=$(_project_active_file)
  mkdir -p "$(dirname "$f")"
  printf '%s\n' "$pid" > "$f"
  cfg_project_activate "$pid" >/dev/null 2>&1 || true
}

# Ship a Markdown list of known projects with a ✓ by the active one so users
# can copy/paste an id into `/project use`.
handler_project() {
  local sub="${1:-list}" arg="${2:-}"
  local current; current=$(project_current)

  case "$sub" in
    list|"")
      local lines="" pid name jira_key site
      for pid in $(cfg_project_list); do
        name=$(cfg_project_field "$pid" "name"        2>/dev/null)
        jira_key=$(cfg_project_field "$pid" "tracker.project" 2>/dev/null)
        site=$(cfg_project_field "$pid" "tracker.siteUrl" 2>/dev/null)
        local mark="  "
        [[ "$pid" == "$current" ]] && mark="✓ "
        lines+="${mark}\`${pid}\`"
        [[ -n "$name"     ]] && lines+=" — ${name}"
        [[ -n "$jira_key" ]] && lines+=" (${jira_key}"
        [[ -n "$site"     ]] && lines+=" @ ${site#https://}"
        [[ -n "$jira_key" ]] && lines+=")"
        lines+=$'\n'
      done
      tg_send "*Projects*
${lines}
Switch with \`/project use <id>\`."
      ;;
    use)
      if [[ -z "$arg" ]]; then
        tg_send "Usage: \`/project use <id>\`  (run \`/project list\` to see ids)"
        return 0
      fi
      # Verify the id exists before persisting.
      local found=0 pid
      for pid in $(cfg_project_list); do
        [[ "$pid" == "$arg" ]] && { found=1; break; }
      done
      if (( found == 0 )); then
        tg_send "Unknown project: \`$arg\`. Run \`/project list\` to see available ids."
        return 0
      fi
      project_set "$arg"
      tg_send "Active project → \`$arg\` ($(cfg_project_field "$arg" 'tracker.project' 2>/dev/null || echo '?'))"
      ;;
    info|show)
      local pid="${arg:-$current}"
      local name jira_key site model bot_env chat_id
      name=$(cfg_project_field     "$pid" "name"            2>/dev/null)
      jira_key=$(cfg_project_field "$pid" "tracker.project" 2>/dev/null)
      site=$(cfg_project_field     "$pid" "tracker.siteUrl" 2>/dev/null)
      model=$(cfg_project_field    "$pid" "agent.model"     2>/dev/null)
      bot_env=$(cfg_project_field  "$pid" "chat.tokenEnv"   2>/dev/null)
      chat_id=$(cfg_project_field  "$pid" "chat.chatId"     2>/dev/null)
      tg_send "*Project \`${pid}\`*
name: ${name:-_(none)_}
tracker: ${jira_key:-_?_} @ ${site:-_?_}
agent model: ${model:-_(inherited)_}
telegram bot env: ${bot_env:-TELEGRAM_BOT_TOKEN}
telegram chat id: ${chat_id:-_(inherited)_}"
      ;;
    *)
      tg_send "Usage:
\`/project list\`         — show all projects (active marked with ✓)
\`/project use <id>\`     — switch active project
\`/project info [<id>]\`  — show config for a project"
      ;;
  esac
}
