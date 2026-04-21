# Host driver contract

A host driver speaks to the code-hosting platform (GitLab, GitHub,
Bitbucket). Like tracker drivers, each host driver is a sourced bash file.

## File layout

```
scripts/drivers/host/
├── _interface.md
├── _dispatch.sh
├── gitlab.sh       ← reference driver (replaces scripts/lib/gitlab.sh)
├── github.sh
└── bitbucket.sh
```

## Required public functions

### `host_probe`

```
host_probe
→ exit 0 if auth token works; non-zero otherwise
```

### `host_current_user`

```
host_current_user
→ stdout: the authenticated username (one word, no newline)
→ exit 0
```

Cached by callers; cheap auth check substitute.

### `host_mr_list <scope>`

```
host_mr_list self        # MRs the current user opened
host_mr_list reviewer    # MRs assigned to the current user for review
→ stdout: JSON list [{"iid":..., "url":..., "title":..., "project_id":...}, …]
```

"MR" is the canonical vocabulary regardless of platform (PR on GitHub,
change-request on Bitbucket). Callers never need platform-specific terms.

### `host_mr_get <project_id> <iid>`

```
host_mr_get 123 42
→ stdout: JSON with {"iid","title","state","draft","approvals":[…],"pipeline_status","url",…}
```

### `host_mr_create <project_id> <source_branch> <target_branch> <title> <body>`

```
host_mr_create 123 feat/X main "feat: X" "Closes TICK-1"
→ stdout: {"iid":..., "url":...}
→ exit 0
```

### `host_mr_update <project_id> <iid> <field> <value>`

```
host_mr_update 123 42 ready true         # mark ready
host_mr_update 123 42 assignees "alice,bob"
host_mr_update 123 42 reviewers "charlie"
→ exit 0
```

Drivers translate `field=ready` to their native API (GitLab
`mark_ready_for_review`, GitHub `pull/{n}/ready-for-review`).

### `host_mr_merge <project_id> <iid> [<strategy>]`

```
host_mr_merge 123 42 squash
→ exit 0 on merge or already-merged
```

### `host_ci_status <project_id> <iid>`

```
host_ci_status 123 42
→ stdout: one of: pending | running | success | failed | canceled | skipped
```

### `host_notes <project_id> <iid> [<since_epoch>]`

```
host_notes 123 42 1713000000
→ stdout: JSON list [{"id":..., "author":..., "body":..., "created":...}, …]
```

### `host_branch_exists <project_id> <branch>`

### `host_repo_slug_for_alias <alias>`

```
host_repo_slug_for_alias ssr
→ stdout: "mygroup/services/ssr"
```

Drivers read `projects[].host.repositories` (or similar) to resolve
the alias. Keeps watcher code platform-agnostic.

## Environment contract

| var              | meaning                                  |
|------------------|------------------------------------------|
| `HOST_KIND`      | `gitlab` / `github` / `bitbucket`        |
| `HOST_BASE_URL`  | e.g. `https://gitlab.com/api/v4`         |
| `HOST_TOKEN`     | PAT or app-token                         |
| `HOST_GROUP`     | group / org slug                         |

## Error taxonomy

Same as tracker: ≥500 → exit 1; 404 → exit 2; 401/403 → exit 3.

## Testing contract

- `scripts/tests/drivers/host/<name>/fixtures/*.json`
- `scripts/tests/drivers/host/<name>.sh`

Fixtures must cover: list, get, create, update-ready, merge, ci-status,
notes.
