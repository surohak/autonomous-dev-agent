#!/bin/bash
# scripts/lib/prompt.sh
#
# Render a prompt template by substituting {{TOKEN}} placeholders with values
# from the environment (populated earlier by lib/cfg.sh and secrets.env).
#
# Tokens supported:
#   {{OWNER_NAME}}, {{OWNER_FIRST_NAME}}, {{OWNER_EMAIL}}
#   {{COMPANY}}
#   {{JIRA_SITE}}, {{JIRA_ACCOUNT_ID}}, {{JIRA_PROJECT}}, {{TICKET_KEY_PATTERN}}
#   {{TICKET_PREFIX}}       — same as JIRA_PROJECT (clearer name in prose)
#   {{TICKET_EXAMPLE_KEY}}  — example ticket string: "$TICKET_PREFIX-123"
#   {{GITLAB_USER}}, {{BRANCH_USER}}
#   {{SSR_REPO}}, {{BLOG_REPO}}
#   {{SSR_GITLAB_PROJECT}}, {{BLOG_GITLAB_PROJECT}}
#   {{SSR_GITLAB_PROJECT_ENCODED}}, {{BLOG_GITLAB_PROJECT_ENCODED}}  — for REST URLs
#   {{SSR_BRANCH}}, {{BLOG_BRANCH}}
#   {{OWNER_SLACK_ID}}      — from config.json owner.slackUserId
#   {{REVIEWERS_POOL}}      — bullet list rendered from config.json reviewers[]
#   {{PROJECT_ID}}, {{PROJECT_NAME}}
#   {{PROJECT_CACHE_DIR}}   — per-project cache root, e.g. ".../cache/projects/<id>"
#   {{GLOBAL_CACHE_DIR}}    — shared cache root,       e.g. ".../cache/global"
#   {{SKILL_DIR}}           — absolute path to the skill's install dir
#   {{AGENT_MODEL}}         — Cursor CLI model for the default phase
#   {{RECENT_LESSONS}}      — last N entries from PROJECT_CACHE_DIR/lessons.md,
#                              rendered as a bullet list. Empty string if none.
#
# Usage:
#   source lib/env.sh; source lib/cfg.sh; source lib/prompt.sh
#   RENDERED=$(prompt_render "$SKILL_DIR/prompts/phase1-monitor.md")
#
# Also exposed: prompt_render_all — pre-renders every prompt under prompts/
# once (used by bin/init.sh so the user has ready-to-read prompt files).

[[ -n "${_DEV_AGENT_PROMPT_LOADED:-}" ]] && return 0
_DEV_AGENT_PROMPT_LOADED=1

prompt_render() {
  local path="$1"
  [[ -f "$path" ]] || { echo "prompt_render: $path not found" >&2; return 1; }
  # Keep the substitution in Python: straightforward, handles all tokens in one
  # pass, doesn't mangle sed metacharacters inside multi-paragraph prose.
  PROMPT_FILE="$path" python3 - <<'PY'
import json, os, sys, urllib.parse

def qenc(v):
    return urllib.parse.quote(v, safe="") if v else ""

# Load a few non-exported fields directly from config.json because they're
# structured data (lists of reviewers, nested IDs) that don't fit cleanly in
# shell env vars.
cfg = {}
cfg_path = os.environ.get("CONFIG_FILE", "")
if cfg_path and os.path.exists(cfg_path):
    try: cfg = json.load(open(cfg_path))
    except Exception: cfg = {}

owner_slack = (cfg.get("owner") or {}).get("slackUserId", "")

# Reviewers moved from root to projects[].reviewers in config v0.3. Without
# this fallback the v0.3 configs render {{REVIEWERS_POOL}} as "(none configured)"
# even though the pool is populated — which makes the LLM's reviewer-picker
# step in phase2-executor.md a no-op.
_proj0 = (cfg.get("projects") or [{}])[0] if isinstance(cfg.get("projects"), list) else {}
_reviewers = cfg.get("reviewers") or _proj0.get("reviewers") or []
reviewer_lines = []
for r in _reviewers:
    name    = r.get("name", "?")
    slack   = r.get("slackUserId") or "<no-slack-id>"
    domains = ", ".join(r.get("domains", [])) or "general"
    reviewer_lines.append(f"- {name} — Slack: {slack} — Domains: {domains}")
reviewers_pool = "\n".join(reviewer_lines) or "(none configured — edit config.json reviewers[])"

tokens = {
    "OWNER_NAME":          os.environ.get("OWNER_NAME", ""),
    "OWNER_FIRST_NAME":    os.environ.get("OWNER_FIRST_NAME", ""),
    "OWNER_EMAIL":         os.environ.get("OWNER_EMAIL", ""),
    "COMPANY":             os.environ.get("COMPANY", ""),
    "JIRA_SITE":           os.environ.get("JIRA_SITE", ""),
    "JIRA_ACCOUNT_ID":     os.environ.get("JIRA_ACCOUNT_ID", ""),
    "JIRA_PROJECT":        os.environ.get("JIRA_PROJECT", ""),
    "TICKET_PREFIX":       os.environ.get("JIRA_PROJECT", ""),
    "TICKET_KEY_PATTERN":  os.environ.get("TICKET_KEY_PATTERN", ""),
    "GITLAB_USER":         os.environ.get("GITLAB_USER", ""),
    "BRANCH_USER":         os.environ.get("BRANCH_USER", ""),
    "SSR_REPO":            os.environ.get("SSR_REPO", ""),
    "BLOG_REPO":           os.environ.get("BLOG_REPO", ""),
    "SSR_GITLAB_PROJECT":  os.environ.get("SSR_PROJECT", ""),
    "BLOG_GITLAB_PROJECT": os.environ.get("BLOG_PROJECT", ""),
    "SSR_BRANCH":          os.environ.get("SSR_BRANCH", ""),
    "BLOG_BRANCH":         os.environ.get("BLOG_BRANCH", ""),
    "PROJECT_ID":          os.environ.get("PROJECT_ID", ""),
    "PROJECT_NAME":        os.environ.get("PROJECT_NAME", ""),
    "PROJECT_CACHE_DIR":   os.environ.get("PROJECT_CACHE_DIR", ""),
    "GLOBAL_CACHE_DIR":    os.environ.get("GLOBAL_CACHE_DIR", ""),
    "SKILL_DIR":           os.environ.get("SKILL_DIR", ""),
    "AGENT_MODEL":         os.environ.get("AGENT_MODEL", ""),
}
tokens["TICKET_EXAMPLE_KEY"] = f"{tokens['TICKET_PREFIX']}-123" if tokens["TICKET_PREFIX"] else "ABC-123"
tokens["SSR_GITLAB_PROJECT_ENCODED"]  = qenc(tokens["SSR_GITLAB_PROJECT"])
tokens["BLOG_GITLAB_PROJECT_ENCODED"] = qenc(tokens["BLOG_GITLAB_PROJECT"])
tokens["OWNER_SLACK_ID"] = owner_slack
tokens["REVIEWERS_POOL"] = reviewers_pool

# v0.5.0 — recent lessons. The agent's post-mortem step appends bullets to
# PROJECT_CACHE_DIR/lessons.md. We pull the last N (default 8) and inject
# them into the executor prompt, so the next run learns from the last ones.
# Keep the rendering cheap: a flat text read + tail.
RECENT_LESSONS = ""
lessons_path = os.path.join(os.environ.get("PROJECT_CACHE_DIR",""), "lessons.md") if tokens["PROJECT_CACHE_DIR"] else ""
max_lessons = int(os.environ.get("LESSONS_MAX", "8") or 8)
if lessons_path and os.path.isfile(lessons_path):
    try:
        raw = open(lessons_path).read().splitlines()
    except Exception:
        raw = []
    # Keep only bullet lines ("- ..."), newest first. The agent is asked to
    # append newest-at-bottom, so we take the tail.
    bullets = [l for l in raw if l.strip().startswith(("-","*"))]
    tail = bullets[-max_lessons:]
    if tail:
        RECENT_LESSONS = "\n".join(tail)
tokens["RECENT_LESSONS"] = RECENT_LESSONS

text = open(os.environ["PROMPT_FILE"]).read()
for k, v in tokens.items():
    text = text.replace("{{" + k + "}}", str(v))
sys.stdout.write(text)
PY
}

prompt_render_all() {
  local src_dir="${1:-$SKILL_DIR/prompts}"
  local dest_dir="${2:-$src_dir}"
  local suffix="${3:-.rendered.md}"
  local f
  for f in "$src_dir"/*.md; do
    # Skip already-rendered outputs so prompt_render_all is idempotent.
    [[ "$f" == *"$suffix" ]] && continue
    local base
    base="$(basename "${f%.md}")"
    prompt_render "$f" > "$dest_dir/${base}${suffix}"
  done
}
