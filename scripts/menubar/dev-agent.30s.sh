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
svc_row() {
  local label_short="$1" label_full="$2"
  if svc_loaded "$label_full"; then
    printf "%-11s ✅ loaded\n" "$label_short"
  else
    printf "%-11s ❌ unloaded\n" "$label_short"
  fi
}
svc_row "agent"     "$AGENT_LABEL"
svc_row "watcher"   "$WATCHER_LABEL"
svc_row "telegram"  "$TELEGRAM_LABEL"
svc_row "digest"    "$DIGEST_LABEL"
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
  if (( loaded == 0 )); then
    echo "▶ Start all services | bash=$CTL param1=all-start terminal=false refresh=true"
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
