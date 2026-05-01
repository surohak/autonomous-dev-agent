## Phase 5.5: Self-Review as Frontend Architect

After your MR is created, switch roles. You are now a **Senior Frontend
Architect** reviewing this MR before it reaches the human reviewer. Your goal
is zero reviewer comments — every issue you catch here is one fewer round-trip.

### What to review

Run `glab mr diff <MR_IID>` and audit the diff against the checklist below.
Also re-read the full files you touched — not just the diff — to catch context
issues that a diff-only review misses.

#### 1. Completeness — did you change everything that needs changing?

This is the most common gap. Examples from real reviews:

- Ticket says "remove feature from LPs" but you only touched 2 of 4 LP layouts.
  Grep for the feature name across the repo to find all usage sites.
- You changed a component but a sibling page uses a different layout that still
  has the old behaviour.
- You updated `definePageMeta` on one registration page but three similar pages
  (`/registration/99`, `/registration/100`, `/registration/199`) use the same
  pattern and were not touched.

**Action**: For every file you changed, search the repo for similar files and
verify they don't need the same treatment. Pay special attention to:
- Pages with similar route patterns (`/registration/*`, `/lp/*`)
- Layouts that share components
- Composables used by multiple consumers

#### 2. Architecture consistency

- Do sibling files follow the same `definePageMeta` pattern? If you added
  `layout: 'lp'` to one page, should other pages in the same group also have it?
- Did you introduce inline logic that already exists as a named middleware or
  composable?
- Are imports consistent with auto-import conventions?

#### 3. Dead code and cleanup

- If you removed a feature, did you also remove all associated:
  - Imports and type references
  - Reactive state (`ref()`, `computed()`) that only served the removed feature
  - Template conditional blocks that are now always-true or always-false
  - CSS classes or Tailwind utilities that are no longer referenced
- Are there trailing blank lines or whitespace-only changes in the diff?

#### 4. Edge cases

- Could the change break SSR hydration? (e.g., client-only logic in a
  server-rendered component)
- Are there null/undefined guards where data might be missing?
- If you modified routing or middleware, does navigation still work for both
  direct visits and SPA transitions?

#### 5. Cross-MR awareness

- `glab mr list --state opened` — are there other open MRs touching the same
  files? If so, will they conflict with your changes?

### Output

After the review, take one of these actions:

**If you found issues:**
1. Fix each issue in the worktree.
2. Commit: `fix({TICKET_KEY}): address self-review findings`
3. `git push`
4. Set `SELF_REVIEW_SUMMARY` to a brief list of what you fixed, for the
   Telegram notification. Example:
   `"2 findings fixed: aligned /registration/139 and /140 with lp layout; removed dead OneTap refs"`

**If the diff is clean:**
- Set `SELF_REVIEW_SUMMARY` to `"Clean — no issues found"`
- Continue immediately to worktree cleanup and Phase 6 (Notify).
  Do NOT pause, stop, or wait for confirmation — a clean review means
  the MR is ready for the human reviewer.
