# Architecture

_A one-page map of how `autonomous-dev-agent` fits together, so you can
land changes without reading every file first._

## 30-second pitch

A macOS-native agent that watches your tracker (Jira / GitHub Issues),
opens MRs/PRs on your code host (GitLab / GitHub), and talks back over
chat (Telegram / Slack). Runs as a `launchd` tick every
couple of minutes, spawns one Cursor CLI agent per due ticket, and
hands human decisions back to you in a chat thread with inline buttons.

No server. No database. Everything lives under
`~/.cursor/skills/autonomous-dev-agent/`.

## Directory map

```
autonomous-dev-agent/
├─ bin/                       CLI entry points (install, doctor, release)
│  ├─ install.sh              Re-runnable setup (idempotent)
│  ├─ init.sh                 Interactive first-time config generator
│  ├─ doctor.sh               Health checks + --fix + --smoke
│  └─ release.sh              Semantic-version bumper + GitHub Release
├─ scripts/
│  ├─ watcher.sh              ⏰ Tick loop (launchd 2-min ticks)
│  ├─ telegram-handler.sh     📨 Chat inbound (poll → dispatch)
│  ├─ spawn-agent.sh          🚀 Run one agent (prompt → Cursor CLI)
│  ├─ daily-digest.sh         📰 End-of-day summary (launchd 16:00)
│  ├─ lib/                    Shared libraries (config, prompt, queue, …)
│  │  ├─ cfg.sh               config.json + project activation
│  │  ├─ prompt.sh            Templated prompt rendering
│  │  ├─ queue.sh             Priority + fair-share scoring
│  │  ├─ workflow.sh          Tracker-workflow intent discovery
│  │  ├─ rebase.sh            Auto-rebase with safe auto-resolve
│  │  ├─ transcribe.sh        Voice-note → text (Whisper / whisper.cpp)
│  │  ├─ ocr.sh               Screenshot → text (Vision API / macOS)
│  │  └─ log-rotate.sh        50 MB log rotation
│  ├─ drivers/                Pluggable backends (v0.4+)
│  │  ├─ tracker/             jira-cloud, github-issues
│  │  ├─ host/                gitlab, github
│  │  └─ chat/                telegram, slack
│  ├─ handlers/               Chat-command dispatchers (/run, /queue, …)
│  ├─ menubar/                SwiftBar plugin (live status)
│  └─ tests/                  Offline unit suite (Bash + Python)
├─ prompts/                   Prompt templates (phase1/phase2)
├─ docs/                      Architecture, drivers, stability, …
│  └─ schemas/                Frozen JSON Schemas (v1)
├─ cache/                     Runtime state (see docs/STABILITY.md)
├─ logs/                      Rotated logs + archive/
├─ config.json                User config (.gitignored)
└─ secrets.env                API tokens (.gitignored)
```

## Request flow — "a ticket gets picked up"

```
launchd ──► watcher.sh ────► tracker_search (driver)
                              │
                              ├──► priority queue (lib/queue.sh)
                              │
                              └──► fair-share pick
                                     │
                                     ▼
                              spawn-agent.sh
                                     │
     ┌───────────────────────────────┼────────────────────────────┐
     ▼                               ▼                            ▼
prompt.sh (renders             cursor-agent CLI             host_mr_create
  phase2-executor.md +          (writes code + git           (driver: gitlab/github)
  RECENT_LESSONS from           + pushes branch)                   │
  cache/projects/<pid>/                                            ▼
  lessons.md)                                              chat_send (driver)
                                                                   │
                                                                   ▼
                                                          tracker_transition
                                                          (intent=push_review)
```

## Request flow — "a chat message comes in"

```
launchd ──► telegram-handler.sh ──► chat_poll (driver: telegram/slack)
                                      │
     ┌────────────────────────────────┼────────────────────────────┐
     ▼                                ▼                            ▼
text command                     voice note                     screenshot
   │                                │                              │
   ▼                                ▼                              ▼
handler_* (handlers/)         lib/transcribe.sh              lib/ocr.sh
   │                                │                              │
   │                                └──────────► re-dispatch ◄─────┘
   ▼                                                  │
tracker_* / host_* /                                  ▼
chat_send (drivers) ◄──────────────────────── handler_* (handlers/)
```

## Driver layer (the v0.4 pivot)

Three thin function interfaces isolate vendor APIs from agent logic:

| Layer   | Contract                                    | Reference impls            |
|---------|---------------------------------------------|----------------------------|
| tracker | `tracker_search/get/transition/comment/…`   | jira-cloud, github-issues |
| host    | `host_mr_{list,get,create,merge}/ci_status/…` | gitlab, github             |
| chat    | `chat_{send,send_interactive,edit,poll}`    | telegram, slack            |

Each driver is a single `.sh` file under `scripts/drivers/<layer>/`.
`_dispatch.sh` picks the right one based on the active project's
`<layer>.kind` field. `test_driver_contract.sh` asserts every required
function is exported before shipping.

See [`docs/DRIVERS.md`](./DRIVERS.md) and the `_interface.md` files for
the frozen signature tables.

## State

All state is on local disk — deletable safely except `config.json` and
`secrets.env`. Layout frozen at v1, see
[`docs/STABILITY.md`](./STABILITY.md).

## Concurrency model

- `watcher.sh` is **serial per-project** (subshell-wrapped so a failure
  in project A doesn't poison project B).
- Per-project processing may spawn multiple Cursor CLI agents in
  parallel up to `agent.parallelism` (default 3).
- Chat handler and watcher run in separate launchd jobs; no shared
  process state — they coordinate through `cache/` JSON files.

## Security model

- Tokens live in `secrets.env` (mode 600, git-ignored). Doctor enforces.
- Cursor CLI inherits the agent's env; it has the same access you do.
- No callbacks/webhooks are exposed: chat is strictly poll-based, so
  no inbound firewall holes.
- Voice notes and photos are downloaded to `cache/{voice,photos}/` and
  deleted after processing.

## Extension points (if you want to hack on it)

- **New tracker / host / chat** → drop a driver under `scripts/drivers/`
  and add its `kind` to `_cfg_lint.py` allow-lists.
- **New chat command** → add `scripts/handlers/<name>.sh`, source it
  from `telegram-handler.sh`, dispatch in the big `case` block.
- **New prompt token** → add it to `prompts/phase2-executor.md` and
  populate it in `scripts/lib/prompt.sh`'s Python block.
- **New daily ritual** → add a `scripts/<name>.sh` + a launchd plist in
  `bin/install.sh`.
