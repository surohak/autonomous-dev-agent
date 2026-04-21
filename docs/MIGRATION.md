# Migration Guide

How to move between versions of `autonomous-dev-agent`. Keep this
document **short**: if something requires a page of instructions, we
add a codemod to `bin/install.sh` instead.

## Upgrade in one line

```bash
cd ~/.cursor/skills/autonomous-dev-agent && git pull && bin/install.sh
```

`install.sh` is idempotent: re-running it reloads launchd agents,
refreshes symlinks, and re-validates `config.json`.

---

## Unreleased → v1.0.0

### 1. Add `schemaVersion` to `config.json`

```json
{
  "schemaVersion": 1,
  "owner": { ... },
  "projects": [ ... ]
}
```

Starting in v1, `bin/doctor.sh` warns when `schemaVersion` is missing
and errors when it's newer than the installed agent understands. If you
omit it, the agent treats your config as legacy and keeps working —
but new fields defined in v1+ may not be available.

### 2. Freeze your driver kinds

v1 locks the vocabulary:

| Layer   | Valid values                                  |
|---------|-----------------------------------------------|
| tracker | `jira-cloud`, `github-issues`, `linear`       |
| host    | `gitlab`, `github`                            |
| chat    | `telegram`, `slack`                           |

If you wrote a third-party driver, it keeps working — the allow-list
is advisory. Doctor warns about unknown kinds rather than erroring.

### 3. Callback-data prefixes

See [`docs/STABILITY.md`](./STABILITY.md) §3. Telegram callback prefixes
(`run:`, `approve:`, `tm_*`, …) are frozen. Custom callbacks should use
a **distinct** prefix (e.g. `my_foo:`) to avoid future collisions.

### 4. Nothing else breaks

- Directory layout under `cache/` is frozen at v1 (see STABILITY.md §4).
- Existing `scripts/lib/*.sh` functions remain for backward compat;
  new code should call the driver layer (`scripts/drivers/*`) instead.

---

## v0.2 → v0.3 (historical)

You likely already ran this migration. The shape of your config
changed from a single top-level `atlassian`/`gitlab`/`telegram` block
to a `projects[]` array. `scripts/lib/cfg.sh` auto-normalises v0.2
shapes at load time — so v0.2 configs still work in v0.3/v1 without
edits, but you miss out on multi-project, per-project bot, and
per-project model config.

To convert:

```jsonc
{
  "schemaVersion": 1,
  "owner":   { "name": "Jane", "email": "jane@co" },
  "company": "JobLeads",
  "projects": [{
    "id":      "ssr",
    "name":    "Portal SSR",
    "tracker": { "kind": "jira-cloud",  "site": "https://co.atlassian.net", "projectKey": "UA" },
    "host":    { "kind": "gitlab",      "site": "https://gitlab.com",       "group": "jobleads" },
    "chat":    { "kind": "telegram",    "tokenEnv": "TELEGRAM_BOT_TOKEN" }
  }],
  "defaultProject": "ssr"
}
```

Run `bin/doctor.sh --fix` after editing to auto-fix permissions and
caches.

---

## Troubleshooting an upgrade

1. `bin/doctor.sh --fix --json | jq` — applies safe auto-fixes and
   prints a machine-readable summary.
2. Still broken? `bin/doctor.sh --smoke` runs an end-to-end integration
   ping (tracker → host → chat) so you see exactly which leg fails.
3. File a bug with the `driver-request.yml` or `bug.yml` GitHub issue
   template; include the smoke output verbatim.
