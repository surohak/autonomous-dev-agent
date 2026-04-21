#!/bin/bash
# SwiftBar plugin for autonomous-dev-agent.
#
# Install: symlinked into ~/Library/Application Support/SwiftBar/Plugins/
# by bin/install.sh when SwiftBar is detected. The file name controls the
# refresh interval: dev-agent.30s.sh = every 30 seconds.
#
# Everything identity-specific is read from the agent's own config at runtime:
#   - owner display name  ← config.json .owner.name
#   - launchd label prefix ← AGENT_LABEL_PREFIX env or com.$USER
#   - skill path          ← SKILL_DIR env or ~/.cursor/skills/autonomous-dev-agent
#
# Override anything by setting env vars in SwiftBar's plugin settings, e.g.:
#   SKILL_DIR=/custom/path swiftbar://…
#
# Refresh logic is deliberately cheap — this script runs every 30s on every
# user, so it must not call the network, fork cursor-agent, or touch cache/.

SKILL_DIR="${SKILL_DIR:-$HOME/.cursor/skills/autonomous-dev-agent}"
CTL="$SKILL_DIR/scripts/ctl.sh"
LOG_DIR="$SKILL_DIR/logs"
LABEL_PREFIX="${AGENT_LABEL_PREFIX:-com.${USER:-user}}"

AGENT_LABEL="${LABEL_PREFIX}.autonomous-dev-agent"
WATCHER_LABEL="${LABEL_PREFIX}.dev-agent-watcher"
TELEGRAM_LABEL="${LABEL_PREFIX}.dev-agent-telegram"
DIGEST_LABEL="${LABEL_PREFIX}.dev-agent-digest"

# --- Title (owner name from config, fallback to "Dev Agent") ---------------
TITLE_NAME="Dev Agent"
if [[ -f "$SKILL_DIR/config.json" ]] && command -v python3 >/dev/null 2>&1; then
  TITLE_NAME=$(python3 -c '
import json, sys
try:
    c = json.load(open(sys.argv[1]))
    n = (c.get("owner") or {}).get("name") or ""
    n = n.split()[0] if n else ""
    print(f"{n} Dev Agent" if n else "Dev Agent")
except Exception:
    print("Dev Agent")
' "$SKILL_DIR/config.json" 2>/dev/null || echo "Dev Agent")
fi

# --- Service health (any -> green, none -> gray) ---------------------------
svc_loaded() { launchctl list 2>/dev/null | grep -q "[[:space:]]$1$"; }

loaded=0
for l in "$AGENT_LABEL" "$WATCHER_LABEL" "$TELEGRAM_LABEL" "$DIGEST_LABEL"; do
  svc_loaded "$l" && loaded=$((loaded + 1))
done

if   (( loaded == 4 )); then ICON="🤖"; STATUS="Running"; COLOR="green"
elif (( loaded > 0  )); then ICON="🤖"; STATUS="Partial ($loaded/4)"; COLOR="orange"
else                         ICON="⏸";  STATUS="Stopped";            COLOR="gray"
fi

# --- Last run: newest log excluding telegram/digest noise -------------------
LAST_RUN="never"; RESULT=""; LAST_EXIT="?"
latest_log=""
if [[ -d "$LOG_DIR" ]]; then
  latest_log=$(ls -t "$LOG_DIR"/*.log 2>/dev/null | grep -v telegram | grep -v digest | head -1)
fi
if [[ -n "$latest_log" ]]; then
  log_epoch=$(stat -f "%m" "$latest_log" 2>/dev/null || echo 0)
  now_epoch=$(date +%s)
  diff=$(( now_epoch - log_epoch ))
  if   (( diff < 60   )); then LAST_RUN="just now"
  elif (( diff < 3600 )); then LAST_RUN="$(( diff / 60 )) min ago"
  elif (( diff < 86400)); then LAST_RUN="$(( diff / 3600 )) hr ago"
  else                         LAST_RUN="$(( diff / 86400 )) days ago"
  fi

  # Best-effort exit-code parse. run-agent.sh logs "exit code: <n>" at tail.
  LAST_EXIT=$(tail -20 "$latest_log" 2>/dev/null | grep -oE 'exit[[:space:]]code:?[[:space:]]*[0-9]+' | tail -1 | grep -oE '[0-9]+$' || echo "?")
  case "$LAST_EXIT" in
    0)   RESULT="✅" ;;
    "")  RESULT="⏳"; LAST_EXIT="?" ;;
    "?") RESULT="⏳" ;;
    *)   RESULT="❌" ;;
  esac
fi

# --- Menu bar title --------------------------------------------------------
echo "$ICON"

# --- Dropdown --------------------------------------------------------------
echo "---"
echo "$TITLE_NAME | size=14"
echo "Status: $STATUS | color=$COLOR"
if [[ "$LAST_RUN" == "never" ]]; then
  echo "Last run: never"
else
  suffix=""; [[ "$LAST_EXIT" != "?" ]] && suffix=" (exit $LAST_EXIT)"
  echo "Last run: ${RESULT} ${LAST_RUN}${suffix}"
fi
echo "---"

# Per-service rows. SwiftBar renders as monospace-ish; pad to align.
# Each row is now clickable: unloaded rows fire `ctl.sh svc-start <name>`,
# loaded rows expose a nested submenu with Restart / Stop. This means a
# user who sees "telegram ❌ unloaded" can fix it in one tap from the menu
# bar instead of opening Terminal and running launchctl by hand — and it
# works because SwiftBar shells out in the user's GUI session domain,
# which has the permissions the Cursor-sandboxed shell lacks.
#
# Descriptions under each row explain what the service actually does. This
# matters because "telegram" in particular is non-obvious: sending
# Telegram messages works without it (tg_send is a standalone curl), but
# every inline button (reviewer picker, /start, tk_later, tm_log, etc.)
# is dead until this daemon is polling for updates.
svc_row() {
  local short="$1" full="$2" desc="$3"
  if svc_loaded "$full"; then
    printf "%-11s ✅ loaded\n" "$short"
    echo "-- $desc | color=gray"
    echo "-- 🔄 Restart | bash=$CTL param1=svc-restart param2=$short terminal=false refresh=true"
    echo "-- ⏹ Stop    | bash=$CTL param1=svc-stop    param2=$short terminal=false refresh=true"
  else
    printf "%-11s ❌ unloaded | color=orange\n" "$short"
    echo "-- $desc | color=gray"
    echo "-- ▶ Start | bash=$CTL param1=svc-start param2=$short terminal=false refresh=true"
  fi
}
svc_row "agent"    "$AGENT_LABEL"    "Runs run-agent.sh every ~30 min during work hours — autonomously picks up Jira tickets, opens MRs."
svc_row "watcher"  "$WATCHER_LABEL"  "Polls Jira + GitLab every 2 min for status changes, new comments, CI failures. Sends Telegram notifications."
svc_row "telegram" "$TELEGRAM_LABEL" "Long-polling daemon for Telegram callbacks. REQUIRED for any inline button (reviewer picker, /start, /tempo, tk_later, etc.)."
svc_row "digest"   "$DIGEST_LABEL"   "Posts the end-of-day summary to Telegram at the time configured in config.json → time.dailyDigest."
echo "---"

# --- v0.5.0 — Queue snapshot (read-only, zero-network) ---------------------
# watcher.sh drops cache/global/queue-snapshot.json each tick. Shape:
#   { "<project-id>": { "todo": [ {key,summary,priority,...}, ... ], "updated_at": ts }, ... }
# We render a compact per-project count plus the top 5 priority tickets.
QUEUE_SNAP=""
for candidate in \
    "$SKILL_DIR/cache/global/queue-snapshot.json" \
    "$SKILL_DIR/cache/queue-snapshot.json"; do
  if [[ -f "$candidate" ]]; then QUEUE_SNAP="$candidate"; break; fi
done

if [[ -n "$QUEUE_SNAP" ]]; then
  QUEUE_OUT=$(python3 - "$QUEUE_SNAP" <<'PY' 2>/dev/null
import json, sys, time
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
if not isinstance(d, dict) or not d:
    sys.exit(0)

# Priority -> weight (same table as lib/queue.sh).
WEIGHT = {"highest":5,"p0":5,"critical":5,"blocker":5,"urgent":5,
         "high":4,"p1":4,"major":4,
         "medium":3,"p2":3,"normal":3,"default":3,
         "low":2,"p3":2,"minor":2,
         "lowest":1,"p4":1,"trivial":1}
def w(p): return WEIGHT.get((p or "medium").lower(), 3)

projects = sorted([k for k in d.keys() if not k.startswith("_")])
if not projects:
    sys.exit(0)

totals = {}
flat = []
for p in projects:
    items = (d.get(p) or {}).get("todo") or []
    totals[p] = len(items)
    for it in items:
        flat.append((w(it.get("priority")), p, it))

print("Queue snapshot")
for p in projects:
    print(f"  {p}: {totals[p]} open | font=Menlo")
print("---")

# Top 5 across projects by priority weight.
flat.sort(key=lambda t: -t[0])
shown = 0
for weight, proj, it in flat[:5]:
    key = it.get("key","?")
    summ = (it.get("summary","") or "")[:60].replace("|"," ").replace("\n"," ")
    prio = it.get("priority","?")
    print(f"  {key} [{prio}] {summ} | font=Menlo size=11 length=80")
    shown += 1
if shown == 0:
    print("  (no open tickets) | color=gray")

# Quick-nav entries.
print("---")
PY
)
  [[ -n "$QUEUE_OUT" ]] && printf '%s\n' "$QUEUE_OUT"
fi

# --- Actions ---------------------------------------------------------------
if [[ -x "$CTL" ]]; then
  # Smart top-level action: "Start all" when nothing is running, "Start
  # missing" when partially running (the previous build only offered
  # "Stop all" in that case, which was exactly the opposite of what a
  # user wanting to recover from a partial install needs), and "Stop all"
  # only when everything is up.
  if (( loaded == 0 )); then
    echo "▶ Start all services | bash=$CTL param1=all-start terminal=false refresh=true"
  elif (( loaded < 4 )); then
    echo "▶ Start missing services ($((4-loaded)) unloaded) | bash=$CTL param1=all-start terminal=false refresh=true color=orange"
    echo "⏹ Stop all services | bash=$CTL param1=all-stop terminal=false refresh=true"
  else
    echo "⏹ Stop all services | bash=$CTL param1=all-stop terminal=false refresh=true"
  fi
  echo "🔄 Run agent once | bash=$CTL param1=run terminal=true"
  echo "---"
  echo "📋 View latest log | bash=$CTL param1=logs terminal=true"
  echo "📂 Open logs folder | bash=/usr/bin/open param1=$LOG_DIR terminal=false"
  echo "🩺 Run doctor | bash=$SKILL_DIR/bin/doctor.sh terminal=true"
  echo "---"
fi
echo "🔁 Refresh | refresh=true"
