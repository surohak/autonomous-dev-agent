# Chat driver contract

A chat driver handles everything user-facing — outbound notifications AND
inbound command polling. Telegram is the reference implementation; Slack
is the first non-reference driver.

## File layout

```
scripts/drivers/chat/
├── _interface.md
├── _dispatch.sh
├── telegram.sh      ← reference driver (replaces scripts/lib/telegram.sh)
└── slack.sh
```

## Required public functions

### `chat_probe`

```
chat_probe
→ exit 0 if the bot token is valid and the bot account is reachable
```

### `chat_send <text>`

Plain text / Markdown-flavored. Each driver escapes as needed for its
backend.

```
chat_send "Ticket AL-123 is ready for review"
→ exit 0 on success
```

### `chat_send_interactive <text> <actions_json>`

```
chat_send_interactive "Start AL-123?" '[{"id":"start:AL-123","label":"Start"},{"id":"skip","label":"Skip"}]'
→ stdout: the backend's message id (for later edit/delete)
→ exit 0
```

`actions_json` is the canonical action list — drivers translate to
inline-keyboard buttons (Telegram) or Block Kit buttons (Slack). Every
action has an `id` (callback payload) and a `label` (button text). Drivers
may support extra fields via `"style":"primary"` etc. but unknown fields
must be silently ignored.

### `chat_edit <message_id> <new_text> [<new_actions_json>]`

```
chat_edit 1234 "Started ✓" '[]'
```

### `chat_poll [<cursor>]`

```
chat_poll 12345
→ stdout: JSON {"events":[…], "next":12400}
```

`events` is a list of inbound events, each one of:

```
{"type":"message","text":"/status","user":"u123","chat":"c456"}
{"type":"action","id":"start:AL-123","user":"u123","chat":"c456","msg":1234}
```

The `cursor` is driver-internal (Telegram = update_id, Slack = event
timestamp). Caller opaquely persists `next` in a state file and passes
it back next tick.

### `chat_handle_file <event>`

```
chat_handle_file '{"type":"file","mime":"image/png","url":"…"}'
→ stdout: local file path where the download landed
```

Drivers must download voice/photo/document attachments to
`cache/chat-attachments/` and return the local path. Later milestones
(voice transcription, OCR) depend on this.

## Environment contract

| var                  | meaning                             |
|----------------------|-------------------------------------|
| `CHAT_KIND`          | `telegram` / `slack`                |
| `CHAT_TOKEN`         | bot token                           |
| `CHAT_CHANNEL`       | target user / channel id            |
| `CHAT_OFFSET_FILE`   | where `chat_poll`'s cursor persists |

Per-project overrides from `projects[].chat.*` are handled by
`cfg_project_activate` — drivers always read the pivoted env, never
cross-project data.

## Rendering contract

Every driver must support the same small set of visual primitives:

- Plain paragraph (Markdown allowed)
- Inline code block (``` … ```)
- Action row (1–3 buttons)
- Icon in the first position of a line (✅, ⚠️, ❌, 🔎, ⏳)

Drivers that can't render a primitive must degrade cleanly — e.g. Slack
ignores `*bold*`-only formatting differences; IRC (future) strips emoji.

## Testing contract

- `scripts/tests/drivers/chat/<name>/fixtures/*.json`
- `scripts/tests/drivers/chat/<name>.sh`

Fixture expectations:

- sending plain text → posts ONE message with the exact text
- sending interactive → posts ONE message whose native action list has the
  correct length
- polling returns canonical events regardless of backend quirks
