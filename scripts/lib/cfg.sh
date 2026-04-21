#!/bin/bash
# scripts/lib/cfg.sh
#
# Read config.json and export per-project env vars. Delegates all parsing to
# scripts/lib/_cfg_resolve.py so we avoid fragile heredoc-in-subshell tricks.
#
# CONFIG SHAPE
#
# v0.3 introduces a multi-project shape but stays backward-compatible with
# v0.2 flat shape via auto-normalisation in _cfg_resolve.py.
#
#   if config.projects is a non-empty array:
#       each element is a project; root-level fields are global defaults
#   else:
#       the whole file is treated as a single implicit project "default"
#
# Root-level keys (apply across all projects):
#   owner, chat, time, agent, releaseApprovers, company
#
# Per-project keys:
#   id, name, tracker, host, repositories, workflow, agent, chat,
#   conventions, reviewers
#
# PUBLIC API
#
#   cfg_project_list                  space-separated project ids
#   cfg_project_default               first project id
#   cfg_project_activate <id>         re-export all per-project env vars
#   cfg_project_field    <id> <path>  python-accessor into one project
#   cfg_root_field       <path>       python-accessor into root
#   cfg_get              <path>       legacy alias of cfg_root_field
#   cfg_branch <type> <key> <short>   render branch name from template
#
# Exported env (after cfg_project_activate):
#   Identity: OWNER_NAME, OWNER_FIRST_NAME, OWNER_EMAIL, OWNER_SLACK_ID,
#             JIRA_ACCOUNT_ID, GITLAB_USER, COMPANY, LAUNCHD_LABEL_PREFIX
#   Project:  PROJECT_ID, PROJECT_NAME, PROJECT_REPO_SLUGS,
#             PROJECT_CACHE_DIR, GLOBAL_CACHE_DIR, REVIEWS_DIR
#             JIRA_SITE, JIRA_PROJECT, JIRA_CLOUD_ID, TICKET_KEY_PATTERN
#             BRANCH_USER, BRANCH_FORMAT
#             TELEGRAM_CHAT_ID, TELEGRAM_BOT_TOKEN, TELEGRAM_TOKEN_ENV
#             AGENT_MODEL, AGENT_MODEL_CODEREVIEW, AGENT_MODEL_CIFIX,
#             AGENT_MODEL_PLANNER, AGENT_MODEL_EXECUTOR
#   Repos:    <SLUG>_REPO / <SLUG>_BRANCH / <SLUG>_PROJECT for every slug
#
# Idempotent — safe to source repeatedly or activate a different project.

[[ -n "${_DEV_AGENT_CFG_LOADED:-}" ]] && return 0
_DEV_AGENT_CFG_LOADED=1

[[ -z "${SKILL_DIR:-}" ]] && { echo "cfg.sh: env.sh not loaded" >&2; return 1; }
[[ -f "$CONFIG_FILE" ]] || { echo "cfg.sh: $CONFIG_FILE not found" >&2; return 1; }

_CFG_RESOLVE_PY="$LIB_DIR/_cfg_resolve.py"
[[ -f "$_CFG_RESOLVE_PY" ]] || { echo "cfg.sh: $_CFG_RESOLVE_PY missing" >&2; return 1; }

# Cached normalized JSON for the life of the shell (performance — avoids
# re-parsing config.json for every list/field lookup).
_cfg_normalized() {
  if [[ -z "${_CFG_NORM_JSON:-}" ]]; then
    _CFG_NORM_JSON=$(python3 "$_CFG_RESOLVE_PY" normalize "$CONFIG_FILE") || return 1
    export _CFG_NORM_JSON
  fi
  printf '%s' "$_CFG_NORM_JSON"
}

cfg_project_list() {
  _cfg_normalized | python3 -c '
import json, sys
print(" ".join(p["id"] for p in json.load(sys.stdin)["projects"]))
'
}

cfg_project_default() {
  # Honour explicit "defaultProject" (under root.) if set, otherwise fall back
  # to the first entry in projects[]. The v0.2→v0.3 migration always sets
  # defaultProject so existing installs see no change.
  _cfg_normalized | python3 -c '
import json, sys
d = json.load(sys.stdin)
root = d.get("root") or {}
dp   = root.get("defaultProject")
if dp and any(p["id"] == dp for p in d.get("projects", [])):
    print(dp)
elif d.get("projects"):
    print(d["projects"][0]["id"])
'
}

cfg_root_field() {
  local path="$1"
  _cfg_normalized | python3 -c "
import json, sys
d = json.load(sys.stdin)['root']
try: print(d$path)
except Exception: pass
"
}
cfg_get() { cfg_root_field "$@"; }

cfg_project_field() {
  # Two path syntaxes accepted:
  #   * dot-notation  — "tracker.project", "chat.chatId"        (preferred)
  #   * bracket-raw   — "[\"tracker\"][\"project\"]"            (legacy)
  # A path that starts with '[' is pasted after p verbatim; anything else is
  # split on '.' and walked with a KeyError-safe getattr-ish loop.
  local id="$1" path="$2"
  _cfg_normalized | ID="$id" P="$path" python3 -c '
import json, os, sys
path = os.environ["P"]
cfg = json.load(sys.stdin)
for p in cfg.get("projects", []):
    if p.get("id") != os.environ["ID"]:
        continue
    if path.startswith("["):
        # legacy: eval the raw expression against `p`. Contained to cfg data
        # so an "eval" here is acceptable for local trusted config.
        try: print(eval("p"+path))
        except Exception: pass
    else:
        cur = p
        ok = True
        for part in path.split("."):
            if isinstance(cur, dict) and part in cur:
                cur = cur[part]
            else:
                ok = False; break
        if ok and cur is not None:
            print(cur if not isinstance(cur, (dict, list)) else json.dumps(cur))
    break
'
}

cfg_project_activate() {
  local id="${1:-}"
  [[ -z "$id" ]] && id=$(cfg_project_default)
  [[ -z "$id" ]] && { echo "cfg.sh: no project id and no default" >&2; return 1; }

  local exports
  exports=$(python3 "$_CFG_RESOLVE_PY" activate "$CONFIG_FILE" "$id") || return $?
  eval "$exports"

  mkdir -p "$PROJECT_CACHE_DIR" "$GLOBAL_CACHE_DIR" 2>/dev/null || true
  export REVIEWS_DIR="$PROJECT_CACHE_DIR/reviews"
  export PENDING_DM_DIR="$PROJECT_CACHE_DIR/pending-dm"
  mkdir -p "$REVIEWS_DIR" "$PENDING_DM_DIR" 2>/dev/null || true

  # Per-project state files. Unconditional re-export so repeated activations
  # (watcher outer loop) switch correctly — env-var fallbacks would otherwise
  # freeze the first project's paths for the rest of the process.
  export WATCHER_STATE_FILE="$PROJECT_CACHE_DIR/watcher-state.json"
  export ACTIVE_RUNS_FILE="$PROJECT_CACHE_DIR/active-runs.json"
  export ESTIMATES_FILE="$PROJECT_CACHE_DIR/estimates.json"
  export FAILURES_FILE="$PROJECT_CACHE_DIR/failures.json"
  export TIME_LOG_FILE="$PROJECT_CACHE_DIR/time-log.jsonl"
  export WORKFLOW_FILE="$PROJECT_CACHE_DIR/workflow.json"
  export PROMOTED_FILE="$PROJECT_CACHE_DIR/promoted.json"
  export GITLAB_JIRA_USERS_FILE="$PROJECT_CACHE_DIR/gitlab-jira-users.json"
  export LESSONS_FILE="$PROJECT_CACHE_DIR/lessons.md"

  # Global (cross-project) state files.
  export SLACK_TOKEN_FILE="$GLOBAL_CACHE_DIR/slack-token.json"
  export WATCHER_LOCK_FILE="$GLOBAL_CACHE_DIR/watcher.pid"

  # Telegram-offset is scoped per-bot-token so one-bot-per-project works
  # without races (each bot polls its own offset file). Key is the env var
  # name that holds the token — hashed to keep the file name short.
  local tg_key
  tg_key=$(printf '%s' "${TELEGRAM_TOKEN_ENV:-TELEGRAM_BOT_TOKEN}" | shasum -a 1 2>/dev/null | cut -c1-8)
  [[ -z "$tg_key" ]] && tg_key="default"
  export TG_OFFSET_FILE="$GLOBAL_CACHE_DIR/telegram-offset-$tg_key.txt"

  # One-shot legacy migration: if the old flat-cache file exists and the new
  # per-project file doesn't, move it. Keeps v0.2 users' state on upgrade.
  _cfg_migrate_legacy_state
}

_cfg_migrate_legacy_state() {
  local f
  local -a per_project=(watcher-state.json active-runs.json estimates.json failures.json
                        time-log.jsonl workflow.json promoted.json gitlab-jira-users.json lessons.md)
  for f in "${per_project[@]}"; do
    local old="$CACHE_DIR/$f"
    local new="$PROJECT_CACHE_DIR/$f"
    if [[ -f "$old" && ! -f "$new" ]]; then
      mv "$old" "$new" 2>/dev/null || true
    fi
  done
  # Legacy reviews/ and pending-dm/ subdirs.
  if [[ -d "$CACHE_DIR/reviews" && ! -e "$REVIEWS_DIR" ]]; then
    mv "$CACHE_DIR/reviews" "$REVIEWS_DIR" 2>/dev/null || mkdir -p "$REVIEWS_DIR"
  fi
  if [[ -d "$CACHE_DIR/pending-dm" && ! -e "$PENDING_DM_DIR" ]]; then
    mv "$CACHE_DIR/pending-dm" "$PENDING_DM_DIR" 2>/dev/null || mkdir -p "$PENDING_DM_DIR"
  fi
  # Global: migrate slack-token and telegram-offset once.
  if [[ -f "$CACHE_DIR/slack-token.json" && ! -f "$SLACK_TOKEN_FILE" ]]; then
    mv "$CACHE_DIR/slack-token.json" "$SLACK_TOKEN_FILE" 2>/dev/null || true
  fi
  if [[ -f "$CACHE_DIR/telegram-offset.txt" && ! -f "$TG_OFFSET_FILE" ]]; then
    mv "$CACHE_DIR/telegram-offset.txt" "$TG_OFFSET_FILE" 2>/dev/null || true
  fi
}

cfg_branch() {
  local type="$1" ticket_key="$2" short_desc="$3"
  python3 - "$type" "$ticket_key" "$short_desc" "$BRANCH_USER" "$JIRA_PROJECT" "$BRANCH_FORMAT" <<'PY'
import sys
type_, ticket_key, short, user, prefix, tpl = sys.argv[1:7]
print(tpl
      .replace("{type}", type_)
      .replace("{ticketPrefix}", prefix)
      .replace("{ticketKey}", ticket_key)
      .replace("{user}", user)
      .replace("{short-description}", short))
PY
}

export LAUNCHD_LABEL_PREFIX="com.${USER:-user}"

# Auto-activate the default project on first load. Multi-project callers
# (watcher outer loop) override this by calling cfg_project_activate <id>
# per iteration.
cfg_project_activate "$(cfg_project_default)" 2>/dev/null || true
