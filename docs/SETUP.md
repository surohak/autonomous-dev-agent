# Setup

This is the long-form version of the install instructions in the root README.
Skim the README first for a mental model; come here when something doesn't
work.

## Prerequisites

On a fresh macOS (13+):

```bash
# Homebrew itself, if you don't have it:
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

brew install python@3 jq glab
```

Install Cursor IDE from <https://cursor.com/download>, then enable the CLI:

- Cursor → **Settings** → **General** → **Install `cursor` command in PATH**.

Verify:

```bash
which cursor python3 jq glab curl
```

## Atlassian (Jira + optional Tempo)

You need:

1. **Email** — the one you use to log into Atlassian.
2. **API token** — <https://id.atlassian.com/manage-profile/security/api-tokens>
   → **Create API token** → name it "autonomous-dev-agent" → copy.
3. **Site URL** — the full `https://<your-company>.atlassian.net`.
4. **Project key** — the short prefix before ticket numbers (e.g. `ABC` for
   `ABC-123`).
5. **Account ID** — in Jira, click your avatar → **Profile** → the URL
   contains `/people/<accountId>`. Copy that UUID-ish string.

Optional (enables worklog suggestions):

6. **Tempo API token** — Jira → apps → Tempo → **Settings** → **API
   integration** → **+ New token**.

## GitLab

1. Create a Personal Access Token:
   <https://gitlab.com/-/user_settings/personal_access_tokens>
   → scopes `api`, `read_repository`, `write_repository`.
2. Login with the CLI (stores the token in macOS keychain):
   ```bash
   glab auth login --hostname gitlab.com
   ```
   Paste the token when prompted. For self-hosted, swap in your host.

## Telegram

1. DM [@BotFather](https://t.me/BotFather) → `/newbot` → follow prompts → copy
   the bot token (looks like `1234567:ABC...`).
2. DM your new bot once (any message) so it can reach you.
3. Get your numeric chat ID:

   ```bash
   curl -s "https://api.telegram.org/bot<BOT_TOKEN>/getUpdates" | jq
   ```

   Look for `result[0].message.chat.id` — that's a number, not a `@username`.

## Install

```bash
git clone https://github.com/<you>/autonomous-dev-agent.git
cd autonomous-dev-agent
bash bin/install.sh
```

The interactive wizard will ask for everything above. Secrets are hidden
while typing. All inputs land in `~/.cursor/skills/autonomous-dev-agent/`:

- `config.json` — non-secret identity (mode 644)
- `secrets.env` — tokens (mode 600, gitignored)
- `SKILL.md` — rendered from `SKILL.md.template`
- `~/Library/LaunchAgents/com.<USER>.*.plist` — 4 services

## Verify

```bash
bash bin/doctor.sh
```

Expected output: `PASS` for binaries, config, Jira, Telegram, GitLab, disk.
`WARN` is tolerable (e.g. launchd not loaded yet if you ran `install.sh
--skip-launchd`).

If Jira/Telegram probes fail, re-check the email/token/site URL — the error
messages are intentionally specific.

## First Telegram message

Send `/status` to your bot. You should get back something like:

```
autonomous-dev-agent
  agent     ⏸  idle (next run in 18m)
  watcher   ✅ running (last poll 48s ago)
  telegram  ✅ listening
  digest    🌙 scheduled 16:00
```

If nothing comes back, `launchctl list | grep com.<USER>.dev-agent-telegram`
and check `logs/telegram-handler.log`.

## Optional: SwiftBar menu-bar icon

Install [SwiftBar](https://swiftbar.app) (`brew install --cask swiftbar`),
open it once so it creates `~/Library/Application Support/SwiftBar/Plugins/`,
then re-run `bash bin/install.sh`. The installer detects SwiftBar and
symlinks `scripts/menubar/dev-agent.30s.sh` into the plugins folder. The
robot icon in your menu bar shows:

- overall service health (green when all 4 services are loaded, orange on
  partial, gray when stopped)
- a per-service checklist (`agent`, `watcher`, `telegram`, `digest`)
- "last run" timestamp + exit status of the most recent agent invocation
- one-click actions: **Start/Stop all**, **Run agent once**, **View log**,
  **Open logs folder**, **Run doctor**

Skip with `bash bin/install.sh --skip-swiftbar` if you don't want it.
Remove it with `bash bin/uninstall.sh` (which also removes the symlink).

## Updating

`install.sh` is idempotent. Pull latest, re-run:

```bash
cd autonomous-dev-agent
git pull
bash bin/install.sh
```

It preserves `config.json`, `secrets.env`, `cache/`, `logs/`, and reloads the
launchd services with the new code.

## Managing multiple projects

From v0.3, one install can drive several Jira projects + GitLab groups from a
single watcher. Each project gets its own cache namespace, its own Jira
workflow mapping, and optionally its own Telegram bot and agent model.

### Add a second project

```bash
bin/project add            # interactive wizard
# prompts: id, name, Jira site URL, Jira project key, repos,
#          optional Telegram chat id / bot-token env var / agent model.
bin/install.sh             # regenerate launchd plists
bin/doctor.sh              # sanity-check the new project
```

### Switch which project Telegram commands target

The watcher notifies you about all projects, but commands like `/run`,
`/status`, `/queue` act on the currently-active project.

```
/project list            — shows all projects; ✓ marks the active one
/project use acme        — switches active project
/project info acme       — shows tracker, chat, model for a project
/status all              — cross-project status summary
```

The selection persists across daemon restarts (stored in
`cache/global/active-project.txt`).

### Per-project Telegram bots

If project `beta` should use a different Telegram bot than project `acme`:

1. Create a new bot via BotFather, grab its token.
2. Pick an env-var name for it (e.g. `BETA_BOT_TOKEN`), put the token in
   `secrets.env` under that name.
3. Set `projects[].chat.tokenEnv` to that name for the `beta` project (or
   run `bin/project add` and answer the "telegram bot token env var"
   prompt with `BETA_BOT_TOKEN`).
4. Re-run `bin/install.sh`. It detects the distinct tokens and generates
   one LaunchAgent plist per bot (`…dev-agent-telegram-beta.plist` next to
   `…dev-agent-telegram-acme.plist`), each pinned to its project via
   `AGENT_PROJECT`.

### Jira workflow auto-discovery

First time the watcher/handler touches a project's Jira, it discovers
every available transition and maps it to semantic intents
(`start`, `push_review`, `after_approve`, `done`, `block`, `unblock`).
The mapping is cached at `cache/projects/<id>/workflow.json`.

If your team uses non-standard status names (e.g. *"Code Review To Ready
For QA"*), the default patterns may miss one. `bin/doctor.sh` lists any
unresolved intents; add aliases under
`projects[].workflow.aliases.<intent>`:

```jsonc
{
  "id": "acme",
  "workflow": {
    "aliases": {
      "after_approve": "Code Review To Ready For QA",
      "done":          "Ready For Release"
    }
  }
}
```

Then `rm cache/projects/acme/workflow.json && bin/doctor.sh` to re-
discover. Running agents pick up the new mapping on their next tick.

### Per-project agent model

```jsonc
{
  "agent": { "model": "claude-opus-4-7-high" },              // default
  "projects": [
    {
      "id": "acme",
      "agent": {
        "model": "claude-sonnet-4-5",                         // project default
        "perPhase": {
          "codereview": "claude-opus-4-7-high",               // phase override
          "cifix":      "claude-haiku-4"
        }
      }
    }
  ]
}
```

`bin/doctor.sh` prints the resolved model for every phase.

## Uninstalling

```bash
bash bin/uninstall.sh           # removes launchd services, keeps config
bash bin/uninstall.sh --purge   # also deletes ~/.cursor/skills/autonomous-dev-agent
```
