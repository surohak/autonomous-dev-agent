# Phase 9: CI Auto-Fix Mode

## Activation

You are in **CI Auto-Fix Mode** when `run-agent.sh` passes `FORCE_MODE=ci-fix`
with `FORCE_MR=<iid>` and `FORCE_REPO=<ssr|blog>`. This means the watcher
detected a failed pipeline on one of the user's own MRs and {{OWNER_FIRST_NAME}} tapped
`Auto-fix` in Telegram.

In this mode you do **exactly one thing**: diagnose the failure, push the
minimal fix commit, and notify. You do NOT create/close MRs, do NOT move Jira
tickets, do NOT open new reviews.

## Inputs

- `FORCE_REPO` — repo slug (`ssr` or `blog`); resolve to localPath via `config.json`
- `FORCE_MR` — MR IID
- `FORCE_MODE=ci-fix`

## Steps

### Step 1 — Gather failure context

```bash
# 1. Fetch MR to get source branch + head SHA + pipeline id
glab api "projects/:fullpath/merge_requests/${FORCE_MR}"
#   → capture: source_branch, head_pipeline.id, head_pipeline.web_url

# 2. List failing jobs of that pipeline
glab api "projects/:fullpath/pipelines/<pipeline_id>/jobs?scope=failed"
#   → pick each failed job's id + name

# 3. For each failed job, fetch the trace (last 4 KB is usually enough)
glab api "projects/:fullpath/jobs/<job_id>/trace" | tail -c 4096
```

### Step 2 — Classify the failure

Common categories (ordered by likelihood):

1. **Lint / formatting** — ESLint, Prettier, Stylelint failure
2. **Type check** — `tsc --noEmit`, `vue-tsc` failure
3. **Unit tests** — Vitest / Jest assertion failure
4. **Build** — Nuxt/Vite/Webpack compile error
5. **Translation extraction** — missing `$t(...)` key, broken `.pot` file
6. **Storybook / a11y** — skip, notify user (not safe to auto-fix)
7. **Environment / infra** — flaky runner, expired token → retry pipeline instead of code change

Detection hints (trace text):
- `"error  " or "✖"` + ESLint rule name → lint
- `"error TS\d+"` → TypeScript
- `"FAIL src/..."` or `"AssertionError"` → tests
- `"Module not found"` or `"Cannot find module"` → build / import path
- `"✖ Failed to parse"` in `.po` or `.pot` → translations

### Step 3 — Checkout the branch and fix

```bash
cd $REPO_LOCAL_PATH
git fetch origin <source_branch>
git checkout <source_branch>
git pull --ff-only origin <source_branch>
```

Apply the **minimal** fix for the category:

**Lint**: run the project's `lint --fix` equivalent:
```bash
npm run lint -- --fix <changed files>
```
If the rule isn't autofixable, make a targeted edit.

**Type check**: fix the specific type hole the compiler pointed at — do not
widen types, do not add `any`, do not disable the rule. If you cannot fix it
in one edit without compromising type safety, **stop and report** in Step 5
(do not force-push something worse than before).

**Unit test**: first try to reproduce locally:
```bash
npm test -- <specific file>
```
If the test is correct but the production code is wrong → fix the production
code. If the test itself is wrong because the behaviour legitimately changed
→ update the test, but only if the change is obviously intended (e.g. a
string you just added to the source).

**Build / import**: resolve path, check `tsconfig.json` paths and `nuxt.config.ts`
alias list.

**Translation**: re-run `npm run i18n:extract` (or project equivalent) and
commit the regenerated `.pot`/JSON.

**Infra / flaky**: do **not** change code. Instead retry the pipeline:
```bash
glab ci retry <pipeline_id>
```
Then stop.

### Step 4 — Verify locally before pushing

Run the same command the failing job ran, locally:
```bash
npm run lint            # for lint job
npm run type-check      # for type job
npm test -- <files>     # for test job
```

Only push if local run passes. **Never push a fix you have not verified.**

### Step 5 — Commit and push

Commit format (semantic-release compatible):
```
fix({ticketKey}): resolve {job_name} failure

{1–2 sentences describing what the fix does}
```

Example:
```
fix({{TICKET_PREFIX}}-123): resolve eslint no-unused-vars in SeoSrp.vue

The `h1` computed became unused after removing `keywords`; dropped the
declaration.
```

Push:
```bash
git push origin <source_branch>
```

### Step 6 — Log fix to lessons

Append a one-liner to `{{PROJECT_CACHE_DIR}}/lessons.md`:
```
## CI fix: <category> (<date>)
<ticket_key> !<mr_iid> — <1-sentence cause> → <1-sentence fix>
```

### Step 7 — Notify Telegram

On success:
```
Auto-fixed pipeline on !<mr_iid> (<ticket_key>)
<category>: <short description>
New commit pushed. Pipeline re-running.
```

On failure (cannot fix safely):
```
Could not auto-fix !<mr_iid> (<ticket_key>)
Reason: <why — e.g. "type hole is legitimate and requires API contract change">
Leaving branch untouched. Tap Open Pipeline to inspect.
```

Use the inline keyboard:
```
[Open MR] [Open pipeline]
```

## Safety guarantees

- **Never force-push**. Use a normal `git push`.
- **Never push without verifying locally** that the fix passes the same check.
- **Never disable lint/type rules** to make the pipeline green — fix the code.
- **Never widen types** (`any`, `unknown`, `!`). If you can't fix the type
  cleanly, stop and report.
- **Never amend or rewrite history** on a branch that has reviewers looking at it.
- **Maximum 1 fix attempt per activation**. If the fix itself fails, stop and
  report — do not chain attempts.

## Re-queue policy

Once this phase completes (success or give-up), the watcher will observe the
next pipeline run within 2 minutes. If the new pipeline is also failed, the
watcher will notify again — but the handler deduplicates by `pipeline_id`, so
you won't get spammed for the same failure twice.
