# Adoption playbook — onboarding your first external user

Shipping v0.3 to a public repo isn't the same as proving it works outside
your own MacBook. This doc is the protocol for turning one colleague into
your first real external user, with each stumble becoming a docs PR or a
bug fix instead of a Slack thread that evaporates.

## Goal

Get a teammate running their own instance against their own Jira project
+ Telegram bot within a single 60-minute session, with no hand-holding
beyond `docs/SETUP.md` and `bin/doctor`.

## Pick a candidate

Best picks, in order:

1. A developer who already uses Cursor CLI daily.
2. Someone on a different Jira project than you (so we exercise workflow
   auto-discovery on unfamiliar transitions).
3. A dev who will tell you when docs are bad, not a polite user.

## Session script (60 min)

Record the session (with consent). You want the raw "wait, what do I do
now?" moments — those are the docs gaps.

### 0–10 min — prerequisites

Read `docs/SETUP.md` together. Anything unclear → PR.

Install prereqs:

```bash
brew install jq python@3 gh
# Cursor CLI: https://docs.cursor.com/cli
```

### 10–30 min — clone + install

```bash
git clone https://github.com/<you>/autonomous-dev-agent ~/code/autonomous-dev-agent
cd ~/code/autonomous-dev-agent
bin/init.sh       # interactive wizard
bin/install.sh
bin/doctor        # expect all green
```

**Intervene only for blockers**, not for confusion. If the user gets stuck
for >3 minutes, file a GitHub issue right there:

```bash
gh issue create --label triage --title "[docs] SETUP: user got stuck at <step>"
```

### 30–45 min — first real run

Have them:

1. Find one "To Do" Jira ticket in their project.
2. Trigger `/run` on Telegram.
3. Watch the agent work through phases.
4. Review + approve the MR the usual way.

Success criteria: the `/status` card shows the run progressing, and
Telegram sends a "Ready for review" card when the MR is up.

### 45–60 min — retrospective

Walk through what broke. Convert each into an issue:

- Docs ambiguity → `[docs]` issue, milestone = v0.3.2
- Missing driver for their stack → `[driver]` issue, milestone = v0.4.0
- Hardcoded assumption → `[bug]` issue, milestone = next patch

## After the session

Within 24 hours:

- File every issue. Each one gets a milestone.
- Fix the top 3 painful ones before end-of-week.
- If they ask "how do I do X?" and the answer isn't in docs — that's a
  docs PR, not a DM reply.

## When to call v0.3.2 done

- First external user has been using it for a full work-week.
- Every friction they hit has either shipped a fix or been filed with a
  milestone.
- They describe the agent as "saving me time" without prompting.

If that's true: bump version, cut the release, move on to v0.4.0.
