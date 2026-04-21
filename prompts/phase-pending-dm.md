# Phase: Pending DM Dispatcher (IDE-only)

When the user (in Cursor IDE chat) says anything like:

- `Process pending DM for <TK_KEY>`
- `Process all pending DMs`
- `Send pending Slack DMs`
- `Drain DM queue`

…read and drain the queue at `{{PROJECT_CACHE_DIR}}/pending-dm/*.json`
using your loaded Slack MCP.

## Why this exists

The `rel_dm` Telegram button can't send via the CLI cursor-agent — Cursor's CLI uses
an OAuth redirect_uri (`http://localhost:8787/callback`) that isn't whitelisted on
Cursor's Slack app, so CLI login fails. The IDE agent's Slack MCP works fine
because OAuth was completed interactively. The Telegram handler therefore queues
a task file and asks the user to paste a one-liner in IDE chat — which lands here.

## Steps

For each `{{PROJECT_CACHE_DIR}}/pending-dm/<TK_KEY>.json` (or just the single TK_KEY if specified):

1. Read the task JSON. Required fields: `ticket_key`, `slack_user_id`, `message`,
   `approver_name`. Optional: `mr_url`, `jira_url`.

2. Call your Slack MCP send-message tool. The correct tool for the bundled
   Cursor Slack plugin is `slack_send_message` with:
   ```
   channel_id = <slack_user_id>   # user IDs like "U08..." are valid DM channels
   message    = <message>         # use exactly the text from the task file
   ```
   If your environment exposes a differently-named tool (e.g.
   `slack_post_message`, `chat_postMessage`), use the first available one.

3. On success:
   - Move the task file to `{{PROJECT_CACHE_DIR}}/pending-dm/sent/<TK_KEY>-<unix_ts>.json` so
     it's not re-sent. Create the `sent/` dir if needed.
   - Add a `sent_at` and `slack_message_link` (if the tool returns one) to the
     moved file.
   - Send a single Telegram message to `chat_id = $TELEGRAM_CHAT_ID` (from
     `secrets.env`) with text:
     `Agent: DM sent to <approver_name> for <TK_KEY>` — one line, no markdown.

4. On failure (Slack tool errors, user not found, etc.):
   - Leave the task file in place so it can be retried.
   - Send one Telegram message: `Agent: DM failed for <TK_KEY> — <short reason>`
   - Do NOT retry automatically unless the user explicitly asks.

## Strict rules

- Do NOT run Phase 1 (discovery), Phase 2 (implementation), Phase 8 (review),
  Phase 9 (CI-fix), or any other workflow phase.
- Do NOT modify any files outside `{{PROJECT_CACHE_DIR}}/pending-dm/`.
- Do NOT commit or push anything.
- Send at most one Telegram message per task (success or failure).
- If the queue is empty, reply in IDE chat with a short "No pending DMs." —
  don't notify Telegram.

## Finding the right Slack MCP tool quickly

If you're unsure which tool to call, probe with a dry-run: read the tool
descriptor folder `~/.cursor/projects/*/mcps/plugin-slack-slack/tools/`
or whatever your MCP file-system path is. Prefer `slack_send_message` over
the `_draft` variants.

## Telegram send snippet (bash fallback, if no Telegram MCP)

```bash
source ~/.cursor/skills/autonomous-dev-agent/secrets.env
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -H 'Content-Type: application/json' \
  -d "$(python3 -c 'import json,sys; print(json.dumps({"chat_id":int(sys.argv[1]),"text":sys.argv[2]}))' "$TELEGRAM_CHAT_ID" "Agent: DM sent to Lei Wang for {{TICKET_PREFIX}}-123")" \
  > /dev/null
```
