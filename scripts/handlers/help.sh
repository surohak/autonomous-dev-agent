#!/bin/bash
# scripts/handlers/help.sh — /help

[[ -n "${_DEV_AGENT_HANDLER_HELP_LOADED:-}" ]] && return 0
_DEV_AGENT_HANDLER_HELP_LOADED=1

cmd_help() {
  tg_send "Commands — tap / in Telegram for the menu.

Parallel runs
- Up to 10 agents run in parallel. Duplicates on the same ticket/MR are
  rejected — you'll get 'already running' with a pointer to /status.
- Manual runs bypass the 7:00–23:00 work-hour guard. Scheduled runs don't.
- Every manual run pings you on exit (Done / Failed / Skipped + duration).

Top-level
- /ask <anything> — free-form prompt (shortcut: '?', or reply to Agent: …)
- /status — live view: active runs with [View log] [Stop] per run
- /status all — status across ALL projects (multi-project installs)
- /project list — show all projects (active marked ✓)
- /project use <id> — switch active project
- /project info [<id>] — tracker/bot/model settings for a project
- /workflow [<id>] — show Jira workflow intents (active or named project)
- /workflow refresh [<id>] — re-discover Jira workflow after admin changes
- /tickets — Active runs section + New/To Do queue
- /queue [<n>] — cross-project priority queue (fair-share, top N; default 10)
- /rebase <mr-iid> [<alias>] — auto-rebase onto main (safe conflicts only)
- /rebase check <mr-iid> — inspect drift without pushing
- /reviews — MRs assigned to you for code review
- /mrs — your own open MRs
- /run — trigger full agent run
- /digest — daily summary
- /logs — latest run log (pick a specific one via /status)
- /stop, /start — scheduled-agent control (the every-30-min run)
- /watch, /snooze 1h, /unsnooze — watcher controls
- /stopall — SIGTERM every active run

Tickets (/tickets)
- Active run card: [Status] [View log] [Stop]
- Queue card (not running): [Run] [Skip]
- If a ticket is size-blocked in estimates.json: [Run] [Force run (size)] [Skip]
- Skip on a running ticket stops the agent first, then moves to Backlog.

Code review (/reviews)
- Not reviewed yet / no comments: [Review now] [Approve without review] [Skip for now]
- Comments pending: [Show comments] [Send to dev] [Approve MR] [Re-review] [Skip]
- LGTM: [Approve MR] [Re-review] [Skip]
- Re-review detection is automatic — the round number shows in the card
  (round 2, 3, …) after the dev pushes fixes and re-assigns.

Standup & Describe
- /standup — generate daily standup from Tempo + Jira + open MRs
- /describe UA-XXX — generate MR description from diff + Jira context

Merge & Promote
- /merge UA-XXX — merge approved MR to stage
- /cherries — Done tickets not yet on main (combined view)
- /cherry PROJ-XXX — cherry-pick to main

Tempo (worklog suggestions + summary)
- /tempo — suggestions for yesterday (one card per ticket×day)
- /tempo today, /tempo week — other windows
- /tempo summary — read-only view of already-logged Tempo worklogs (yesterday)
- /tempo summary today, /tempo summary week — other summary windows
- Immediate cards also fire right after dev-done (ticket → Code Review)
  and review-done (MR approved → Ready For QA). Respects Skip and the
  15-min floor. Set TEMPO_AUTO_SUGGEST=0 in secrets.env to silence.
- Per-card: [Log <Xh Ym>] logs to Tempo · [Edit] prompts for a custom
  duration · [Skip] dismisses. After logging, [Undo] appears.

Slack hotfix (auto — no command needed)
- Watcher monitors configured Slack channels for bug reports
- New messages appear as cards: [Fix this] [Ask Reporter] [Reply only] [Ignore]
- Fix this: reads thread + screenshots, spawns agent, opens MR to stage,
  replies in Slack with MR link
- Ask Reporter: prompts you for a question, posts it in the Slack thread
- Reply only: type a freeform reply to post in the thread
- Configure: slack.monitor.channels in config.json

Review nudges
- MRs in Code Review >24h get daily follow-up notifications
- [Follow-up in DM] sends a Slack nudge to the reviewer
- Nudge frequency: once per 24h per MR

Typed shortcuts
- run PROJ-XXX, retry PROJ-XXX, approve PROJ-XXX, skip PROJ-XXX
- review PROJ-XXX: <feedback>   (starts a feedback-review turn)
- /help — this message"
}
