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
      {"command": "status",          "description": "Show agent status"},
      {"command": "status_all",      "description": "Status across all projects"},
      {"command": "tickets",         "description": "List New/To Do tickets"},
      {"command": "mrs",             "description": "List your open MRs"},
      {"command": "reviews",         "description": "MRs assigned to you for review"},
      {"command": "logs",            "description": "Show last run log"},
      {"command": "digest",          "description": "Send daily digest now"},
      {"command": "run",             "description": "Trigger agent run"},
      {"command": "stop",            "description": "Stop scheduled runs"},
      {"command": "start",           "description": "Resume scheduled runs"},
      {"command": "cherries",        "description": "Done tickets ready to cherry-pick to main"},
      {"command": "merge",           "description": "Merge approved MR to stage (merge UA-XXX)"},
      {"command": "tempo",           "description": "Tempo worklog suggestions (yesterday)"},
      {"command": "tempo_today",     "description": "Tempo suggestions for today"},
      {"command": "tempo_week",      "description": "Tempo suggestions for last 7 days"},
      {"command": "tempo_summary",   "description": "Tempo logged summary (yesterday)"},
      {"command": "tempo_summary_today", "description": "Tempo logged summary (today)"},
      {"command": "tempo_summary_week",  "description": "Tempo logged summary (last 7 days)"},
      {"command": "watch",           "description": "Show watcher status"},
      {"command": "snooze",          "description": "Mute watcher (e.g. /snooze 1h)"},
      {"command": "unsnooze",        "description": "Resume watcher notifications"},
      {"command": "workflow",        "description": "Show ticket workflow/transitions"},
      {"command": "workflow_refresh", "description": "Refresh workflow cache"},
      {"command": "project",         "description": "List configured projects"},
      {"command": "queue",           "description": "Cross-project priority queue"},
      {"command": "rebase",          "description": "Rebase open MR branches"},
      {"command": "ask",             "description": "Free-form prompt (chat with agent)"},
      {"command": "help",            "description": "Show all commands"}
    ]
  }' | python3 -m json.tool

echo ""
echo "Bot commands registered. Open Telegram and tap the / menu to see them."
