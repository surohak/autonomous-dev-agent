#!/bin/bash
# scripts/handlers/workflow.sh — /workflow command: inspect + refresh Jira
# workflow intent mappings per project.
#
# Usage from Telegram:
#   /workflow              — dump the active project's resolved intents
#   /workflow <project>    — dump a specific project's intents (doesn't switch)
#   /workflow refresh      — force re-discover for the active project
#   /workflow refresh <id> — force re-discover for a specific project
#
# v0.3 shipped auto-discovery but had no on-demand way to inspect it or
# re-run after a Jira admin tweaked the workflow. This handler closes that
# gap and is the recommended first step when an unresolved-intent warning
# shows up in the logs.
#
# Requires: lib/workflow.sh, lib/cfg.sh, lib/telegram.sh.

[[ -n "${_DEV_AGENT_HANDLER_WORKFLOW_LOADED:-}" ]] && return 0
_DEV_AGENT_HANDLER_WORKFLOW_LOADED=1

# _workflow_with_project <project-id> <callback ...>
# Activate the given project for the duration of a single operation without
# leaking env changes back to the caller. We re-activate the original project
# on the way out so /status, /queue, etc. keep targeting the correct one.
_workflow_with_project() {
  local target_proj="$1"; shift
  local original_proj="${AGENT_PROJECT:-$(project_current 2>/dev/null || echo default)}"

  if [[ -n "$target_proj" && "$target_proj" != "$original_proj" ]]; then
    cfg_project_activate "$target_proj" >/dev/null 2>&1 || {
      tg_send "❌ Unknown project: \`$target_proj\`. Try /project list."
      return 1
    }
  fi

  "$@"
  local rc=$?

  if [[ -n "$target_proj" && "$target_proj" != "$original_proj" ]]; then
    cfg_project_activate "$original_proj" >/dev/null 2>&1 || true
  fi
  return $rc
}

# _workflow_show — emit the resolved-intents table and any unresolved
# warnings for the currently-active project. Formats for Telegram.
_workflow_show() {
  local proj="${AGENT_PROJECT:-$(project_current 2>/dev/null || echo default)}"
  local dump
  dump=$(workflow_dump 2>&1)
  if [[ -z "$dump" || "$dump" == *"not yet populated"* ]]; then
    tg_send "⚠️ No workflow cache for *${proj}* yet. Running discovery…"
    if workflow_discover >/dev/null 2>&1; then
      dump=$(workflow_dump 2>&1)
    else
      tg_send "❌ Discovery failed for *${proj}*. Check Jira credentials + network, then retry."
      return 1
    fi
  fi

  tg_send "🔎 *Workflow for ${proj}*
\`\`\`
${dump}
\`\`\`"

  # Unresolved intents → actionable guidance, one message per missing intent
  # so Telegram doesn't truncate the Markdown. Keep output small: at most 3.
  local unresolved
  unresolved=$(workflow_unresolved 2>/dev/null | head -n 3)
  if [[ -n "$unresolved" ]]; then
    while IFS= read -r intent; do
      [[ -z "$intent" ]] && continue
      local explain
      explain=$(workflow_explain_unresolved "$intent" 2>/dev/null)
      tg_send "$explain"
    done <<< "$unresolved"
  fi
}

# _workflow_refresh — wipe + re-discover + show.
_workflow_refresh() {
  local proj="${AGENT_PROJECT:-$(project_current 2>/dev/null || echo default)}"
  tg_send "🔄 Refreshing workflow cache for *${proj}*…"
  if workflow_refresh >/dev/null 2>&1; then
    _workflow_show
  else
    tg_send "❌ Refresh failed. Is Jira reachable? Try \`bin/doctor\` to check."
  fi
}

# handler_workflow <subcommand?> <project?>
# Main dispatch. Subcommands:
#   (none)          — show active project's workflow
#   refresh         — refresh active project's workflow
#   <project-id>    — show that project's workflow (doesn't change active)
#   refresh <id>    — refresh that project's workflow
handler_workflow() {
  local arg1="${1:-}" arg2="${2:-}"

  if [[ -z "$arg1" ]]; then
    _workflow_show
    return
  fi

  if [[ "$arg1" == "refresh" ]]; then
    if [[ -n "$arg2" ]]; then
      _workflow_with_project "$arg2" _workflow_refresh
    else
      _workflow_refresh
    fi
    return
  fi

  # Treat arg1 as a project id. Reject unknown ids up front so we don't
  # silently fall through to "show default".
  if ! cfg_project_list | grep -qx "$arg1"; then
    tg_send "❌ Unknown project: \`$arg1\`. Try /project list."
    return 1
  fi
  _workflow_with_project "$arg1" _workflow_show
}
