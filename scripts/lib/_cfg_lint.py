#!/usr/bin/env python3
"""
scripts/lib/_cfg_lint.py — minimal structural linter for config.json.

Hand-rolled validator (no jsonschema dep so the agent stays zero-install on
a fresh Mac). Emits one issue per line, prefixed with ERROR/WARN/INFO, to
stdout. Doctor.sh parses these prefixes to route them to fail/warn/info.

Rules encoded here mirror the v0.3 schema. They exist to catch the mistakes
we've actually seen in issues, NOT to implement full JSON Schema. The full
reference schema lives at docs/CONFIG_SCHEMA.json for contributors.

Exit code is always 0 — the caller decides whether to fail the run based
on the issue level (ERROR vs WARN vs INFO).
"""

from __future__ import annotations

import json
import os
import re
import sys


CONFIG_PATH = os.environ.get("CFG", "config.json")

KNOWN_TRACKER_KINDS = {"jira-cloud", "jira-server", "github-issues", "linear"}
KNOWN_HOST_KINDS = {"gitlab", "github", "bitbucket"}
KNOWN_CHAT_KINDS = {"telegram", "slack"}
KNOWN_AGENT_MODELS = {
    # best-effort allow-list; unknown models produce a WARN, not ERROR.
    "claude-4.5-sonnet",
    "claude-4.7-opus",
    "composer-2-fast",
    "gpt-5",
    "gpt-5-high",
    "gpt-5-codex",
    "auto",
}
VALID_INTENTS = {"start", "push_review", "after_approve", "done", "block", "unblock"}
PROJECT_ID_RX = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$")


def issue(level: str, msg: str) -> None:
    sys.stdout.write(f"{level}: {msg}\n")


def lint_config(cfg: dict) -> None:
    if not isinstance(cfg, dict):
        issue("ERROR", "config.json root is not a JSON object")
        return

    # v1.0.0 — schemaVersion contract. Agents refuse to start on unknown majors.
    sv = cfg.get("schemaVersion")
    if sv is None:
        issue(
            "INFO",
            "schemaVersion missing — assume legacy (pre-v1). Add \"schemaVersion\": 1 to silence this.",
        )
    elif not isinstance(sv, int):
        issue("ERROR", f"schemaVersion must be an integer, got {type(sv).__name__}")
    elif sv > 1:
        issue(
            "ERROR",
            f"schemaVersion={sv} is newer than this agent understands (max=1). Upgrade the agent.",
        )
    elif sv < 1:
        issue("WARN", f"schemaVersion={sv} is older than v1; please migrate.")

    # Root-level time block
    time = cfg.get("time") or {}
    if time and not isinstance(time, dict):
        issue("ERROR", "config.time must be an object (has start/end/timezone/quietHours)")

    projects = cfg.get("projects")
    if projects is None:
        # v0.2 shape — still accepted; the resolver normalises. Say so plainly.
        issue("INFO", "no projects[] array — falling back to v0.2 flat shape (auto-normalised)")
        # Sanity-check the v0.2 tracker/host fields live at the root.
        if not cfg.get("atlassian") and not cfg.get("tracker"):
            issue("WARN", "neither 'atlassian' (v0.2) nor 'tracker' (v0.3) present at root; Jira will not be reachable")
        return

    if not isinstance(projects, list):
        issue("ERROR", "config.projects must be an array")
        return
    if not projects:
        issue("ERROR", "config.projects is empty — add at least one project")
        return

    default_project = cfg.get("defaultProject")
    ids_seen: set[str] = set()
    id_to_tokens: dict[str, str] = {}

    for idx, proj in enumerate(projects):
        label = f"projects[{idx}]"
        if not isinstance(proj, dict):
            issue("ERROR", f"{label}: must be an object")
            continue

        pid = proj.get("id")
        if not isinstance(pid, str) or not pid:
            issue("ERROR", f"{label}.id: missing or not a string")
            continue
        if not PROJECT_ID_RX.match(pid):
            issue("ERROR", f"{label}.id: '{pid}' must match [a-zA-Z0-9][a-zA-Z0-9_-]*")
        if pid in ids_seen:
            issue("ERROR", f"duplicate project id: '{pid}'")
        ids_seen.add(pid)

        # Tracker
        tracker = proj.get("tracker") or {}
        if tracker:
            kind = tracker.get("kind")
            if kind and kind not in KNOWN_TRACKER_KINDS:
                issue("WARN", f"{label}.tracker.kind='{kind}' is not a known driver (expected one of: {sorted(KNOWN_TRACKER_KINDS)})")
            if not tracker.get("project") and not cfg.get("atlassian", {}).get("project"):
                issue("WARN", f"{label}.tracker.project: empty — watcher will skip this project")

        # Host
        host = proj.get("host") or {}
        if host:
            kind = host.get("kind")
            if kind and kind not in KNOWN_HOST_KINDS:
                issue("WARN", f"{label}.host.kind='{kind}' is not a known driver (expected one of: {sorted(KNOWN_HOST_KINDS)})")

        # Chat
        chat = proj.get("chat") or cfg.get("chat") or {}
        if chat:
            kind = chat.get("kind") or "telegram"
            if kind not in KNOWN_CHAT_KINDS:
                issue("WARN", f"{label}.chat.kind='{kind}' is not a known driver (expected one of: {sorted(KNOWN_CHAT_KINDS)})")
            token_env = chat.get("tokenEnv") or "TELEGRAM_BOT_TOKEN"
            id_to_tokens[pid] = token_env
            # Cross-check: referenced env var should exist in secrets.env (best-effort).
            secrets_path = os.environ.get("SECRETS_FILE", "secrets.env")
            if os.path.exists(secrets_path):
                try:
                    with open(secrets_path) as fh:
                        secrets_text = fh.read()
                    if not re.search(rf"^\s*export\s+{re.escape(token_env)}=", secrets_text, re.MULTILINE):
                        issue("WARN", f"{label}.chat.tokenEnv='{token_env}' not found in {secrets_path} — per-project bot will silently fall back")
                except OSError:
                    pass

        # Workflow aliases
        wf = proj.get("workflow") or {}
        aliases = wf.get("aliases") or {}
        if aliases and not isinstance(aliases, dict):
            issue("ERROR", f"{label}.workflow.aliases must be an object")
        else:
            for intent, patterns in aliases.items():
                if intent not in VALID_INTENTS:
                    issue("WARN", f"{label}.workflow.aliases.{intent}: unknown intent (expected one of: {sorted(VALID_INTENTS)})")
                if not isinstance(patterns, list) or not all(isinstance(p, str) for p in patterns):
                    issue("ERROR", f"{label}.workflow.aliases.{intent}: must be a list of regex strings")

        # Agent model
        agent = proj.get("agent") or {}
        if agent:
            model = agent.get("model")
            if model and model not in KNOWN_AGENT_MODELS:
                issue("INFO", f"{label}.agent.model='{model}' is not in the known-models list (likely still works; update _cfg_lint.py when confirmed)")

    if default_project and default_project not in ids_seen:
        issue("ERROR", f"defaultProject='{default_project}' does not match any projects[].id (have: {sorted(ids_seen)})")


def main() -> int:
    try:
        with open(CONFIG_PATH) as fh:
            cfg = json.load(fh)
    except FileNotFoundError:
        issue("ERROR", f"{CONFIG_PATH} not found")
        return 0
    except json.JSONDecodeError as e:
        issue("ERROR", f"{CONFIG_PATH}: invalid JSON — {e}")
        return 0

    lint_config(cfg)
    return 0


if __name__ == "__main__":
    sys.exit(main())
