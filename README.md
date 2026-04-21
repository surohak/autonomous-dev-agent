# Autonomous Dev Agent

> Your local MacBook running a Cursor-powered dev clone that listens to Jira,
> spawns agent runs in the Cursor IDE, opens MRs on GitLab, and talks back to
> you on Telegram — all while you eat lunch.

**Status: v0.3 (fork-friendly, multi-project).** Jira Cloud + GitLab +
Telegram + Tempo Cloud. One install can manage several projects, each with
its own Jira board, GitLab group, Telegram bot, and agent model. Alternate
drivers (GitHub, Slack, Linear, …) are on the roadmap — see
[CHANGELOG.md](./CHANGELOG.md).

## What it actually does

| Trigger | Action |
|---|---|
| Jira ticket assigned to you | Scheduler agent plans it, opens an MR, assigns a reviewer |
| CI fails on your MR | Watcher notifies Telegram; one tap re-runs the agent to fix |
| Reviewer comments land | Telegram card per comment; approve/reject individually |
| MR approved | Agent merges, transitions Jira to Ready For QA, unassigns |
| Ticket moves to Code Review | Tempo suggests a worklog; one tap logs it |
| `/status`, `/queue`, `/tempo`, … in Telegram | Direct control of the agent |
| Menu-bar icon (optional, via SwiftBar) | See service health + one-click start/stop/run-once |

Everything runs under launchd on your Mac. Nothing talks to a SaaS you don't
already own. Your tokens never leave `~/.cursor/skills/`.

## 60-second install

```bash
git clone https://github.com/<you>/autonomous-dev-agent.git
cd autonomous-dev-agent
bash bin/install.sh
```

The installer:

1. Verifies `python3`, `jq`, `curl`, `glab`, `cursor` are on `PATH`.
2. Copies files into `~/.cursor/skills/autonomous-dev-agent/`.
3. Runs `bin/init.sh` to collect your Jira/GitLab/Telegram/Tempo credentials.
4. Renders `SKILL.md` and every prompt from templates using your config.
5. Generates `~/Library/LaunchAgents/com.<user>.*.plist` and loads them.
6. If [SwiftBar](https://swiftbar.app) is installed, links
   `scripts/menubar/dev-agent.30s.sh` into its plugins folder so you get a
   menu-bar icon with service health + start/stop/run-once actions. Opt out
   with `--skip-swiftbar`.

Verify with:

```bash
bash bin/doctor.sh    # pings Jira, Telegram, GitLab, Tempo; checks launchd.
```

Full walkthrough (with screenshots): [docs/SETUP.md](./docs/SETUP.md).

## Requirements

- macOS 13+ (tested 14 Sonoma, 15 Sequoia).
- Cursor IDE installed and the `cursor` CLI on `PATH`.
- Atlassian Cloud (Jira + optional Tempo).
- GitLab (self-hosted or `gitlab.com`).
- A Telegram bot + your numeric chat ID.
- `brew install jq glab python@3`.

## Configuration model

Two files, both local, both gitignored:

| File | What it stores |
|---|---|
| `config.json` | Non-secret identity: Jira site, project key, your name, repo paths, branch conventions. See [`config.example.json`](./config.example.json). |
| `secrets.env` | API tokens: Atlassian, Telegram, GitLab, Tempo. See [`secrets.env.example`](./secrets.env.example). |

`SKILL.md`, `prompts/*.md`, and `launchd/*.plist` are rendered from their
`.template` counterparts at install time using values from `config.json` —
no hardcoded identities anywhere in the committed code.

### Multi-project setups

Since v0.3, one install can manage many projects.

```jsonc
{
  "owner": { "name": "You",     "email": "you@example.com", … },
  "chat":  { "chatId": "123",   "tokenEnv": "TELEGRAM_BOT_TOKEN" },
  "agent": { "model":  "claude-opus-4-7-high" },
  "projects": [
    {
      "id": "acme",
      "tracker": { "siteUrl": "https://acme.atlassian.net", "project": "ACME" },
      "repositories": { "web": { "localPath": "~/code/acme-web", "gitlabProject": "acme/web" } }
    },
    {
      "id": "beta",
      "tracker": { "siteUrl": "https://beta.atlassian.net", "project": "BETA" },
      "chat":    { "tokenEnv": "BETA_BOT_TOKEN" },   // separate Telegram bot
      "agent":   { "model":    "claude-sonnet-4-5" } // cheaper model per project
    }
  ]
}
```

Commands:

```bash
bin/project list                         # see configured projects
bin/project add  [<id>]                  # wizard to add one
bin/project show <id>                    # print the project's config block
bin/project remove <id>                  # delete a project (keeps cache/)
```

From Telegram: `/project list`, `/project use <id>`, `/project info`,
`/status all` (cross-project status view). Multi-project installs prepend
`[<project-id>]` to each notification card so you always know which board
a message is about.

Per-project state is namespaced: `cache/projects/<id>/watcher-state.json`,
`cache/projects/<id>/active-runs.json`, etc. Cross-project state
(Telegram offsets per bot, watcher lock, Slack token cache) lives under
`cache/global/`.

**Different Telegram bots per project**: put each token in `secrets.env`
under the env-var name you set in `chat.tokenEnv`, then re-run
`bin/install.sh` — it generates one LaunchAgent plist per distinct token,
each pinned to its project via `AGENT_PROJECT=<id>`.

**Jira status names are auto-discovered** at first use and cached under
`cache/projects/<id>/workflow.json`. If your team uses non-standard status
names (e.g. "Code Review To Ready For QA"), add
`projects[].workflow.aliases` to map semantic intents (`start`,
`push_review`, `after_approve`, `done`, `block`, `unblock`) to your
transition names. `bin/doctor.sh` warns about unresolved intents.

## Repo layout

```
autonomous-dev-agent/
├── bin/                 install.sh / init.sh / doctor.sh / uninstall.sh
├── docs/                SETUP.md, TROUBLESHOOTING.md, AUDIT-identity-strings.md
├── prompts/             Tokenised phase prompts consumed by run-agent.sh
├── scripts/
│   ├── launchd/         Plist templates (agent, watcher, telegram, digest)
│   ├── menubar/         SwiftBar plugin (optional menu-bar icon)
│   ├── lib/             Shared bash libs: cfg, env, jira, gitlab, telegram,
│   │                    tempo, prompt, timelog, timegate, jsonstate, …
│   ├── handlers/        Telegram command handlers (basic, tempo, watch, …)
│   ├── tests/           Unit tests (run with scripts/tests/run-tests.sh)
│   ├── run-agent.sh     Main Cursor-driven agent loop
│   ├── watcher.sh       Poll Jira/GitLab for events every 2 minutes
│   ├── telegram-handler.sh  Long-running Telegram listener
│   └── daily-digest.sh  End-of-day summary
├── SKILL.md.template    Tokenised skill prompt (SKILL.md is rendered locally)
├── config.example.json  Copy this to config.json
└── secrets.env.example  Copy this to secrets.env
```

## Philosophy

- **Local-first.** No cloud, no SaaS control plane. Your tokens stay on
  your Mac.
- **launchd over cron.** macOS restarts services cleanly after reboot.
- **Plain bash + Python stdlib.** Zero node/rust/go deps — install friction
  is the enemy.
- **Cursor Agent CLI does the thinking.** We do the plumbing.
- **Every identity string is a config value.** See
  [`docs/AUDIT-identity-strings.md`](./docs/AUDIT-identity-strings.md).

## Learn more

- [docs/SETUP.md](./docs/SETUP.md) — step-by-step install
- [docs/TROUBLESHOOTING.md](./docs/TROUBLESHOOTING.md) — common failure modes
- [docs/CONTRIBUTING.md](./docs/CONTRIBUTING.md) — how to contribute a driver
- [CHANGELOG.md](./CHANGELOG.md) — release history + roadmap

## License

MIT. See [LICENSE](./LICENSE).
