#!/usr/bin/env python3
"""
One-shot migration: v0.2 flat config.json → v0.3 multi-project shape.

Run once after upgrading. Idempotent — re-running on an already-migrated
file is a no-op. Keeps a backup at config.json.v02.bak.

Usage:
    python3 scripts/migrate-config-v0.3.py            # default $SKILL_DIR/config.json
    python3 scripts/migrate-config-v0.3.py path.json  # explicit file
"""

from __future__ import annotations

import json
import os
import shutil
import sys
from pathlib import Path


def needs_migration(cfg: dict) -> bool:
    """True if config is still the v0.2 flat shape."""
    projects = cfg.get("projects")
    if isinstance(projects, list) and projects:
        return False
    # Heuristic: v0.2 has atlassian/repositories at root, no projects[].
    return bool(cfg.get("atlassian") or cfg.get("repositories"))


def migrate(cfg: dict) -> dict:
    """Return a new dict in the v0.3 shape."""
    out: dict = {}
    out["owner"] = cfg.get("owner") or {}
    if "company" in cfg:
        out["company"] = cfg["company"]

    # Chat: synthesise from old flat shape.
    old_chat = cfg.get("chat") or {}
    out["chat"] = {
        "driver":            "telegram",
        "chatId":            old_chat.get("telegramChatId") or old_chat.get("chatId") or "",
        "tokenEnv":          "TELEGRAM_BOT_TOKEN",
    }

    # Time / agent / release approvers all stay at root.
    if "time" in cfg:
        out["time"] = cfg["time"]
    if "agent" in cfg:
        out["agent"] = cfg["agent"]
    else:
        out["agent"] = {
            "model": "claude-opus-4-7-high",
            "_comment": "Override per-project via projects[].agent.model, or per-phase via agent.perPhase.{codereview,cifix,planner,executor}",
        }
    if "releaseApprovers" in cfg:
        out["releaseApprovers"] = cfg["releaseApprovers"]

    # Figure out the project id. Prefer cfg.id, then company (lowercased), then
    # the Jira project prefix, then "default".
    pid = (
        cfg.get("id")
        or (cfg.get("company") or "").lower().replace(" ", "-")
        or (cfg.get("atlassian") or {}).get("project", "").lower()
        or "default"
    )

    project = {
        "id":          pid,
        "name":        cfg.get("company") or pid,
        "tracker":     {
            "kind":             "jira-cloud",
            "siteUrl":          (cfg.get("atlassian") or {}).get("siteUrl", ""),
            "project":          (cfg.get("atlassian") or {}).get("project", ""),
            "cloudId":          (cfg.get("atlassian") or {}).get("cloudId", ""),
        },
        "host":        {"kind": "gitlab"},
        "repositories": cfg.get("repositories") or {},
        "conventions": cfg.get("conventions") or {},
        "reviewers":   cfg.get("reviewers") or [],
    }
    # Move legacy jiraWorkflow → project.workflow.aliases (best-effort).
    legacy_wf = cfg.get("jiraWorkflow") or {}
    if legacy_wf:
        project["workflow"] = {
            "_comment": "Legacy v0.2 jiraWorkflow moved here. The new auto-discovery in scripts/lib/workflow.sh caches resolved transitions in cache/projects/<id>/workflow.json. You can leave this empty unless you have custom status names that need alias regexes.",
            "aliases": {},
            "_legacy": legacy_wf,
        }
    out["projects"] = [project]

    # Preserve anything else we don't know about at root.
    for k, v in cfg.items():
        if k in {
            "owner", "company", "chat", "time", "agent", "releaseApprovers",
            "id", "atlassian", "repositories", "conventions", "reviewers",
            "jiraWorkflow",
        }:
            continue
        out.setdefault(k, v)

    return out


def main() -> int:
    if len(sys.argv) > 1:
        path = Path(sys.argv[1])
    else:
        skill_dir = os.environ.get("SKILL_DIR") or os.path.expanduser(
            "~/.cursor/skills/autonomous-dev-agent"
        )
        path = Path(skill_dir) / "config.json"

    if not path.exists():
        print(f"migrate: {path} not found; nothing to do")
        return 0

    cfg = json.load(open(path))
    if not needs_migration(cfg):
        print(f"migrate: {path} already in v0.3 shape (no changes)")
        return 0

    backup = path.with_suffix(".json.v02.bak")
    shutil.copy2(path, backup)
    print(f"migrate: backed up original to {backup}")

    new_cfg = migrate(cfg)
    with open(path, "w") as f:
        json.dump(new_cfg, f, indent=2)
        f.write("\n")

    print(f"migrate: rewrote {path} as single-project v0.3 config")
    print(f"  project id: {new_cfg['projects'][0]['id']}")
    print("Next: bash bin/doctor.sh   # verifies nothing broke")
    return 0


if __name__ == "__main__":
    sys.exit(main())
