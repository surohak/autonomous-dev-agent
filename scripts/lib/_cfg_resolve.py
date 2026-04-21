#!/usr/bin/env python3
"""
Helpers invoked by scripts/lib/cfg.sh.

Two modes:
    python3 _cfg_resolve.py normalize <config.json>
        Emits JSON {"root": {...}, "projects": [...]}; normalises v0.2 flat
        config into v0.3 projects[] shape for uniform downstream handling.
        Every project dict has tracker/host/repositories/workflow/agent/chat/
        conventions/reviewers keys (possibly empty) after normalisation.

    python3 _cfg_resolve.py activate <config.json> <project_id>
        Emits `export VAR=value` shell lines for every per-project env var.
        The active project is looked up in the normalised config. Env vars
        for existing OS env (e.g. TELEGRAM_BOT_TOKEN_SIDE) are inherited.
"""

from __future__ import annotations

import json
import os
import shlex
import sys


def normalise(cfg: dict) -> dict:
    projects = cfg.get("projects")
    if not isinstance(projects, list) or not projects:
        projects = [{
            "id":           cfg.get("id") or "default",
            "name":         cfg.get("company") or "default",
            "tracker": {
                "kind":             "jira-cloud",
                "siteUrl":          (cfg.get("atlassian") or {}).get("siteUrl", ""),
                "project":          (cfg.get("atlassian") or {}).get("project", ""),
                "cloudId":          (cfg.get("atlassian") or {}).get("cloudId", ""),
                "ticketKeyPattern": (cfg.get("atlassian") or {}).get("ticketKeyPattern", ""),
            },
            "host":         cfg.get("host") or {"kind": "gitlab"},
            "repositories": cfg.get("repositories") or {},
            "workflow":     cfg.get("workflow") or cfg.get("jiraWorkflow") or {},
            "agent":        cfg.get("agent") or {},
            "chat":         cfg.get("chat") or {},
            "conventions":  cfg.get("conventions") or {},
            "reviewers":    cfg.get("reviewers") or [],
        }]

    for p in projects:
        p.setdefault("id", "default")
        p.setdefault("tracker", {})
        p.setdefault("host", {"kind": "gitlab"})
        p.setdefault("repositories", {})
        p.setdefault("workflow", {})
        p.setdefault("agent", {})
        p.setdefault("chat", {})
        p.setdefault("conventions", {})
        p.setdefault("reviewers", [])

    root = {k: v for k, v in cfg.items() if k != "projects"}
    return {"root": root, "projects": projects}


def activate(cfg: dict, pid: str) -> list[str]:
    data = normalise(cfg)
    root = data["root"]
    project = None
    for p in data["projects"]:
        if p["id"] == pid:
            project = p
            break
    if project is None:
        sys.stderr.write(f"_cfg_resolve: project id {pid!r} not in config.json\n")
        sys.exit(2)

    owner = root.get("owner") or {}
    conv = project.get("conventions") or root.get("conventions") or {}
    out: list[str] = []

    def exp(name: str, val) -> None:
        out.append(f"export {name}={shlex.quote(str(val))}")

    # --- Identity ---
    exp("OWNER_NAME",       owner.get("name", ""))
    exp("OWNER_FIRST_NAME", owner.get("firstName") or (owner.get("name", "").split() or [""])[0])
    exp("OWNER_EMAIL",      owner.get("email", ""))
    exp("OWNER_SLACK_ID",   owner.get("slackUserId", ""))
    exp("JIRA_ACCOUNT_ID",  owner.get("jiraAccountId", ""))
    exp("GITLAB_USER",      owner.get("gitlabUsername", ""))
    exp("COMPANY",          root.get("company", ""))

    # --- Active project ---
    exp("PROJECT_ID",   project["id"])
    exp("PROJECT_NAME", project.get("name") or project["id"])

    tracker = project.get("tracker") or {}
    exp("JIRA_SITE",    tracker.get("siteUrl", ""))
    exp("JIRA_PROJECT", tracker.get("project", ""))
    exp("JIRA_CLOUD_ID",tracker.get("cloudId", ""))
    prefix = (tracker.get("project") or "").strip()
    default_pat = (rf"{prefix}-\d+") if prefix else r"[A-Z]+-\d+"
    exp("TICKET_KEY_PATTERN", tracker.get("ticketKeyPattern") or default_pat)

    exp("BRANCH_USER",   conv.get("branchUser") or owner.get("gitlabUsername", "").split(".")[0])
    exp("BRANCH_FORMAT", conv.get("branchFormat") or conv.get("branchFormatTemplate") or
                         "{type}/{ticketPrefix}/{ticketKey}/{user}/{short-description}")

    # --- Chat (per-project override wins) ---
    root_chat = root.get("chat") or {}
    project_chat = project.get("chat") or {}

    def chat_val(key: str) -> str:
        return project_chat.get(key) or root_chat.get(key) or ""

    exp("TELEGRAM_CHAT_ID", chat_val("chatId") or chat_val("telegramChatId"))
    token_env = project_chat.get("tokenEnv") or root_chat.get("tokenEnv") or "TELEGRAM_BOT_TOKEN"
    exp("TELEGRAM_TOKEN_ENV", token_env)
    token = os.environ.get(token_env) or os.environ.get("TELEGRAM_BOT_TOKEN", "")
    exp("TELEGRAM_BOT_TOKEN", token)

    # --- Agent model (per-phase > per-project > root) ---
    root_agent = root.get("agent") or {}
    project_agent = project.get("agent") or {}

    def agent_model(phase: str | None = None) -> str:
        if phase:
            pp = project_agent.get("perPhase") or {}
            if pp.get(phase):
                return pp[phase]
            rp = root_agent.get("perPhase") or {}
            if rp.get(phase):
                return rp[phase]
        return project_agent.get("model") or root_agent.get("model") or "claude-opus-4-7-high"

    exp("AGENT_MODEL",            agent_model())
    exp("AGENT_MODEL_CODEREVIEW", agent_model("codereview"))
    exp("AGENT_MODEL_CIFIX",      agent_model("cifix"))
    exp("AGENT_MODEL_PLANNER",    agent_model("planner"))
    exp("AGENT_MODEL_EXECUTOR",   agent_model("executor"))

    # --- Repositories: emit generic <SLUG>_REPO / _BRANCH / _PROJECT ---
    repos = project.get("repositories") or {}
    if isinstance(repos, dict):
        for slug, r in repos.items():
            if slug == "_comment" or not isinstance(r, dict):
                continue
            up = slug.upper().replace("-", "_")
            exp(f"{up}_REPO",    r.get("localPath", ""))
            exp(f"{up}_BRANCH",  r.get("defaultBranch", ""))
            exp(f"{up}_PROJECT", r.get("gitlabProject", ""))
        slugs = " ".join(s for s in repos.keys() if s != "_comment" and isinstance(repos.get(s), dict))
    else:
        slugs = ""
    exp("PROJECT_REPO_SLUGS", slugs)

    # --- Per-project cache namespace ---
    cache_dir = os.environ.get("CACHE_DIR", "")
    exp("PROJECT_CACHE_DIR", os.path.join(cache_dir, "projects", project["id"]))
    exp("GLOBAL_CACHE_DIR",  os.path.join(cache_dir, "global"))

    return out


def main() -> int:
    if len(sys.argv) < 3:
        sys.stderr.write("usage: _cfg_resolve.py {normalize|activate} <config.json> [<pid>]\n")
        return 2
    mode, config_path = sys.argv[1], sys.argv[2]
    cfg = json.load(open(config_path))
    if mode == "normalize":
        print(json.dumps(normalise(cfg)))
    elif mode == "activate":
        pid = sys.argv[3] if len(sys.argv) > 3 else ""
        if not pid:
            data = normalise(cfg)
            pid = data["projects"][0]["id"] if data["projects"] else ""
        for line in activate(cfg, pid):
            print(line)
    else:
        sys.stderr.write(f"_cfg_resolve: unknown mode {mode!r}\n")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
