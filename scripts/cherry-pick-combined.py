#!/usr/bin/env python3
"""Combined cherry-pick: promote commits from multiple tickets to main in a
single branch + single MR.

Given a comma-separated list of ticket keys and a repo slug, this:
  1. Finds each ticket's commits on origin/<stage> that aren't yet on
     origin/main (same search strategy as cherry-pick.py).
  2. Merges the set and orders chronologically by committer date.
  3. Creates one new branch from origin/main, cherry-picks all commits,
     pushes, opens ONE MR to main titled "promote <K1> + <K2> to main
     (N commits)".
  4. Writes promoted.json entries:
       - promoted["__combined__<hash-of-keys>"] = {url, keys, ...}
       - promoted[<each_key>]                   = {url, combined_siblings=[…], ...}
     so rel_dm:<any key> can find the shared MR AND know the full sibling
     list for the DM message body.

Env: TK_KEYS (comma separated, required), FORCE_REPO (required — combined
     cherry-pick is always scoped to a single repo), CONFIG_PATH.

Exit: 0 OK (prints OK:…), 1 error (prints ERR:…), 2 nothing-to-do
     (prints INFO:…).
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.parse


KEYS_RAW = os.environ.get("TK_KEYS", "").strip()
FORCE_REPO = os.environ.get("FORCE_REPO", "").strip()

if not KEYS_RAW:
    print("ERR: TK_KEYS env var is required (comma-separated ticket keys).")
    sys.exit(1)
if not FORCE_REPO:
    print("ERR: FORCE_REPO env var is required — combined cherry-pick is scoped to a single repo.")
    sys.exit(1)

KEYS = [k.strip().upper() for k in KEYS_RAW.split(",") if k.strip()]
if len(KEYS) < 2:
    print("ERR: combined cherry-pick needs at least 2 ticket keys.")
    sys.exit(1)

config = json.load(open(os.environ["CONFIG_PATH"]))
_proj0 = (config.get("projects") or [{}])[0] if isinstance(config.get("projects"), list) else {}
repos = config.get("repositories") or _proj0.get("repositories") or {}

if FORCE_REPO not in repos:
    print(f"ERR: unknown repo '{FORCE_REPO}'. Available: {list(repos)}")
    sys.exit(1)

meta = repos[FORCE_REPO]
local = meta.get("localPath")
stage = meta.get("defaultBranch", "stage")
proj = meta.get("gitlabProject")
if not local or not os.path.isdir(local):
    print(f"ERR: repo path missing for '{FORCE_REPO}': {local}")
    sys.exit(1)


def run(cmd, cwd=None, timeout=180):
    try:
        r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout.strip(), r.stderr.strip()
    except subprocess.TimeoutExpired:
        return 124, "", f"command timed out after {timeout}s: {' '.join(str(c) for c in cmd[:4])}"


# --- 1) fetch + sanity checks --------------------------------------------
rc, _, err = run(["git", "fetch", "origin", "--prune"], cwd=local, timeout=180)
if rc != 0:
    print(f"ERR: fetch failed: {err[:300]}")
    sys.exit(1)

for ref in ("origin/main", f"origin/{stage}"):
    rc, _, _ = run(["git", "rev-parse", "--verify", ref], cwd=local)
    if rc != 0:
        print(f"ERR: {ref} not found in {FORCE_REPO}")
        sys.exit(1)

rc, dirty, _ = run(["git", "status", "--porcelain"], cwd=local)
if dirty.strip():
    print(f"ERR: {FORCE_REPO} working tree is dirty. Commit/stash first.\n{dirty[:400]}")
    sys.exit(1)


# --- 2) collect commits for every ticket, de-duplicate, sort chronological
# Same regex strategy as cherry-pick.py: grep commit messages on
# origin/main..origin/<stage> for a whole-word match of the ticket key.
# Collect tuples of (committer_date_iso, sha, subject, ticket_key) so we
# can sort globally and still know which ticket each sha belongs to.
entries = []  # list of (ci_date, sha, subject, ticket_key)
per_key_counts: dict[str, int] = {}

for key in KEYS:
    rc, out, err = run([
        "git", "log",
        f"origin/main..origin/{stage}",
        "--no-merges",
        "--regexp-ignore-case",
        "--extended-regexp",
        "--grep", rf"\b{re.escape(key)}\b",
        "--format=%H%x01%ci%x01%s",
        "--reverse",
    ], cwd=local)
    if rc != 0:
        print(f"ERR: git log failed for {key}: {err[:200]}")
        sys.exit(1)
    count = 0
    for line in out.splitlines():
        parts = line.split("\x01")
        if len(parts) < 3:
            continue
        sha, ci, subject = parts
        if len(sha) != 40:
            continue
        entries.append((ci, sha, subject, key))
        count += 1
    per_key_counts[key] = count

if not entries:
    print(f"INFO: no pending commits for {', '.join(KEYS)} on origin/{stage} not already on origin/main.")
    sys.exit(2)

# De-duplicate (same commit can mention two keys); keep the first occurrence
# (iteration is KEYS-ordered but we'll resort anyway).
seen = set()
unique = []
for ci, sha, subject, key in entries:
    if sha in seen:
        continue
    seen.add(sha)
    unique.append((ci, sha, subject, key))

# Chronological order (oldest first) — matches how cherry-pick.py orders a
# single ticket's commits and avoids fabricating a fake history.
unique.sort(key=lambda t: t[0])
shas_ordered = [sha for _, sha, _, _ in unique]


# --- 3) guard against existing combined MR that already covers these keys ---
# If an open MR's source branch is a previous combined/* branch covering the
# same set, we refuse to create a duplicate.
proj_enc = urllib.parse.quote(proj, safe="") if proj else ""
rc, out, _ = run([
    "glab", "mr", "list",
    "--target-branch", "main",
    "--per-page", "100",
    "-F", "json",
], cwd=local, timeout=60)
existing = []
if rc == 0 and out.strip().startswith(("[", "{")):
    try:
        existing = json.loads(out)
    except Exception:
        existing = []

existing_match = None
for m in existing:
    src = (m.get("source_branch") or "")
    title = (m.get("title") or "")
    if not src.startswith("promote/combined/"):
        continue
    if all(re.search(r'\b' + re.escape(k) + r'\b', title + " " + src) for k in KEYS):
        existing_match = m
        break

if existing_match:
    url = existing_match.get("web_url") or ""
    print(f"INFO: combined promote MR already open: !{existing_match.get('iid')} → {url}")
    sys.exit(2)


# --- 4) create branch, cherry-pick every commit --------------------------
ts = time.strftime("%Y%m%d-%H%M%S")
slug_keys = "+".join(KEYS[:3])
if len(KEYS) > 3:
    slug_keys += f"+{len(KEYS) - 3}more"
new_branch = f"promote/combined/{slug_keys}-{ts}"

rc, current_branch, _ = run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=local)

rc, _, err = run(["git", "checkout", "-b", new_branch, "origin/main"], cwd=local)
if rc != 0:
    print(f"ERR: branch create failed: {err[:400]}")
    sys.exit(1)

picked, skipped, conflicts = [], [], []
# auto_resolved: [{"sha": "...", "ticket": "PROJ-942", "files": [...], "strategy": "theirs"}]
# Files whose conflicts we let git resolve with `-X theirs` (stage wins).
# We surface these in the MR description so the reviewer double-checks them.
auto_resolved: list[dict] = []
for sha in shas_ordered:
    rc, _, _ = run(["git", "merge-base", "--is-ancestor", sha, "origin/main"], cwd=local)
    if rc == 0:
        skipped.append(sha[:8])
        continue

    rc, parents, _ = run(["git", "rev-list", "--parents", "-n", "1", sha], cwd=local)
    parent_count = max(0, len(parents.split()) - 1)

    # IMPORTANT: do NOT pass --empty=drop or --skip. The former landed in
    # git 2.32 and the latter in 2.25. Homebrew (and some Linux distros)
    # still ship older git (2.23 seen in the wild), where those flags
    # abort the command with the usage banner — which looks like a
    # cherry-pick failure but actually means "unknown flag".
    # We detect "redundant pick → empty result" post-hoc instead, using
    # only `git cherry-pick --abort` which exists on every git version.
    cp_cmd = ["git", "cherry-pick", "-x"]
    if parent_count >= 2:
        cp_cmd += ["-m", "1"]
    cp_cmd.append(sha)

    rc, out, err = run(cp_cmd, cwd=local, timeout=180)
    if rc != 0:
        # Distinguish real conflict from "pick with nothing to resolve"
        # (commit's changes are already on main under a different SHA —
        # squash, prior manual pick, revert-of-revert). Key signal is the
        # absence of unmerged paths; staged changes may or may not exist
        # (the partial-apply case can leave files staged whose net diff
        # vs HEAD is zero). We do NOT require staged=0.
        rc_u, unmerged_out, _ = run(
            ["git", "diff", "--name-only", "--diff-filter=U"],
            cwd=local, timeout=30,
        )
        unmerged_paths = [f for f in (unmerged_out or "").splitlines() if f.strip()]
        rc_s, staged_out, _ = run(
            ["git", "diff", "--cached", "--name-only"],
            cwd=local, timeout=30,
        )
        staged_paths = [f for f in (staged_out or "").splitlines() if f.strip()]
        in_progress = os.path.exists(os.path.join(local, ".git", "CHERRY_PICK_HEAD"))

        # Debug breadcrumb on stderr — cheap insurance the next time this
        # fires in a way we don't expect.
        print(
            f"[cherry-pick-combined] {sha[:8]}: pick failed. "
            f"in_progress={in_progress} unmerged={len(unmerged_paths)} "
            f"staged={len(staged_paths)} git_rc={rc}",
            file=sys.stderr,
        )

        if in_progress and not unmerged_paths:
            # No unmerged paths mid-pick = no conflict for the operator to
            # resolve. Either the change is already on main (redundant
            # pick) OR git stopped for another non-conflict reason (empty
            # message, etc.). Either way, skipping + aborting is safe —
            # we never commit empties into the branch.
            rc_a, _, err_a = run(
                ["git", "cherry-pick", "--abort"],
                cwd=local, timeout=60,
            )
            if rc_a != 0:
                # --abort itself failed — force the tree clean so the next
                # iteration doesn't inherit a half-applied state.
                run(["git", "reset", "--hard", "HEAD"], cwd=local, timeout=60)
                # Remove the sentinel file by hand if reset didn't clear it.
                try:
                    os.remove(os.path.join(local, ".git", "CHERRY_PICK_HEAD"))
                except FileNotFoundError:
                    pass
                except Exception:
                    pass
            skipped.append(f"{sha[:8]}(empty)")
            continue

        # Real conflict. Snapshot the paths NOW — `git cherry-pick --abort`
        # on the next line wipes the unmerged state, so re-querying after
        # the abort returns nothing (the "Conflicting files: (none
        # reported)" bug through 1.0.14–1.0.16).
        snapshot_unmerged = list(unmerged_paths)
        snapshot_staged = list(staged_paths)

        # First recovery attempt: retry the pick with `-X theirs`. For a
        # stage→main promote workflow, stage IS the source of truth, so
        # taking stage's version of a conflicting file is almost always
        # correct. Common cause: the pick depends on earlier stage-only
        # commits (under other tickets) that touched the same file — the
        # `theirs` strategy short-circuits that by directly importing
        # stage's current content for the file.
        rc_abort, _, _ = run(["git", "cherry-pick", "--abort"], cwd=local, timeout=60)
        if rc_abort != 0:
            run(["git", "reset", "--hard", "HEAD"], cwd=local, timeout=60)

        theirs_cmd = ["git", "cherry-pick", "-x", "-X", "theirs"]
        if parent_count >= 2:
            theirs_cmd += ["-m", "1"]
        theirs_cmd.append(sha)
        rc_t, out_t, err_t = run(theirs_cmd, cwd=local, timeout=180)
        if rc_t == 0:
            # SAFETY CHECK (added in 1.0.19): `-X theirs` imports the file
            # state from the cherry-picked commit itself — NOT stage HEAD.
            # If later stage commits under other tickets refactored the
            # same file, "theirs" is a stale snapshot and merging our MR
            # would erase those refactors on main. Verify every auto-
            # resolved file matches origin/<stage> HEAD; if not, undo this
            # pick and go manual. (This caught a broken ModalWrapper.vue
            # promote in MR 2067 — 136 lines of modalComponentMap would
            # have been deleted because PROJ-1939's refactor on stage was
            # newer than the cherry-picked cdeb4b52.)
            stale_files: list[str] = []
            for f in snapshot_unmerged:
                rc_cmp, diff_out, _ = run(
                    ["git", "diff", "--exit-code", f"origin/{stage}",
                     "--", f],
                    cwd=local, timeout=30,
                )
                if rc_cmp != 0:
                    stale_files.append(f)

            if not stale_files:
                # All auto-resolved files equal stage HEAD — safe.
                conflict_ticket = "?"
                for _ci, _sha, _sub, _k in unique:
                    if _sha.startswith(sha[:8]):
                        conflict_ticket = _k
                        break
                auto_resolved.append({
                    "sha": sha[:8],
                    "ticket": conflict_ticket,
                    "files": snapshot_unmerged,
                    "strategy": "theirs",
                })
                picked.append(f"{sha[:8]}(theirs)")
                print(
                    f"[cherry-pick-combined] {sha[:8]}: auto-resolved with "
                    f"-X theirs on {len(snapshot_unmerged)} file(s): "
                    f"{', '.join(snapshot_unmerged)}",
                    file=sys.stderr,
                )
                continue

            # Stale snapshot detected — the cherry-picked commit's version
            # of these files predates later stage work under other tickets.
            # FIX: replace the stale files with origin/<stage> HEAD and
            # amend the commit. This is correct because:
            #   - stage is the source of truth for promote-to-main
            #   - after ALL stage work is eventually promoted, main must
            #     equal stage, so importing stage HEAD for these files is
            #     the correct end-state
            #   - subsequent cherry-picks in our set were authored against
            #     stage history, so having stage HEAD here lets them apply
            #     cleanly
            print(
                f"[cherry-pick-combined] {sha[:8]}: -X theirs produced "
                f"stale content vs origin/{stage} for: "
                f"{', '.join(stale_files)}. Replacing with origin/{stage} "
                f"HEAD and amending.",
                file=sys.stderr,
            )
            checkout_ok = True
            for sf in stale_files:
                rc_co, _, err_co = run(
                    ["git", "checkout", f"origin/{stage}", "--", sf],
                    cwd=local, timeout=30,
                )
                if rc_co != 0:
                    print(
                        f"[cherry-pick-combined] {sha[:8]}: checkout "
                        f"origin/{stage} -- {sf} failed: {err_co[:100]}",
                        file=sys.stderr,
                    )
                    checkout_ok = False
            if not checkout_ok:
                run(["git", "reset", "--hard", "HEAD~1"], cwd=local, timeout=60)
                conflicts.append({
                    "sha": sha[:8],
                    "detail": f"Stage HEAD checkout failed for one or more stale files",
                    "unmerged": snapshot_unmerged,
                    "staged": snapshot_staged,
                    "stale_vs_stage": stale_files,
                })
                break
            run(["git", "add"] + stale_files, cwd=local, timeout=30)
            rc_amend, _, err_amend = run(
                ["git", "commit", "--amend", "--no-edit", "--no-verify"],
                cwd=local, timeout=60,
            )
            if rc_amend != 0:
                print(
                    f"[cherry-pick-combined] {sha[:8]}: amend after stage "
                    f"HEAD replacement failed (rc={rc_amend}): "
                    f"{err_amend[:200]}. Falling to manual flow.",
                    file=sys.stderr,
                )
                run(["git", "reset", "--hard", "HEAD~1"], cwd=local,
                    timeout=60)
                conflicts.append({
                    "sha": sha[:8],
                    "detail": (
                        f"Stage HEAD replacement + amend failed: "
                        f"{err_amend[:300]}"
                    )[:500],
                    "unmerged": snapshot_unmerged,
                    "staged": snapshot_staged,
                    "stale_vs_stage": stale_files,
                })
                break

            conflict_ticket = "?"
            for _ci, _sha, _sub, _k in unique:
                if _sha.startswith(sha[:8]):
                    conflict_ticket = _k
                    break
            auto_resolved.append({
                "sha": sha[:8],
                "ticket": conflict_ticket,
                "files": snapshot_unmerged,
                "stale_fixed": stale_files,
                "strategy": "theirs+stage-head",
            })
            picked.append(f"{sha[:8]}(stage)")
            print(
                f"[cherry-pick-combined] {sha[:8]}: resolved via "
                f"-X theirs + stage HEAD fixup on {len(stale_files)} "
                f"file(s): {', '.join(stale_files)}",
                file=sys.stderr,
            )
            continue

        # `-X theirs` also failed (binary conflict, deleted-vs-modified,
        # submodule, etc.). Bail with the original diagnostic state so
        # Telegram can surface the manual-finish block.
        print(
            f"[cherry-pick-combined] {sha[:8]}: -X theirs retry also failed "
            f"(rc={rc_t}). Falling back to manual flow.",
            file=sys.stderr,
        )
        conflicts.append({
            "sha": sha[:8],
            "detail": (err_t or out_t or err or out)[:400],
            "unmerged": snapshot_unmerged,
            "staged": snapshot_staged,
        })
        run(["git", "cherry-pick", "--abort"], cwd=local)
        break
    picked.append(sha[:8])

if conflicts:
    # Use the paths captured at conflict-time (pre-abort). Re-querying here
    # would return nothing because --abort has already cleared the state.
    files_in_conflict = conflicts[0].get("unmerged") or []
    staged_at_conflict = conflicts[0].get("staged") or []

    # Which ticket key does the failing sha belong to? unique[] is a list of
    # (ci_date, sha, subject, ticket_key) — prefix-match against conflict sha.
    conflict_sha_short = conflicts[0]["sha"]
    conflict_ticket = "?"
    conflict_subject = ""
    for _ci, _sha, _sub, _k in unique:
        if _sha.startswith(conflict_sha_short):
            conflict_ticket = _k
            conflict_subject = _sub
            break

    # Which tickets in KEYS have at least one commit still un-applied? Those
    # are the ones worth retrying individually.
    applied_shas = {s.split("(")[0] for s in picked}
    remaining_by_ticket: dict[str, int] = {}
    seen_conflict = False
    for _ci, _sha, _sub, _k in unique:
        if _sha[:8] in applied_shas:
            continue
        if not seen_conflict and _sha[:8] != conflict_sha_short:
            # commits BEFORE the conflict were either picked or skipped
            continue
        seen_conflict = True
        remaining_by_ticket[_k] = remaining_by_ticket.get(_k, 0) + 1

    run(["git", "cherry-pick", "--abort"], cwd=local)
    run(["git", "checkout", current_branch or "-"], cwd=local)
    run(["git", "branch", "-D", new_branch], cwd=local)

    file_list = ", ".join(files_in_conflict[:8])
    if len(files_in_conflict) > 8:
        file_list += f" (+{len(files_in_conflict) - 8} more)"
    remaining_str = ", ".join(
        f"{k}:{n}" for k, n in remaining_by_ticket.items()
    ) or "(none)"

    # Build a copy-pasteable manual-resolution block. If the operator
    # prefers to finish by hand instead of splitting into per-ticket MRs,
    # these exact commands reproduce the combined branch up to the point
    # of conflict and drop them at the editor.
    clean_picked = [s.split("(")[0] for s in picked]
    manual_block = (
        "\nManual finish (copy/paste):\n"
        f"  cd {local}\n"
        f"  git checkout -B {new_branch} origin/main\n"
        + (f"  git cherry-pick -x {' '.join(clean_picked)}\n" if clean_picked else "")
        + f"  git cherry-pick -x {conflict_sha_short}   # resolve conflicts in: {file_list or '(see git status)'}\n"
        "  git add <resolved> && git cherry-pick --continue\n"
        "  git push -u origin HEAD && glab mr create --target-branch main\n"
    )

    # Emit a machine-readable marker (FALLBACK_KEYS=...) so the Telegram
    # handler can render retry buttons for exactly the affected tickets.
    print(
        "ERR: combined cherry-pick conflict.\n"
        f"Ticket: {conflict_ticket} — commit {conflict_sha_short}"
        + (f" ({conflict_subject[:80]})" if conflict_subject else "")
        + "\n"
        f"Conflicting files ({len(files_in_conflict)}): {file_list or '(none — pick failed without unmerged paths, see stderr log)'}\n"
        f"Staged at conflict ({len(staged_at_conflict)}): "
        + (", ".join(staged_at_conflict[:6]) + (f" (+{len(staged_at_conflict) - 6} more)" if len(staged_at_conflict) > 6 else "") or "(none)")
        + "\n"
        f"Applied before abort: {picked or '(none)'} • "
        f"Skipped (already in main): {skipped or '(none)'} • "
        f"Still pending per ticket: {remaining_str}\n"
        f"Detail: {conflicts[0]['detail']}\n"
        + manual_block
        + "Hint: either finish manually with the commands above, or retry each ticket individually below.\n"
        f"FALLBACK_KEYS={','.join(remaining_by_ticket.keys()) or ','.join(KEYS)}"
    )
    sys.exit(1)

if not picked:
    run(["git", "checkout", current_branch or "-"], cwd=local)
    run(["git", "branch", "-D", new_branch], cwd=local)
    print(f"INFO: nothing to cherry-pick — all commits for {', '.join(KEYS)} already on main "
          f"(skipped: {skipped}).")
    sys.exit(2)


# --- 5) push + open MR ---------------------------------------------------
rc, _, err = run(["git", "push", "-u", "origin", new_branch], cwd=local, timeout=240)
if rc != 0:
    print(f"ERR: push failed: {err[:400]}")
    sys.exit(1)

title_keys = " + ".join(KEYS)
title = f"{title_keys}: promote to main ({len(picked)} commit{'s' if len(picked) != 1 else ''})"

desc_lines = [f"Promotes multiple tickets from `{stage}` to `main` in a single MR.\n",
              "Tickets included:"]
for k in KEYS:
    desc_lines.append(f"- {k} ({per_key_counts.get(k, 0)} commit(s) on stage)")
desc_lines.append("\nCherry-picked commits (chronological, oldest first):")
for sha in picked:
    desc_lines.append(f"- {sha}")
if skipped:
    desc_lines.append(f"\nAlready on main (skipped): {', '.join(skipped)}")

# Flag auto-resolved conflicts so the reviewer can double-check those
# files against what stage actually has. Typical cause: the pick required
# earlier stage commits (under different tickets) that weren't in the
# pick set; we took stage's current version of the file.
if auto_resolved:
    desc_lines.append("\n⚠ Auto-resolved conflicts (please review):")
    for ar in auto_resolved:
        files_short = ", ".join(ar["files"][:6])
        if len(ar["files"]) > 6:
            files_short += f" (+{len(ar['files']) - 6} more)"
        strat = ar.get("strategy", "theirs")
        if "stage-head" in strat:
            stale = ar.get("stale_fixed") or []
            stale_short = ", ".join(stale[:4])
            desc_lines.append(
                f"- {ar['sha']} ({ar['ticket']}) via `-X theirs` + "
                f"stage HEAD fixup on: {stale_short}. "
                f"All files touched: {files_short}"
            )
        else:
            desc_lines.append(
                f"- {ar['sha']} ({ar['ticket']}) via `-X theirs`: "
                f"{files_short}"
            )
    desc_lines.append(
        "_All auto-resolved files match `origin/stage` HEAD exactly. "
        "The promote is safe, but please double-check the flagged paths._"
    )
desc = "\n".join(desc_lines)

rc, out, err = run([
    "glab", "mr", "create",
    "--title", title,
    "--description", desc,
    "--source-branch", new_branch,
    "--target-branch", "main",
    "--remove-source-branch",
    "--yes",
], cwd=local, timeout=120)
if rc != 0:
    print(f"ERR: mr create failed: {err[:400]}\n{out[:400]}")
    sys.exit(1)

m = re.search(r"https?://\S+/merge_requests/\d+", out + "\n" + err)
url = m.group(0) if m else ""


# --- 6) persist to promoted.json ----------------------------------------
try:
    promoted_path = os.environ.get("PROMOTED_FILE") or os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "cache", "promoted.json",
    )
    os.makedirs(os.path.dirname(promoted_path), exist_ok=True)
    try:
        promoted = json.load(open(promoted_path))
    except Exception:
        promoted = {}
    combined_hash = hashlib.sha1(",".join(KEYS).encode()).hexdigest()[:8]
    combined_key = f"__combined__{combined_hash}"
    shared_entry = {
        "url": url,
        "branch": new_branch,
        "repo": FORCE_REPO,
        "stage": stage,
        "picked": picked,
        "skipped": skipped,
        "auto_resolved": auto_resolved,
        "ts": int(time.time()),
        "combined_siblings": KEYS,
    }
    promoted[combined_key] = shared_entry
    # Mirror under each individual ticket key so rel_dm:<any> resolves
    for k in KEYS:
        promoted[k] = dict(shared_entry)
    tmp_fd, tmp_path = tempfile.mkstemp(
        dir=os.path.dirname(promoted_path), suffix=".tmp",
    )
    try:
        with os.fdopen(tmp_fd, "w") as tmp_f:
            json.dump(promoted, tmp_f)
        os.replace(tmp_path, promoted_path)
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise
except Exception as e:
    # Non-fatal: MR is created. Just warn.
    print(f"WARN: promoted.json persistence failed: {e}", file=sys.stderr)


ok_lines = [
    f"OK: promoted {title_keys} to main → {url or '(URL not parsed — check glab output)'}",
    f"Branch: {new_branch}",
    f"Picked: {', '.join(picked)}",
]
if skipped:
    ok_lines.append(f"Skipped (already in main): {', '.join(skipped)}")
if auto_resolved:
    ar_summary = "; ".join(
        f"{ar['sha']} ({ar['ticket']}) → {len(ar['files'])} file(s) from stage"
        for ar in auto_resolved
    )
    ok_lines.append(
        f"⚠ Auto-resolved with -X theirs: {ar_summary}. "
        f"Check the MR description for the file list."
    )
print("\n".join(ok_lines))
