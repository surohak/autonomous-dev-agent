#!/usr/bin/env python3
"""
scripts/tempo-suggest.py

Reads cache/time-log.jsonl (captured by lib/timelog.sh) and produces per-day,
per-ticket worklog suggestions for Tempo. The algorithm is intentionally
transparent — a human can look at a suggestion and understand exactly which
events contributed and why.

FORMULA (v1)

    dev_time(ticket, day) =
        sum of (agent_end.ts - agent_start.ts)
        for all runs where
            manual == 1                            # scheduled runs are auto
            mode in DEV_MODES                      # implementation/ci-fix/…
            ticket == <this ticket>
            start_ts in local-day(day)

    review_time(ticket, day) =
        sum of (close_event.ts - review_ready.ts)
        for all MRs of this ticket on this day,
        where close_event in {mr_approved, review_sent_to_dev, review_skipped}
        and start_ts in local-day(day).
        A review_ready without a closer on the same day is *ignored* (we wait
        for the next day's data — no point suggesting open-ended time).

Both totals are rounded to the nearest 15 min (900 s). Minimum 15 min
(we don't suggest 0/5/10-min slivers). Caps: 8h dev, 4h review per day.

Existing Tempo worklogs by the same author for the same (issue, day) are
subtracted from the suggestion — so re-running this script after you've
already accepted a card is idempotent.

USAGE

    python3 scripts/tempo-suggest.py                 # yesterday, human output
    python3 scripts/tempo-suggest.py --date 2026-04-15
    python3 scripts/tempo-suggest.py --week          # last 7 calendar days
    python3 scripts/tempo-suggest.py --json          # machine-readable

Zero suggestions → exit 0 with empty output, so it's safe to wire into the
daily digest. Network failures (Tempo unreachable) produce suggestions WITHOUT
the existing-logs subtraction and flag `"tempo_dedup": false` so the Telegram
card can warn you.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

DEV_MODES = {"implementation", "ci-fix", "retry", "feedback"}
REVIEW_CLOSE_EVENTS = {"mr_approved", "review_sent_to_dev", "review_skipped"}

QUARTER = 15 * 60  # 900 s
MIN_SUGGESTION = QUARTER
DEV_CAP = 8 * 3600
REVIEW_CAP = 4 * 3600

# ---------- helpers ---------------------------------------------------------


def _round_quarter(seconds: int) -> int:
    # Round to nearest 15 min, with 0 staying 0 (don't bump trivial noise up to 15).
    if seconds <= 0:
        return 0
    return int(round(seconds / QUARTER) * QUARTER)


def _parse_ts(s: str) -> dt.datetime:
    # Our timelog writes ...Z; datetime.fromisoformat accepts that from 3.11+.
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    return dt.datetime.fromisoformat(s)


def _local_date(ts: dt.datetime, tz: ZoneInfo) -> dt.date:
    return ts.astimezone(tz).date()


def _load_events(path: Path) -> list[dict]:
    if not path.exists():
        return []
    out = []
    with path.open() as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                # Tolerate a corrupt line (shouldn't happen with flock, but
                # don't let one bad line kill the report).
                continue
    return out


def _pair_runs(events: list[dict]) -> list[dict]:
    """Match agent_start → agent_end by run_id. Returns a list of dicts with
    keys: ticket, mode, manual, start, end, seconds. Orphan starts (no end
    observed) get seconds=None and are flagged incomplete."""
    starts: dict[str, dict] = {}
    pairs: list[dict] = []
    for e in events:
        rid = e.get("run_id")
        if not rid:
            continue
        if e["type"] == "agent_start":
            starts[rid] = e
        elif e["type"] == "agent_end":
            s = starts.pop(rid, None)
            if not s:
                continue
            try:
                secs = int((_parse_ts(e["ts"]) - _parse_ts(s["ts"])).total_seconds())
            except Exception:
                secs = None
            pairs.append({
                "ticket":  s.get("ticket", "--"),
                "mode":    s.get("mode", "unknown"),
                "manual":  int(s.get("manual", 0)) == 1,
                "mr_iid":  s.get("mr_iid", "--"),
                "start":   s["ts"],
                "end":     e["ts"],
                "seconds": secs,
                "exit":    e.get("exit", "?"),
            })
    # Orphan starts: keep them so the user knows about crashed runs
    for rid, s in starts.items():
        pairs.append({
            "ticket":  s.get("ticket", "--"),
            "mode":    s.get("mode", "unknown"),
            "manual":  int(s.get("manual", 0)) == 1,
            "mr_iid":  s.get("mr_iid", "--"),
            "start":   s["ts"],
            "end":     None,
            "seconds": None,
            "exit":    "orphan",
        })
    return pairs


def _pair_reviews(events: list[dict]) -> list[dict]:
    """Match review_ready → next closer with same mr_iid. Orphans discarded
    (we can't compute a duration without a closer)."""
    open_reviews: dict[str, dict] = {}   # mr_iid → ready event
    pairs: list[dict] = []
    for e in events:
        mr = str(e.get("mr_iid", ""))
        if not mr or mr == "--":
            continue
        et = e["type"]
        if et == "review_ready":
            open_reviews[mr] = e
        elif et in REVIEW_CLOSE_EVENTS:
            ready = open_reviews.pop(mr, None)
            if not ready:
                continue
            try:
                secs = int((_parse_ts(e["ts"]) - _parse_ts(ready["ts"])).total_seconds())
            except Exception:
                continue
            pairs.append({
                "ticket":  ready.get("ticket") or e.get("ticket", "--"),
                "mr_iid":  mr,
                "start":   ready["ts"],
                "end":     e["ts"],
                "close":   et,
                "seconds": max(secs, 0),
            })
    return pairs


# ---------- Tempo integration ---------------------------------------------


def _fetch_existing_totals(
    tempo_token: str,
    account_id: str,
    dates: list[dt.date],
) -> tuple[dict[tuple[str, str], int], bool]:
    """Returns ({(issueKey, YYYY-MM-DD): seconds_already_logged}, ok_flag).
    ok_flag=False if Tempo couldn't be reached — caller should flag the card."""
    if not tempo_token or not account_id or not dates:
        return {}, False
    try:
        import urllib.request
        import urllib.error

        body = json.dumps({
            "authorIds": [account_id],
            "from":      min(dates).isoformat(),
            "to":        max(dates).isoformat(),
        }).encode()
        req = urllib.request.Request(
            "https://api.tempo.io/4/worklogs/search",
            data=body,
            headers={
                "Authorization": f"Bearer {tempo_token}",
                "Content-Type":  "application/json",
                "Accept":        "application/json",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=20) as resp:
            d = json.loads(resp.read())
    except Exception as exc:
        print(f"WARN: Tempo fetch failed: {exc}", file=sys.stderr)
        return {}, False

    # Tempo returns worklogs with `issue.id` (numeric) — we also need the key.
    # v4 response has `issue.key` in most setups; fall back to id if not.
    totals: dict[tuple[str, str], int] = defaultdict(int)
    for w in d.get("results", []) or []:
        issue = (w.get("issue") or {})
        key = issue.get("key") or str(issue.get("id", ""))
        date = w.get("startDate", "")
        secs = int(w.get("timeSpentSeconds", 0))
        if key and date:
            totals[(key, date)] += secs
    return dict(totals), True


# ---------- Main suggestion algorithm --------------------------------------


def suggest(
    events: list[dict],
    day: dt.date,
    tz: ZoneInfo,
    existing_totals: dict[tuple[str, str], int],
    tempo_ok: bool,
) -> list[dict]:
    run_pairs = _pair_runs(events)
    review_pairs = _pair_reviews(events)

    dev_by_ticket: dict[str, int] = defaultdict(int)
    dev_details: dict[str, list[dict]] = defaultdict(list)
    for p in run_pairs:
        if p["seconds"] is None:
            continue
        if not p["manual"]:
            continue
        if p["mode"] not in DEV_MODES:
            continue
        if p["ticket"] in ("--", "", None):
            continue
        if _local_date(_parse_ts(p["start"]), tz) != day:
            continue
        dev_by_ticket[p["ticket"]] += p["seconds"]
        dev_details[p["ticket"]].append({
            "mode":    p["mode"],
            "start":   p["start"],
            "seconds": p["seconds"],
            "mr_iid":  p["mr_iid"],
        })

    review_by_ticket: dict[str, int] = defaultdict(int)
    review_details: dict[str, list[dict]] = defaultdict(list)
    for p in review_pairs:
        if p["ticket"] in ("--", "", None):
            continue
        if _local_date(_parse_ts(p["start"]), tz) != day:
            continue
        review_by_ticket[p["ticket"]] += p["seconds"]
        review_details[p["ticket"]].append({
            "mr_iid":  p["mr_iid"],
            "close":   p["close"],
            "start":   p["start"],
            "end":     p["end"],
            "seconds": p["seconds"],
        })

    tickets = sorted(set(dev_by_ticket) | set(review_by_ticket))
    day_str = day.isoformat()
    suggestions = []
    for t in tickets:
        dev_raw = dev_by_ticket.get(t, 0)
        rev_raw = review_by_ticket.get(t, 0)
        dev = min(_round_quarter(dev_raw), DEV_CAP)
        rev = min(_round_quarter(rev_raw), REVIEW_CAP)
        total = dev + rev

        existing = existing_totals.get((t, day_str), 0)
        remaining = max(total - existing, 0)
        # Remaining rounded down to quarter so we don't over-suggest after a
        # partial manual log of, say, 0:37 mins.
        remaining = (remaining // QUARTER) * QUARTER

        if remaining < MIN_SUGGESTION:
            # Either nothing meaningful captured OR already logged enough.
            # Still include in --json output for debugging, but flag skip.
            skip_reason = "below 15min" if total < MIN_SUGGESTION else "already logged"
        else:
            skip_reason = None

        desc_parts = []
        dev_count = len(dev_details.get(t, []))
        rev_count = len(review_details.get(t, []))
        if dev_count:
            desc_parts.append(f"{dev_count} dev run{'s' if dev_count > 1 else ''}")
        if rev_count:
            desc_parts.append(f"{rev_count} review{'s' if rev_count > 1 else ''}")
        description = "Agent-assisted work (" + ", ".join(desc_parts) + ")" if desc_parts else "Agent-assisted work"

        suggestions.append({
            "ticket":           t,
            "date":             day_str,
            "suggested_seconds": remaining,
            "raw_seconds":       total,
            "dev_seconds":       dev,
            "review_seconds":    rev,
            "already_logged_seconds": existing,
            "tempo_dedup":       tempo_ok,
            "skip":              skip_reason,
            "description":       description,
            "dev_runs":          dev_details.get(t, []),
            "review_rounds":     review_details.get(t, []),
        })

    return suggestions


# ---------- CLI ------------------------------------------------------------


def _fmt(secs: int) -> str:
    if secs <= 0:
        return "0m"
    h, m = divmod(secs // 60, 60)
    if h and m: return f"{h}h{m:02d}m"
    if h:       return f"{h}h"
    return f"{m}m"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--date", help="YYYY-MM-DD (default: yesterday local)")
    ap.add_argument("--week", action="store_true", help="Last 7 days instead of one")
    ap.add_argument("--json", action="store_true", help="Emit JSON on stdout")
    ap.add_argument("--log-file", default=os.environ.get("TIME_LOG_FILE", ""),
                    help="Override time-log.jsonl path")
    ap.add_argument("--include-skipped", action="store_true",
                    help="Include suggestions below the 15-min floor in output")
    ap.add_argument("--ticket", default="",
                    help="Filter to a single ticket key (e.g. UA-997)")
    ap.add_argument("--respect-user-skips", action="store_true",
                    help="Drop suggestions the user previously tm_skip'd (cache/tempo-skipped.json)")
    args = ap.parse_args()

    tz_name = os.environ.get("WORK_TZ", "Europe/Berlin")
    try:
        tz = ZoneInfo(tz_name)
    except Exception:
        tz = ZoneInfo("UTC")

    today_local = dt.datetime.now(tz).date()
    if args.date:
        try:
            anchor = dt.date.fromisoformat(args.date)
        except ValueError:
            print(f"invalid --date: {args.date}", file=sys.stderr)
            return 2
    else:
        anchor = today_local - dt.timedelta(days=1)

    days = [anchor - dt.timedelta(days=i) for i in range(7)] if args.week else [anchor]

    log_path = Path(args.log_file) if args.log_file else Path(
        os.environ.get("CACHE_DIR",
                       os.path.expanduser("~/.cursor/skills/autonomous-dev-agent/cache"))
    ) / "time-log.jsonl"

    events = _load_events(log_path)

    existing, tempo_ok = _fetch_existing_totals(
        os.environ.get("TEMPO_API_TOKEN", ""),
        os.environ.get("JIRA_ACCOUNT_ID", ""),
        days,
    )

    all_suggestions: list[dict] = []
    for d in sorted(days):
        all_suggestions.extend(suggest(events, d, tz, existing, tempo_ok))

    if args.ticket:
        wanted = args.ticket.strip().upper()
        all_suggestions = [s for s in all_suggestions if s["ticket"].upper() == wanted]

    if args.respect_user_skips:
        # Drop (ticket,date) pairs the user already dismissed via tm_skip.
        skipped_path = Path(
            os.environ.get("CACHE_DIR",
                           os.path.expanduser("~/.cursor/skills/autonomous-dev-agent/cache"))
        ) / "tempo-skipped.json"
        skipped_set: set[tuple[str, str]] = set()
        if skipped_path.exists():
            try:
                raw = json.loads(skipped_path.read_text() or "{}")
                for key in raw.keys():
                    # key format: "UA-997:2026-04-15"
                    if ":" in key:
                        t, d2 = key.split(":", 1)
                        skipped_set.add((t, d2))
            except Exception:
                pass
        all_suggestions = [
            s for s in all_suggestions
            if (s["ticket"], s["date"]) not in skipped_set
        ]

    if not args.include_skipped:
        all_suggestions = [s for s in all_suggestions if not s["skip"]]

    if args.json:
        json.dump(all_suggestions, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return 0

    if not all_suggestions:
        print(f"No suggestions for {anchor.isoformat()}"
              + (" (last 7 days)" if args.week else "")
              + ". Either nothing captured, already fully logged, or no work matched the formula.")
        return 0

    print(f"Tempo suggestions (source: {log_path.name}, dedup with Tempo: {tempo_ok})")
    print()
    for s in all_suggestions:
        flag = " [skipped: " + s["skip"] + "]" if s["skip"] else ""
        print(f"  {s['date']}  {s['ticket']:<10}  suggest {_fmt(s['suggested_seconds'])}"
              f"  (dev {_fmt(s['dev_seconds'])}, review {_fmt(s['review_seconds'])},"
              f" already {_fmt(s['already_logged_seconds'])}){flag}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
