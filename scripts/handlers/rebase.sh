#!/bin/bash
# scripts/handlers/rebase.sh — Telegram commands for rebase + safe auto-resolve.
#
# Commands:
#   /rebase <mr-iid> [<repo-alias>]  - check and, if safe, apply auto-rebase
#   /rebase check <mr-iid> [<alias>] - only check; don't mutate
#
# The repo alias defaults to the project's primary repo. Use /project info
# to see available aliases per project.

[[ -n "${_DEV_AGENT_HANDLER_REBASE_LOADED:-}" ]] && return 0
_DEV_AGENT_HANDLER_REBASE_LOADED=1

_rebase_lib_load() {
  # shellcheck disable=SC1091
  source "$SKILL_DIR/scripts/lib/rebase.sh" 2>/dev/null
  # shellcheck disable=SC1091
  source "$SKILL_DIR/scripts/drivers/host/_dispatch.sh" 2>/dev/null
}

# Resolve the local checkout path for a given repo alias. Falls back to
# the project's default repo if unset.
_rebase_resolve_repo() {
  local alias="${1:-}"
  local path
  if [[ -z "$alias" ]]; then
    # First repo of active project.
    path=$(cfg_get ".projects[] | select(.id==\"${AGENT_PROJECT:-}\") | .repositories | to_entries[0].value.localPath" "")
  else
    path=$(cfg_get ".projects[] | select(.id==\"${AGENT_PROJECT:-}\") | .repositories.${alias}.localPath" "")
  fi
  # Expand ~
  path="${path/#\~/$HOME}"
  printf '%s' "$path"
}

_rebase_iid_branches() {
  local mr_iid="$1" repo="$2"
  # Ask the host driver for source/target branches.
  local proj_id
  proj_id=$(cfg_get ".projects[] | select(.id==\"${AGENT_PROJECT:-}\") | .host.group + \"/\" + (.repositories | to_entries[0].key)" "")
  # Fallback: ask glab/gh by cd-ing into the local repo.
  ( cd "$repo" 2>/dev/null && (
      if command -v glab >/dev/null 2>&1 && glab mr view "$mr_iid" --output=json 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("source_branch","")+"\t"+d.get("target_branch",""))'; then :
      elif command -v gh >/dev/null 2>&1 && gh pr view "$mr_iid" --json headRefName,baseRefName 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("headRefName","")+"\t"+d.get("baseRefName",""))'; then :
      fi
    ) )
}

handler_rebase() {
  local subcmd="${1:-}"; shift || true
  local check_only=0
  if [[ "$subcmd" == "check" ]]; then
    check_only=1
    subcmd="${1:-}"; shift || true
  fi

  local mr_iid="$subcmd" alias="${1:-}"
  if [[ -z "$mr_iid" || ! "$mr_iid" =~ ^[0-9]+$ ]]; then
    tg_send "Usage: /rebase <mr-iid> [<repo-alias>] — or /rebase check <mr-iid>"
    return 1
  fi

  _rebase_lib_load

  local repo
  repo=$(_rebase_resolve_repo "$alias")
  if [[ -z "$repo" || ! -d "$repo/.git" ]]; then
    tg_send "Can't find local checkout for alias \`${alias:-<default>}\`. Check \`.repositories\` in config.json."
    return 1
  fi

  local branches src tgt
  branches=$(_rebase_iid_branches "$mr_iid" "$repo")
  src=$(printf '%s' "$branches" | cut -f1)
  tgt=$(printf '%s' "$branches" | cut -f2)
  if [[ -z "$src" || -z "$tgt" ]]; then
    tg_send "Couldn't resolve branches for MR #${mr_iid}. Is the repo authenticated with glab/gh?"
    return 1
  fi

  tg_send "🔍 Checking drift of \`${src}\` vs \`${tgt}\`…"
  local report
  report=$(rebase_check "$repo" "$src" "$tgt")
  local drift behind safe manual_n
  drift=$(   printf '%s' "$report" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("drift"))')
  behind=$(  printf '%s' "$report" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("behind",0))')
  safe=$(    printf '%s' "$report" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("safe",False))')
  manual_n=$(printf '%s' "$report" | python3 -c 'import json,sys;print(len(json.load(sys.stdin).get("manual",[])))')

  if [[ "$drift" != "True" ]]; then
    tg_send "✅ MR #${mr_iid} is up to date with \`${tgt}\`."
    return 0
  fi

  if [[ "$safe" == "True" ]]; then
    if [[ $check_only -eq 1 ]]; then
      tg_send "ℹ MR #${mr_iid} is ${behind} commits behind — safe auto-rebase available. Use /rebase ${mr_iid} to apply."
      return 0
    fi
    tg_send "🔄 Rebasing MR #${mr_iid} (${behind} commits behind, no unsafe conflicts)…"
    local apply
    apply=$(rebase_apply "$repo" "$src" "$tgt")
    local applied
    applied=$(printf '%s' "$apply" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("applied"))')
    if [[ "$applied" == "True" ]]; then
      local sha
      sha=$(printf '%s' "$apply" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("rebased_to",""))')
      tg_send "✅ Rebased & pushed \`${src}\` → ${sha:0:10}. CI will re-run."
    else
      local reason
      reason=$(printf '%s' "$apply" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("reason","?"))')
      tg_send "❌ Rebase aborted: ${reason}. Try \`/rebase check ${mr_iid}\` or rebase manually."
    fi
    return 0
  fi

  # Unsafe — surface the conflict list and let the user decide.
  local conflicts_pretty
  conflicts_pretty=$(printf '%s' "$report" | python3 -c '
import json, sys
d = json.load(sys.stdin)
m = d.get("manual") or []
return_txt = "\n".join(f"  • {x}" for x in m[:15])
extra = ""
if len(m) > 15:
    extra = f"\n  …and {len(m)-15} more"
print(return_txt + extra)
' 2>/dev/null)
  tg_send "⚠ MR #${mr_iid} is ${behind} commits behind with ${manual_n} unsafe conflict(s):
${conflicts_pretty}

Resolve manually or extend \`projects[].rebase.autoResolve\` in config.json."
}
