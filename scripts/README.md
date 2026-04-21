# scripts/ — autonomous-dev-agent runtime

This directory contains every shell/python entry point the agent uses at
runtime. The layout is deliberately flat-plus-two-subfolders so a single
`ls scripts/` is enough to see what's where.

```
scripts/
├── lib/              ← sourced-only helpers (no top-level side effects)
│   ├── env.sh           bootstrap: SKILL_DIR, CACHE_DIR, LOG_DIR, PYTHONPATH, secrets
│   ├── cfg.sh           reads config.json → env vars (JIRA_ACCOUNT_ID, SSR_REPO, …)
│   ├── telegram.sh      tg_send / tg_inline / tg_force_reply / tg_answer / tg_edit
│   ├── jira.sh          jira_get / jira_post / jira_search / jira_transition_to
│   │                    jira_unassign / jira_assign — emits jira_transition events
│   ├── gitlab.sh        gl_encode / gl_api / gl_mr_get / gl_mr_approve
│   │                    gl_mr_resolve_discussion — thin wrapper over `glab api`
│   ├── tempo.sh         tempo_api / tempo_ping / tempo_list_worklogs
│   │                    tempo_post_worklog / tempo_delete_worklog — Tempo Cloud v4
│   ├── timegate.sh      in_work_hours / snoozed_now / should_notify
│   ├── timelog.sh       tl_emit / tl_run_id — appends to cache/time-log.jsonl
│   │                    (Tempo Phase 1: event capture)
│   ├── log.sh           log_info / log_warn / log_error
│   └── jsonstate.py     locked_json() / read_json() / write_json() — atomic state
│
├── handlers/         ← Telegram command handlers (sourced by telegram-handler.sh)
│   ├── common.sh        _spawn_agent, _active_runs_file
│   ├── help.sh          /help
│   ├── basic.sh         /status /logs /digest /run /stop /start,
│   │                    run PROJ-X / approve / skip / retry / review / ask
│   ├── queue.sh         /tickets /mrs
│   ├── runs.sh          /stopall, rn_log <pid>, rn_stop <pid>
│   ├── watch.sh         /watch /snooze /unsnooze /menu|hide
│   └── tempo.sh         /tempo [today|yesterday|week], tm_log / tm_edit /
│                        tm_skip / tm_undo callbacks; `tempo_suggest_now`
│                        single-ticket helper used by immediate triggers
│
├── tests/            ← bash-driven unit tests; run with ./tests/run-tests.sh
│   ├── run-tests.sh     discovers & runs every test_*.sh in isolated $TEST_TMP
│   ├── test_jsonstate.sh
│   ├── test_tsv.sh
│   ├── test_admit.sh
│   ├── test_active_run.sh
│   ├── test_timegate.sh
│   ├── test_jira_lib.sh
│   ├── test_gitlab_lib.sh
│   ├── test_telegram_lib.sh
│   ├── test_timelog.sh
│   ├── test_tempo_lib.sh       curl-on-PATH shim for every ping status code
│   ├── test_tempo_suggest.sh   formula coverage over a synthetic time-log
│   └── test_handlers_load.sh
│
├── telegram-handler.sh   long-polling Telegram daemon (case-dispatches handlers)
├── run-agent.sh          Cursor CLI launcher — the core agent workflow
├── spawn-agent.sh        admission (dedup + cap) + early Jira transition + background launch
├── active-run.sh         active-runs.json CRUD (sourced by spawn + handlers + status)
├── watcher.sh            every-2-min poller (GitLab CI + MR comments + Jira assignments)
├── tempo-suggest.py      event-log → per-day/per-ticket worklog suggestions (Phase 2)
├── daily-digest.sh       end-of-day summary to Telegram
└── notify-review-ready.sh  pings you when a review artifact lands
```

## Rules of thumb

1. **Bootstrap via `lib/env.sh`.** Every executable script starts with
   `source "$SKILL_DIR/scripts/lib/env.sh"` (after setting `SKILL_DIR` if
   needed). That gives you `CACHE_DIR`, `LOG_DIR`, `LIB_DIR`, `PYTHONPATH`,
   and sourced secrets in one line.

2. **Never hit Telegram / Jira / GitLab / Tempo APIs directly.** Use
   `tg_send` / `tg_inline` / `jira_search` / `jira_transition_to` /
   `gl_mr_approve` / `gl_mr_resolve_discussion` / `tempo_post_worklog` /
   `tempo_list_worklogs`. Handlers never embed `curl` or raw `glab api`
   calls — every wrapper encodes paths, tolerates known benign errors, and
   (where relevant) emits Tempo capture events in one place.

3. **Never write JSON state with `>`**. Use `locked_json` (Python) — it
   holds an `flock` lock, round-trips a default, and does atomic
   `tempfile + os.replace`. If you need a read-only snapshot, use
   `read_json` (best-effort, never raises).

4. **New Telegram command?** Add a function to the right `handlers/*.sh`
   (or create a new module) and add one case branch in
   `telegram-handler.sh` that just calls it. No business logic belongs in
   the dispatcher.

5. **New test?** Drop a `test_<name>.sh` into `tests/`. The harness
   auto-discovers and isolates it. Use `$TEST_TMP` for any scratch files.

## Tempo time logging

The agent auto-captures enough signal to suggest Tempo worklogs — you never
type durations, you just tap a button. The pipeline has two phases.

### Phase 1 — event capture (always on, cheap)

`lib/timelog.sh` provides `tl_emit <type> k=v …` which appends a JSON line
to `cache/time-log.jsonl`. Crash-safe (flock + O_APPEND), kill-switchable
(`TIME_LOG_ENABLED=0`), and tolerant of values with spaces.

Where it's called (the natural "something happened" moments):

| Event                   | Emitted from                     | Meaning                                  |
|-------------------------|----------------------------------|------------------------------------------|
| `agent_start` / `agent_end` | `run-agent.sh`               | wraps every agent run with a duration    |
| `review_ready`          | `notify-review-ready.sh`         | a review artifact just landed for us     |
| `mr_approved`           | `rv_approve` handler             | we just approved an MR                   |
| `review_sent_to_dev`    | `rv_sendtodev` handler           | we bounced the MR back to the author     |
| `review_skipped`        | `rv_skipmr` handler              | we skipped an MR without reviewing       |
| `jira_transition`       | `lib/jira.sh::jira_transition_to`| any ticket status change we initiated    |

`tests/test_timelog.sh` covers the append path. No other phase runs unless
`TEMPO_API_TOKEN` + `JIRA_ACCOUNT_ID` are set.

### Phase 2 — suggestions on demand (and on natural triggers)

`tempo-suggest.py` reads `time-log.jsonl` and produces per-day/per-ticket
suggestions:

```
dev_time(ticket, day) =
    sum of (agent_end - agent_start) for runs where manual=1,
    mode ∈ {implementation, ci-fix, retry, feedback}, on `day`.

review_time(ticket, day) =
    sum of (closer - review_ready) where closer ∈ {mr_approved,
    review_sent_to_dev, review_skipped}, matched by mr_iid on `day`.
    Open windows (ready without a closer) are ignored until closed.
```

Both totals round to the nearest 15 min, are capped (8h dev, 4h review), and
are then **deduped against Tempo** — existing worklogs for the same
`(issueKey, day, authorAccountId)` are subtracted so re-runs are idempotent.
If Tempo is unreachable the card is still emitted with
`tempo_dedup: false` and a "(Tempo dedup skipped)" warning.

`tests/test_tempo_suggest.sh` covers the formula (14 scenarios from
DEV_CAP hits to orphan starts). `tests/test_tempo_lib.sh` covers the
Tempo Cloud v4 wrapper (200/401/403/500/post/list) via a fake `curl` on
PATH — no live API calls in tests.

### How suggestions reach you

Three surfaces, all using the same card (`[Log Xh Ym] [Edit] [Skip]`,
with `[Undo]` after logging):

1. **Immediate, dev-done.** When `watcher.sh` sees a ticket transition
   into Code Review, it fires `tempo_suggest_now "$KEY" "Dev done on
   $KEY …"` right after the usual status-change ping.

2. **Immediate, review-done.** The `rv_approve` handler in
   `telegram-handler.sh` fires `tempo_suggest_now "$TICKET" "Review done
   …"` right after transitioning the ticket to Ready For QA.

3. **On-demand digest.** `/tempo` (yesterday, default), `/tempo today`,
   `/tempo week` — emits one card per pending `(ticket, day)` that
   passes the 15-min floor.

All three paths:

* Honour `TEMPO_AUTO_SUGGEST=0` (kill switch in `secrets.env`) for the
  immediate variants.
* Skip `(ticket, day)` pairs the user tapped **Skip** on previously —
  persisted in `cache/tempo-skipped.json` and consulted via
  `--respect-user-skips`.
* Silent no-op when the 15-min floor isn't cleared or Tempo already has
  the time logged — no empty nags.

### Files owned by the Tempo subsystem

| File                              | Purpose                                       |
|-----------------------------------|-----------------------------------------------|
| `cache/time-log.jsonl`            | append-only event log (Phase 1)               |
| `cache/tempo-skipped.json`        | `(ticket:date) → dismiss timestamp`           |
| `cache/tempo-logged.jsonl`        | posted worklogs, for Undo                     |
| `scripts/lib/tempo.sh`            | API wrapper (Bearer token → api.tempo.io)     |
| `scripts/tempo-suggest.py`        | formula → JSON or human-readable suggestions  |
| `scripts/handlers/tempo.sh`       | `/tempo`, `tm_*` callbacks, card renderer     |

## Running the tests

```sh
bash scripts/tests/run-tests.sh               # all
bash scripts/tests/run-tests.sh handlers_load # filter by substring
```

The harness exits non-zero on any failure, so it's safe to wire into CI.

## Why the split?

Before the refactor, `telegram-handler.sh` was ~2500 lines of one-off
`curl` calls, inline Jira JQL, ad-hoc JSON mutation, and copy-pasted
logic between four daemons. The common pieces — Telegram I/O, Jira
access, work-hour gating, atomic state — are now libraries with tests,
and the command handlers are small focused functions (~20–80 lines each)
instead of 200-line case bodies.

The win: any new handler is ~20 lines of shell, one test, and two diff
touches in `telegram-handler.sh`. Changing how we call Telegram, Jira, or
write state is a single-file edit.
