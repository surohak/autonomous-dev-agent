# Contributing

Thanks for considering a contribution! A few guardrails so PRs land smoothly.

## Ground rules

- **Bash + Python stdlib only.** No node/rust/go/pipenv. Every new dep is a
  point of install friction for someone.
- **Tests required for libs.** Anything under `scripts/lib/` needs a
  `scripts/tests/test_<name>.sh` that the test runner picks up.
- **No hardcoded identifiers.** If you grep for a company name, a
  hardcoded Jira URL, or a specific ticket prefix, it should not match
  anything in a PR diff. All identity strings must come from `config.json`.
- **Idempotent scripts.** `install.sh`, `doctor.sh`, `uninstall.sh`,
  migration scripts — re-running must converge, not multiply.

## Dev workflow

```bash
git clone https://github.com/<you>/autonomous-dev-agent.git
cd autonomous-dev-agent
bash bin/install.sh --dev           # symlink instead of copy
bash scripts/tests/run-tests.sh     # should show Passed: 13 Failed: 0
```

`--dev` means edits in the checkout affect the running skill immediately —
no copy step between iterations.

When you change a `lib/` module:

```bash
bash scripts/tests/test_<name>.sh   # run just that test
bash scripts/tests/run-tests.sh     # run all (<10s total)
```

## Commit style

Conventional commits, short subject, imperative mood:

```
feat(tempo): round to 15min and dedupe against existing worklogs
fix(jira): match transitions by destination status name
chore(docs): add TROUBLESHOOTING entry for Tempo cap
test(prompt): guard against token substitution regressions
```

## Adding a driver (Phase-3 work)

The roadmap splits a `driver/` layer out from hardcoded Jira/GitLab/Telegram
calls. The interface in each adapter is small:

| Adapter | Methods (minimum) |
|---|---|
| `tracker`  | `list_tickets`, `get_ticket`, `transition`, `assign`, `comment` |
| `host`     | `list_mrs`, `get_mr`, `approve`, `merge`, `commit_messages` |
| `chat`     | `send_message`, `edit_message`, `listen_updates` |
| `worklogs` | `create`, `list`, `delete` (can be no-op) |

New adapters live under `scripts/drivers/<name>.sh` and register themselves
via `scripts/lib/drivers.sh`. See
`scripts/lib/jira.sh` and `scripts/lib/gitlab.sh` as templates — they'll
become the Jira/GitLab drivers once the abstraction lands.

Open an issue with the driver name you'd like to add so we can coordinate
the interface before you write a lot of code.

## Code review

Turnaround is best-effort — this is a weekends-and-evenings project. To help
us (and each other):

- Keep PRs small (one lib change + tests, one installer tweak, etc.).
- Paste `bash bin/doctor.sh` output if the PR touches auth or connectivity.
- Note the macOS + shell version you tested on.

## What not to contribute

- **Anything that adds a SaaS control plane.** The agent is local-first on
  principle.
- **Telemetry or analytics.** If the agent should phone home, the user should
  ask it to.
- **Dependencies on a specific company's tooling.** If you need an internal
  lib, it belongs in a private fork.

## License

By contributing you agree your changes are MIT-licensed, like the rest of the
project.
