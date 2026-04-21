# Stability Contract (v1)

As of **v1.0.0**, the following surfaces are frozen. Anything changing in
a backward-incompatible way requires a **major** version bump (v2.0.0).

## 1. `config.json` schema

The authoritative JSON Schema is at
[`docs/schemas/config.v1.schema.json`](./schemas/config.v1.schema.json).

**Contract:**
- `schemaVersion` is an integer; the agent refuses to start on unknown
  majors.
- Fields defined in v1 will keep their name, path, and meaning forever.
- Minor releases MAY add new **optional** fields anywhere, but will never
  change the shape of an existing one.
- Removing or renaming a field is a v2 event.
- Runtime validation is handled by `scripts/lib/_cfg_lint.py` (invoked by
  `bin/doctor.sh`) — it loads `config.v1.schema.json` when present, else
  falls back to its built-in structural checks for offline use.

## 2. Driver interface

The `tracker_*`, `host_*`, and `chat_*` functions defined in:

- `scripts/drivers/tracker/_interface.md`
- `scripts/drivers/host/_interface.md`
- `scripts/drivers/chat/_interface.md`

…are the public contract. Third-party drivers relying on these names and
signatures will keep working across all v1.x releases.

**Contract:**
- Required function names will not be removed or renamed.
- Argument order and return-value shape (stdout JSON) are frozen.
- New optional functions MAY be added; callers must feature-detect with
  `type -t <fn>` before use, and drivers may choose not to implement them.
- Env-var names used for configuration (`TRACKER_KIND`, `HOST_KIND`,
  `CHAT_KIND`, `TRACKER_PROJECT`, `HOST_GROUP`, `CHAT_CHANNEL`) are frozen.
- `test_driver_contract.sh` must pass for every driver in-tree.

## 3. Telegram command vocabulary

Commands listed in [`scripts/handlers/help.sh`](../scripts/handlers/help.sh)
are frozen. **Contract:**
- Each command name and top-level argument shape in the help output will
  keep working for the life of v1.x.
- New commands MAY be added.
- Renames or removals are v2 events; existing users scripting their own
  callbacks/keyboards against these names will not break mid-major.

Frozen commands (top-level):

- `/status`, `/status all`
- `/tickets`, `/queue [<n>]`
- `/reviews`, `/mrs`
- `/run`, `/digest`, `/logs`
- `/stop`, `/start`
- `/watch`, `/snooze <duration>`, `/unsnooze`
- `/stopall`
- `/project {list|use|info|add|remove}`
- `/workflow [<id>]`, `/workflow refresh [<id>]`
- `/rebase <mr-iid> [<alias>]`, `/rebase check <mr-iid>`
- `/help`

Callback-data prefixes (frozen):
`run:`, `approve:`, `skip:`, `review:`, `rel_*`, `rv_*`, `ci_*`, `fb_*`,
`tk_*`, `rn_*`, `tm_*`, `snooze:`.

## 4. Cache layout

`cache/` directory layout is frozen at v1 so upgrades don't orphan state:

```
cache/
  global/                           — cross-project state
    queue-snapshot.json             — watcher queue snapshot (v0.5.0+)
    telegram-offset-<bot-hash>.txt  — per-bot Telegram long-poll offset
    watcher-crash-<pid>.ts          — rate-limited crash report timestamps
  projects/<pid>/                   — per-project state (pid = projects[].id)
    watcher-state.json              — per-project watcher state
    active-runs.json                — per-project in-flight agent runs
    workflow.json                   — discovered tracker workflow
    estimates.json                  — per-ticket size estimates
    lessons.md                      — newline-separated post-mortem bullets
  voice/                            — transient voice-note downloads
  photos/                           — transient photo attachments for OCR
```

## Migration policy

- **v1.x → v1.y**: zero-touch upgrade. `bin/install.sh` (re-run after `git
  pull`) is sufficient.
- **v1.x → v2.0**: a migration guide at `docs/MIGRATION.md` is mandatory
  and ships in the same release. `bin/init.sh` will detect v1 state and
  walk through the upgrade interactively.
