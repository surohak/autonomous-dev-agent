# Tracker driver contract

A tracker driver speaks to the issue tracker (Jira, GitHub Issues, Linear,
…). Every driver file is a plain bash file sourced by the dispatcher. The
dispatcher resolves which file to source per project from
`projects[].tracker.kind`.

## File layout

```
scripts/drivers/tracker/
├── _interface.md       ← this file
├── _dispatch.sh        ← routes calls to the right driver (internal)
├── jira-cloud.sh       ← reference driver (replaces scripts/lib/jira.sh)
├── github-issues.sh
└── linear.sh
```

## Required public functions

Every driver MUST export the following bash functions. Signatures use
`(result via stdout)` for any function that needs to return structured data
— emit a single line of JSON so callers can pipe through `jq`/`python3`.

### `tracker_probe`

```
tracker_probe
→ exit 0 if credentials + siteUrl resolve and an auth probe succeeds
→ exit 1 otherwise
```

Used by `bin/doctor` to turn the `[tracker]` section green/red.

### `tracker_search <jql-or-filter> [<max>] [<fields>]`

```
tracker_search "project=AL AND status='To Do'" 10 "summary,status,assignee"
→ stdout: one-line JSON list of issue dicts: [{"key":..., "summary":..., ...}, …]
→ exit 0 on success, non-zero on network/auth error
```

Driver translates the filter into its native query language. For GitHub
Issues this means mapping labels; for Linear, GraphQL. The shape of each
result dict is fixed:

```
{
  "key":       "AL-123",
  "url":       "https://…",
  "summary":   "…",
  "status":    "in_progress",    # lowercased semantic name, not raw string
  "assignee":  "suren.toorosian", # handle or email; may be ""
  "updated":   "2026-04-16T10:00:00Z"
}
```

### `tracker_get <key>`

```
tracker_get AL-123
→ stdout: full issue JSON, including description body (markdown preferred)
```

### `tracker_transition <key> <intent>`

```
tracker_transition AL-123 push_review
→ exit 0 on success
```

`intent` is one of: `start`, `push_review`, `after_approve`, `done`,
`block`, `unblock`. Drivers call their own lookup (Jira → `workflow.sh`;
GitHub Issues → label swap; Linear → state UUID).

### `tracker_comment <key> <body>`

```
tracker_comment AL-123 "First draft MR up"
→ exit 0 on success
```

### `tracker_assign <key> <user>`

```
tracker_assign AL-123 unset     # clear assignee
tracker_assign AL-123 <user>
→ exit 0 on success
```

User identifier format is driver-specific but must accept `unset` /
`unassigned` as the "no assignee" sentinel.

## Optional functions

A driver MAY export the following if the backend supports them. Callers
must check with `type` before using.

- `tracker_add_label <key> <label>`
- `tracker_remove_label <key> <label>`
- `tracker_set_priority <key> <p0..p3>`

## Environment contract

Drivers rely on these env vars (set by `cfg_project_activate`):

| var                  | meaning                                  |
|----------------------|------------------------------------------|
| `TRACKER_KIND`       | `jira-cloud` / `github-issues` / …       |
| `TRACKER_SITE`       | base URL (e.g. `https://x.atlassian.net`)|
| `TRACKER_PROJECT`    | project key / slug                       |
| `TRACKER_API_TOKEN`  | token (from `secrets.env`)               |
| `TRACKER_EMAIL`      | email if the auth scheme needs it        |

Legacy vars (`JIRA_SITE`, `ATLASSIAN_API_TOKEN`, …) are kept as aliases in
`cfg.sh` through at least v0.4.x — driver authors must NOT read those
directly.

## Error handling

- Any HTTP ≥ 500 → exit 1, `echo` nothing on stdout. Caller retries.
- HTTP 404 on `tracker_get` → exit 2, caller treats as "not found".
- Auth errors (401/403) → exit 3, caller gives up with a clear message.

## Testing contract

Every driver must ship:

- `scripts/tests/drivers/tracker/<name>/fixtures/*.json` — canned API
  responses (redacted).
- `scripts/tests/drivers/tracker/<name>.sh` — replays fixtures and asserts
  the driver outputs the canonical result shape.

The shared `test_driver_contract.sh` walks every installed driver and
verifies the required functions exist with the right signatures.
