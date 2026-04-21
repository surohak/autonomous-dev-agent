# Identity-string audit (for Phase 1 de-personalization)

Goal: every hardcoded "JobLeads / Suren / UA-" identifier replaced with a
config-driven value. This file is the replacement list produced at the start
of Phase 1 — once all items are checked off, the code is fork-ready.

## Tokens and their config sources

| Token | Source (config.json path) | Exported as (cfg.sh) |
|-------|---------------------------|----------------------|
| Jira site URL (`https://jobleads.atlassian.net`) | `tracker.siteUrl` | `$JIRA_SITE` |
| Ticket key prefix (`UA`) | `tracker.project` | `$JIRA_PROJECT` |
| Ticket key regex (`UA-\d+`) | computed | `$TICKET_KEY_PATTERN` |
| Owner name (`Suren Hakobyan`) | `owner.name` | `$OWNER_NAME` |
| Owner email (`suren.hakobyan@jobleads.com`) | `owner.email` | `$OWNER_EMAIL` |
| Owner GitLab username (`suren.hakobyan`) | `owner.gitlabUsername` | `$GITLAB_USER` |
| Branch-user slug (`suren` in branchFormat) | `conventions.branchUser` | `$BRANCH_USER` |
| launchd label prefix (`com.suren.`) | derived from `$USER` at install time | `$LAUNCHD_LABEL_PREFIX` |

## Hardcoded sites to replace

### `jobleads.atlassian.net` — 15 occurrences
- `scripts/telegram-handler.sh:434,608,618,639,1293,1318,1343,1355,1673,1692,1703,1725,1787,1828,1874` — all inside inline Python; replace `https://jobleads.atlassian.net` with `os.environ["JIRA_SITE"]`
- `scripts/watcher.sh:389,398,439,444,449,456,462` — inside inline Python
- `scripts/run-agent.sh:323,347` — static prompt scaffold, replace with `$JIRA_SITE`
- `scripts/lib/jira.sh:24` — change default from `"https://jobleads.atlassian.net"` to empty; force it to come from config
- `scripts/lib/cfg.sh:35` — same (already parameterized but with JobLeads default)
- `SKILL.md:173,183,193,234,396,506,533,540,734` — documentation; replace with `{{JIRA_SITE}}`
- `SETUP.md:129` — documentation; already templated format

### `UA-\d+` regex — 5 occurrences
- `scripts/telegram-handler.sh:197,222,378`
- `scripts/watcher.sh:173,267`
- `scripts/handlers/tempo.sh:426` (uses `UA-[0-9]+`)
- `scripts/handlers/queue.sh:160`
- All replaced with `os.environ["TICKET_KEY_PATTERN"]` or bash `"$TICKET_KEY_PATTERN"`.

### `suren.hakobyan` literal — 2 occurrences
- `scripts/telegram-handler.sh:656` (`ME="suren.hakobyan"`) → use `$GITLAB_USER`
- `scripts/run-agent.sh:298` (already has fallback `${GITLAB_USER:-suren.hakobyan}`) → drop the fallback

### `com.suren.` launchd label — 5 occurrences in code
- `scripts/handlers/basic.sh:13,14,126,131,132`
- `scripts/handlers/watch.sh:13`
- All replaced with `${LAUNCHD_LABEL_PREFIX}.*` derived at install time.

### Branch user slug `/suren/` — 1 config location
- `config.json:91` (`branchFormat`) — replace with `{user}` token, add `conventions.branchUser` field.
- `config.json:93-95` (`branchExamples`) — regenerate from the template at init time, not stored in config.

### Email literal `@jobleads.com` — in config.json only
- All 6 email fields in `config.json` are config values and become the user's responsibility to fill in via the `init` wizard. Not a code change.

### Personal paths `/Users/sh/Desktop/...` — in config.json only
- `config.json:79,85` (`repositories.*.localPath`) — user's values, filled in via wizard.

### `jobleads/` in code comments / test fixtures
- `scripts/lib/timelog.sh:18` — docstring example; generalize to `project=ssr` without org prefix
- `scripts/tests/test_gitlab_lib.sh:23,67` — fixture path; change to generic `demo/app`
- `scripts/lib/gitlab.sh:19,36` — docstring examples; change to `demo/app`

### Prompts (`prompts/*.md`) — 48 references across 6 files
All to become `{{TOKEN}}` placeholders, substituted at prompt-render time by
an extended `lib/prompt.sh`. Tokens used:
- `{{OWNER_NAME}}` — replaces "Suren Hakobyan"
- `{{OWNER_FIRST_NAME}}` — replaces standalone "Suren"
- `{{OWNER_EMAIL}}`
- `{{JIRA_SITE}}`
- `{{TICKET_PREFIX}}` — replaces "UA" in prose
- `{{TICKET_EXAMPLE_KEY}}` — replaces "UA-973", "UA-XXX" in examples
- `{{BRANCH_USER}}` — replaces "suren" in branch naming
- `{{COMPANY}}` — replaces "JobLeads" (becomes `""` in default config)
- `{{REPO_LOCAL_PATHS}}` — generated block listing each repo's localPath
- `{{REVIEWERS_TABLE}}` — generated Markdown table from `config.reviewers`

## Launchd plists (installed, need templating)

- `~/Library/LaunchAgents/com.suren.autonomous-dev-agent.plist`
- `~/Library/LaunchAgents/com.suren.dev-agent-digest.plist`
- `~/Library/LaunchAgents/com.suren.dev-agent-telegram.plist`
- `~/Library/LaunchAgents/com.suren.dev-agent-watcher.plist`

All four have:
- `/Users/sh/...` in ProgramArguments → template `{{SKILL_DIR}}`
- `com.suren.*` labels → template `{{LABEL_PREFIX}}`
- `/Users/sh` in HOME env var → template `{{HOME}}`
- `/Users/sh/.local/bin` in PATH → template `{{USER_LOCAL_BIN}}`

Templates live in `scripts/launchd/*.plist.template` (new), rendered at install time by `bin/install.sh`.

## Secrets (never committed)

- `ATLASSIAN_EMAIL`, `ATLASSIAN_API_TOKEN`
- `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`
- `TEMPO_API_TOKEN` (optional)
- `SLACK_BOT_TOKEN` (optional)

Ship `secrets.env.example` with placeholders. `.gitignore` the real one.
