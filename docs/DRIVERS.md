# Driver Layer

The agent talks to three kinds of external systems through **drivers**:

| Layer   | What it abstracts            | Examples               |
|---------|------------------------------|------------------------|
| tracker | issue tracker (tickets)      | `jira-cloud`, `github-issues`, `linear` |
| host    | code host (branches, PRs/MRs)| `gitlab`, `github`     |
| chat    | chat platform (notifications)| `telegram`, `slack`    |

Each driver is a plain bash file under `scripts/drivers/<layer>/<kind>.sh`
that exports a small set of `tracker_*` / `host_*` / `chat_*` functions. A
dispatcher (`_dispatch.sh`) sources the right file based on the
per-project `KIND` env var — so one installation can have one project on
Jira+GitLab+Telegram and another on Linear+GitHub+Slack.

## Architecture

```
cfg.sh  ──(exports TRACKER_KIND / HOST_KIND / CHAT_KIND for active project)──>
         └──> scripts/drivers/<layer>/_dispatch.sh  ──(source)──>
                    └──> scripts/drivers/<layer>/<kind>.sh
                                 └──> exported API (tracker_* / host_* / chat_*)
```

Consumers (`scripts/watcher.sh`, `scripts/handlers/*.sh`, `spawn-agent.sh`
…) only call the generic `tracker_*` / `host_*` / `chat_*` functions.

## Driver contracts

The full API each driver must implement is documented in:

- [`scripts/drivers/tracker/_interface.md`](../scripts/drivers/tracker/_interface.md)
- [`scripts/drivers/host/_interface.md`](../scripts/drivers/host/_interface.md)
- [`scripts/drivers/chat/_interface.md`](../scripts/drivers/chat/_interface.md)

`scripts/tests/test_driver_contract.sh` verifies every driver under
`scripts/drivers/*/*.sh` exports the required functions.

## Shipped drivers

### Tracker

| Kind            | Reqs                  | Config                                    |
|-----------------|-----------------------|-------------------------------------------|
| `jira-cloud`    | `curl`, `jq`          | `tracker.site`, `tracker.projectKey`, `JIRA_EMAIL`+`JIRA_API_TOKEN` in `secrets.env` |
| `github-issues` | `gh` CLI (authed)     | `tracker.repo` = `owner/repo`; login via `gh auth login` |
| `linear`        | `curl`                | `tracker.teamKey`; `LINEAR_API_TOKEN` in `secrets.env` (personal API key from Linear settings) |

### Host

| Kind     | Reqs             | Config                                    |
|----------|------------------|-------------------------------------------|
| `gitlab` | `glab` CLI, `curl` | `host.site`, `host.group`; `GITLAB_TOKEN` |
| `github` | `gh` CLI (authed)| `host.group` = owner; login via `gh auth login` |

### Chat

| Kind       | Reqs    | Config                                                          |
|------------|---------|-----------------------------------------------------------------|
| `telegram` | `curl`  | `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID` in `secrets.env` (per project allowed) |
| `slack`    | `curl`  | `SLACK_BOT_TOKEN` + `chat.channel` (channel id or user id)      |

## Per-project configuration

`config.json` selects driver kinds independently per project:

```json
{
  "projects": [
    {
      "id": "blog",
      "tracker": { "kind": "jira-cloud", "site": "https://acme.atlassian.net", "projectKey": "BLOG" },
      "host":    { "kind": "gitlab", "site": "https://gitlab.com", "group": "acme/blog" },
      "chat":    { "kind": "telegram", "tokenEnv": "BLOG_TELEGRAM_BOT_TOKEN", "chatIdEnv": "BLOG_TELEGRAM_CHAT_ID" }
    },
    {
      "id": "opensource",
      "tracker": { "kind": "github-issues", "repo": "my-org/project" },
      "host":    { "kind": "github",        "group": "my-org" },
      "chat":    { "kind": "slack",         "tokenEnv": "SLACK_BOT_TOKEN", "channel": "C01234567" }
    }
  ]
}
```

Unset fields fall back to legacy v0.2 env vars so existing installs keep
working.

## Writing a new driver

1. Read the matching `_interface.md`.
2. Copy `scripts/drivers/<layer>/jira-cloud.sh` (or another reference
   driver) as a starting point.
3. Implement every required function. Don't implement optional ones
   until there's a caller that needs them.
4. Add `scripts/tests/test_<layer>_<kind>_driver.sh` with offline fixture
   stubs where possible (mock the external CLI with a `PATH` shim — see
   `test_driver_contract.sh`).
5. Run:
   ```bash
   bash scripts/tests/test_driver_contract.sh
   bash scripts/tests/run-tests.sh <layer>_<kind>
   ```
6. Document: add a row to the table above and a short section below with
   required env vars and probe command.
7. Open a Driver Request issue on GitHub — templates live at
   `.github/ISSUE_TEMPLATE/driver-request.yml`.

## Testing a driver locally

```bash
# Source env + activate a project
source scripts/lib/env.sh
source scripts/lib/cfg.sh
cfg_project_activate my-project

# Pull in the dispatchers
source scripts/drivers/tracker/_dispatch.sh
source scripts/drivers/host/_dispatch.sh
source scripts/drivers/chat/_dispatch.sh

# Sanity check
tracker_probe  && echo "tracker OK"
host_probe     && echo "host OK"
chat_probe     && echo "chat OK"

# Example usage
tracker_get PROJ-123
host_mr_list self
chat_send "hello from $(hostname)"
```
