# 90-second demo video — shot list

The roadmap calls for a short demo video that ships with v1.0.0. The
video itself is a binary deliverable and lives as a GitHub Release
asset (and a link in the README), not in-tree. This file is the
canonical script + shot list so any contributor can re-shoot it after
a major refactor.

## Goals

In ≤ 90 seconds a viewer should learn:

1. What the agent does (one sentence).
2. How it looks on the receiving end (Telegram + SwiftBar).
3. That it's multi-project, pluggable, and fully local.

## Format

- **1080p screen capture**, Cmd-Shift-5 on macOS.
- No voice-over. Captions only (keeps re-shoots cheap; localisation
  becomes just a caption file).
- Output formats: `.mp4` for GitHub Release, animated `.webp` thumbnail
  linked from the README.

## Shot list

| t       | Scene                                                                                | Caption                              |
|---------|--------------------------------------------------------------------------------------|--------------------------------------|
| 0:00    | Terminal: `glab mr list --author=@me` shows an empty queue                           | "You: zero MRs open."                |
| 0:05    | Jira board: drag ticket PROJ-999 → "To Do"                                             | "Assign yourself a Jira ticket."     |
| 0:12    | Fast-forward 2 min (clock overlay) — SwiftBar icon goes ⏳ → 🤖                       | "2 min tick — agent picks it up."    |
| 0:20    | Telegram: inline card "PROJ-999: Add feedback toast" [Approve] [Skip] [Review scope]   | "Approve, skip, or review scope."    |
| 0:30    | Click [Approve]                                                                      |                                      |
| 0:35    | Cursor CLI stream in a terminal: creating branch, editing files, running tests       | "Cursor CLI does the work."          |
| 0:50    | Telegram: "MR !2345 opened — Ready for review"  with [Approve MR] [Changes requested]| "MR opens itself."                   |
| 0:58    | Code host: MR page, green CI                                                         |                                      |
| 1:05    | Click [Approve MR] in Telegram                                                       |                                      |
| 1:10    | Telegram: "PROJ-999 → Ready for QA. Tempo? [Log 45m ▸ PROJ-999]"                         | "Tempo one-tap backfill."            |
| 1:18    | SwiftBar menu: top 5 tickets across 3 projects                                       | "Multi-project, fair-share queue."   |
| 1:25    | `cat config.json` — show chat/tracker/host all switchable                            | "Pluggable. Local. No server."       |
| 1:30    | End card: github.com/<owner>/autonomous-dev-agent                                    | "github.com/.../autonomous-dev-agent"|

## Asset references

- Jira board URL: use a demo project (not a real one!).
- SwiftBar plugin: `scripts/menubar/dev-agent.30s.sh`.
- Telegram chat: use a clean demo bot, not your personal one.
- Terminal theme: use a default theme so viewers don't get distracted.

## Production checklist

- [ ] Clean `cache/` + `logs/` before recording (fresh install look).
- [ ] Use demo tokens, redacted chat ID, public-safe project names.
- [ ] Compress with `ffmpeg -i in.mov -vf scale=1920:-2 -crf 26 out.mp4`.
- [ ] Upload to GitHub Release `v1.0.0` as `demo.mp4`.
- [ ] Update the README teaser link to the Release asset URL.
