#!/usr/bin/env bash
# reset-telegram.sh — bring the telegram handler back to a known-good state.
#
# Handles every failure mode we've hit so far:
#   - Duplicate daemons launchd lost track of
#   - launchd limbo state ("Bootstrap failed: 5: Input/output error")
#   - Stale plist label cached in the bootstrap domain
#   - KeepAlive respawning a crashing daemon in a tight loop
#
# Safe to run repeatedly. Exit codes: 0 ok, non-zero with readable error.
#
# Usage:
#   bash "$HOME/.cursor/skills/autonomous-dev-agent/scripts/reset-telegram.sh"

set -u

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SKILL_DIR/scripts/telegram-handler.sh"
LA_DIR="$HOME/Library/LaunchAgents"
UID_NUM="$(id -u)"

say() { printf '[reset-telegram] %s\n' "$*"; }
die() { printf '[reset-telegram] FATAL: %s\n' "$*" >&2; exit 1; }

count_pids() { /usr/bin/pgrep -f "$SCRIPT" 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' '; }
list_pids()  { /usr/bin/pgrep -fla "$SCRIPT" 2>/dev/null || true; }

plists_glob() {
  /bin/ls -1 "$LA_DIR"/*dev-agent-telegram*.plist 2>/dev/null || true
}

label_from() {
  /usr/libexec/PlistBuddy -c 'Print :Label' "$1" 2>/dev/null || true
}

say "on-disk handler: $SCRIPT"
[ -f "$SCRIPT" ] || die "handler script missing at $SCRIPT"

say ""
say "=== STEP 1: snapshot before ==="
BEFORE="$(count_pids)"
say "processes alive: $BEFORE"
list_pids | /usr/bin/sed 's/^/  /' || true
say "launchd jobs loaded:"
/bin/launchctl list 2>/dev/null | /usr/bin/grep -iE 'dev-agent-telegram' | /usr/bin/sed 's/^/  /' || echo "  (none)"

say ""
say "=== STEP 2: unload every telegram plist (all forms) ==="
for plist in $(plists_glob); do
  label="$(label_from "$plist")"
  [ -n "$label" ] || { say "  skip $plist (no Label in plist)"; continue; }
  say "  plist: $plist"
  say "    label: $label"

  # Try modern bootout (by label in the gui domain)
  if /bin/launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null; then
    say "    bootout by label: ok"
  else
    # Try bootout by plist path (alternate form some macOS versions prefer)
    if /bin/launchctl bootout "gui/$UID_NUM" "$plist" 2>/dev/null; then
      say "    bootout by plist path: ok"
    else
      # Legacy unload
      if /bin/launchctl unload "$plist" 2>/dev/null; then
        say "    legacy unload: ok"
      else
        say "    (already unloaded or in limbo — continuing)"
      fi
    fi
  fi
done

say ""
say "=== STEP 3: reap any process that survived (SIGTERM → grace → SIGKILL) ==="
/usr/bin/pkill -TERM -f "$SCRIPT" 2>/dev/null || true
/bin/sleep 3
STILL="$(count_pids)"
if [ "$STILL" != "0" ]; then
  say "  $STILL process(es) survived SIGTERM, sending SIGKILL"
  /usr/bin/pkill -KILL -f "$SCRIPT" 2>/dev/null || true
  /bin/sleep 1
fi
STILL="$(count_pids)"
if [ "$STILL" != "0" ]; then
  say "  $STILL still alive, per-pid kill -9"
  for pid in $(/usr/bin/pgrep -f "$SCRIPT" 2>/dev/null); do
    /bin/kill -9 "$pid" 2>/dev/null || true
  done
  /bin/sleep 1
fi
STILL="$(count_pids)"
say "  processes alive after reap: $STILL"
[ "$STILL" = "0" ] || die "could not kill all handlers — inspect with: pgrep -fa telegram-handler.sh"

say ""
say "=== STEP 4: let launchd settle (bootstrap limbo needs a moment) ==="
/bin/sleep 2

say ""
say "=== STEP 5: bootstrap fresh daemon(s) ==="
LOADED=0
for plist in $(plists_glob); do
  label="$(label_from "$plist")"
  say "  bootstrap: $label"

  if /bin/launchctl bootstrap "gui/$UID_NUM" "$plist" 2>/tmp/reset-telegram-err.$$; then
    say "    ok"
    LOADED=$((LOADED+1))
  else
    ERR="$(/bin/cat /tmp/reset-telegram-err.$$ 2>/dev/null)"
    say "    bootstrap failed: $ERR"

    # Handle "Input/output error" (code 5): launchd limbo — the label is
    # half-registered. Forcefully bootout by every form we know, wait, retry.
    if echo "$ERR" | /usr/bin/grep -q 'Input/output error\|File exists\|already loaded'; then
      say "    retrying: limbo cleanup"
      /bin/launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null || true
      /bin/launchctl bootout "gui/$UID_NUM" "$plist"  2>/dev/null || true
      /bin/launchctl unload "$plist" 2>/dev/null || true
      /bin/sleep 3
      if /bin/launchctl bootstrap "gui/$UID_NUM" "$plist" 2>/tmp/reset-telegram-err.$$; then
        say "    ok (after limbo cleanup)"
        LOADED=$((LOADED+1))
      else
        ERR="$(/bin/cat /tmp/reset-telegram-err.$$ 2>/dev/null)"
        say "    STILL failing: $ERR"
        # Last resort: legacy load
        if /bin/launchctl load "$plist" 2>/dev/null; then
          say "    ok (legacy load)"
          LOADED=$((LOADED+1))
        fi
      fi
    fi
  fi
  /bin/rm -f /tmp/reset-telegram-err.$$
done

say ""
say "=== STEP 6: verify ==="
/bin/sleep 3
AFTER="$(count_pids)"
say "processes alive: $AFTER"
list_pids | /usr/bin/sed 's/^/  /' || true
say "launchd state:"
/bin/launchctl list 2>/dev/null | /usr/bin/grep -iE 'dev-agent-telegram' | /usr/bin/sed 's/^/  /' || echo "  (nothing loaded)"

say ""
if [ "$AFTER" = "1" ] && [ "$LOADED" -ge 1 ]; then
  say "✓ SUCCESS — one clean handler running the fixed code."
  say ""
  say "Verify in Telegram: send /cherries — you should get a reply within ~1s."
  say ""
  say "If no reply after 5s, tail the log:"
  say "  tail -f $SKILL_DIR/logs/telegram-handler.log"
  exit 0
fi

say "✗ UNEXPECTED STATE: processes=$AFTER, bootstraps_succeeded=$LOADED"
say ""
say "Dump full launchd info for debugging:"
say "  launchctl print gui/$UID_NUM | grep -A2 dev-agent-telegram"
say "  launchctl dumpstate | grep -A5 dev-agent-telegram"
exit 2
