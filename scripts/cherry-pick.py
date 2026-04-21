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
repos = config.get("repositories", {})
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
    # --regexp-ignore-case handles 'UA-832' / 'ua-832'. --extended-regexp lets
    # us match the key as a word (UA-832 but not UA-8320).
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
                   "--per-page", "100", "--all",
                   "-F", "json"], cwd=local, timeout=60)
if rc == 0 and _out.strip().startswith(("[", "{")):
    try:
        _existing = json.loads(_out)
    except Exception:
        _existing = []
if not _existing:
    rc, _out, _ = run(["glab", "mr", "list",
                       "--target-branch", "main",
                       "--per-page", "100", "--all"], cwd=local, timeout=60)
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
    # Cache it so [DM Lei] still works from the success notification path
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
for sha in shas:
    rc, _, _ = run(["git", "merge-base", "--is-ancestor", sha, "origin/main"], cwd=local)
    if rc == 0:
        skipped.append(sha[:8])
        continue

    rc, parents, _ = run(["git", "rev-list", "--parents", "-n", "1", sha], cwd=local)
    parent_count = max(0, len(parents.split()) - 1)

    cp_cmd = ["git", "cherry-pick", "-x"]
    if parent_count >= 2:
        cp_cmd += ["-m", "1"]
    cp_cmd.append(sha)

    rc, out, err = run(cp_cmd, cwd=local, timeout=120)
    if rc != 0:
        conflicts.append({"sha": sha[:8], "detail": (err or out)[:300]})
        run(["git", "cherry-pick", "--abort"], cwd=local)
        break
    picked.append(sha[:8])

if conflicts:
    run(["git", "checkout", current_branch or "-"], cwd=local)
    run(["git", "branch", "-D", new_branch], cwd=local)
    print(f"ERR: cherry-pick conflict on {conflicts[0]['sha']}. "
          f"Picked so far: {picked}. Skipped (already in main): {skipped}.\n"
          f"Detail: {conflicts[0]['detail']}")
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
desc = (f"Promotes {TK_KEY} from `{stage}` to `main`.\n\n"
        f"Cherry-picked commits (found on origin/{stage} via `git log --grep={TK_KEY}`):\n"
        + "\n".join(f"- {s}" for s in picked)
        + (f"\n\nAlready on main (skipped): {', '.join(skipped)}" if skipped else ""))

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
        "ts": int(time.time()),
    }
    json.dump(promoted, open(promoted_path, "w"))
except Exception:
    pass

print(f"OK: {TK_KEY} promoted from {slug}/{stage} → {url or '(URL not parsed — check glab output)'}\n"
      f"Branch: {new_branch}\n"
      f"Picked: {', '.join(picked)}"
      + (f"\nSkipped (already in main): {', '.join(skipped)}" if skipped else ""))
