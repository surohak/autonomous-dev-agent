# Autonomous Dev Agent

> Your local MacBook running a Cursor-powered dev clone that listens to Jira,
> spawns agent runs in the Cursor IDE, opens MRs on GitLab, and talks back to
> you on Telegram — all while you eat lunch.

**Status: v0.4 (driver layer).** Mix-and-match **trackers**
(Jira Cloud, GitHub Issues), **code hosts** (GitLab, GitHub), and
**chat platforms** (Telegram, Slack) per project. One install can manage
several projects, each with its own driver stack, agent model, and
credentials. See [docs/DRIVERS.md](./docs/DRIVERS.md) for the catalogue
and [CHANGELOG.md](./CHANGELOG.md) for release history.

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

## Install

The agent runs on macOS and drives the Cursor CLI, so step 1 is always:
get the toolchain ready, then clone-and-install.

### 1. Base toolchain (always)

macOS 13+ (tested on 14 Sonoma and 15 Sequoia). Everything else flows
through Homebrew.

```bash
# Homebrew itself — skip if you already have it.
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Core deps used by every driver and every script.
brew install jq python@3 curl git
```

### 2. Cursor IDE + Cursor CLI

The agent invokes the Cursor CLI (`agent`/`cursor-agent`) to drive the
LLM. Install both:

```bash
# Option A — Homebrew cask (recommended on macOS).
brew install --cask cursor

# Option B — direct download: https://www.cursor.com/download
```

Then install the `cursor` and `cursor-agent` command-line binaries:

1. Open Cursor → Cmd-Shift-P → "Shell Command: Install 'cursor' command
   in PATH".
2. Install Cursor CLI for agent execution:

   ```bash
   curl https://cursor.com/install -fsS | bash
   ```

   This puts `cursor-agent` on your PATH (usually `~/.local/bin/`).
   See [docs.cursor.com/cli](https://docs.cursor.com/en/cli/overview) for
   auth (`cursor-agent login`) and model selection.

Verify:

```bash
cursor --version && cursor-agent --version
```

### 3. MCP servers inside Cursor (optional but recommended)

MCP servers give Cursor — and therefore the agent runs it spawns — native
access to your tracker, chat, and design tools. None of them are
*required* (everything still works through the CLIs below), but they make
Cursor smarter when it needs to read a Jira ticket, a Figma frame, or a
Slack thread while coding.

Install from **Cursor Settings → MCP → "+ Add new global MCP server"** or
by editing `~/.cursor/mcp.json`. Relevant ones for this agent:

| MCP             | Why you'd add it                                            | How                                                         |
|-----------------|-------------------------------------------------------------|-------------------------------------------------------------|
| **Atlassian**   | Agent can read a Jira ticket's full body + linked pages.    | Cursor Plugin → Atlassian → sign in                         |
| **GitLab**      | Agent can read MR threads, pipelines, file history.         | Cursor Plugin → GitLab → sign in                            |
| **GitHub**      | Same as GitLab but for GH repos + PRs.                      | Cursor Plugin → GitHub → sign in                            |
| **Slack**       | Agent can read the thread it's asked about.                 | Cursor Plugin → Slack → sign in                             |
| **Figma**       | `figma-use` / design-to-code workflows.                     | Cursor Plugin → Figma → sign in                             |
| **Context7**    | Live library docs when agent hits a library it doesn't know.| `npx -y @upstash/context7-mcp` (add to `~/.cursor/mcp.json`)|

Full catalogue and JSON examples:
[docs.cursor.com/en/context/mcp](https://docs.cursor.com/en/context/mcp).

### 4. Driver-specific CLIs

Drivers are picked per-project — install only the CLIs for drivers you'll
actually configure.

| Driver                     | Install                                        | Auth                                                   |
|----------------------------|------------------------------------------------|--------------------------------------------------------|
| tracker `jira-cloud`       | (curl+jq already installed)                    | Atlassian Cloud email + API token (`id.atlassian.com`) |
| tracker `github-issues`    | `brew install gh`                              | `gh auth login`                                        |
| host `gitlab`              | `brew install glab`                            | `glab auth login` + GitLab personal access token       |
| host `github`              | `brew install gh`                              | `gh auth login` (same as the tracker driver)           |
| chat `telegram`            | (curl already installed)                       | Bot token from `@BotFather` + numeric chat id          |
| chat `slack`               | (curl already installed)                       | Slack bot token (`xoxb-…`) + channel id                |
| worklog (optional) `tempo` | (curl already installed)                       | Tempo Cloud API token (Tempo → Settings → API)         |

Verify:

```bash
gh auth status      # if you picked GitHub drivers
glab auth status    # if you picked GitLab host
```

### 5. Optional extras

Skip any of these; the agent degrades gracefully.

| Tool                  | Enables                                                                                    | Install                                                                      |
|-----------------------|--------------------------------------------------------------------------------------------|------------------------------------------------------------------------------|
| [SwiftBar](https://swiftbar.app) | Menu-bar icon with live status + start/stop/run-once.                           | `brew install --cask swiftbar`                                               |
| `ffmpeg`              | Voice-note transcription via local `whisper.cpp` (audio→WAV conversion).                   | `brew install ffmpeg`                                                        |
| `whisper.cpp`         | Local offline voice transcription (fallback when `OPENAI_API_KEY` isn't set).              | `brew install whisper-cpp` then `whisper-cli --help`                         |
| OpenAI API key        | Faster cloud voice transcription + screenshot OCR via Vision.                              | Put `OPENAI_API_KEY=sk-…` in `secrets.env`                                   |
| Tempo                 | One-tap worklog suggestions in the daily digest and code-review flow.                      | Tempo Cloud API token in `secrets.env` as `TEMPO_API_TOKEN`                  |

### 6. Clone + run the installer

```bash
git clone https://github.com/<you>/autonomous-dev-agent.git
cd autonomous-dev-agent
bash bin/install.sh
```

The installer:

1. Verifies `python3`, `jq`, `curl`, `git`, `cursor`, `cursor-agent` are on `PATH`
   — and the host CLI for whichever host driver you pick (`gh` / `glab`).
2. Copies files into `~/.cursor/skills/autonomous-dev-agent/`.
3. Runs `bin/init.sh` interactively to collect credentials for your
   chosen drivers (trackers, host, chat, optional Tempo).
4. Renders `SKILL.md` and every prompt from templates using your config.
5. Generates `~/Library/LaunchAgents/com.<user>.*.plist` and loads them.
6. If SwiftBar is installed, symlinks `scripts/menubar/dev-agent.30s.sh`
   into its plugins folder. Opt out with `--skip-swiftbar`.

### 7. Verify

```bash
bash bin/doctor.sh            # checks every configured driver + launchd.
bash bin/doctor.sh --fix      # applies safe auto-remediations.
bash bin/doctor.sh --smoke    # end-to-end integration ping per project.
```

Full walkthrough with screenshots: [docs/SETUP.md](./docs/SETUP.md).
See [docs/DRIVERS.md](./docs/DRIVERS.md) for per-driver config shapes and
[docs/TROUBLESHOOTING.md](./docs/TROUBLESHOOTING.md) for common failures.

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
- [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md) — one-page map of how it fits together
- [docs/DRIVERS.md](./docs/DRIVERS.md) — driver catalogue + how to write a new one
- [docs/STABILITY.md](./docs/STABILITY.md) — v1 freeze: config, interface, command vocab
- [docs/MIGRATION.md](./docs/MIGRATION.md) — how to move between versions
- [docs/TROUBLESHOOTING.md](./docs/TROUBLESHOOTING.md) — common failure modes
- [docs/CONTRIBUTING.md](./docs/CONTRIBUTING.md) — how to contribute a driver
- [CHANGELOG.md](./CHANGELOG.md) — release history + roadmap

## License

MIT. See [LICENSE](./LICENSE).
