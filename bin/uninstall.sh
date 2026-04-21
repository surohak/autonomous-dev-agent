#!/bin/bash
# bin/uninstall.sh — stop + remove launchd services. Optionally wipe the
# skill directory (config, secrets, cache, logs).
#
# Usage:
#   bin/uninstall.sh            # stop + remove plists only (safe default)
#   bin/uninstall.sh --purge    # also delete $SKILL_DIR
#
# Idempotent — safe to re-run.

set -euo pipefail

PURGE=0
for a in "$@"; do
  case "$a" in
    --purge) PURGE=1 ;;
    -h|--help) echo "Usage: $0 [--purge]"; exit 0 ;;
    *) echo "Unknown arg: $a"; exit 2 ;;
  esac
done

SKILL_DIR="${SKILL_DIR:-$HOME/.cursor/skills/autonomous-dev-agent}"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
LABEL_PREFIX="com.${USER:-user}"

echo "=== autonomous-dev-agent uninstall ==="
echo "  skill dir : $SKILL_DIR"
echo "  purge     : $PURGE"
echo

services=(
  "autonomous-dev-agent"
  "dev-agent-watcher"
  "dev-agent-digest"
)

echo "[1/3] Unloading + removing launchd plists..."
for svc in "${services[@]}"; do
  label="${LABEL_PREFIX}.${svc}"
  plist="$LAUNCH_AGENTS/${label}.plist"
  if [[ -f "$plist" ]]; then
    launchctl unload "$plist" 2>/dev/null || true
    rm -f "$plist"
    echo "  removed $plist"
  else
    echo "  absent  $label"
  fi
done

# Telegram plists: glob-match because multi-bot installs produce one per token
# (dev-agent-telegram, dev-agent-telegram-<project>, …).
for plist in "$LAUNCH_AGENTS"/"${LABEL_PREFIX}".dev-agent-telegram*.plist; do
  [[ -f "$plist" ]] || continue
  launchctl unload "$plist" 2>/dev/null || true
  rm -f "$plist"
  echo "  removed $plist"
done
echo

echo "[2/3] Removing SwiftBar plugin link..."
SWIFTBAR_LINK="$HOME/Library/Application Support/SwiftBar/Plugins/dev-agent.30s.sh"
if [[ -L "$SWIFTBAR_LINK" || -f "$SWIFTBAR_LINK" ]]; then
  rm -f "$SWIFTBAR_LINK"
  echo "  removed $SWIFTBAR_LINK"
else
  echo "  absent  $SWIFTBAR_LINK"
fi
echo

if (( PURGE == 1 )); then
  echo "[3/3] Removing $SKILL_DIR..."
  if [[ -d "$SKILL_DIR" || -L "$SKILL_DIR" ]]; then
    rm -rf "$SKILL_DIR"
    echo "  deleted $SKILL_DIR"
  else
    echo "  already absent"
  fi
else
  echo "[3/3] Skipping file removal (pass --purge to wipe $SKILL_DIR)"
fi

echo
echo "Uninstall complete."
