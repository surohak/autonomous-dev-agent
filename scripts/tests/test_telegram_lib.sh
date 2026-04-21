#!/bin/bash
# test_telegram_lib.sh — asserts the Python JSON encoders handle all the nasty
# characters (quotes, newlines, backticks, backslashes) without breaking the
# payload, WITHOUT actually hitting the Telegram API.
set -euo pipefail
source "$HOME/.cursor/skills/autonomous-dev-agent/scripts/lib/env.sh"

# Stub out _tg_call so we capture the payload instead of sending it.
export CAPTURE="$TEST_TMP/payload.json"
source "$HOME/.cursor/skills/autonomous-dev-agent/scripts/lib/telegram.sh"
_tg_call() {
  cat > "$CAPTURE"
  return 0
}
export -f _tg_call
# Ensure these are set (test doesn't actually call Telegram)
export TELEGRAM_BOT_TOKEN="dummy"
export TELEGRAM_CHAT_ID="123"

tricky=$'quote "x" back `tick`\nnewline\\slash'

tg_send "$tricky"
# Parse back as JSON → the decoded text MUST equal the input.
got=$(python3 -c "
import json
d = json.load(open('$CAPTURE'))
import sys
sys.stdout.write(d['text'])
")
if [[ "$got" != "$tricky" ]]; then
  echo "tg_send: text mismatch"
  echo "expected: $(printf '%q' "$tricky")"
  echo "got:      $(printf '%q' "$got")"
  exit 1
fi

# inline keyboard round-trip
kb='[[{"text":"OK","callback_data":"ok"}]]'
tg_inline "$tricky" "$kb"
python3 -c "
import json
d = json.load(open('$CAPTURE'))
assert d['text'] == '''$tricky''', d['text']
assert d['reply_markup']['inline_keyboard'] == [[{'text':'OK','callback_data':'ok'}]], d
print('inline OK')
" >/dev/null

# Back-compat alias works
send_telegram "plain"
python3 -c "
import json
d = json.load(open('$CAPTURE'))
assert d['text'] == 'plain', d
" >/dev/null

echo "telegram lib encoding OK"
