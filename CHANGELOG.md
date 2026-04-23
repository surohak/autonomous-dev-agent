# Changelog

All notable changes to this project are tracked here. Versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.31] - 2026-04-23

### Fixed

- **`/status` shows "Running"** when there are active agent runs instead
  of always showing "Stopped" (launchd entry disappears between scheduled
  triggers but spawned processes persist).
- **`/status` result line** now shows clean "Success (exit 0)" or
  "Failed (exit N)" instead of dumping the raw log tail.
- **Watcher stop no longer reports a crash**: SIGTERM (exit 143) and
  SIGINT (exit 130) are recognized as normal shutdown signals — no more
  spurious "Watcher crashed" Telegram warnings when stopping the watcher.
- **Review nudge `AGE_HOURS` guard**: added numeric validation before
  `printf '%.0f'` to prevent stderr spam when tab-split produces a
  non-numeric value.
- **Test fixes**: `test_admit.sh` and `test_tempo_suggest.sh` used `ua-`
  prefix in assertions but `PROJ-` in fixture data — corrected to match.
  Full suite now passes 24/24.

## [1.0.30] - 2026-04-23

### Added

- **Slack hotfix automation**: end-to-end flow that monitors Slack
  channels/DMs for bug reports, surfaces them as Telegram cards with
  `[Fix this]` / `[Ask Reporter]` / `[Reply only]` / `[Ignore]` buttons,
  spawns an agent to fix the bug and open an MR to stage, and
  automatically replies in the Slack thread with the MR link.
- **`scripts/read-slack.py`**: new script for reading Slack messages
  (conversations.history + conversations.replies) and downloading
  file attachments (screenshots). Uses the same Cursor OAuth token
  decryption as send-slack-dm.py.
- **`prompts/phase-slack-hotfix.md`**: agent prompt for Slack hotfix
  mode with prompt injection protection, repo auto-detection, and
  ticket key handling.
- **`slack.monitor` config section**: channels, keywords, and
  ignoreUsers configuration in config.json for Slack monitoring.
- **`FORCE_MODE=slack-hotfix` in run-agent.sh**: new agent mode that
  passes Slack thread context and downloaded images to the agent.
- **Post-agent Slack notification**: on successful slack-hotfix run,
  the exit handler parses the log for the MR URL and replies in the
  original Slack thread automatically.
- **Watcher Slack monitoring section**: polls configured channels
  every cycle, filters by keywords, deduplicates with state tracking
  in watcher-state-slack.json, and sends Telegram notification cards.
  Includes first-run guard (no backfill), token unavailability handling,
  and 7-day auto-pruning of seen messages.

### Changed

- **`send-slack-dm.py`**: extended with `--thread_ts` parameter for
  replying in Slack threads (used by Ask Reporter and MR notification
  flows).
- **`telegram-handler.sh`**: added `sl_fix`, `sl_ask`, `sl_ign`,
  `sl_reply`, `sl_notify`, `sl_askapply`, and `sl_replyapply` callback
  handlers for the Slack hotfix Telegram card buttons and force-reply
  interactions.

## [1.0.29] - 2026-04-23

### Added

- **`/standup` command**: auto-generates a daily standup summary from
  yesterday's Tempo worklogs, current in-progress/code-review tickets,
  blocked tickets, and open MRs. One tap to get a copy-ready standup.
- **`/describe UA-XXX` command**: analyzes the git diff of the open MR
  for a ticket and generates a concise MR description with file change
  categories and commit summaries.
- **Reviewer response time tracking**: the watcher now detects MRs that
  have been in Code Review for more than 24 hours and sends a daily
  nudge notification with a `[Follow-up in DM]` button that sends a
  friendly Slack DM to the reviewer.

## [1.0.28] - 2026-04-23

### Changed

- **`/cherries` consolidated into single message**: instead of one
  Telegram message per ticket + a separate combined card, the command
  now sends a single message listing all eligible tickets with a
  `[Combine all into one MR]` button at the top and per-ticket
  `[Cherry-pick KEY]` / `[Jira]` buttons below.

### Added

- **`/merge UA-XXX` command**: merges an approved open MR to stage in
  one tap. Also available as an inline `[Merge to stage]` button.
- **Watcher detects merge-ready MRs**: when a ticket is in Ready For
  QA or Ready For RC with an approved but unmerged MR, the watcher
  sends a notification with `[Merge to stage]` / `[Open MR]` /
  `[Open in Jira]` / `[Later]` buttons.

## [1.0.27] - 2026-04-23

### Fixed

- **Strengthened MR URL safety**: agent prompts now explicitly warn
  against hand-typed GitLab URLs (citing past `jobleadsapp` /
  `mergerequests` errors) and provide a concrete `grep` command to
  parse the URL from `glab mr create` output.

### Added

- **Log time buttons on MR-opened card**: the Telegram notification
  sent when the agent opens an MR now includes `[Log 30m]` `[Log 1h]`
  `[Log 2h]` `[Log 4h]` buttons that post a Tempo worklog in one tap,
  reusing the existing `tm_log` callback flow.
- **Auto-transition approved MRs to Ready For QA** (watcher 1c): every
  2-minute tick checks author's open MRs for approvals; if a ticket is
  still in Code Review despite the MR being approved, the watcher
  transitions it to Ready For QA, reassigns to owner, and notifies via
  Telegram. Deduped via `watcher-state.json`.
- **Buttonless WIP status notifications**: when the agent moves a
  ticket to Work In Progress, the watcher now sends a plain text
  notification instead of showing Proceed/Open buttons.

## [1.0.26] - 2026-04-23

### Fixed

- **Cursor IDE detection on macOS**: `pgrep -x "Cursor"` always failed
  because macOS `pgrep` matches the full executable path, not the short
  name. Changed to `pgrep -f "Cursor.app/Contents/MacOS/Cursor"` so the
  agent correctly detects a running Cursor IDE and no longer skips runs.

### Added

- **Slack thread enrichment in Phase 2**: when the agent reads a Jira
  ticket, it now scans the description and comments for Slack message
  links and reads the full thread via `slack_read_thread` MCP. Thread
  content is treated as first-class context for analysis and
  implementation.

## [1.0.25] - 2026-04-22

### Added

- **`/tempo summary` Telegram command**: read-only view of already-logged
  Tempo worklogs. Pulls entries from the Tempo REST API, enriches each
  with Jira issue key/summary/status, and sends a formatted summary to
  Telegram with per-entry durations and a total.
  - `/tempo summary` — yesterday (default)
  - `/tempo summary today` — today's worklogs so far
  - `/tempo summary week` — last 7 days with per-date breakdown
- Updated `/help` text to document the new summary sub-commands.
- **Expanded Telegram bot command menu**: all subcommands registered as
  separate entries for one-tap access (tempo_summary, tempo_today,
  tempo_week, status_all, workflow, workflow_refresh, project, queue,
  rebase). Handler normalizes underscore variants to space-delimited.
- **Agent launchd watchdog in watcher**: detects when the scheduled
  agent job is stuck (`last exit code = (never exited)`) or has been
  running for >45 minutes, bounces the launchd job, kickstarts a new
  run, and notifies via Telegram. Runs every watcher tick (~2 min)
  during work hours.

## [1.0.24] - 2026-04-22

Comprehensive reliability pass across cherry-pick, Telegram handler,
watcher, and Telegram API library. Eliminates edge-case failures that
caused the combined cherry-pick to fail on repos with pre-commit hooks,
and hardens state persistence against corruption.

### Fixed

- **Pre-commit hook breaks stage-HEAD amend during cherry-pick**: when
  the `-X theirs` conflict resolution detects stale files and replaces
  them with `origin/<stage>` HEAD, the subsequent
  `git commit --amend --no-edit` was triggering the target repo's
  pre-commit hook (husky). In environments without AWS credentials or
  Docker (the automation runner), this caused `make npm` / husky to
  fail with exit code 2, aborting the entire cherry-pick. Fixed by
  adding `--no-verify` to the amend in both `cherry-pick.py` and
  `cherry-pick-combined.py`. The code has already been validated on
  the staging branch, so skipping the hook on amend is safe.

- **`applied_shas` membership bug in combined cherry-pick**: the
  `picked` list contains suffixed entries like `sha(theirs)` and
  `sha(stage)`, but the FALLBACK_KEYS logic compared bare 8-char
  prefixes against this set — membership always failed, causing
  `remaining_by_ticket` to over-include tickets and emit wrong
  "still pending" counts. Fixed by stripping suffixes when building
  `applied_shas`.

- **Manual-finish block contained invalid git commands**: the
  copy-paste `git cherry-pick -x ...` command joined `picked` entries
  including `(theirs)`/`(stage)` suffixes, producing commands git
  cannot parse. Fixed by stripping suffixes in the manual block.

- **Uncaught `TimeoutExpired` in both cherry-pick scripts**: any
  `subprocess.run(..., timeout=...)` that exceeded its timeout raised
  an unhandled exception, crashing the script with a traceback and
  leaving the repo in an ambiguous state. Now caught and returned as
  `(124, "", "command timed out...")`.

- **`cherry-pick --abort` return code ignored before `-X theirs`
  retry**: if abort failed, the retry ran in a corrupted cherry-pick
  state. Now falls back to `git reset --hard HEAD` if abort fails.

- **Per-file `git checkout origin/<stage>` return code ignored in
  stale fixup**: if a file was renamed/deleted on stage, the checkout
  would fail silently and the amend would run with wrong index state.
  Now checks each checkout and aborts cleanly on failure.

- **`PROMOTED_FILE` ignored on `cherry-pick.py` success path**:
  the success-path write hardcoded `cache/promoted.json` relative to
  `__file__` instead of honoring the `PROMOTED_FILE` env var. This
  caused the Telegram handler's DM/approver follow-up to read from a
  different file than what was written. Fixed to use `PROMOTED_FILE`
  with the same fallback as the existing-MR detection path.

- **Duplicate MR detection used substring match**: `TK_KEY in title`
  caused false positives (e.g. `PROJ-1` matching `PROJ-10`). Changed
  to word-boundary regex in both `cherry-pick.py` and
  `cherry-pick-combined.py`.

- **Non-atomic `promoted.json` writes**: a kill/crash during
  `json.dump(open(..., "w"))` left a truncated file that subsequent
  reads parsed as `{}`. All writes now use `tempfile.mkstemp` +
  `os.replace` for atomic replacement.

- **`rel_dm` handler used wrong config key (`repos` instead of
  `repositories`)**: the MR-freshness verification in the Slack DM
  flow could never resolve the local repo path, so `glab mr view`
  was always skipped — stale/merged MR URLs could reach the approver.
  Fixed to use the same `repositories` / `projects[0].repositories`
  lookup as the cherry-pick scripts.

- **Callback data could exceed Telegram's 64-byte limit**: the
  `tk_cherryall` button builder trimmed at `> 60` using `len(str)`
  (character count) instead of `len(str.encode())` (byte count).
  Fixed to check encoded byte length against the hard 64-byte limit.

- **Approver name with `:` broke `cut -d:` parsing in `rel_dm`**:
  the Python→shell handoff used `:` as the delimiter for a field
  that can contain colons (e.g. name with suffix). Changed to `|`
  delimiter.

- **Watcher state writes were non-atomic**: all four inline-Python
  `json.dump(open(..., 'w'))` calls for pipeline state, MR notes,
  Jira tickets, and queue snapshot could corrupt on kill. Replaced
  with `tempfile.mkstemp` + `os.replace`.

- **Watcher Jira response not validated**: if the Jira API returned
  non-JSON (HTML error page, empty body, network error), the diff
  block would crash. Now skips the Jira section with a log entry
  when the response fails to parse.

- **Watcher state file read crash on corruption**: `json.load(open(STATE))`
  with no try/except would crash the Jira diff block if the state
  file was truncated. Added fallback to empty dict.

- **Telegram API errors completely invisible**: `_tg_call` discarded
  all curl output (`>/dev/null 2>&1`), making HTTP 400/403/429 errors
  undetectable. Now captures response, logs HTTP status and body to
  stderr on 4xx/5xx, and returns non-zero exit code.

## [1.0.23] - 2026-04-21

Cumulative patch series (1.0.1 – 1.0.23) covering the cherry-pick
promote-to-main workflow for multi-ticket stage→main promotions.

### Added (highlights across 1.0.1 – 1.0.23)

- **Combined cherry-pick** (`cherry-pick-combined.py`): promote
  multiple tickets from a staging branch to `main` in a single MR.
  De-duplicates commits, sorts chronologically, creates one branch
  and one MR.
- **`/cherries` Telegram command**: lists tickets eligible for
  cherry-pick, shows "Cherry-pick ALL N to main" when multiple
  tickets share a repo, and per-ticket cherry-pick buttons.
- **Auto-conflict resolution** via `-X theirs` with a post-merge
  safety check: if the resolved file diverges from the staging
  branch HEAD (because later commits under other tickets reshaped
  it), the script replaces the stale file with the staging HEAD
  version and amends the commit. Only falls back to manual mode
  when the amend itself fails.
- **DM approver flow**: after a successful promote, a follow-up
  Telegram card offers a "DM <approver>" button that sends a Slack
  DM with the MR URL and Jira links. Verifies the MR is still open
  before sending to prevent stale-URL DMs.
- **Per-ticket fallback buttons** when a combined cherry-pick fails:
  individual "Cherry-pick <KEY> alone" buttons for each ticket.
- **Manual-finish copy/paste block** with exact `git cherry-pick`
  commands when auto-resolution is not possible.
- **Conflict diagnostics**: conflicting files and staged paths are
  captured before `git cherry-pick --abort` (not after, which would
  always return empty) and surfaced in the Telegram message.

### Fixed (highlights across 1.0.1 – 1.0.23)

- Redundant/empty cherry-picks (commits already on main under a
  different SHA) detected post-hoc without relying on modern git
  flags (`--empty=drop`, `--skip`) that break on older git versions.
- `glab mr list` calls now default to `state=opened` (removed
  `--all` flag) so closed MRs don't false-positive as duplicates.
- OK/INFO/ERR dispatch in the Telegram handler uses line-oriented
  `grep` instead of a whole-string glob, so stderr diagnostic
  breadcrumbs from the Python scripts don't prevent the success
  path from matching.
- `promoted.json` entries for closed MRs are detected and handled
  gracefully by the DM flow.

## [1.0.0] - 2026-04-21

_General availability. Completes the post-v0.3 roadmap (milestones M1–M5)
in a single release, because nothing between v0.3.0 and v1.0.0 was ever
shipped to an external user. The sections below are preserved from the
internal roadmap so readers can see the shape of what landed._

### M1 — Polish

- **watcher.sh** wraps each project's tick in a subshell, so one
  project's Jira 5xx no longer kills the watcher for all others.
  Rate-limited crash reports to Telegram.
- **`/workflow`**, **`/workflow refresh`**, and **`/workflow <project>`**
  Telegram commands to inspect and re-discover tracker status mappings
  without editing `config.json`.
- **`bin/doctor --fix`** auto-remediates common issues (mode 600 on
  `secrets.env`, missing `cache/` / `logs/archive/`, stale
  `workflow.json`, broken SwiftBar symlink).
- **`bin/doctor` schema lint** via `scripts/lib/_cfg_lint.py` — catches
  typos, unknown driver kinds, duplicate project ids, orphan
  `defaultProject`, and `chat.tokenEnv` not present in `secrets.env`.
- **Log rotation** (`scripts/lib/log-rotate.sh`): files > 50 MB move to
  `logs/archive/`, gzipped in the background, pruned to 14 archives per
  base name.

### M2 — Adoption readiness

- **GitHub Actions CI** (`.github/workflows/test.yml`) runs the offline
  test suite across macOS-13/14/15 + Ubuntu, plus shell syntax and
  `docs/CONFIG_SCHEMA.json` validation on every push/PR.
- **Issue templates** for `bug`, `feature`, `driver-request` and a PR
  template checklist matching `docs/CONTRIBUTING.md`.
- **Dependabot** configured for GitHub Actions only (runtime has no
  package manifest by design).
- **`bin/release.sh`** semantic-version bumper: preflight checks (clean
  tree, default branch, tests green), CHANGELOG promotion, annotated
  tag, push, draft GitHub Release via `gh`.
- **`docs/ADOPTION.md`** playbook for onboarding the first external
  user (candidate selection, session script, friction-point → docs-PR
  loop).

### M3 — Driver layer (the v0.4 pivot)

- **Driver interfaces** under `scripts/drivers/{tracker,host,chat}/` with
  `_interface.md` contracts and `_dispatch.sh` loaders keyed off
  `projects[].<layer>.kind`.
- **Reference drivers extracted** from existing libs with zero
  user-visible change: `jira-cloud` (tracker), `gitlab` (host),
  `telegram` (chat).
- **New reference drivers**: `github-issues` (tracker), `github` (host),
  `slack` (chat with Block Kit buttons).
- **`test_driver_contract.sh`** table-driven suite asserting every
  driver exports its required functions; Bash 3.2 compatible for stock
  macOS.
- **`docs/DRIVERS.md`** + per-driver pages; README rewritten with
  conditional-requirements table so users install only what their
  configured drivers need.

### M4 — Personal features

- **Voice notes**: Telegram voice → `scripts/lib/transcribe.sh` (OpenAI
  Whisper API with local `whisper.cpp` fallback) → re-dispatched as a
  text command.
- **Screenshot OCR**: photo attachments → `scripts/lib/ocr.sh` (OpenAI
  Vision with macOS Vision framework fallback) → injected into command
  text, reply-context aware for review flows.
- **Priority queue** with per-project fair-share scoring
  (`scripts/lib/queue.sh`): score = priority × project weight × age
  factor. SwiftBar plugin reads `cache/global/queue-snapshot.json` for
  a zero-network live view; `/queue [<n>]` Telegram command.
- **Auto-rebase with safe auto-resolve** (`scripts/lib/rebase.sh`):
  `git merge-tree` conflict probe, whitelisted auto-resolve patterns
  (lock files, translations, generated docs), `push --force-with-lease`
  for safety. `/rebase [check] <iid> [<alias>]` Telegram commands.
- **Lessons loop**: `{{RECENT_LESSONS}}` token in
  `prompts/phase2-executor.md`, populated from
  `cache/projects/<id>/lessons.md` so past post-mortems surface into
  the next run's context.
- **Daily Tempo delta**: `daily-digest.sh` compares logged vs target
  hours (`owner.dailyWorkSeconds`, default 8h), appends a one-line
  summary, and sends a follow-up inline card with a one-tap backfill
  button when under target.

### M5 — GA

- **v1 stability contract** (`docs/STABILITY.md`): freezes `config.json`
  shape, driver function signatures, Telegram command vocabulary,
  callback-data prefixes, and `cache/` layout until v2.0.0.
- **JSON Schema** at `docs/schemas/config.v1.schema.json` with
  `schemaVersion` enforcement in `_cfg_lint.py` — unknown majors error,
  missing version emits a migration hint.
- **`docs/ARCHITECTURE.md`** one-page map (directory layout, request
  flows, concurrency + security model, extension points).
- **`docs/MIGRATION.md`** "upgrade in one line" playbook covering
  v0.2→v1.0.0 and v0.x→v1.x.
- **`docs/DEMO_SCRIPT.md`** shot list + captions for the 90-second demo
  video (video itself ships as a v1.0.0 GitHub Release asset).
- **`bin/doctor --smoke`** end-to-end integration ping: per-project
  `tracker_probe` + `tracker_search` + `host_probe` +
  `host_current_user` + `chat_probe`. Read-only by default;
  `--smoke --chat` optionally sends a visible heartbeat.

### Breaking changes

None. v0.3.0 configs continue to load unchanged. Adding
`"schemaVersion": 1` silences the new doctor warning but is not
required.

### Migration

See [`docs/MIGRATION.md`](./docs/MIGRATION.md). Upgrade path:

```bash
cd ~/.cursor/skills/autonomous-dev-agent && git pull && bin/install.sh
```

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
- `docs/SETUP.md`, `docs/TROUBLESHOOTING.md`, `docs/CONTRIBUTING.md`.
- `LICENSE` (MIT).

### Changed
- All hardcoded Jira site URLs, ticket-key prefixes, owner usernames,
  launchd label prefixes, and absolute repo paths replaced with
  config-driven values.
- `scripts/lib/cfg.sh` exports the full identity set: `OWNER_NAME`,
  `OWNER_FIRST_NAME`, `OWNER_EMAIL`, `COMPANY`, `JIRA_SITE`, `JIRA_PROJECT`,
  `JIRA_ACCOUNT_ID`, `GITLAB_USER`, `BRANCH_USER`, `TICKET_KEY_PATTERN`,
  `LAUNCHD_LABEL_PREFIX`, and the per-repo `*_REPO`/`*_BRANCH`/`*_PROJECT`
  triples.
- `run-agent.sh` now reads prompts through `prompt_render` so the committed
  templates never leak personal identifiers.

## [0.1.0] - 2025-12 (pre-public)

Original single-team build used internally. Not released publicly.

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
