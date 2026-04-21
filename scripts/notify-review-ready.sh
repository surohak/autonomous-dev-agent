#!/bin/bash
# Notify user in Telegram that an agent review is ready.
# Sends:
#   1. Summary message with MR-level buttons (Show comments / Approve / Open / Skip)
#   2. If comments > 0: one message per pending comment with per-comment buttons
#      (Post / Edit / Discuss w/ AI / Skip)
#
# Usage: notify-review-ready.sh <MR_IID>
# Env:   TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID (loaded from secrets.env by env.sh)

set -uo pipefail

MR_IID="${1:-}"
if [ -z "$MR_IID" ]; then
  echo "Usage: $0 <MR_IID>" >&2
  exit 1
fi

# --- Shared bootstrap ------------------------------------------------------
SKILL_DIR="${SKILL_DIR:-$HOME/.cursor/skills/autonomous-dev-agent}"
source "$SKILL_DIR/scripts/lib/env.sh"
source "$SKILL_DIR/scripts/lib/telegram.sh"
source "$SKILL_DIR/scripts/lib/timelog.sh"
# ---------------------------------------------------------------------------

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
  echo "ERROR: TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID not set" >&2
  exit 1
fi

RFILE=$(ls -t "$REVIEWS_DIR/${MR_IID}-"*.json 2>/dev/null | grep -v discussions | grep -v stub | head -1)
if [ -z "$RFILE" ] || [ ! -s "$RFILE" ]; then
  echo "ERROR: no review cache for MR $MR_IID" >&2
  exit 1
fi

# --- 1) Summary + MR-level keyboard ---
read -r TICKET_KEY AUTHOR MR_URL VERDICT N_PENDING N_TOTAL ROUND PRIOR_SHA < <(
  RFILE="$RFILE" python3 <<'PY'
import json, os
r = json.load(open(os.environ["RFILE"]))
cs = r.get("comments", [])
pending = [c for c in cs if c.get("status","pending") == "pending"]
round_n = r.get("round") or 1
prior_sha = (r.get("prior_review_sha") or "-")[:8] or "-"
print(r.get("ticket_key",""), r.get("author",""), r.get("mr_url",""),
      r.get("verdict","needs-comments"), len(pending), len(cs), round_n, prior_sha)
PY
)

SUMMARY=$(RFILE="$RFILE" python3 -c "
import json, os
r = json.load(open(os.environ['RFILE']))
print((r.get('summary','') or '').strip()[:900])
")

# Re-review context line (only non-empty when round > 1)
REREVIEW_CTX=$(RFILE="$RFILE" python3 <<'PY'
import json, os
r = json.load(open(os.environ["RFILE"]))
round_n = r.get("round") or 1
if round_n <= 1:
    print(""); raise SystemExit
prior_sha = (r.get("prior_review_sha") or "")[:8]
head_sha  = (r.get("diff_refs", {}).get("head_sha") or "")[:8]
pcs = r.get("prior_comments_status") or []
addressed = sum(1 for p in pcs if p.get("status") in ("addressed","addressed-by-reply","obsolete"))
still     = sum(1 for p in pcs if p.get("status") == "still_valid")
total     = len(pcs)
lines = [f"Re-review (round {round_n})"]
if prior_sha and head_sha:
    lines.append(f"Prior: {prior_sha} → Now: {head_sha}")
if total:
    lines.append(f"Prior comments: {addressed}/{total} addressed, {still} still valid")
print("\n".join(lines))
PY
)

if [ "$VERDICT" = "lgtm" ]; then
  if [ "$ROUND" -gt 1 ] 2>/dev/null; then
    HEADER="[$TICKET_KEY] !$MR_IID by $AUTHOR — LGTM (round $ROUND)"
  else
    HEADER="[$TICKET_KEY] !$MR_IID by $AUTHOR — LGTM"
  fi
  KB="[[{\"text\":\"Approve MR\",\"callback_data\":\"rv_approve:$MR_IID\"},{\"text\":\"Open in GitLab\",\"url\":\"$MR_URL\"}],[{\"text\":\"Re-review\",\"callback_data\":\"rv_reviewnow:$MR_IID\"},{\"text\":\"Skip for now\",\"callback_data\":\"rv_skipmr:$MR_IID\"}]]"
else
  if [ "$ROUND" -gt 1 ] 2>/dev/null; then
    HEADER="[$TICKET_KEY] !$MR_IID by $AUTHOR — $N_PENDING/$N_TOTAL new (round $ROUND)"
  else
    HEADER="[$TICKET_KEY] !$MR_IID by $AUTHOR — $N_PENDING/$N_TOTAL comments pending"
  fi
  KB="[[{\"text\":\"Show comments ($N_PENDING)\",\"callback_data\":\"rv_show:$MR_IID\"},{\"text\":\"Open in GitLab\",\"url\":\"$MR_URL\"}],[{\"text\":\"Send to dev\",\"callback_data\":\"rv_sendtodev:$MR_IID\"},{\"text\":\"Approve MR\",\"callback_data\":\"rv_approve:$MR_IID\"}],[{\"text\":\"Skip for now\",\"callback_data\":\"rv_skipmr:$MR_IID\"}]]"
fi

if [ -n "$REREVIEW_CTX" ]; then
  MSG_BODY="Review ready
$HEADER

$REREVIEW_CTX

$SUMMARY"
else
  MSG_BODY="Review ready
$HEADER

$SUMMARY"
fi

tg_inline "$MSG_BODY" "$KB"

# Tempo capture: the moment an agent-produced review is handed to me. Marks
# the start of "my review time" window that closes on mr_approved (or
# rv_skipmr / rv_sendtodev, both handled in telegram-handler.sh).
tl_emit review_ready \
  ticket="$TICKET_KEY" \
  mr_iid="$MR_IID" \
  verdict="$VERDICT" \
  round="$ROUND" \
  pending="$N_PENDING" \
  total="$N_TOTAL"

# --- 2) One message per pending comment with per-comment buttons ---
if [ "$N_PENDING" -gt 0 ] 2>/dev/null; then
  RFILE="$RFILE" MR_IID="$MR_IID" python3 <<'PY' | while IFS=$'\t' read -r CIDX TEXT KB; do
import json, os
r = json.load(open(os.environ["RFILE"]))
mr_iid = os.environ["MR_IID"]
for idx, c in enumerate(r.get("comments", [])):
    if c.get("status","pending") != "pending":
        continue
    sev = c.get("severity","")
    cat = c.get("category","")
    fpath = c.get("file","")
    line = c.get("line_new") or c.get("line_old") or ""
    body = (c.get("body","") or "").strip()
    if len(body) > 900:
        body = body[:900] + "…"
    text = f"[{idx}] {sev} | {cat}\n{fpath}:{line}\n\n{body}"
    kb = json.dumps([
        [{"text":"Post","callback_data":f"rv_post:{mr_iid}:{idx}"},
         {"text":"Edit","callback_data":f"rv_edit:{mr_iid}:{idx}"}],
        [{"text":"Discuss with AI","callback_data":f"rv_discuss:{mr_iid}:{idx}"},
         {"text":"Skip","callback_data":f"rv_skipc:{mr_iid}:{idx}"}]
    ])
    text_tsv = text.replace("\t"," ").replace("\n","\\n")
    print(f"{idx}\t{text_tsv}\t{kb}")
PY
    TEXT_DEC=$(printf '%b' "$TEXT")
    tg_inline "$TEXT_DEC" "$KB"
  done
fi

echo "Notification sent for MR $MR_IID."
