# Phase 8: Code Review Mode

## Activation

You are in **Code Review Mode** (not implementation mode) when a Jira ticket matches ALL of:

1. `assignee = <me>` (from `config.json` → `owner.jiraAccountId`)
2. `status = "Code Review"`
3. The associated MR has `author.username != config.owner.gitlabUsername`

In this mode you do **NOT** touch any code, branches, or commits. You only:
- Read the MR
- Audit existing discussions
- Produce structured review output
- Let the human (Telegram) decide what to post

## Inputs per MR

You will receive (from `run-agent.sh`) a context block:

```
TICKET_KEY: {{TICKET_PREFIX}}-XXX
MR_URL: https://gitlab.com/<project>/-/merge_requests/<iid>
MR_IID: <iid>
PROJECT_PATH: <namespace/project>
AUTHOR: <gitlab username>
```

## Steps

### Step 1 — Detect scenario: first-review / same-SHA / re-review

A ticket can land in Code Review multiple times (dev pushes fixes → moves back to
Code Review → back to dev → fixes → Code Review again). We must handle all three
cases distinctly to avoid re-raising comments you already posted.

```bash
HEAD_SHA=$(glab api "projects/:encoded_project/merge_requests/<iid>" 2>/dev/null \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['sha'])")
HEAD_SHORT="${HEAD_SHA:0:8}"
CURRENT_CACHE="cache/reviews/<MR_IID>-${HEAD_SHORT}.json"
```

List all prior review cache files for this MR (sorted newest first by mtime):

```bash
ls -t cache/reviews/<MR_IID>-*.json 2>/dev/null
```

Ignore: `-discussions.json`, `-stub.json`, temp files starting with `.`.

Classify the scenario:

| Prior files exist? | Match current `<MR_IID>-${HEAD_SHORT}.json`? | Scenario |
|---|---|---|
| No | — | **first-review** (normal flow, Steps 2–6) |
| Yes | Yes, matches | **same-sha** (see below) |
| Yes | No (prior exists but at a different SHA) | **re-review** (Step 1a) |

**same-sha**: If the cache file exists AND there are no new discussion notes from
anyone other than you since `cache.reviewed_at` → **stop, nothing new to review**.
If there are new author replies on your prior comments, treat as **re-review**
(Step 1a) with `delta_reason: "author-replied"`.

### Step 1a — Re-review mode

When a prior review exists at a different SHA, this is round N+1. The cycle is:

1. You reviewed at `prior.diff_refs.head_sha` and posted comments.
2. Dev worked through them, pushed new commits, put the ticket back in Code Review.
3. Now you're reviewing at a new `head_sha`.

**Load the most recent prior review file** as `prior`. Determine `round`:
- `round = (prior.round or 1) + 1` — write this into the new cache file.
- `prior_review_sha = prior.diff_refs.head_sha`

**Scope the review to only what changed**:

```bash
# Fetch only commits added since the prior review (anchored on SHAs, not dates)
cd <repo_local_path>
git fetch origin <source_branch> --quiet
git log --oneline "${prior.diff_refs.head_sha}..${HEAD_SHA}"
git diff "${prior.diff_refs.head_sha}..${HEAD_SHA}"
```

- **Do NOT re-run the full Step 4 checklist on files that were unchanged between
  `prior.head_sha` and the current `head_sha`.** Limit the checklist to lines
  present in the delta diff — anything else was already reviewed.
- **DO still evaluate all `thread_audit` entries from `prior`** against the
  current branch state (they may now be addressed). This is Step 3.

**Verify your previous comments were addressed**. For every `prior.comments[i]`
that the user actually posted (status was `posted` in the prior cycle — see the
handler's mutation to the cache file, or the `cache/reviews/<MR_IID>.posted.json`
side-file), look up the corresponding GitLab discussion and classify it:

- `addressed-by-commit` — a commit in the delta explicitly fixes it → record in
  `prior_comments_status` with `status: "addressed"` and `resolving_sha`.
- `addressed-by-reply` — author replied with a convincing justification, no code
  change needed → `status: "addressed-by-reply"` with `resolving_note_id`.
- `still-valid` — concern remains, delta does not fix it → `status: "still_valid"`.
  Do NOT emit a duplicate inline comment for it; it's already on the thread.
- `obsolete` — the code in question was deleted or heavily refactored so the
  concern no longer applies → `status: "obsolete"`.

Write these into `prior_comments_status` in the new cache file.

**New comments from the delta** go into `comments[]` as normal. Flag each new
comment's `body` with a leading `Round ${round}:` is NOT required — keep it
natural. The round number lives in the cache file; the handler surfaces it in
the Telegram summary.

The Telegram summary for a re-review must start with:

```
Re-review (round N) — <TICKET_KEY> !<MR_IID>
Prior review: <prior_head_short> → Now: <head_short>
Delta: <commit_count> commits, <file_count> files
Prior comments addressed: <k>/<total>
```

This is handled by `notify-review-ready.sh` when `round > 1`.

### Step 2 — Pull MR metadata, diff, and discussions

```bash
# MR details
glab api "projects/:encoded_project/merge_requests/<iid>"

# Diff (changes API returns per-file patches with position info)
glab api "projects/:encoded_project/merge_requests/<iid>/changes"

# Existing discussions (threads)
glab api "projects/:encoded_project/merge_requests/<iid>/discussions"
```

Capture from the MR metadata:
- `sha` (head), `diff_refs.base_sha`, `diff_refs.start_sha`, `diff_refs.head_sha` — needed for posting inline comments later
- `source_branch` (for local checkout)

### Step 3 — Existing threads audit (thread hygiene)

For each discussion that is NOT resolved:

1. Read the original `position` (file + line) and the comment body.
2. Check the current branch state to decide if the concern is addressed:
   - Has the code changed to fix it? Use `git blame` on the anchor line + `git log -p -- <file>` since the thread's `created_at` to see if an explicit fix commit happened.
   - Has the author replied in-thread with a justification that is reasonable?
3. Classify:
   - **Addressed-by-commit** — set `"status":"should_resolve"` with `resolving_sha` in the cache. **Do NOT resolve the thread yourself here** — the handler resolves all `should_resolve` threads atomically when the user approves the MR (or clicks "Resolve threads" from the review summary). This prevents premature resolution if the user wants to re-examine.
   - **Addressed-by-reply** — same as above but with `resolving_note_id` instead of `resolving_sha`.
   - **Not addressed** — record in `carried_over_threads` with `"status":"still_open"`. Do NOT raise a duplicate new comment about the same concern in Step 4.
   - **Ambiguous** — record with `"status":"unclear"` and a 1-sentence note. The user decides.

Never resolve a thread yourself in this phase — just recommend resolution. Only the
Telegram handler posts writes to GitLab (preserves the "human in the loop" contract).

### Step 3.5 — Spec drift check (Jira ticket vs MR diff)

Before reviewing the code itself, verify the MR actually delivers what the ticket
asked for. This catches cases where a dev forgot an AC, misinterpreted a requirement,
or over-scoped the change.

```bash
# Pull ticket description + any acceptance-criteria fields + linked-issue summaries
curl -s -u "${ATLASSIAN_EMAIL}:${ATLASSIAN_API_TOKEN}" \
  "{{JIRA_SITE}}/rest/api/3/issue/<TICKET_KEY>?fields=summary,description,customfield_*,issuelinks"
```

Build a structured view of the ticket's requirements:

1. **Primary goal** — one sentence from the ticket summary + description.
2. **Acceptance criteria** — bullet list (from description bullets, AC custom fields, or linked epics).
3. **Out-of-scope hints** — anything the ticket explicitly says NOT to do.

Then compare against the MR diff:

- For each AC, locate the diff hunk(s) that implement it. If you cannot find one,
  that AC is **missing** → add a **spec-drift comment** (not an inline code comment —
  a general discussion at MR level, severity=`high`).
- If the diff contains substantial changes unrelated to any AC, flag as **scope creep**
  → general discussion, severity=`medium`. Exception: renames / obvious cleanup in
  files already touched for the AC.
- If the AC is partially implemented (e.g. desktop done but no mobile), flag as
  **partial** → general discussion, severity=`high`.

Write these into `spec_drift` in the cache file (separate from line-comments):

```json
"spec_drift": [
  { "kind": "missing-ac", "severity": "high", "ac": "Tracking fires on mobile too",
    "body": "The ticket lists 'Fire on mobile' as AC #3, but the diff only adds `useIsMobile()` guards that *exclude* mobile. Please confirm if mobile coverage is intentionally deferred." },
  { "kind": "scope-creep", "severity": "medium",
    "body": "This MR also refactors `useSearchBar.ts` which is unrelated to the tracking goal. Consider splitting into a separate MR." }
]
```

The Telegram handler will surface `spec_drift` in the review summary with its own
section so the user can approve/edit/skip each one like a normal comment.

### Step 4 — Senior Frontend Review (BALANCED checklist)

Check the diff for the following categories. For each concrete issue found, emit **one inline comment**.

**High-value checks (always apply):**

1. **Pattern reuse** — are there existing enums/constants/utils that should have been used instead of inline values?
   - Mixpanel: `MXP_EVENT_NAME`, `MXP_TRACKING_ELEMENT`, `TrackingElementType`, `TrackingElementLocation`
   - URL builders: `buildArticleUrl`, `buildAuthorUrl`, `buildJDPUrl` — never construct URLs with string interpolation
   - API calls: use `$useFetchApi` / `useFetchApi` — not raw fetch
2. **Type safety** — no `any`, no `unknown` casts, no `!` non-null assertions, string-typed params that have an enum available
3. **Framework conventions** — `<script setup lang="ts">` only, no Options API, composable naming (`useXxx`), Pinia action patterns
4. **SSR safety** (from `CLAUDE.md`) — composables called BEFORE any `await`, no `useRoute()` in server middleware, `AsyncLocalStorage` context capture
5. **i18n** — user-facing strings wrapped in `$t()`, no hardcoded copy
6. **Design system** — no hardcoded hex colors, uses Tailwind tokens mapped to CSS variables
7. **Test coverage** — new public functions / composables should have unit tests; stores need action tests
8. **Error handling** — network failures handled; user-facing errors translated; no silent `catch {}`
9. **Commit message** — matches `{type}({ticketKey}): {description}` format (semantic-release requirement)
10. **Diff hygiene** — no `console.log`, no commented-out code, no unrelated changes, no whitespace-only files

**Skip (too pedantic for balanced review):**
- Line-length nitpicks
- Preference-level naming debates
- Style issues ESLint would catch anyway
- Hypothetical future scalability concerns

**Severity rule:**
- Only comment if the issue would reasonably **block approval** in a code review or create **real risk** (bug, type hole, broken convention that will cascade, missing test for new logic).
- If unsure, omit the comment.

### Step 5 — Emit the review file

Write to `cache/reviews/<MR_IID>-<head_sha_short>.json`:

```json
{
  "mr_iid": 2018,
  "mr_url": "https://gitlab.com/.../-/merge_requests/2018",
  "ticket_key": "{{TICKET_PREFIX}}-123",
  "project_path": "{{SSR_GITLAB_PROJECT}}",
  "project_encoded": "{{SSR_GITLAB_PROJECT_ENCODED}}",
  "author": "jane.doe",
  "source_branch": "feat/{{TICKET_PREFIX}}/{{TICKET_PREFIX}}-123/jane/vdb-tracking",
  "diff_refs": {
    "base_sha": "...",
    "start_sha": "...",
    "head_sha": "..."
  },
  "reviewed_at": "2026-04-18T10:30:00Z",
  "round": 1,
  "prior_review_sha": null,
  "delta_reason": null,
  "prior_comments_status": [],
  "summary": "Two-paragraph overview of the MR. State what it does, overall quality, and top concerns (if any).",
  "thread_audit": [
    { "discussion_id": "abc", "file": "src/Foo.vue", "line": 42,
      "original_comment": "Use the enum here",
      "status": "should_resolve",
      "resolving_sha": "a1b2c3",
      "note": "Fixed in commit a1b2c3 — now imports MXP_TRACKING_ELEMENT.SEARCH_BAR" },
    { "discussion_id": "def", "file": "src/Bar.vue", "line": 17,
      "original_comment": "Missing null check",
      "status": "still_open",
      "note": "Not addressed — carried over, will not be re-raised in comments below" },
    { "discussion_id": "ghi", "file": "src/Baz.vue", "line": 88,
      "original_comment": "Is this async-safe?",
      "status": "unclear",
      "note": "Author replied with 'will check' — no resolution either way" }
  ],
  "spec_drift": [
    { "kind": "missing-ac", "severity": "high", "ac": "Fire on mobile",
      "body": "AC #3 not implemented..." }
  ],
  "comments": [
    {
      "idx": 0,
      "file": "app/components/Foo.vue",
      "line_new": 42,
      "line_old": null,
      "severity": "medium",
      "category": "pattern-reuse",
      "body": "The string 'search_bar' is also defined in `MXP_TRACKING_ELEMENT.SEARCH_BAR`. Please use the enum for consistency and to prevent typos.",
      "status": "pending"
    }
  ],
  "verdict": "needs-comments | lgtm"
}
```

`verdict` is `"lgtm"` only if `comments` is empty AND there are no `carried_over_threads` with high-severity items.

For a **re-review** (round > 1), `prior_comments_status` looks like:

```json
"prior_comments_status": [
  { "idx": 0, "status": "addressed",         "resolving_sha": "a1b2c3d4",
    "original_body": "Use MXP_TRACKING_ELEMENT.SEARCH_BAR instead of 'search_bar'" },
  { "idx": 1, "status": "addressed-by-reply", "resolving_note_id": 12345678,
    "original_body": "Missing null check on props.query" },
  { "idx": 2, "status": "still_valid",
    "original_body": "This composable should be called before the await" },
  { "idx": 3, "status": "obsolete",
    "original_body": "Extract this into a util" }
]
```

`verdict` rules for re-review:
- `"lgtm"` only if **all** prior comments are `addressed` or `addressed-by-reply`
  or `obsolete`, AND `comments` is empty, AND no high-severity thread_audit items.
- `"needs-comments"` otherwise.

### Choosing the inline anchor (`line_new` vs `line_old`)

GitLab inline comments can anchor on **any line of the file**, not only lines in the hunk — as long as you provide the right `line_new` / `line_old` combination. Choose the anchor so the highlighted line in the UI matches the point of the comment:

- **Comment about a newly added line** (a `+` line in the diff) → set `line_new` to that line. Leave `line_old` unset.
- **Comment about a removed line** (a `-` line in the diff) → set `line_old` to that old-file line. Leave `line_new` unset.
- **Comment about an unchanged line** — whether inside or outside the hunk (e.g. "this existing function above has become dead code", "this constant should have been updated too") → set **both** `line_new` and `line_old` to the same line number (they are equal for unchanged lines). This works for any line of the file; GitLab will anchor the comment there and highlight it.
- **Comment about a file that is NOT touched by the MR at all** (e.g. "this other file was missed from the scope") → set `line_new` to a sensible line number; the poster will fall back to a general discussion with a bold `**file:line**` header.

Prefer pointing at the **most semantically relevant line** — the definition/declaration you're actually talking about — rather than at a deleted `{` or a context `});`. Readers will see exactly the line the comment is about, not a bracket nearby.

Examples:
- Dead `h1 = computed(...)` at lines 155–185 after a deletion → `line_new: 155, line_old: 155` (the `const h1 = computed(...)` declaration itself).
- Missing `<meta name="keywords">` removal at line 66 of an untouched file → `line_new: 66` (the poster will fall back to a general discussion with a `**file:66**` header because the file isn't in the diff).

### Step 6 — Notify Telegram (auto-push summary + per-comment buttons)

After writing the review cache file, invoke the notification helper so the user gets:
1. A summary message with MR-level buttons (`Show comments`, `Approve MR`, `Open in GitLab`, `Skip`)
2. One message per **pending** comment with per-comment buttons (`Post`, `Edit`, `Discuss with AI`, `Skip`)

This lets the user act on every comment directly from the review-ready Telegram thread without needing to tap `reviews` first.

Run this command from the shell (it reads the latest cache file for the given `MR_IID`):

```bash
bash ~/.cursor/skills/autonomous-dev-agent/scripts/notify-review-ready.sh <MR_IID>
```

Then also log `REVIEW READY: cache/reviews/<filename>.json` to the agent log for traceability.

Do **not** send raw Telegram messages yourself — the helper handles formatting, inline keyboards, and chunking consistently with how the `reviews` command renders.

### Step 7 — Discussion mode (if `cache/reviews/<MR_IID>-discussions.json` exists)

At agent-run start, before queuing any new reviews, check for pending discussion questions.

`cache/reviews/<MR_IID>-discussions.json` format:

```json
{
  "questions": [
    {
      "idx": 0,
      "comment_idx": 2,
      "question": "Is there really an enum for this event?",
      "asked_at": "...",
      "answered": false,
      "answer": null
    }
  ]
}
```

For each unanswered question:
1. Load the original review file and the specific comment at `comment_idx`.
2. Re-read the referenced file/line in the current branch state.
3. Answer the question based on code reality. Be concise (2-3 sentences).
4. If your answer implies the comment body should change, also return a `suggested_new_body`.
5. Write `answered=true`, `answer=<your reply>`, `suggested_new_body=<optional>`.

The handler will notify the user with the answer and `[Post]` `[Use Suggested Body]` `[Ask Again]` buttons.

## Output guarantees

- **Never modify the branch or push commits** in this phase.
- **Never post comments directly to GitLab** — only write the JSON cache file. Posting is done by the Telegram handler on user approval.
- **Mark existing threads resolved only when you are confident the concern is fully addressed** in the current code.
- **Use the author's language for `body`** — match the project style: English, concise, constructive, reference existing code with backticks.

## Multi-MR handling

If multiple Code Review tickets are assigned to you, review them sequentially in the same agent run. Each review writes its own cache file. Do NOT batch them into one file.
