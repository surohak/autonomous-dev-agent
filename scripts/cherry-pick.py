#!/usr/bin/env python3
"""Cherry-pick a ticket's stage commits onto a new branch from main, open MR to main.

Strategy: search the repo's stage branch (SSR=stage, blog=staging) for commits whose
message mentions the ticket key, filter to only those not yet on origin/main, then
cherry-pick in chronological order onto a fresh branch from origin/main.

Env: TK_KEY, CONFIG_PATH, [FORCE_REPO=ssr|blog].
Exit: 0 OK, 1 error, 2 nothing to pick (all already in main).
Prints a line starting with 'OK:' / 'INFO:' / 'ERR:' for the handler to route.
"""
import os, json, subprocess, urllib.parse, re, sys, time

TK_KEY = os.environ["TK_KEY"].upper().strip()
config = json.load(open(os.environ["CONFIG_PATH"]))
# v0.2 flat schema kept `repositories` at root; v0.3 moved them under
# projects[0].repositories. Fall back so this script works on both.
_proj0 = (config.get("projects") or [{}])[0] if isinstance(config.get("projects"), list) else {}
repos = config.get("repositories") or _proj0.get("repositories") or {}
force_repo = os.environ.get("FORCE_REPO", "").strip()


def run(cmd, cwd=None, timeout=120):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def find_ticket_commits(slug, meta):
    """Return list of commit SHAs (oldest first) on the stage branch that
    mention TK_KEY in their message and are NOT yet reachable from origin/main.
    Returns (shas, stage_branch) or ([], stage_branch) if none found.
    """
    local = meta.get("localPath")
    stage = meta.get("defaultBranch", "stage")

    if not local or not os.path.isdir(local):
        return None, stage, f"repo path missing: {local}"

    rc, _, err = run(["git", "fetch", "origin", "--prune"], cwd=local, timeout=180)
    if rc != 0:
        return None, stage, f"fetch failed: {err[:200]}"

    rc, _, _ = run(["git", "rev-parse", "--verify", "origin/main"], cwd=local)
    if rc != 0:
        return None, stage, "origin/main not found"

    rc, _, _ = run(["git", "rev-parse", "--verify", f"origin/{stage}"], cwd=local)
    if rc != 0:
        return None, stage, f"origin/{stage} not found"

    # Commits on stage but not on main, whose message contains the ticket key.
    # --regexp-ignore-case handles 'PROJ-832' / 'ua-832'. --extended-regexp lets
    # us match the key as a word (PROJ-832 but not PROJ-8320).
    rc, out, err = run([
        "git", "log",
        f"origin/main..origin/{stage}",
        "--no-merges",
        "--regexp-ignore-case",
        "--extended-regexp",
        "--grep", rf"\b{re.escape(TK_KEY)}\b",
        "--format=%H %ci %s",
        "--reverse",
    ], cwd=local)
    if rc != 0:
        return None, stage, f"git log failed: {err[:200]}"

    shas = []
    for line in out.splitlines():
        parts = line.split(" ", 1)
        if parts and len(parts[0]) == 40:
            shas.append(parts[0])

    return shas, stage, None


# --- 1) pick the repo ---
target = None
if force_repo:
    if force_repo not in repos:
        print(f"ERR: unknown FORCE_REPO '{force_repo}'. Available: {list(repos)}")
        sys.exit(1)
    shas, stage, err = find_ticket_commits(force_repo, repos[force_repo])
    if err:
        print(f"ERR: {force_repo}: {err}")
        sys.exit(1)
    target = (force_repo, repos[force_repo], shas, stage)
else:
    hits = []
    errs = []
    for slug, meta in repos.items():
        shas, stage, err = find_ticket_commits(slug, meta)
        if err:
            errs.append(f"{slug}: {err}")
            continue
        if shas:
            hits.append((slug, meta, shas, stage))
    if not hits:
        joined = " | ".join(errs) if errs else ""
        print(f"ERR: no commits mentioning {TK_KEY} found on stage branch in any configured repo (searched: {', '.join(repos.keys())}).{' ' + joined if joined else ''}")
        sys.exit(1)
    if len(hits) > 1:
        details = ", ".join(f"{slug}({len(shas)})" for slug, _, shas, _ in hits)
        print(f"ERR: commits for {TK_KEY} found in multiple repos [{details}]. Re-run with FORCE_REPO=<slug> to disambiguate.")
        sys.exit(1)
    target = hits[0]

slug, meta, shas, stage = target
local = meta["localPath"]
proj = meta["gitlabProject"]
proj_enc = urllib.parse.quote(proj, safe="")

if not shas:
    print(f"INFO: no commits for {TK_KEY} on origin/{stage} that aren't already on origin/main in {slug}.")
    sys.exit(2)

# Early-exit: a promote-to-main MR for this ticket already exists → don't create a duplicate
# Opened is glab's default. -F json for structured output; fallback to plain-text parsing.
_existing = []
rc, _out, _ = run(["glab", "mr", "list",
                   "--target-branch", "main",
                   "--per-page", "100",
                   "-F", "json"], cwd=local, timeout=60)
if rc == 0 and _out.strip().startswith(("[", "{")):
    try:
        _existing = json.loads(_out)
    except Exception:
        _existing = []
if not _existing:
    rc, _out, _ = run(["glab", "mr", "list",
                       "--target-branch", "main",
                       "--per-page", "100"], cwd=local, timeout=60)
    for _line in (_out or "").splitlines():
        _ln = _line.strip()
        if not _ln.startswith("!"):
            continue
        _iid_part, _, _rest = _ln.partition(" ")
        try:
            _iid = int(_iid_part.lstrip("!"))
        except Exception:
            continue
        _src = ""
        if "->" in _rest:
            _head = _rest.rsplit("(", 1)[-1]
            _src = _head.split("->", 1)[0].strip()
        _existing.append({
            "iid": _iid,
            "title": _rest.rsplit("(", 1)[0].strip(),
            "source_branch": _src,
            "target_branch": "main",
            "web_url": f"https://gitlab.com/{proj}/-/merge_requests/{_iid}",
        })

_match = None
for _m in _existing:
    _title = _m.get("title", "") or ""
    _src = _m.get("source_branch", "") or ""
    if (_m.get("target_branch") or "main") == "main" and (TK_KEY in _title or TK_KEY in _src):
        _match = _m
        break
if _match:
    _url = _match.get("web_url", "")
    # Cache it so [DM Approver] still works from the success notification path
    try:
        promoted_path = os.environ.get("PROMOTED_FILE") or os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "cache", "promoted.json"
        )
        os.makedirs(os.path.dirname(promoted_path), exist_ok=True)
        try:
            promoted = json.load(open(promoted_path))
        except Exception:
            promoted = {}
        promoted[TK_KEY] = {
            "url": _url,
            "branch": _match.get("source_branch", "") or "",
            "repo": slug,
            "stage": stage,
            "ts": int(time.time()),
            "source": "existing-mr-detected-by-cherry",
        }
        json.dump(promoted, open(promoted_path, "w"))
    except Exception:
        pass
    print(f"INFO: {TK_KEY} already has an open promote MR to main: !{_match.get('iid')} → {_url}")
    sys.exit(2)

# --- 2) sanity check working tree ---
rc, out, _ = run(["git", "status", "--porcelain"], cwd=local)
if out.strip():
    print(f"ERR: {slug} working tree is dirty. Commit/stash first.\n{out[:400]}")
    sys.exit(1)

# --- 3) create branch from origin/main ---
ts = time.strftime("%Y%m%d-%H%M%S")
new_branch = f"promote/{TK_KEY}/to-main-{ts}"

rc, _, _ = run(["git", "rev-parse", "--verify", new_branch], cwd=local)
if rc == 0:
    run(["git", "branch", "-D", new_branch], cwd=local)

# Remember current branch to restore on failure
rc, current_branch, _ = run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=local)

rc, _, err = run(["git", "checkout", "-b", new_branch, "origin/main"], cwd=local)
if rc != 0:
    print(f"ERR: branch create failed: {err[:400]}")
    sys.exit(1)

# --- 4) cherry-pick each SHA in chronological order ---
picked, skipped, conflicts = [], [], []
# See cherry-pick-combined.py for the full rationale; mirror the behavior
# so single-ticket picks recover from base-divergence conflicts too.
auto_resolved: list[dict] = []
for sha in shas:
    rc, _, _ = run(["git", "merge-base", "--is-ancestor", sha, "origin/main"], cwd=local)
    if rc == 0:
        skipped.append(sha[:8])
        continue

    rc, parents, _ = run(["git", "rev-list", "--parents", "-n", "1", sha], cwd=local)
    parent_count = max(0, len(parents.split()) - 1)

    # IMPORTANT: we rely ONLY on universally-available git features here.
    # `--empty=drop` (2.32+) and `--skip` (2.25+) would be nicer but break
    # on older git (Homebrew 2.23 seen in the wild), where they make the
    # command exit with a usage banner — looking like a real pick failure
    # but actually meaning "unknown flag". We detect redundant picks after
    # the fact using only `git cherry-pick --abort`.
    cp_cmd = ["git", "cherry-pick", "-x"]
    if parent_count >= 2:
        cp_cmd += ["-m", "1"]
    cp_cmd.append(sha)

    rc, out, err = run(cp_cmd, cwd=local, timeout=120)
    if rc != 0:
        # Key signal is "no unmerged paths" — see cherry-pick-combined.py
        # for the rationale. staged paths may be non-zero on partial
        # applies whose net diff vs HEAD is still empty.
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

        print(
            f"[cherry-pick] {sha[:8]}: pick failed. "
            f"in_progress={in_progress} unmerged={len(unmerged_paths)} "
            f"staged={len(staged_paths)} git_rc={rc}",
            file=sys.stderr,
        )

        if in_progress and not unmerged_paths:
            rc_a, _, _ = run(
                ["git", "cherry-pick", "--abort"],
                cwd=local, timeout=60,
            )
            if rc_a != 0:
                run(["git", "reset", "--hard", "HEAD"], cwd=local, timeout=60)
                try:
                    os.remove(os.path.join(local, ".git", "CHERRY_PICK_HEAD"))
                except FileNotFoundError:
                    pass
                except Exception:
                    pass
            skipped.append(f"{sha[:8]}(empty)")
            continue

        # Real conflict: retry with `-X theirs` before giving up. For a
        # stage→main promote workflow, stage is the source of truth.
        snapshot_unmerged = list(unmerged_paths)
        snapshot_staged = list(staged_paths)

        run(["git", "cherry-pick", "--abort"], cwd=local, timeout=60)

        theirs_cmd = ["git", "cherry-pick", "-x", "-X", "theirs"]
        if parent_count >= 2:
            theirs_cmd += ["-m", "1"]
        theirs_cmd.append(sha)
        rc_t, out_t, err_t = run(theirs_cmd, cwd=local, timeout=180)
        if rc_t == 0:
            # See cherry-pick-combined.py for the rationale of this
            # safety check. `-X theirs` imports the commit-era snapshot,
            # not stage HEAD; if later stage commits reshaped the file we
            # must NOT silently land a stale version on main.
            stale_files: list[str] = []
            for f in snapshot_unmerged:
                rc_cmp, _, _ = run(
                    ["git", "diff", "--exit-code", f"origin/{stage}",
                     "--", f],
                    cwd=local, timeout=30,
                )
                if rc_cmp != 0:
                    stale_files.append(f)

            if not stale_files:
                auto_resolved.append({
                    "sha": sha[:8],
                    "ticket": TK_KEY,
                    "files": snapshot_unmerged,
                    "strategy": "theirs",
                })
                picked.append(f"{sha[:8]}(theirs)")
                print(
                    f"[cherry-pick] {sha[:8]}: auto-resolved with -X theirs "
                    f"on {len(snapshot_unmerged)} file(s): "
                    f"{', '.join(snapshot_unmerged)}",
                    file=sys.stderr,
                )
                continue

            # See cherry-pick-combined.py for the full rationale. Replace
            # stale files with origin/<stage> HEAD and amend — stage is
            # the source of truth for promote-to-main.
            print(
                f"[cherry-pick] {sha[:8]}: -X theirs produced stale content "
                f"vs origin/{stage} for: {', '.join(stale_files)}. Replacing "
                f"with origin/{stage} HEAD and amending.",
                file=sys.stderr,
            )
            for sf in stale_files:
                run(["git", "checkout", f"origin/{stage}", "--", sf],
                    cwd=local, timeout=30)
            run(["git", "add"] + stale_files, cwd=local, timeout=30)
            rc_amend, _, err_amend = run(
                ["git", "commit", "--amend", "--no-edit"],
                cwd=local, timeout=60,
            )
            if rc_amend != 0:
                print(
                    f"[cherry-pick] {sha[:8]}: amend after stage HEAD "
                    f"replacement failed (rc={rc_amend}): "
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

            auto_resolved.append({
                "sha": sha[:8],
                "ticket": TK_KEY,
                "files": snapshot_unmerged,
                "stale_fixed": stale_files,
                "strategy": "theirs+stage-head",
            })
            picked.append(f"{sha[:8]}(stage)")
            print(
                f"[cherry-pick] {sha[:8]}: resolved via -X theirs + "
                f"stage HEAD fixup on {len(stale_files)} file(s): "
                f"{', '.join(stale_files)}",
                file=sys.stderr,
            )
            continue

        print(
            f"[cherry-pick] {sha[:8]}: -X theirs retry also failed "
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
    run(["git", "checkout", current_branch or "-"], cwd=local)
    run(["git", "branch", "-D", new_branch], cwd=local)
    c = conflicts[0]
    unmerged_list = c.get("unmerged") or []
    staged_list = c.get("staged") or []
    files_line = (
        f"Conflicting files ({len(unmerged_list)}): {', '.join(unmerged_list)}"
        if unmerged_list else "Conflicting files: (none reported)"
    )
    staged_line = (
        f"Staged at conflict ({len(staged_list)}): {', '.join(staged_list)}"
        if staged_list else ""
    )
    lines = [
        f"ERR: cherry-pick conflict on {c['sha']} (and `-X theirs` retry also failed).",
        files_line,
    ]
    if staged_line:
        lines.append(staged_line)
    lines.append(
        f"Picked so far: {picked} • Skipped (already in main): {skipped or '(none)'}"
    )
    lines.append(f"Detail: {c['detail']}")
    print("\n".join(lines))
    sys.exit(1)

if not picked:
    run(["git", "checkout", current_branch or "-"], cwd=local)
    run(["git", "branch", "-D", new_branch], cwd=local)
    print(f"INFO: nothing to cherry-pick — all {len(shas)} {TK_KEY} commit(s) already on origin/main "
          f"(skipped: {skipped}).")
    sys.exit(2)

# --- 5) push + open MR ---
rc, _, err = run(["git", "push", "-u", "origin", new_branch], cwd=local, timeout=180)
if rc != 0:
    print(f"ERR: push failed: {err[:400]}")
    sys.exit(1)

title = f"{TK_KEY}: promote to main ({len(picked)} commit{'s' if len(picked) != 1 else ''})"
desc_parts = [
    f"Promotes {TK_KEY} from `{stage}` to `main`.",
    "",
    f"Cherry-picked commits (found on origin/{stage} via `git log --grep={TK_KEY}`):",
    *(f"- {s}" for s in picked),
]
if skipped:
    desc_parts += ["", f"Already on main (skipped): {', '.join(skipped)}"]
if auto_resolved:
    desc_parts += ["", "⚠ Auto-resolved conflicts (stage's version taken — please review):"]
    for ar in auto_resolved:
        files_short = ", ".join(ar["files"][:6])
        if len(ar["files"]) > 6:
            files_short += f" (+{len(ar['files']) - 6} more)"
        desc_parts.append(f"- {ar['sha']} via `-X theirs`: {files_short}")
    desc_parts.append(
        "_Reason: base divergence between `%s` and `main` on these files. "
        "Final contents match stage at the time of promote._" % stage
    )
desc = "\n".join(desc_parts)

rc, out, err = run(["glab", "mr", "create",
                    "--title", title,
                    "--description", desc,
                    "--source-branch", new_branch,
                    "--target-branch", "main",
                    "--remove-source-branch",
                    "--yes"], cwd=local, timeout=90)
if rc != 0:
    print(f"ERR: mr create failed: {err[:400]}\n{out[:400]}")
    sys.exit(1)

m = re.search(r"https?://\S+/merge_requests/\d+", out + "\n" + err)
url = m.group(0) if m else ""

# Persist the promoted-MR info so the Telegram handler can build the DM button.
try:
    cache_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "cache")
    os.makedirs(cache_dir, exist_ok=True)
    promoted_path = os.path.join(cache_dir, "promoted.json")
    try:
        promoted = json.load(open(promoted_path))
    except Exception:
        promoted = {}
    promoted[TK_KEY] = {
        "url": url,
        "branch": new_branch,
        "repo": slug,
        "stage": stage,
        "picked": picked,
        "skipped": skipped,
        "auto_resolved": auto_resolved,
        "ts": int(time.time()),
    }
    json.dump(promoted, open(promoted_path, "w"))
except Exception:
    pass

ok_lines = [
    f"OK: {TK_KEY} promoted from {slug}/{stage} → {url or '(URL not parsed — check glab output)'}",
    f"Branch: {new_branch}",
    f"Picked: {', '.join(picked)}",
]
if skipped:
    ok_lines.append(f"Skipped (already in main): {', '.join(skipped)}")
if auto_resolved:
    ar_summary = "; ".join(
        f"{ar['sha']} → {len(ar['files'])} file(s) from stage"
        for ar in auto_resolved
    )
    ok_lines.append(
        f"⚠ Auto-resolved with -X theirs: {ar_summary}. "
        f"Check the MR description for the file list."
    )
print("\n".join(ok_lines))
