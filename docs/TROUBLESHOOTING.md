# Troubleshooting

Most problems fall into one of six categories. Skim until you find yours.

## "Nothing is happening"

```bash
bash bin/doctor.sh
```

fixes half of these. For the other half, check the logs directly:

```bash
tail -f ~/.cursor/skills/autonomous-dev-agent/logs/watcher.log
tail -f ~/.cursor/skills/autonomous-dev-agent/logs/telegram-handler.log
tail -f ~/.cursor/skills/autonomous-dev-agent/logs/launchd-stderr.log
```

Each launchd service writes `*.log` and `*-error.log`. If `*-error.log` is
empty the service is probably not running — `launchctl list | grep dev-agent`.

## Jira auth returns HTTP 401

The Atlassian API expects Basic Auth with email + API token, not password.
In `secrets.env` confirm:

```
export ATLASSIAN_EMAIL="you@your-company.atlassian.net"
export ATLASSIAN_API_TOKEN="…"   # from id.atlassian.com, not from Jira itself
```

Then probe manually:

```bash
source ~/.cursor/skills/autonomous-dev-agent/secrets.env
curl -u "${ATLASSIAN_EMAIL}:${ATLASSIAN_API_TOKEN}" \
  "https://your-site.atlassian.net/rest/api/3/myself" | jq
```

If that returns your user, edit `config.json` to match the site URL.

## "Ready For QA transition not available" / "no transition matches intent <X>"

Since v0.3 the agent auto-discovers every Jira project's transition graph
(`scripts/lib/workflow.sh`) and maps the six semantic intents the agent
uses — `start`, `push_review`, `after_approve`, `done`, `block`, `unblock` —
to the appropriate transition IDs. The mapping is cached at
`cache/projects/<id>/workflow.json`.

**First diagnose:**

```bash
bin/doctor.sh        # shows [workflow] section with resolved intents
```

If any intent comes back unresolved, it means the default name patterns
didn't match any of your Jira columns.

**Fix:** add aliases for that project in `config.json`:

```jsonc
"projects": [
  {
    "id": "acme",
    "workflow": {
      "aliases": {
        "after_approve": "Code Review To Ready For QA",   // exact transition name
        "done":          "Ready For Release"
      }
    }
  }
]
```

Then invalidate the cache and re-probe:

```bash
rm cache/projects/acme/workflow.json
bin/doctor.sh
```

No restart needed — running agents pick up the new mapping on next tick.

### Legacy single-project config

The older `jiraWorkflow.statuses.readyForQA = { name: "..." }` format from
v0.2 still works — `scripts/lib/jira.sh::jira_transition_to` falls back to
name-matching if the workflow cache is missing.

## Telegram bot never replies

1. Did you DM the bot **first**? Bots can't reach users they've never heard
   from — this is a Telegram restriction, not ours.
2. Is `TELEGRAM_CHAT_ID` numeric? Not `@username`, not `"+371..."`.
   Re-derive it:
   ```bash
   curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates" \
     | jq '.result[0].message.chat.id'
   ```
3. Is the `dev-agent-telegram` service running?
   `launchctl list | grep com.$USER.dev-agent-telegram`.
4. Check `logs/telegram-handler-error.log` — Telegram errors are logged with
   enough detail to distinguish auth from rate-limit from bad JSON.

## GitLab approvals fail

`glab` auth lives in the macOS keychain, separate from `GITLAB_TOKEN`
in `secrets.env`. The code falls back to `glab` for approval operations that
need user-scoped permissions. Run `glab auth status` — if it says "not
logged in":

```bash
glab auth login --hostname gitlab.com   # or your self-hosted host
```

For self-hosted GitLab behind SSO, you may need to set
`GITLAB_HOST=gitlab.mycorp.com` in `secrets.env`.

## launchd service keeps respawning (telegram handler)

`KeepAlive=true` on the Telegram listener means launchd restarts it on any
non-zero exit. A tight respawn loop usually means:

- Missing dependency (`python3` not on the launchd PATH — but the plist
  template sets `PATH` explicitly, including Homebrew paths).
- Bad token (`400 Bad Request` on every `getUpdates`).
- Corrupted state in `cache/telegram-offset.json` — delete it; the handler
  will re-read from Telegram's server-side update offset.

Check `logs/telegram-handler-error.log` for the exit reason.

## Multi-project: commands target the wrong project

`/run`, `/status`, `/queue` default to the *active* project. Check / set:

```
/project list                  # ✓ marks active
/project use <id>               # switch
```

If you have multiple Telegram bots (one per project), each bot's daemon is
*pinned* to its project via the `AGENT_PROJECT` env var in its LaunchAgent
plist. You cannot switch project from a pinned daemon — it will just reject
`/project use` with "already pinned to …". Install/reinstall regenerates
the plists.

## Multi-project: watcher fires the wrong project's notifications

Symptoms: `[acme]` tag on a notification that's clearly about beta.

1. `cat cache/projects/acme/watcher-state.json` — should contain only acme
   MRs/tickets. If it has beta entries, the v0.2→v0.3 migration aliased
   state incorrectly.
2. Nuke the per-project cache and let the watcher re-discover:
   ```bash
   rm cache/projects/acme/watcher-state.json
   launchctl kickstart -k "gui/$(id -u)/com.$USER.dev-agent-watcher"
   ```

## "telegram plist not loaded" after adding a project

`install.sh` groups projects by `chat.tokenEnv`. A new project with a new
bot token only gets its own plist when `install.sh` is re-run **after** the
token is in `secrets.env`:

```bash
# 1. Put the new token in secrets.env (e.g. BETA_BOT_TOKEN=...)
# 2. Add it to config.json (bin/project add does this for you)
# 3. Regenerate plists
bin/install.sh
launchctl list | grep dev-agent-telegram      # should show one per token
```

## Tempo card says "skipping — cap exceeded"

`scripts/tempo-suggest.py` caps a single ticket at `time.worklogCapMinutes`
(default 480 = 8 h). Edit `config.json`:

```json
"time": { "worklogCapMinutes": 600 }
```

Or pass `--force` via the `/tempo` Telegram command.

## "prompt_render: no such file" during install

Means the rsync step in `install.sh` skipped a file. If you're running from
a local copy, `chmod +x bin/*.sh scripts/*.sh` and try again. The installer
doesn't fail on a read-only filesystem — it just warns.

## Resetting to a known-good state

```bash
bash bin/uninstall.sh
rm -rf ~/.cursor/skills/autonomous-dev-agent/cache
rm -rf ~/.cursor/skills/autonomous-dev-agent/logs
bash bin/install.sh          # re-run wizard only if you also removed config.json
```

The `cache/` reset is non-destructive for you personally — it contains only
the agent's per-run memory (last-seen MR state, pending callbacks, Tempo
event log). Worklogs already pushed to Tempo are safe.

## Getting more help

- `docs/SETUP.md` — step-by-step install
- `docs/AUDIT-identity-strings.md` — where every identifier comes from
- `scripts/README.md` — internal architecture
- Open an issue with your `bin/doctor.sh` output attached
