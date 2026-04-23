#!/bin/bash
# Registers Telegram bot commands (the "/" menu in Telegram).
# Run once after creating the bot, or whenever commands change.

set -euo pipefail

SKILL_DIR="$HOME/.cursor/skills/autonomous-dev-agent"
source "$SKILL_DIR/secrets.env"

echo "Registering bot commands..."

curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setMyCommands" \
  -H "Content-Type: application/json" \
  -d '{
    "commands": [
      {"command": "status", "description": "Show agent status"},
      {"command": "tickets", "description": "List New/To Do tickets"},
      {"command": "mrs", "description": "List your open MRs"},
      {"command": "reviews", "description": "MRs assigned to you for review"},
      {"command": "logs", "description": "Show last run log"},
      {"command": "digest", "description": "Send daily digest now"},
      {"command": "ask", "description": "Free-form prompt (chat with agent)"},
      {"command": "cherries", "description": "List tickets eligible for cherry-pick to main"},
      {"command": "cherry", "description": "Promote ticket to main (/cherry PROJ-XXX)"},
      {"command": "run", "description": "Trigger agent run"},
      {"command": "tempo", "description": "Tempo worklog suggestions"},
      {"command": "watch", "description": "Show watcher status"},
      {"command": "snooze", "description": "Mute watcher (e.g. /snooze 1h)"},
      {"command": "unsnooze", "description": "Resume watcher notifications"},
      {"command": "stop", "description": "Stop scheduled runs"},
      {"command": "start", "description": "Resume scheduled runs"},
      {"command": "help", "description": "Show all commands"}
    ]
  }' | python3 -m json.tool

echo ""
echo "Bot commands registered. Open Telegram and tap the / menu to see them."
