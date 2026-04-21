# Changelog

All notable changes to this project are tracked here. Versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned
- Adapter layer (Phase 3): `scripts/drivers/` with swappable tracker/host/
  chat drivers. Reference drivers for GitHub Issues, Linear, and Slack.
  _Targeted for v0.4.0._

## [0.3.0] - 2026-04-16

One user, many projects. v0.3 is the "multi-project" release — a single
install can now manage several Jira boards, GitLab groups, and Telegram bots
from one watcher process.

### Added
- **Multi-project config shape** (`config.json` v0.3): root-level
  `{owner, chat, time, agent}` defaults plus a `projects[]` array of
  `{id, name, tracker, host, workflow, chat, agent, repositories,
  reviewers, conventions}` blocks. Legacy v0.2 flat configs are auto-
  normalised at load time (no user action required); the one-shot
  `scripts/migrate-config-v0.3.py` converts them on disk if preferred.
- **Per-project cache namespace**: state files move to
  `cache/projects/<id>/…` and cross-project state moves to `cache/global/…`.
  First load migrates the legacy flat `cache/watcher-state.json`,
  `cache/reviews/`, `cache/pending-dm/`, etc. into `cache/projects/default/`.
- **Per-project Telegram bots**: `chat.tokenEnv` + `chat.chatId` overrides on
  the project block. `install.sh` generates one LaunchAgent plist per
  distinct bot token, each pinned via `AGENT_PROJECT=<id>`. Offset files
  are scoped per-token so multiple daemons don't race.
- **Per-project agent model**: `config.agent.model` (root) and
  `projects[].agent.model`, plus `agent.perPhase.{codereview,cifix,planner,
  executor}` overrides. `run-agent.sh` picks the right model per phase.
- **Jira workflow auto-discovery** (`scripts/lib/workflow.sh`): at first
  use, discovers all Jira transitions/statuses via REST, resolves them to
  semantic intents (`start`, `push_review`, `after_approve`, `done`,
  `block`, `unblock`) and caches the mapping under
  `cache/projects/<id>/workflow.json`. Eliminates the old hardcoded "Ready
  For QA" strings; teams with custom status names just add
  `projects[].workflow.aliases` overrides.
- **Watcher outer loop**: `scripts/watcher.sh` iterates
  `cfg_project_list` each tick; single-project installs still run once per
  tick (zero behaviour change).
- **Telegram UX**: `/project list`, `/project use <id>`,
  `/project info [<id>]`, `/status all`. Cards from the watcher get a
  `[project-id]` prefix on multi-project installs.
- **`bin/project` CLI**: `bin/project list|show|add|remove` wizard for
  editing `config.json` safely (JSON-aware, writes timestamped `.bak`
  before every change).
- **`bin/doctor.sh`**: new `[projects]`, `[agent model]`, and `[workflow]`
  diagnostic sections — lists every configured project, prints the
  resolved agent model per phase, and probes Jira workflow discovery
  (warning on any unresolved semantic intent).
- Tests: `scripts/tests/test_multi_project.sh`,
  `scripts/tests/test_chat_override.sh`,
  `scripts/tests/test_workflow_lib.sh`.

### Changed
- `scripts/lib/cfg.sh` now exports a full project context on every
  `cfg_project_activate <id>` call: `PROJECT_ID`, `PROJECT_NAME`,
  `JIRA_SITE`, `JIRA_PROJECT`, `TELEGRAM_CHAT_ID`, `TELEGRAM_TOKEN_ENV`,
  `AGENT_MODEL`, `AGENT_MODEL_CODEREVIEW`, `AGENT_MODEL_CIFIX`,
  `AGENT_MODEL_PLANNER`, `AGENT_MODEL_EXECUTOR`, `PROJECT_CACHE_DIR`,
  `GLOBAL_CACHE_DIR`, and the state-file paths (`WATCHER_STATE_FILE`,
  `ACTIVE_RUNS_FILE`, `ESTIMATES_FILE`, `FAILURES_FILE`,
  `TIME_LOG_FILE`, `WORKFLOW_FILE`, `PROMOTED_FILE`,
  `GITLAB_JIRA_USERS_FILE`, `LESSONS_FILE`, `TG_OFFSET_FILE`).
- Re-activation is now idempotent — repeated `cfg_project_activate` calls
  correctly switch all state paths (previously some vars stuck to the
  first project).
- Prompts + `SKILL.md.template` gained `{{PROJECT_ID}}`, `{{PROJECT_NAME}}`,
  `{{PROJECT_CACHE_DIR}}`, `{{GLOBAL_CACHE_DIR}}`, `{{AGENT_MODEL}}`
  tokens via `scripts/lib/prompt.sh`.
- All scripts that touched cache files (`watcher.sh`, `telegram-handler.sh`,
  `run-agent.sh`, `send-slack-dm.py`, `cherry-pick.py`, every handler
  under `scripts/handlers/`) now honour the per-project env vars with
  safe fallbacks to the legacy flat paths.

### Migration notes
- **v0.2 users**: no action required. The first time `cfg.sh` loads it
  auto-migrates your existing `cache/` layout into `cache/projects/default/`
  and normalises your flat `config.json` in memory. If you want the on-disk
  config to reflect the new shape, run `scripts/migrate-config-v0.3.py`
  (writes a `.bak`, fully reversible).
- **Adding a second project**: `bin/project add`, then `bin/install.sh` to
  regenerate the LaunchAgent plists. If the new project uses a different
  Telegram bot, put its token in `secrets.env` under your chosen
  `chat.tokenEnv` name before re-running install.

## [0.2.0] - 2026-04-16

First public release. "Fork-friendly" means: every identity string is a
config value, every prompt is templated, the installer is idempotent, and
the test suite runs in under 10 seconds.

### Added
- `bin/install.sh`, `bin/init.sh` (interactive wizard), `bin/doctor.sh`,
  `bin/uninstall.sh`.
- Optional [SwiftBar](https://swiftbar.app) menu-bar plugin at
  `scripts/menubar/dev-agent.30s.sh`. Shows service health, last-run
  timestamp + exit code, and one-click start/stop/run-once/logs/doctor
  actions. `install.sh` auto-symlinks it into
  `~/Library/Application Support/SwiftBar/Plugins/` when SwiftBar is
  installed; `--skip-swiftbar` opts out; `uninstall.sh` removes the link.
  `doctor.sh` includes an info-only SwiftBar presence check.
- `scripts/launchd/*.plist.template` — tokenised launchd plists rendered at
  install time.
- `scripts/lib/prompt.sh` + `test_prompt_lib.sh` — token substitution engine
  for all rendered templates (`SKILL.md.template`, `prompts/*.md`,
  `*.plist.template`).
- `config.example.json` + `secrets.env.example` with inline documentation.
- `docs/SETUP.md`, `docs/TROUBLESHOOTING.md`, `docs/CONTRIBUTING.md`,
  `docs/AUDIT-identity-strings.md`.
- `LICENSE` (MIT).

### Changed
- All hardcoded `jobleads.atlassian.net`, `UA-\d+`, `suren.hakobyan`,
  `com.suren.*` launchd labels, and absolute repo paths replaced with
  config-driven values. See `docs/AUDIT-identity-strings.md` for the audit.
- `scripts/lib/cfg.sh` exports the full identity set: `OWNER_NAME`,
  `OWNER_FIRST_NAME`, `OWNER_EMAIL`, `COMPANY`, `JIRA_SITE`, `JIRA_PROJECT`,
  `JIRA_ACCOUNT_ID`, `GITLAB_USER`, `BRANCH_USER`, `TICKET_KEY_PATTERN`,
  `LAUNCHD_LABEL_PREFIX`, and the per-repo `*_REPO`/`*_BRANCH`/`*_PROJECT`
  triples.
- `run-agent.sh` now reads prompts through `prompt_render` so the committed
  templates never leak personal identifiers.

## [0.1.0] - 2025-12 (pre-public)

Original JobLeads-specific build used internally. Not released publicly.
See git log for change-by-change history.

### Features at this point
- Jira ticket monitor + executor (scheduler plist, 30min interval).
- Watcher polling CI, MR comments, Jira assignments (watcher plist, 2min).
- Telegram listener with inline keyboards (telegram plist, long-running).
- Daily digest (digest plist, 16:00).
- Tempo Cloud worklog suggestions (Phase-1 event capture, 15min rounding,
  in-place Telegram cards).
- `/tempo`, `/queue`, `/status`, `/watch`, `/review`, `/help` commands.
- Shared libs: `jira.sh`, `gitlab.sh`, `telegram.sh`, `tempo.sh`,
  `timelog.sh`, `timegate.sh`, `jsonstate.py`, `active-run.sh`.
