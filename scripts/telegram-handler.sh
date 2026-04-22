#!/bin/bash
# Telegram Command Handler — persistent daemon using long polling.
# Blocks on Telegram's getUpdates (timeout=30s) so commands respond instantly.
# Handles simple commands in bash (no tokens). Only launches Cursor agent
# for commands that need code changes (run, retry, review, fix).

set -uo pipefail

# --- Shared bootstrap -------------------------------------------------------
# All paths, secrets, config values come from the lib/* helpers so this file
# no longer needs to hard-code SKILL_DIR/CACHE_DIR/JIRA_ACCOUNT_ID/etc.
SKILL_DIR="${SKILL_DIR:-$HOME/.cursor/skills/autonomous-dev-agent}"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/env.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/cfg.sh"

# Pin this daemon to a specific project if $AGENT_PROJECT is set in the
# environment (install.sh writes AGENT_PROJECT=<id> into each per-project
# LaunchAgent plist so one daemon-per-bot-token runs even when several
# projects share the same user but different Telegram bots).
if [[ -n "${AGENT_PROJECT:-}" ]]; then
  cfg_project_activate "$AGENT_PROJECT" >/dev/null 2>&1 \
    || echo "[$(date '+%Y-%m-%d %H:%M:%S')] warn: cfg_project_activate($AGENT_PROJECT) failed — using default"
fi

# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/telegram.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/jira.sh"
source "$SKILL_DIR/scripts/lib/workflow.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/gitlab.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/timelog.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/tempo.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/active-run.sh"

# --- Modular handlers -------------------------------------------------------
# Each handler file defines cmd_*/handler_* functions used by the big case
# statement further down. Splitting them keeps this file readable and lets us
# unit-test handlers in isolation.
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/handlers/common.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/handlers/help.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/handlers/basic.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/handlers/runs.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/handlers/queue.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/handlers/watch.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/handlers/tempo.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/handlers/project.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/handlers/workflow.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/handlers/rebase.sh"

# OFFSET_FILE is specific to this daemon. Scoped per-bot-token via cfg.sh so
# per-project bot overrides don't race (each bot polls its own offset).
OFFSET_FILE="${TG_OFFSET_FILE:-$CACHE_DIR/telegram-offset.txt}"
mkdir -p "$(dirname "$OFFSET_FILE")"

# Back-compat: legacy call sites still use send_telegram / send_telegram_inline
# / send_force_reply / answer_callback. lib/telegram.sh already aliases those
# to the tg_* functions, so nothing else to do.

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Handler started (long-polling mode)"

# --- One-shot Python diagnostic under the launchd context ------------------
# The parser silently fails with PermissionError inside `_path_importer_cache`
# because of macOS TCC/provenance restrictions on ~/.cursor when accessed by a
# launchd agent. Capture sys.path + the actual stat errors once per startup
# so we can see exactly which directory is blocked.
echo "[$(date '+%Y-%m-%d %H:%M:%S')] PY_DIAG starting — capturing sys.path and stat perms under launchd context" >&2
/usr/bin/python3 - <<'PYDIAG' >&2 2>&1 || true
import sys, os, traceback
print(f"PY_DIAG executable={sys.executable}")
print(f"PY_DIAG cwd={os.getcwd()}")
print(f"PY_DIAG PYTHONPATH={os.environ.get('PYTHONPATH','(unset)')}")
print(f"PY_DIAG sys.path={sys.path}")
for p in sys.path:
    if not p: p = os.getcwd()
    try:
        st = os.stat(p)
        print(f"PY_DIAG stat_ok  {p}  mode={oct(st.st_mode)}")
    except Exception as e:
        print(f"PY_DIAG stat_err {p}  err={e!r}")
print("PY_DIAG tiny-import-test:")
try:
    import json, re, base64
    print("  PY_DIAG import_ok  json/re/base64")
except Exception as e:
    traceback.print_exc()
PYDIAG
echo "[$(date '+%Y-%m-%d %H:%M:%S')] PY_DIAG done" >&2

# --- AC-power-aware caffeinate (keep Mac awake only when charging) ---
# Background daemon that starts/stops `caffeinate -s -i` as the power source changes.
# On battery: caffeinate is stopped so we don't drain power.
# On AC:      caffeinate keeps system awake so Telegram long-poll stays responsive.
(
  CAFF_PID_FILE="$CACHE_DIR/caffeinate-handler.pid"
  mkdir -p "$CACHE_DIR"

  cleanup_caffeinate() {
    if [ -f "$CAFF_PID_FILE" ]; then
      local pid
      pid=$(cat "$CAFF_PID_FILE" 2>/dev/null)
      [ -n "$pid" ] && kill "$pid" 2>/dev/null
      rm -f "$CAFF_PID_FILE"
    fi
  }
  trap cleanup_caffeinate EXIT

  while true; do
    # Detect AC vs battery (very cheap).
    if pmset -g ps 2>/dev/null | head -1 | grep -q "AC Power"; then
      POWER="ac"
    else
      POWER="battery"
    fi

    RUNNING_PID=""
    if [ -f "$CAFF_PID_FILE" ]; then
      RUNNING_PID=$(cat "$CAFF_PID_FILE" 2>/dev/null)
      kill -0 "$RUNNING_PID" 2>/dev/null || { rm -f "$CAFF_PID_FILE"; RUNNING_PID=""; }
    fi

    if [ "$POWER" = "ac" ] && [ -z "$RUNNING_PID" ]; then
      # -s: keep system awake (lid can be closed on AC), -i: prevent idle sleep
      caffeinate -s -i &
      echo "$!" > "$CAFF_PID_FILE"
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] caffeinate started (AC power, pid=$!)"
    elif [ "$POWER" = "battery" ] && [ -n "$RUNNING_PID" ]; then
      kill "$RUNNING_PID" 2>/dev/null
      rm -f "$CAFF_PID_FILE"
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] caffeinate stopped (switched to battery)"
    fi

    sleep 60
  done
) &
CAFF_WATCH_PID=$!

# Make sure we kill the caffeinate watcher when handler exits.
trap 'kill $CAFF_WATCH_PID 2>/dev/null; [ -f "$CACHE_DIR/caffeinate-handler.pid" ] && kill $(cat "$CACHE_DIR/caffeinate-handler.pid") 2>/dev/null; rm -f "$CACHE_DIR/caffeinate-handler.pid"' EXIT

# --- Wake-from-sleep detection ---
# On each loop, track wall-clock time. If more than POLL_SLACK_SEC passed since
# the previous iteration end, we likely just woke from sleep — force an
# immediate non-blocking getUpdates so queued messages are processed instantly
# (don't wait for the regular long-poll to time out).
LAST_LOOP_END=$(date +%s)
POLL_SLACK_SEC=120

# --- Trace helper -----------------------------------------------------------
# HANDLER_DEBUG=1 flips on a very small set of TRACE lines across the main
# polling cycle. Cheap to always leave enabled — the alternative (bash -x)
# dumps thousands of lines per iteration. Default is ON so the next time
# the bot "doesn't answer" we have a timeline instead of silence.
: "${HANDLER_DEBUG:=1}"
_trace() {
  [[ "$HANDLER_DEBUG" = "1" ]] || return 0
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] TRACE: $*"
}

while true; do

# Reset per-iteration state at the TOP of the loop. The old position (at the
# bottom, before `done`) was unreachable whenever a `continue` short-circuited
# the iteration (parser_empty, MSG_COUNT=0, API_ERR). That caused UPDATES to
# keep a stale first-iteration response forever — the curl block's guard
# `[ -z "${UPDATES:-}" ]` stayed false, the long-poll never re-fired, and the
# parser kept re-crunching the same bad bytes in a tight loop.
UPDATES=""

OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || echo "0")
_trace "iter_start offset=$OFFSET"

# Re-bind active project each iteration. If this daemon is pinned by
# install.sh (AGENT_PROJECT env) we honour the pin. Otherwise we trust the
# persisted state file written by `/project use <id>` so the switch
# survives getUpdates loops.
if [[ -z "${AGENT_PROJECT:-}" ]]; then
  _active_file="${GLOBAL_CACHE_DIR:-$CACHE_DIR}/active-project.txt"
  if [[ -s "$_active_file" ]]; then
    _desired=$(head -n1 "$_active_file")
    if [[ -n "$_desired" && "$_desired" != "${PROJECT_ID:-}" ]]; then
      cfg_project_activate "$_desired" >/dev/null 2>&1 || true
    fi
  fi
fi

NOW_SEC=$(date +%s)
ELAPSED=$((NOW_SEC - LAST_LOOP_END))
# Reset the wake-detection timer BEFORE any `continue` below can short-circuit
# the iteration. The old location (bottom of the loop) was unreachable on the
# common quiet path (no-messages → `continue`), so ELAPSED grew monotonically
# and the handler ended up permanently stuck in this flush branch, spamming
# the log and racing offsets instead of doing the normal 30s long-poll.
LAST_LOOP_END=$NOW_SEC
if [ "$ELAPSED" -gt "$POLL_SLACK_SEC" ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] woke from sleep after ${ELAPSED}s — flushing queue"
  # Non-blocking getUpdates (timeout=0) to drain any queued updates fast.
  FLUSH=$(curl -s --max-time 10 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?offset=${OFFSET}&timeout=0" 2>/dev/null)
  # If there are updates, process them first by using the flush as the normal
  # response path; otherwise fall through to the long-poll below.
  if echo "$FLUSH" | grep -q '"result":\s*\[[^]]'; then
    UPDATES="$FLUSH"
  else
    UPDATES=""
  fi
fi

if [ -z "${UPDATES:-}" ]; then
  # Long poll: Telegram holds the connection open up to 30s and responds
  # instantly when a new message arrives. curl max-time is 35s as safety margin.
  _trace "curl getUpdates offset=$OFFSET timeout=30"
  UPDATES=$(curl -s --max-time 35 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?offset=${OFFSET}&timeout=30" 2>/dev/null)
  _trace "curl returned bytes=${#UPDATES}"
fi

# --- API error visibility ---------------------------------------------------
# Previously a Telegram `{"ok":false, error_code:409, ...}` response (webhook
# conflict, competing getUpdates consumer, token revoked, network blip)
# silently produced results=[] and the loop spun forever without processing
# any commands. Detect the error up front and log it so operators can see
# WHY the handler is silent. Throttled to once per 5 min per distinct error
# so we don't flood the log on a persistent 409.
if [ -n "${UPDATES:-}" ]; then
  # -E -I = isolated mode: ignore PYTHON* env vars AND skip adding cwd to
  # sys.path. Under launchd, macOS TCC/provenance blocks stat() on directories
  # inside ~/.cursor for unprivileged agents without Full Disk Access. Stripping
  # those paths is enough for stdlib-only parsers to import cleanly. The
  # stderr from this block intentionally flows through to the error log — any
  # future Python-side failure must be visible, not swallowed.
  API_ERR=$(echo "$UPDATES" | /usr/bin/python3 -E -I -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception as e:
    print(f'parse_error:{e}')
    sys.exit(0)
if not isinstance(d, dict):
    print('non_dict_response')
    sys.exit(0)
if d.get('ok') is False:
    ec = d.get('error_code', '?')
    desc = (d.get('description') or '')[:200]
    print(f'{ec}:{desc}')
")
  if [ -n "$API_ERR" ]; then
    _ERR_STATE_FILE="${CACHE_DIR}/telegram-api-last-error.txt"
    _LAST_ERR=$(cat "$_ERR_STATE_FILE" 2>/dev/null || echo "")
    _NOW_EPOCH=$(date +%s)
    _LAST_EPOCH=$(cat "${_ERR_STATE_FILE}.ts" 2>/dev/null || echo 0)
    if [ "$API_ERR" != "$_LAST_ERR" ] || [ $(( _NOW_EPOCH - _LAST_EPOCH )) -gt 300 ]; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: Telegram API error: $API_ERR (offset=${OFFSET}) — handler is alive but updates are blocked" >&2
      echo "$API_ERR" > "$_ERR_STATE_FILE"
      echo "$_NOW_EPOCH" > "${_ERR_STATE_FILE}.ts"
    fi
    UPDATES=""
    sleep 5
    continue
  fi
fi

# -E -I = isolated mode. Same reasoning as the API_ERR parser above: under
# launchd, TCC blocks ~/.cursor access during sys.path probing. Stdlib-only
# parser, so no PYTHONPATH needed. stderr is intentionally NOT redirected —
# any import error, traceback, or PARSER_* message must reach the error log.
MESSAGES=$(echo "$UPDATES" | /usr/bin/python3 -E -I -c "
import sys, json, re, os, base64, traceback

# --- Tripwire markers (all go to stderr) ----------------------------------
# The parser was silently emitting nothing to stdout AND nothing to stderr.
# That's only possible if (a) Python never ran, (b) it died by signal, or
# (c) the bash heredoc produced broken code (SyntaxError shows on stderr).
# These markers prove which one fires:
#   PARSE_TW_START  → interpreter started executing the script body
#   PARSE_TW_END    → we reached the final print()
#   PARSE_TW_EXCEPT → an uncaught exception was caught and logged
sys.stderr.write('PARSE_TW_START\n'); sys.stderr.flush()


def _run():
    try:
        data = json.load(sys.stdin)
    except Exception as e:
        sys.stderr.write(f'PARSER_JSON_ERROR: {e!r}\n')
        return {'messages': [], 'next_offset': 0}
    if not isinstance(data, dict):
        sys.stderr.write(f'PARSER_NON_DICT_RESPONSE: type={type(data).__name__}\n')
        return {'messages': [], 'next_offset': 0}

    # TICKET_KEY_PATTERN is resolved ONCE with a safe default. Earlier the
    # per-message branches did os.environ['TICKET_KEY_PATTERN'] — a KeyError
    # when cfg_project_activate didn't export it killed the parser silently.
    _TICKET_PAT = os.environ.get('TICKET_KEY_PATTERN') or r'[A-Z]+-\d+'

    results = data.get('result', [])
    chat_id = ${TELEGRAM_CHAT_ID}
    msgs = []
    max_id = 0

    for r in results:
        uid = r.get('update_id', 0)
        if uid > max_id:
            max_id = uid

        # 1) Inline button taps (callback_query)
        cq = r.get('callback_query')
        if cq and cq.get('from', {}).get('id') == chat_id:
            data_val = cq.get('data', '')
            MULTI_SPLIT_PREFIXES = ('rv_', 'ci_', 'fb_', 'tk_', 'rel_', 'tm_', 'mr_')
            if data_val.startswith(MULTI_SPLIT_PREFIXES):
                text_cmd = data_val.replace(':', ' ')
            else:
                text_cmd = data_val.replace(':', ' ', 1)
            msg_obj = cq.get('message') or {}
            msgs.append({
                'text': text_cmd,
                'callback_id': cq.get('id'),
                'message_id': msg_obj.get('message_id'),
            })
            continue

        msg = r.get('message', {})
        if msg.get('chat', {}).get('id') != chat_id:
            continue

        # v0.5.0 — voice notes
        voice_obj = msg.get('voice') or msg.get('audio')
        if voice_obj:
            file_id = voice_obj.get('file_id')
            mime    = voice_obj.get('mime_type') or 'audio/ogg'
            dur     = voice_obj.get('duration') or 0
            if file_id:
                msgs.append({'text': f'__VOICE__:{file_id}:{dur}:{mime}'})
                continue

        # v0.5.0 — photo attachments
        photo_arr = msg.get('photo') or []
        if photo_arr:
            largest = max(photo_arr, key=lambda p: (p.get('width',0) * p.get('height',0)))
            file_id = largest.get('file_id')
            caption = msg.get('caption', '') or ''
            reply_ctx = ''
            rt = msg.get('reply_to_message', {})
            rt_text = (rt.get('text','') or '') if rt else ''
            if re.match(r'^Reply with review feedback for ', rt_text):
                m = re.match(r'^Reply with review feedback for (' + _TICKET_PAT + '):', rt_text)
                if m: reply_ctx = f'review {m.group(1)}'
            elif re.match(r'^Edit comment (\d+)#(\d+):', rt_text):
                m = re.match(r'^Edit comment (\d+)#(\d+):', rt_text)
                if m: reply_ctx = f'rv_editapply {m.group(1)} {m.group(2)}'
            elif re.match(r'^Discuss comment (\d+)#(\d+):', rt_text):
                m = re.match(r'^Discuss comment (\d+)#(\d+):', rt_text)
                if m: reply_ctx = f'rv_discussapply {m.group(1)} {m.group(2)}'
            if file_id:
                cap_b64 = base64.urlsafe_b64encode(caption.encode()).decode()
                ctx_b64 = base64.urlsafe_b64encode(reply_ctx.encode()).decode()
                msgs.append({'text': f'__PHOTO__:{file_id}:{cap_b64}:{ctx_b64}'})
                continue

        text = msg.get('text')
        if not text:
            continue

        # 2) Force-reply responses
        reply_to = msg.get('reply_to_message', {})
        reply_text = reply_to.get('text', '') if reply_to else ''

        # 2a) review feedback
        m = re.match(r'^Reply with review feedback for (' + _TICKET_PAT + '):', reply_text)
        if m:
            ticket = m.group(1)
            msgs.append({'text': f'review {ticket}: {text}'})
            continue

        # 2b) edit a pending review comment
        m = re.match(r'^Edit comment (\d+)#(\d+):', reply_text)
        if m:
            mr_iid, idx = m.group(1), m.group(2)
            msgs.append({'text': f'rv_editapply {mr_iid} {idx} {text}'})
            continue

        # 2c) discuss a review comment
        m = re.match(r'^Discuss comment (\d+)#(\d+):', reply_text)
        if m:
            mr_iid, idx = m.group(1), m.group(2)
            msgs.append({'text': f'rv_discussapply {mr_iid} {idx} {text}'})
            continue

        # 2c2) tempo duration edit
        m = re.match(r'^How long for (' + _TICKET_PAT + r') on (\d{4}-\d{2}-\d{2})', reply_text)
        if m:
            ticket, date = m.group(1), m.group(2)
            payload = ' '.join(text.split())
            msgs.append({'text': f'tm_editapply {ticket} {date} {payload}'})
            continue

        # 2d) chat continuation
        if reply_text.startswith(('Thinking', 'Agent:', 'Chat reply')):
            msgs.append({'text': f'ask {text}'})
            continue

        # 2e) '?' shortcut
        if text.startswith('?') and len(text) > 1:
            msgs.append({'text': f'ask {text[1:].strip()}'})
            continue

        # 3) Normal typed message
        msgs.append({'text': text})

    return {'messages': msgs, 'next_offset': max_id + 1 if max_id > 0 else 0}


try:
    result = _run()
    sys.stderr.write(f'PARSE_TW_END msgs={len(result[\"messages\"])} next={result[\"next_offset\"]}\n')
    sys.stderr.flush()
    print(json.dumps(result))
except SystemExit:
    raise
except BaseException:
    sys.stderr.write('PARSE_TW_EXCEPT\n')
    traceback.print_exc(file=sys.stderr)
    sys.stderr.flush()
    # Emit a valid but empty payload so bash keeps polling.
    print('{\"messages\": [], \"next_offset\": 0}')
"
)

if [ -z "$MESSAGES" ] || [ "$MESSAGES" = "null" ]; then
  _trace "parser_empty — python parser returned nothing (see stderr log for PARSER_* or traceback)"
  # Prove to ourselves what the raw response actually was, once per distinct
  # failure, so future debugging doesn't require another round-trip.
  _pe_cache="${CACHE_DIR}/parser-empty-last.txt"
  _pe_hash=$(printf '%s' "$UPDATES" | /usr/bin/shasum | /usr/bin/cut -c1-12)
  _pe_prev=$(cat "$_pe_cache" 2>/dev/null || echo "")
  if [ "$_pe_hash" != "$_pe_prev" ]; then
    echo "$_pe_hash" > "$_pe_cache"
    # Trim to 500 chars for the log so we don't flood it.
    _pe_preview=$(printf '%s' "$UPDATES" | /usr/bin/head -c 500)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] PARSER_EMPTY_RAW hash=$_pe_hash bytes=${#UPDATES} preview=$_pe_preview" >&2
  fi
  sleep 1
  continue
fi

NEXT_OFFSET=$(echo "$MESSAGES" | python3 -c "import sys,json; print(json.load(sys.stdin).get('next_offset', 0))")
MSG_COUNT=$(echo "$MESSAGES" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('messages', [])))")
_trace "parsed msg_count=$MSG_COUNT next_offset=$NEXT_OFFSET"

if [ "$NEXT_OFFSET" != "0" ]; then
  echo "$NEXT_OFFSET" > "$OFFSET_FILE"
  _trace "saved_offset=$NEXT_OFFSET"
fi

if [ "$MSG_COUNT" = "0" ]; then
  _trace "no_messages — long-poll returned empty result list, looping"
  continue
fi

echo "$MESSAGES" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data['messages']:
    # Format: '<callback_id_or_dash>\t<message_id_or_dash>\t<text>'
    cid = m.get('callback_id') or '-'
    mid = m.get('message_id') or '-'
    # Replace tabs/newlines in text with spaces so each record is exactly one line
    text = m['text'].replace('\t', ' ').replace('\n', ' ')
    print(f'{cid}\t{mid}\t{text}')
" | while IFS=$'\t' read -r CB_ID CB_MSG_ID CMD; do
  _trace "dispatch cb_id=${CB_ID} msg_id=${CB_MSG_ID} cmd=$(echo "$CMD" | cut -c1-80)"
  # Answer inline-button taps immediately so the spinner disappears
  if [ "$CB_ID" != "-" ] && [ -n "$CB_ID" ]; then
    answer_callback "$CB_ID"
  fi

  # v0.5.0 — voice-note preprocessing. If the update-parser tagged this
  # message as a voice note (sentinel '__VOICE__:<file_id>:<dur>:<mime>'),
  # download + transcribe first, then substitute the transcript back into
  # CMD so the normal command router handles it unchanged.
  if [[ "$CMD" == __VOICE__:* ]]; then
    _voice_payload="${CMD#__VOICE__:}"
    _voice_file_id="${_voice_payload%%:*}"
    _voice_rest="${_voice_payload#*:}"
    _voice_dur="${_voice_rest%%:*}"
    _voice_mime="${_voice_rest#*:}"

    # Tempdir lives in the per-bot cache so it's auto-rotated by cleanup.
    _voice_dir="${CACHE_DIR:-$HOME/.cursor/skills/autonomous-dev-agent/cache}/voice"
    mkdir -p "$_voice_dir"

    # Step 1 — getFile to resolve a download URL.
    _voice_file_path=$(curl -s --max-time 10 \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getFile?file_id=${_voice_file_id}" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("result") or {}).get("file_path",""))' 2>/dev/null)

    if [[ -z "$_voice_file_path" ]]; then
      tg_send "🎙 Voice note: couldn't fetch the file from Telegram. Try sending as text." >/dev/null 2>&1 || true
      continue
    fi

    # Pick an extension from the mime type so transcribe.sh / ffmpeg are happy.
    case "$_voice_mime" in
      *ogg*)  _voice_ext=ogg ;;
      *m4a*|*mp4*|*aac*) _voice_ext=m4a ;;
      *mp3*|*mpeg*) _voice_ext=mp3 ;;
      *wav*)  _voice_ext=wav ;;
      *)      _voice_ext=ogg ;;
    esac
    _voice_local="${_voice_dir}/${_voice_file_id}.${_voice_ext}"

    curl -sSL --max-time 30 \
      "https://api.telegram.org/file/bot${TELEGRAM_BOT_TOKEN}/${_voice_file_path}" \
      -o "$_voice_local" 2>/dev/null || {
        tg_send "🎙 Voice note: download failed. Try again or type the command." >/dev/null 2>&1 || true
        continue
      }

    # Acknowledge so the user knows we heard it; long clips take a few seconds.
    tg_send "🎙 Transcribing ${_voice_dur}s voice note…" >/dev/null 2>&1 || true

    # shellcheck disable=SC1091
    source "$SKILL_DIR/scripts/lib/transcribe.sh"
    _voice_transcript=$(transcribe_audio "$_voice_local" "$(cfg_get '.owner.voiceLang' 'en')" 2>&1) || {
      tg_send "🎙 Transcribe failed: ${_voice_transcript:-unknown error}. See logs." >/dev/null 2>&1 || true
      rm -f "$_voice_local"
      continue
    }
    rm -f "$_voice_local" 2>/dev/null || true

    if [[ -z "$_voice_transcript" ]]; then
      tg_send "🎙 Transcribe returned empty text. Try closer to the mic." >/dev/null 2>&1 || true
      continue
    fi

    # Echo the transcript so the user can confirm what the bot heard. The
    # leading "/" is stripped later by CMD_CLEAN if present.
    tg_send "🎙 Heard: _${_voice_transcript}_" >/dev/null 2>&1 || true

    # Re-enter the normal command flow with the transcribed text.
    CMD="$_voice_transcript"
  fi

  # v0.5.0 — screenshot OCR. Sentinel:
  #   __PHOTO__:<file_id>:<b64 caption>:<b64 reply_ctx>
  # The reply_ctx captures force-reply parentage (review / rv_editapply /
  # rv_discussapply) so the photo can substitute/augment the expected text
  # reply. A bare photo with no context becomes an "ask" over the OCR.
  if [[ "$CMD" == __PHOTO__:* ]]; then
    _photo_payload="${CMD#__PHOTO__:}"
    _photo_file_id="${_photo_payload%%:*}"
    _photo_rest="${_photo_payload#*:}"
    _photo_cap_b64="${_photo_rest%%:*}"
    _photo_ctx_b64="${_photo_rest#*:}"
    _photo_cap=$(printf '%s' "$_photo_cap_b64" | python3 -c 'import sys,base64; print(base64.urlsafe_b64decode(sys.stdin.read()).decode(errors="replace"))' 2>/dev/null)
    _photo_ctx=$(printf '%s' "$_photo_ctx_b64" | python3 -c 'import sys,base64; print(base64.urlsafe_b64decode(sys.stdin.read()).decode(errors="replace"))' 2>/dev/null)

    _photo_dir="${CACHE_DIR:-$HOME/.cursor/skills/autonomous-dev-agent/cache}/photos"
    mkdir -p "$_photo_dir"

    _photo_file_path=$(curl -s --max-time 10 \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getFile?file_id=${_photo_file_id}" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("result") or {}).get("file_path",""))' 2>/dev/null)

    if [[ -z "$_photo_file_path" ]]; then
      tg_send "📷 Photo: Telegram didn't return a file_path. Re-send as document, or paste the text." >/dev/null 2>&1 || true
      continue
    fi

    _photo_local="${_photo_dir}/${_photo_file_id}.jpg"
    curl -sSL --max-time 30 \
      "https://api.telegram.org/file/bot${TELEGRAM_BOT_TOKEN}/${_photo_file_path}" \
      -o "$_photo_local" 2>/dev/null || {
        tg_send "📷 Photo download failed." >/dev/null 2>&1 || true
        continue
      }

    tg_send "📷 Extracting text from screenshot…" >/dev/null 2>&1 || true
    # shellcheck disable=SC1091
    source "$SKILL_DIR/scripts/lib/ocr.sh"
    _photo_text=$(ocr_image "$_photo_local" 2>&1) || {
      tg_send "📷 OCR failed: ${_photo_text:-unknown error}. See logs; caption-only path is still available." >/dev/null 2>&1 || true
      rm -f "$_photo_local"
      continue
    }
    rm -f "$_photo_local" 2>/dev/null || true

    # Combine caption + extracted text, trimming. Caption (if any) goes first
    # because the user intent usually comes from their typed message.
    _photo_body=""
    [[ -n "$_photo_cap" ]] && _photo_body="$_photo_cap"$'\n'
    _photo_body="$_photo_body$_photo_text"
    _photo_body=$(printf '%s' "$_photo_body" | awk 'NF {print}' | head -c 4000)

    if [[ -z "$_photo_body" ]]; then
      tg_send "📷 No text extracted from the screenshot." >/dev/null 2>&1 || true
      continue
    fi

    # Echo a snippet so the user can verify what was captured.
    _photo_preview=$(printf '%s' "$_photo_body" | head -c 400)
    tg_send "📷 Extracted (first 400 chars): \`${_photo_preview}\`" >/dev/null 2>&1 || true

    # Dispatch based on context. Replace newlines with spaces for single-line
    # command dispatch — the downstream handlers don't expect multi-line CMDs.
    _photo_oneline=$(printf '%s' "$_photo_body" | tr '\n\r\t' ' ' | tr -s ' ')
    if [[ -n "$_photo_ctx" ]]; then
      CMD="${_photo_ctx} ${_photo_oneline}"
    else
      CMD="ask ${_photo_oneline}"
    fi
  fi

  # Strip leading slash and @botname suffix (for slash commands and group mentions)
  CMD_CLEAN=$(echo "$CMD" | sed -E 's/^\///; s/@[a-zA-Z0-9_]+[ ]*/ /')
  CMD_LOWER=$(echo "$CMD_CLEAN" | tr '[:upper:]' '[:lower:]' | xargs)

  case "$CMD_LOWER" in

    status)
      cmd_status
      ;;

    status\ all)
      # Multi-project overview — iterate all projects and print a status
      # block per project. On single-project installs this produces the same
      # output as /status (one block, one project), so it's safe to advertise
      # unconditionally in the help text.
      for _pid_iter in $(cfg_project_list); do
        cfg_project_activate "$_pid_iter" >/dev/null 2>&1 || continue
        tg_send "── *${_pid_iter}* (${JIRA_PROJECT:-?}) ──"
        cmd_status
      done
      # v0.5.0 — one-line queue summary read from the watcher snapshot
      # (global/queue-snapshot.json). Cheap, no tracker round-trips.
      _queue_snap="${GLOBAL_CACHE_DIR:-$CACHE_DIR}/queue-snapshot.json"
      if [[ -f "$_queue_snap" ]]; then
        _queue_line=$(python3 - "$_queue_snap" <<'PY' 2>/dev/null
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
projs = [k for k in d.keys() if not k.startswith("_")]
bits = []
for p in sorted(projs):
    n = len((d.get(p) or {}).get("todo") or [])
    bits.append(f"{p}={n}")
print("Queue: " + " · ".join(bits) if bits else "")
PY
)
        [[ -n "$_queue_line" ]] && tg_send "$_queue_line"
      fi
      # Restore the active project so subsequent commands use it.
      project_set "$(project_current)" >/dev/null 2>&1 || true
      ;;

    project|project\ list)
      handler_project list
      ;;

    project\ use\ *)
      handler_project use "${CMD_LOWER#project use }"
      ;;

    project\ info|project\ show)
      handler_project info
      ;;

    project\ info\ *)
      handler_project info "${CMD_LOWER#project info }"
      ;;

    project\ show\ *)
      handler_project info "${CMD_LOWER#project show }"
      ;;

    workflow)
      handler_workflow
      ;;

    workflow\ refresh)
      handler_workflow refresh
      ;;

    workflow\ refresh\ *)
      handler_workflow refresh "${CMD_LOWER#workflow refresh }"
      ;;

    workflow\ *)
      handler_workflow "${CMD_LOWER#workflow }"
      ;;

    rebase|rebase\ *)
      handler_rebase ${CMD_LOWER#rebase}
      ;;

    tickets)
      cmd_tickets
      ;;

    queue|queue\ all)
      # v0.5.0 — cross-project priority queue with fair-share ordering.
      cmd_queue_all 10
      ;;

    queue\ *)
      # Allow a numeric arg: /queue 20
      _qmax="${CMD_LOWER#queue }"
      [[ "$_qmax" =~ ^[0-9]+$ ]] && cmd_queue_all "$_qmax" || cmd_queue_all 10
      ;;

    mrs)
      cmd_mrs
      ;;

    logs)
      cmd_logs
      ;;

    digest)
      cmd_digest
      ;;

    run)
      cmd_run
      ;;

    run\ ua-*)
      handler_run_ticket "$CMD"
      ;;

    stop)
      cmd_stop_scheduled
      ;;

    start)
      cmd_start_scheduled
      ;;

    approve\ ua-*)
      handler_approve "$CMD"
      ;;

    skip\ ua-*)
      handler_skip "$CMD"
      ;;

    review\ ua-*:*)
      # Agent command — handler ignores it, agent picks up the text directly.
      # (The agent runs on schedule; user can send 'run' to trigger immediately.)
      send_telegram "Review feedback recorded for agent: ${CMD:0:120}..."
      ;;

    review\ ua-*)
      handler_review_prompt "$CMD"
      ;;

    retry\ ua-*)
      handler_retry "$CMD"
      ;;

    cherries)
      # List UA tickets that have YOUR commits on stage not yet on main — regardless
      # of current Jira assignee/status. Source of truth is git, not Jira.
      send_telegram "Checking for tickets eligible for cherry-pick to main…"
      CHERRIES_RESULT=$(
        ATLASSIAN_EMAIL="$ATLASSIAN_EMAIL" \
        ATLASSIAN_API_TOKEN="$ATLASSIAN_API_TOKEN" \
        CONFIG_PATH="$SKILL_DIR/config.json" \
        python3 <<'PYEOF' 2>&1
import os, json, subprocess, urllib.request, base64, re

atl_email = os.environ["ATLASSIAN_EMAIL"]
atl_token = os.environ["ATLASSIAN_API_TOKEN"]
auth = base64.b64encode(f"{atl_email}:{atl_token}".encode()).decode()

config = json.load(open(os.environ["CONFIG_PATH"]))
# Support both v0.2 (flat `repositories` / `owner` at root) and v0.3
# (`projects[].repositories`, owner still at root). Without this fallback the
# cherries scan silently saw zero repos on any v0.3 install — and printed
# "no commits by you on stage-not-on-main" regardless of what's actually
# pending on stage. See _cfg_resolve.py for the canonical normalisation.
_proj0 = (config.get("projects") or [{}])[0] if isinstance(config.get("projects"), list) else {}
repos = config.get("repositories") or _proj0.get("repositories") or {}
owner = config.get("owner") or _proj0.get("owner") or {}
owner_email = owner.get("email", "")
owner_gitlab = owner.get("gitlabUsername", "")

def run(cmd, cwd=None, timeout=180):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.strip(), r.stderr.strip()

# Author-identity tokens to match against `git log --format=%ae %an` lines.
# Covers GitLab email (noreply@gitlab), company email, and name variants.
my_email_fragments = [x for x in [
    owner_email,
    f"{owner_gitlab}@",
    owner.get("name","").lower().replace(" ","."),
] if x]

pat_ua = re.compile(r"\b(" + os.environ["TICKET_KEY_PATTERN"] + r")\b", re.IGNORECASE)

# {key_upper: {"repos": {slug: [{sha, subject, when}, ...]}, "summary": None, "status": None}}
by_key = {}

for slug, meta in repos.items():
    local = meta.get("localPath")
    stage = meta.get("defaultBranch", "stage")
    if not local or not os.path.isdir(local):
        continue
    rc, _, _ = run(["git","fetch","origin","--prune"], cwd=local)
    if rc != 0:
        continue
    rc, _, _ = run(["git","rev-parse","--verify","origin/main"], cwd=local)
    if rc != 0:
        continue
    rc, _, _ = run(["git","rev-parse","--verify",f"origin/{stage}"], cwd=local)
    if rc != 0:
        continue
    # Full log of stage-not-on-main with author email / subject / committer date
    rc, out, _ = run(["git","log",
                      f"origin/main..origin/{stage}",
                      "--no-merges",
                      "--format=%H%x01%ae%x01%an%x01%ci%x01%s"], cwd=local)
    if rc != 0:
        continue
    for line in out.splitlines():
        parts = line.split("\x01")
        if len(parts) < 5:
            continue
        sha, ae, an, ci, subject = parts
        author_blob = (ae + " " + an).lower()
        if not any(f and f.lower() in author_blob for f in my_email_fragments):
            continue
        for m in pat_ua.finditer(subject):
            k = m.group(1).upper()
            entry = by_key.setdefault(k, {"repos": {}, "summary": None, "status": None, "latest_when": ""})
            entry["repos"].setdefault(slug, []).append({"sha": sha[:8], "subject": subject[:120], "when": ci})
            if ci > entry["latest_when"]:
                entry["latest_when"] = ci

if not by_key:
    print(f"INFO: no commits by you on stage-not-on-main in any configured repo.")
    raise SystemExit(0)

# Enrich each ticket key with Jira status + summary + assignee (one bulk query)
owner_jira_aid = owner.get("jiraAccountId", "")
keys_list = list(by_key.keys())
batch = ",".join(keys_list)
# Require current assignee = me AND status = Done, and explicitly exclude
# Released — on workflows where "Released" is a separate leaf status we don't
# want to offer cherry-picking to main again (it's already shipped).
jql = (f"key in ({batch}) AND assignee = '{owner_jira_aid}' "
       f"AND status = 'Done' AND status != 'Released'")
body = json.dumps({"jql": jql, "maxResults": max(50, len(keys_list)),
                   "fields": ["summary","status","assignee"]}).encode()
matching_keys = set()
try:
    # NOTE: heredoc opens with <<'PYEOF' (single-quoted delimiter) so bash
    # does NOT expand ${JIRA_SITE} here — we must look it up via os.environ
    # at runtime. Previous code used the literal bash-style syntax and sent
    # "${JIRA_SITE}/rest/api/3/search/jql" to urllib, producing
    # 'unknown url type' errors the first time /cherries was invoked.
    req = urllib.request.Request(
        f"{os.environ['JIRA_SITE']}/rest/api/3/search/jql",
        data=body,
        headers={"Authorization": f"Basic {auth}", "Content-Type":"application/json"},
        method="POST")
    jira_data = json.loads(urllib.request.urlopen(req, timeout=20).read())
    for iss in jira_data.get("issues", []):
        k = iss["key"].upper()
        matching_keys.add(k)
        if k in by_key:
            by_key[k]["summary"] = iss["fields"].get("summary","")[:80]
            by_key[k]["status"]  = (iss["fields"].get("status") or {}).get("name", "")
            a = iss["fields"].get("assignee") or {}
            by_key[k]["assignee"] = a.get("displayName", "")
except Exception as e:
    print(f"ERR: Jira enrich query failed: {e}")
    raise SystemExit(1)

# Drop tickets that didn't satisfy (assignee=me AND status=Done), and
# belt-and-suspenders: drop anything whose returned status is Released in
# case the JQL filter didn't exclude it (different Jira instances resolve
# 'Done' against status vs statusCategory in inconsistent ways).
by_key = {
    k: v for k, v in by_key.items()
    if k in matching_keys
    and (v.get("status") or "").strip().lower() != "released"
}

if not by_key:
    print("INFO: no Done tickets assigned to you with commits on stage pending for main. Nothing to promote.")
    raise SystemExit(0)

# Check for existing open MRs targeting main — fetch once per repo, then match each ticket
open_to_main_by_repo = {}
for slug, meta in repos.items():
    local = meta.get("localPath")
    if not local or not os.path.isdir(local):
        continue
    mrs = []
    # Only show OPEN MRs — `--all` would include closed/merged, causing
    # false positives (e.g. MR 2067 was closed but kept matching on title).
    rc, out, err = run(["glab","mr","list",
                        "--target-branch","main",
                        "--per-page","100",
                        "-F","json"], cwd=local, timeout=60)
    if rc == 0 and out.strip().startswith(("[", "{")):
        try:
            mrs = json.loads(out)
        except Exception:
            mrs = []
    if not mrs:
        rc, out, _ = run(["glab","mr","list",
                          "--target-branch","main",
                          "--per-page","100"], cwd=local, timeout=60)
        for line in (out or "").splitlines():
            ln = line.strip()
            if not ln.startswith("!"):
                continue
            # crude parse: !2046  UA-832: promote to main (1 commits)  (promote/UA-832/to-main-... -> main)
            iid_part, _, rest = ln.partition(" ")
            try:
                iid = int(iid_part.lstrip("!"))
            except Exception:
                continue
            # source branch inside (… -> main)
            src = ""
            if "->" in rest:
                head = rest.rsplit("(", 1)[-1]
                src = head.split("->", 1)[0].strip()
            mrs.append({
                "iid": iid,
                "title": rest.rsplit("(", 1)[0].strip(),
                "source_branch": src,
                "target_branch": "main",
                "web_url": "",
            })
    open_to_main_by_repo[slug] = mrs

# Try to reconstruct missing web_url from the gitlabProject path
def _mr_url(slug, iid):
    meta = repos.get(slug) or {}
    proj = meta.get("gitlabProject") or ""
    if not proj or not iid:
        return ""
    return f"https://gitlab.com/{proj}/-/merge_requests/{iid}"

for key, info in by_key.items():
    for slug in list(info["repos"].keys()):
        match = None
        for m in open_to_main_by_repo.get(slug, []):
            title = (m.get("title") or "")
            src   = (m.get("source_branch") or "")
            if key in title or key in src:
                match = m
                break
        if match:
            info["open_main_mr"] = {
                "iid": match.get("iid"),
                "title": match.get("title"),
                "web_url": match.get("web_url") or _mr_url(slug, match.get("iid")),
                "repo": slug,
                "source_branch": match.get("source_branch"),
            }
            break

# Persist existing-open-MR info to promoted.json so [DM Approver] button works for these too
promoted_path = os.environ.get("PROMOTED_FILE") or os.path.expanduser(
    "~/.cursor/skills/autonomous-dev-agent/cache/promoted.json"
)
os.makedirs(os.path.dirname(promoted_path), exist_ok=True)
try:
    promoted_cache = json.load(open(promoted_path))
except Exception:
    promoted_cache = {}
import time as _t
for _k, _info in by_key.items():
    _mr = _info.get("open_main_mr")
    if _mr and _mr.get("web_url"):
        promoted_cache[_k] = {
            "url": _mr["web_url"],
            "branch": _mr.get("source_branch") or "",
            "repo": _mr.get("repo") or "",
            "stage": repos.get(_mr.get("repo") or "", {}).get("defaultBranch", "stage"),
            "ts": int(_t.time()),
            "source": "existing-mr-detected-by-cherries",
        }
try:
    json.dump(promoted_cache, open(promoted_path, "w"))
except Exception:
    pass

# Emit, newest commit first
eligible = sorted(by_key.items(), key=lambda kv: kv[1]["latest_when"], reverse=True)

# --- combined-promote opportunity -----------------------------------------
# If 2+ tickets are "eligible-new" (status=Done AND no open_main_mr) and they
# all live in the SAME repo, offer a single "cherry-pick ALL" card. Mixed-
# repo combinations are not supported (one MR per repo by necessity).
_new_items = [(k, v) for k, v in eligible if not v.get("open_main_mr")]
_new_repos = set()
for _, _v in _new_items:
    for _slug in _v["repos"].keys():
        _new_repos.add(_slug)
_combined = None
if len(_new_items) >= 2 and len(_new_repos) == 1:
    _repo = next(iter(_new_repos))
    _total_commits = sum(
        len(_v["repos"].get(_repo, [])) for _, _v in _new_items
    )
    _combined = {
        "__combined__": True,
        "repo": _repo,
        "keys": [k for k, _ in _new_items],
        "total_commits": _total_commits,
        "summaries": {k: (v.get("summary") or "") for k, v in _new_items},
    }

print("LIST")
if _combined:
    print(json.dumps(_combined))
for key, info in eligible:
    repo_slugs = list(info["repos"].keys())
    total = sum(len(c) for c in info["repos"].values())
    latest = max((c for slug in info["repos"] for c in info["repos"][slug]), key=lambda c: c["when"])
    out = {
        "key": key,
        "summary": info.get("summary") or "(summary unavailable)",
        "status": info.get("status") or "?",
        "assignee": info.get("assignee") or "?",
        "repos": repo_slugs,
        "commit_count": total,
        "latest_subject": latest["subject"],
        "open_main_mr": info.get("open_main_mr"),
    }
    print(json.dumps(out))
PYEOF
      )
      if [[ "$CHERRIES_RESULT" == INFO:* ]]; then
        send_telegram "$CHERRIES_RESULT"
      elif [[ "$CHERRIES_RESULT" == ERR:* ]]; then
        send_telegram "Error: $CHERRIES_RESULT"
      elif [[ "$CHERRIES_RESULT" == LIST* ]]; then
        # Send one message per entry with appropriate buttons. The first
        # entry MAY be a {"__combined__": true} summary card — count only
        # real per-ticket entries for the header.
        TICKET_COUNT=$(printf '%s\n' "$CHERRIES_RESULT" | tail -n +2 \
          | grep -cv '"__combined__"' || true)
        send_telegram "$TICKET_COUNT ticket(s) eligible for cherry-pick to main:"
        printf '%s\n' "$CHERRIES_RESULT" | tail -n +2 | while IFS= read -r line; do
          [ -z "$line" ] && continue
          # Render one item via a single python call so quoting stays sane
          RENDER=$(
            python3 - "$line" "$TELEGRAM_CHAT_ID" <<'PYE'
# NOTE: single-quoted heredoc — bash does NOT expand anything here. The
# previous version (a) forgot to `import os` and (b) used
# f"{os.environ[\"JIRA_SITE\"]}/..." (double quotes) is a SyntaxError in 3.9
# because nested double quotes inside a double-quoted f-string were only
# allowed in 3.12+ (PEP 701). We use single quotes inside the f-string
# expression to stay compatible with the /usr/bin/python3 3.9 shipped by
# the CommandLineTools toolchain.
import sys, json, os
line, chat_id = sys.argv[1], sys.argv[2]
d = json.loads(line)
jira_site = os.environ.get("JIRA_SITE", "")

# --- combined-promote summary card (first entry, if present) -------------
if d.get("__combined__"):
    keys = d.get("keys", [])
    repo = d.get("repo", "?")
    total = d.get("total_commits", 0)
    summaries = d.get("summaries", {}) or {}
    # Callback data has a hard 64-byte limit. Drop ticket keys if we exceed.
    joined = ",".join(keys)
    # Reserve 22 bytes for 'tk_cherryall:' + repo + ':' + safety margin
    while len(f"tk_cherryall:{repo}:{joined}") > 60 and len(keys) > 2:
        keys = keys[:-1]
        joined = ",".join(keys)
    lines = [f"Cherry-pick all {len(d.get('keys',[]))} tickets to main ({repo}):"]
    for k in d.get("keys", []):
        s = summaries.get(k) or ""
        lines.append(f"• {k} — {s}" if s else f"• {k}")
    lines.append(f"\nTotal commits to replay: {total}")
    lines.append("One branch, one MR to main.")
    text = "\n".join(lines)
    kb = {"inline_keyboard": [[
        {"text": f"Cherry-pick ALL {len(keys)} to main",
         "callback_data": f"tk_cherryall:{repo}:{joined}"},
    ]]}
    print(json.dumps({"chat_id": chat_id, "text": text, "reply_markup": kb}))
    sys.exit(0)

# --- per-ticket card ------------------------------------------------------
repos_str = ", ".join(d.get("repos", [])) or "?"
open_mr = d.get("open_main_mr") or None

if open_mr:
    text = (f"{d['key']} [{d.get('status','?')}] — {d['summary']}\n"
            f"Already has open promote MR → main: !{open_mr['iid']}\n"
            f"Repo: {open_mr.get('repo','?')}")
    buttons_row1 = [
        {"text": "DM Approver", "callback_data": f"rel_dm:{d['key']}"},
        {"text": "Open MR",     "url": open_mr["web_url"]},
    ]
    buttons_row2 = [
        {"text": "Open in Jira", "url": f"{jira_site}/browse/{d['key']}"},
    ]
    kb = {"inline_keyboard": [buttons_row1, buttons_row2]}
else:
    text = (f"{d['key']} [{d.get('status','?')}] — {d['summary']}\n"
            f"Repos: {repos_str} • {d['commit_count']} commit(s) pending on stage\n"
            f"Assignee: {d.get('assignee','?')}\n"
            f"Latest: {d['latest_subject']}")
    kb = {"inline_keyboard": [
        [{"text": "Cherry-pick to main", "callback_data": f"tk_cherry:{d['key']}"},
         {"text": "Open in Jira",        "url": f"{jira_site}/browse/{d['key']}"}]
    ]}
print(json.dumps({"chat_id": chat_id, "text": text, "reply_markup": kb}))
PYE
          )
          send_telegram_raw "$RENDER"
        done
      else
        send_telegram "Unexpected output from cherries check:
$CHERRIES_RESULT"
      fi
      ;;

    reviews)
      if ! command -v glab >/dev/null 2>&1; then
        send_telegram "Error: glab CLI not found in PATH."
        continue
      fi

      # 1) Query Jira for Code Review tickets assigned to me
      JIRA_RV=$(curl -s -u "${ATLASSIAN_EMAIL}:${ATLASSIAN_API_TOKEN}" \
        -X POST "${JIRA_SITE}/rest/api/3/search/jql" \
        -H "Content-Type: application/json" \
        -d "{
          \"jql\": \"assignee = '${JIRA_ACCOUNT_ID}' AND status = 'Code Review' ORDER BY updated DESC\",
          \"maxResults\": 20,
          \"fields\": [\"summary\",\"status\"]
        }" 2>/dev/null)

      TICKET_KEYS=$(echo "$JIRA_RV" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for i in data.get('issues', []):
    print(i['key'])
" 2>/dev/null)

      # 2) For each ticket, find its MR + author in SSR or Blog repo
      REPOS="$SSR_REPO $BLOG_REPO"
      ME="${GITLAB_USER}"
      ELIGIBLE_ROWS=""   # fields: mr_iid<TAB>ticket<TAB>author<TAB>url<TAB>repo<TAB>project_path

      echo "[reviews] Jira returned tickets: $(echo $TICKET_KEYS | tr '\n' ' ')"

      for TK in $TICKET_KEYS; do
        for REPO in $REPOS; do
          [ ! -d "$REPO" ] && echo "[reviews] skip missing repo $REPO" && continue
          MR_JSON=$(cd "$REPO" && glab mr list --search="$TK" --output=json 2>/dev/null || echo "[]")
          MR_COUNT=$(echo "$MR_JSON" | python3 -c "import sys,json
try: print(len(json.load(sys.stdin)))
except: print(0)" 2>/dev/null)
          echo "[reviews] $TK in $(basename $REPO): $MR_COUNT MR(s) from search"
          ROW=$(REPO="$REPO" TK="$TK" ME="$ME" MR_JSON="$MR_JSON" python3 -c "
import json, os, re
data = json.loads(os.environ.get('MR_JSON','[]') or '[]')
tk = os.environ['TK']
me = os.environ['ME']
repo = os.environ['REPO']
for mr in data:
    state = mr.get('state', '')
    if state not in ('opened', 'open'):
        continue
    branch = mr.get('source_branch', '') or ''
    title = mr.get('title', '') or ''
    if tk.upper() not in (branch.upper() + ' ' + title.upper()):
        continue
    author = mr.get('author', {}).get('username', '') or '-'
    if author == me:
        print(f'__SKIP_MINE__\t{tk}\t{author}', file=__import__('sys').stderr)
        continue
    iid = mr.get('iid') or mr.get('id') or '-'
    url = mr.get('web_url', '') or '-'
    m = re.match(r'https?://[^/]+/([^?]+)/-/merge_requests/', url)
    proj = m.group(1) if m else '-'
    # '-' sentinels prevent bash IFS=tab from collapsing consecutive empty fields
    print(f'{iid}\t{tk}\t{author}\t{url}\t{repo}\t{proj}')
    break
" 2>&1)
          echo "[reviews] $TK match row: '$ROW'"
          if [ -n "$ROW" ] && [[ "$ROW" == *$'\t'* ]] && [[ "$ROW" != __SKIP_MINE__* ]]; then
            ELIGIBLE_ROWS="${ELIGIBLE_ROWS}${ROW}
"
            break
          fi
        done
      done

      if [ -z "$ELIGIBLE_ROWS" ]; then
        send_telegram "No Code Review tickets assigned to you (or all found MRs are authored by you)."
        continue
      fi

      TOTAL=$(printf '%s' "$ELIGIBLE_ROWS" | grep -c $'\t' || echo 0)
      send_telegram "$TOTAL MR(s) need your review:"

      # 3) For each eligible MR, render a summary card with buttons
      printf '%s' "$ELIGIBLE_ROWS" | while IFS=$'\t' read -r MR_IID TICKET_KEY AUTHOR MR_URL REPO_PATH PROJ_PATH; do
        [ -z "$MR_IID" ] && continue

        # Look up cache file (any *.json for this MR_IID, excluding discussions + stub marker)
        RFILE=$(ls -t "$CACHE_DIR/reviews/${MR_IID}-"*.json 2>/dev/null | grep -v discussions | head -1)

        if [ -n "$RFILE" ] && [ -s "$RFILE" ]; then
          # We have a cached review — use it
          RMETA=$(RFILE="$RFILE" python3 <<'PYEOF' 2>/dev/null
import json, os
r = json.load(open(os.environ["RFILE"]))
comments = r.get('comments', [])
pending = [c for c in comments if c.get('status','pending') == 'pending']
print(r.get('verdict','needs-comments'))
print(len(pending))
print(len(comments))
print((r.get('summary','') or '').replace('\n',' ')[:400])
print(r.get('round') or 1)
PYEOF
)
          VERDICT=$(echo "$RMETA" | sed -n '1p')
          N_PENDING=$(echo "$RMETA" | sed -n '2p')
          N_TOTAL=$(echo "$RMETA" | sed -n '3p')
          SUMMARY=$(echo "$RMETA" | sed -n '4p')
          ROUND=$(echo "$RMETA" | sed -n '5p')

          if [ "${ROUND:-1}" -gt 1 ] 2>/dev/null; then
            ROUND_TAG=" (round $ROUND)"
          else
            ROUND_TAG=""
          fi

          if [ "$VERDICT" = "lgtm" ]; then
            TEXT="[$TICKET_KEY] !$MR_IID by $AUTHOR — LGTM$ROUND_TAG
$SUMMARY"
            KB="[[{\"text\":\"Approve MR\",\"callback_data\":\"rv_approve:$MR_IID\"},{\"text\":\"Open in GitLab\",\"url\":\"$MR_URL\"}],[{\"text\":\"Re-review\",\"callback_data\":\"rv_reviewnow:$MR_IID\"},{\"text\":\"Skip for now\",\"callback_data\":\"rv_skipmr:$MR_IID\"}]]"
          elif [ "$VERDICT" = "not-reviewed" ] || [ "${N_TOTAL:-0}" = "0" ]; then
            # Stub or empty review — no real comments yet. Prominent Review now.
            TEXT="[$TICKET_KEY] !$MR_IID by $AUTHOR — not yet reviewed$ROUND_TAG
$SUMMARY"
            KB="[[{\"text\":\"Review now\",\"callback_data\":\"rv_reviewnow:$MR_IID\"},{\"text\":\"Open in GitLab\",\"url\":\"$MR_URL\"}],[{\"text\":\"Approve without review\",\"callback_data\":\"rv_approve:$MR_IID\"},{\"text\":\"Skip for now\",\"callback_data\":\"rv_skipmr:$MR_IID\"}]]"
          else
            TEXT="[$TICKET_KEY] !$MR_IID by $AUTHOR — $N_PENDING/$N_TOTAL comments pending$ROUND_TAG
$SUMMARY"
            KB="[[{\"text\":\"Show comments ($N_PENDING)\",\"callback_data\":\"rv_show:$MR_IID\"},{\"text\":\"Open in GitLab\",\"url\":\"$MR_URL\"}],[{\"text\":\"Send to dev\",\"callback_data\":\"rv_sendtodev:$MR_IID\"},{\"text\":\"Approve MR\",\"callback_data\":\"rv_approve:$MR_IID\"}],[{\"text\":\"Re-review\",\"callback_data\":\"rv_reviewnow:$MR_IID\"},{\"text\":\"Skip for now\",\"callback_data\":\"rv_skipmr:$MR_IID\"}]]"
          fi
        else
          # No cached review yet — write a stub so approve/skip still have context
          STUB="$CACHE_DIR/reviews/${MR_IID}-stub.json"
          MR_IID="$MR_IID" TICKET_KEY="$TICKET_KEY" AUTHOR="$AUTHOR" \
          MR_URL="$MR_URL" PROJ_PATH="$PROJ_PATH" STUB="$STUB" python3 <<'PYEOF' 2>/dev/null
import json, os, urllib.parse
proj = os.environ["PROJ_PATH"]
stub = {
    "mr_iid": int(os.environ["MR_IID"]),
    "mr_url": os.environ["MR_URL"],
    "ticket_key": os.environ["TICKET_KEY"],
    "project_path": proj,
    "project_encoded": urllib.parse.quote(proj, safe=''),
    "author": os.environ["AUTHOR"],
    "diff_refs": {},
    "summary": "",
    "comments": [],
    "verdict": "not-reviewed"
}
json.dump(stub, open(os.environ["STUB"], 'w'), indent=2)
PYEOF
          TEXT="[$TICKET_KEY] !$MR_IID by $AUTHOR — not yet reviewed"
          KB="[[{\"text\":\"Review Now\",\"callback_data\":\"rv_reviewnow:$MR_IID\"},{\"text\":\"Open in GitLab\",\"url\":\"$MR_URL\"}],[{\"text\":\"Approve without review\",\"callback_data\":\"rv_approve:$MR_IID\"},{\"text\":\"Skip for now\",\"callback_data\":\"rv_skipmr:$MR_IID\"}]]"
        fi

        send_telegram_inline "$TEXT" "$KB"
      done
      ;;

    rv_reviewnow\ *)
      # rv_reviewnow <mr_iid> — trigger agent run focused on this MR's ticket
      MR_IID=$(echo "$CMD" | awk '{print $2}')
      RFILE=$(ls -t "$CACHE_DIR/reviews/${MR_IID}-"*.json 2>/dev/null | head -1)
      if [ -z "$RFILE" ]; then
        send_telegram "No context for !$MR_IID — tap 'reviews' first."
        continue
      fi

      TICKET_KEY=$(python3 -c "import json;print(json.load(open('$RFILE')).get('ticket_key',''))" 2>/dev/null)
      if [ -z "$TICKET_KEY" ]; then
        send_telegram "Ticket key missing for !$MR_IID"
        continue
      fi

      export FORCE_TICKET="$TICKET_KEY"
      _spawn_agent "$TICKET_KEY" "Triggering review for $TICKET_KEY (!$MR_IID)..."
      unset FORCE_TICKET
      ;;

    rv_show\ *)
      # rv_show <mr_iid> — send one message per pending comment with Post/Edit/Discuss/Skip
      MR_IID=$(echo "$CMD" | awk '{print $2}')
      RFILE=$(ls -t "$CACHE_DIR/reviews/${MR_IID}-"*.json 2>/dev/null | grep -v discussions | head -1)
      if [ -z "$RFILE" ]; then
        send_telegram "Review file not found for MR !$MR_IID"
        continue
      fi

      # Emit pending comments using a tab-separated single line per comment
      # so bash can parse with `read`. Special chars in the body are handled
      # because body is last and can contain anything except newlines (we replace).
      SHOW_OUT=$(RFILE="$RFILE" python3 <<'PYEOF' 2>/dev/null
import json, os
r = json.load(open(os.environ["RFILE"]))
comments = r.get('comments', [])
pending = [(i, c) for i, c in enumerate(comments) if c.get('status','pending') == 'pending']
if not pending:
    print("ALL_DONE")
else:
    for idx, c in pending:
        body = c.get('body','').replace('\t',' ').replace('\n',' ')
        line = c.get('line_new') or c.get('line_old') or '?'
        print(f"{idx}\t{c.get('file','?')}\t{line}\t{c.get('severity','medium')}\t{c.get('category','other')}\t{body}")
PYEOF
)

      if [ "$SHOW_OUT" = "ALL_DONE" ] || [ -z "$SHOW_OUT" ]; then
        send_telegram "All comments for !$MR_IID have been resolved."
        continue
      fi

      while IFS=$'\t' read -r CIDX CFILE CLINE CSEV CCAT CBODY; do
        [ -z "$CIDX" ] && continue
        TXT="!$MR_IID #$CIDX [$CSEV/$CCAT]
$CFILE:$CLINE

$CBODY"
        KB="[[{\"text\":\"Post\",\"callback_data\":\"rv_post:$MR_IID:$CIDX\"},{\"text\":\"Edit\",\"callback_data\":\"rv_edit:$MR_IID:$CIDX\"}],[{\"text\":\"Discuss with AI\",\"callback_data\":\"rv_discuss:$MR_IID:$CIDX\"},{\"text\":\"Skip\",\"callback_data\":\"rv_skipc:$MR_IID:$CIDX\"}]]"
        send_telegram_inline "$TXT" "$KB"
      done <<< "$SHOW_OUT"
      ;;

    rv_post\ *)
      # rv_post <mr_iid> <idx> — post the comment as inline discussion to GitLab
      MR_IID=$(echo "$CMD" | awk '{print $2}')
      CIDX=$(echo "$CMD" | awk '{print $3}')
      RFILE=$(ls -t "$CACHE_DIR/reviews/${MR_IID}-"*.json 2>/dev/null | grep -v discussions | head -1)
      if [ -z "$RFILE" ]; then
        send_telegram "Review file missing for !$MR_IID"
        continue
      fi

      POST_RESULT=$(MR_IID="$MR_IID" CIDX="$CIDX" RFILE="$RFILE" python3 <<'PYEOF' 2>&1
import json, os, subprocess, urllib.parse, re

rfile = os.environ["RFILE"]
cidx = int(os.environ["CIDX"])
r = json.load(open(rfile))
comments = r.get('comments', [])
if cidx >= len(comments):
    print("ERR: index out of range"); raise SystemExit(1)
c = comments[cidx]
diff = r.get('diff_refs', {})
project = r.get('project_path', '')
proj_enc = urllib.parse.quote(project, safe='')
mr_iid = r.get('mr_iid')
file_path = c.get('file', '')
body = c.get('body', '')
line_new = c.get('line_new')
line_old = c.get('line_old')

# --- 1) Fetch the MR diff to resolve proper line positions ---
diff_cmd = ["glab", "api", f"projects/{proj_enc}/merge_requests/{mr_iid}/diffs?per_page=100"]
dres = subprocess.run(diff_cmd, capture_output=True, text=True)
diffs = []
if dres.returncode == 0:
    try:
        diffs = json.loads(dres.stdout)
    except Exception:
        diffs = []

# Build line map for our target file: new_line -> (type, old_line)
# type in {'context', 'added'}; for removed lines we'd map via old_line
line_map_new = {}   # new_line -> {type, old_line}
line_map_old = {}   # old_line -> {type, new_line}
file_in_diff = False
new_path = file_path
old_path = file_path

for d in diffs:
    if d.get('new_path') == file_path or d.get('old_path') == file_path:
        file_in_diff = True
        new_path = d.get('new_path') or file_path
        old_path = d.get('old_path') or file_path
        raw = d.get('diff', '') or ''
        old_n = new_n = 0
        for ln in raw.split('\n'):
            m = re.match(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@', ln)
            if m:
                old_n = int(m.group(1))
                new_n = int(m.group(2))
                continue
            if not ln:
                continue
            tag = ln[0]
            if tag == '+':
                line_map_new[new_n] = {'type': 'added', 'old_line': None}
                new_n += 1
            elif tag == '-':
                line_map_old[old_n] = {'type': 'removed', 'new_line': None}
                old_n += 1
            elif tag == ' ':
                line_map_new[new_n] = {'type': 'context', 'old_line': old_n}
                line_map_old[old_n] = {'type': 'context', 'new_line': new_n}
                old_n += 1
                new_n += 1
        break

# --- 2) Decide how to post ---
import tempfile

def _post_json(payload):
    # glab's --field only supports flat form-data; GitLab strips nested
    # position[...] brackets. We must send JSON via --input.
    tf = tempfile.NamedTemporaryFile('w', suffix='.json', delete=False)
    json.dump(payload, tf)
    tf.close()
    try:
        cmd = ["glab", "api", "--method", "POST",
               "--header", "Content-Type: application/json",
               "--input", tf.name,
               f"projects/{proj_enc}/merge_requests/{mr_iid}/discussions"]
        res = subprocess.run(cmd, capture_output=True, text=True)
        ok = res.returncode == 0
        # Verify that the response is a DiffNote when we expected inline
        response_type = None
        if ok and res.stdout:
            try:
                rj = json.loads(res.stdout)
                notes = rj.get('notes', [])
                if notes:
                    response_type = notes[0].get('type')
            except Exception:
                pass
        return ok, response_type, (res.stderr or '')[:400]
    finally:
        try: os.unlink(tf.name)
        except Exception: pass

def post_with_position(pos_fields, include_old_path=True):
    position = {
        "position_type": "text",
        "base_sha": diff.get('base_sha',''),
        "start_sha": diff.get('start_sha',''),
        "head_sha": diff.get('head_sha',''),
        "new_path": new_path,
        "old_path": old_path,
    }
    position.update(pos_fields)
    ok, rtype, err = _post_json({"body": body, "position": position})
    # Treat "silent fallback to DiscussionNote" as failure so caller retries / falls back.
    if ok and rtype is not None and rtype != "DiffNote":
        return False, f"GitLab rejected position (got {rtype})"
    return ok, err

def post_general(prefix_body):
    ok, rtype, err = _post_json({"body": prefix_body})
    return ok, err

posted = False
err_msg = ''
mode = 'unknown'

if file_in_diff:
    target_new = line_new if line_new else None
    target_old = line_old if line_old else None
    pos = None

    # If the cache explicitly sets BOTH line_new and line_old (and they're equal),
    # trust it as an unchanged-line anchor — works for lines outside the hunk too.
    if target_new and target_old and target_new == target_old \
       and target_new not in line_map_new and target_old not in line_map_old:
        pos = {'new_line': target_new, 'old_line': target_old}
        mode = 'inline-unchanged'
    elif target_new and target_new in line_map_new:
        info = line_map_new[target_new]
        if info['type'] == 'context' and info['old_line']:
            pos = {'new_line': target_new, 'old_line': info['old_line']}
            mode = 'inline-context'
        else:
            pos = {'new_line': target_new}
            mode = 'inline-added'
    elif target_old and target_old in line_map_old:
        info = line_map_old[target_old]
        if info['type'] == 'context' and info['new_line']:
            pos = {'old_line': target_old, 'new_line': info['new_line']}
            mode = 'inline-context'
        else:
            pos = {'old_line': target_old}
            mode = 'inline-removed'
    elif target_new and target_old:
        # Both provided but not equal and not in hunks — try as-is
        pos = {'new_line': target_new, 'old_line': target_old}
        mode = 'inline-explicit'
    elif target_new:
        # Line not in hunk — try context-style guess (may fail)
        pos = {'new_line': target_new, 'old_line': target_new}
        mode = 'inline-guess'

    if pos is not None:
        posted, err_msg = post_with_position(pos)
        if not posted and mode == 'inline-guess':
            posted, err_msg = post_with_position({'new_line': target_new})
            mode = 'inline-added-fallback'

if not posted:
    # File not in diff, or inline position rejected -> general discussion with a clear header
    loc = file_path
    if line_new: loc += f":{line_new}"
    elif line_old: loc += f":{line_old}"
    prefix_body = f"**{loc}**\n\n{body}"
    posted, err_msg = post_general(prefix_body)
    mode = 'general' if posted else mode

if not posted:
    print(f"ERR: {err_msg}")
    raise SystemExit(1)

# Mark as posted with mode info
comments[cidx]['status'] = 'posted'
comments[cidx]['post_mode'] = mode
r['comments'] = comments
json.dump(r, open(rfile, 'w'), indent=2)
print(f"OK:{mode}")
PYEOF
)

      if [[ "$POST_RESULT" == OK:* ]]; then
        MODE="${POST_RESULT#OK:}"
        send_telegram "Posted comment #$CIDX to !$MR_IID ($MODE)"
      else
        send_telegram "Failed to post #$CIDX on !$MR_IID: $POST_RESULT"
      fi
      ;;

    rv_edit\ *)
      # rv_edit <mr_iid> <idx> — ask user for new text via force_reply
      MR_IID=$(echo "$CMD" | awk '{print $2}')
      CIDX=$(echo "$CMD" | awk '{print $3}')
      send_force_reply "Edit comment ${MR_IID}#${CIDX}:"
      ;;

    rv_editapply\ *)
      # rv_editapply <mr_iid> <idx> <new_body> — save edited body to cache
      MR_IID=$(echo "$CMD" | awk '{print $2}')
      CIDX=$(echo "$CMD" | awk '{print $3}')
      NEW_BODY=$(echo "$CMD" | cut -d' ' -f4-)
      RFILE=$(ls -t "$CACHE_DIR/reviews/${MR_IID}-"*.json 2>/dev/null | grep -v discussions | head -1)

      MR_IID="$MR_IID" CIDX="$CIDX" NEW_BODY="$NEW_BODY" RFILE="$RFILE" python3 <<'PYEOF' 2>/dev/null
import json, os
r = json.load(open(os.environ["RFILE"]))
i = int(os.environ["CIDX"])
r['comments'][i]['body'] = os.environ["NEW_BODY"]
r['comments'][i]['status'] = 'edited'
json.dump(r, open(os.environ["RFILE"], 'w'), indent=2)
PYEOF
      # Re-present the updated comment with action buttons
      KB="[[{\"text\":\"Post\",\"callback_data\":\"rv_post:$MR_IID:$CIDX\"},{\"text\":\"Edit again\",\"callback_data\":\"rv_edit:$MR_IID:$CIDX\"}],[{\"text\":\"Discuss with AI\",\"callback_data\":\"rv_discuss:$MR_IID:$CIDX\"},{\"text\":\"Skip\",\"callback_data\":\"rv_skipc:$MR_IID:$CIDX\"}]]"
      send_telegram_inline "Updated !$MR_IID #$CIDX:

$NEW_BODY" "$KB"
      ;;

    rv_discuss\ *)
      # rv_discuss <mr_iid> <idx> — ask user for question via force_reply
      MR_IID=$(echo "$CMD" | awk '{print $2}')
      CIDX=$(echo "$CMD" | awk '{print $3}')
      send_force_reply "Discuss comment ${MR_IID}#${CIDX}:"
      ;;

    rv_discussapply\ *)
      # rv_discussapply <mr_iid> <idx> <question> — store question, trigger agent run
      MR_IID=$(echo "$CMD" | awk '{print $2}')
      CIDX=$(echo "$CMD" | awk '{print $3}')
      QUESTION=$(echo "$CMD" | cut -d' ' -f4-)
      DFILE="$CACHE_DIR/reviews/${MR_IID}-discussions.json"

      MR_IID="$MR_IID" CIDX="$CIDX" QUESTION="$QUESTION" DFILE="$DFILE" python3 <<'PYEOF' 2>/dev/null
import json, os, datetime
p = os.environ["DFILE"]
data = json.load(open(p)) if os.path.exists(p) else {"questions": []}
data["questions"].append({
    "idx": len(data["questions"]),
    "comment_idx": int(os.environ["CIDX"]),
    "question": os.environ["QUESTION"],
    "asked_at": datetime.datetime.utcnow().isoformat() + "Z",
    "answered": False,
    "answer": None
})
json.dump(data, open(p, 'w'), indent=2)
PYEOF
      send_telegram "Question saved for !$MR_IID #$CIDX. Agent will answer on the next run. Send 'run' to trigger now."
      ;;

    rv_skipc\ *)
      # rv_skipc <mr_iid> <idx> — mark comment as skipped
      MR_IID=$(echo "$CMD" | awk '{print $2}')
      CIDX=$(echo "$CMD" | awk '{print $3}')
      RFILE=$(ls -t "$CACHE_DIR/reviews/${MR_IID}-"*.json 2>/dev/null | grep -v discussions | head -1)

      MR_IID="$MR_IID" CIDX="$CIDX" RFILE="$RFILE" python3 <<'PYEOF' 2>/dev/null
import json, os
r = json.load(open(os.environ["RFILE"]))
r['comments'][int(os.environ["CIDX"])]['status'] = 'skipped'
json.dump(r, open(os.environ["RFILE"], 'w'), indent=2)
PYEOF
      send_telegram "Skipped !$MR_IID #$CIDX"
      ;;

    rv_approve\ *)
      # rv_approve <mr_iid> — approve MR, auto-resolve stale threads, move Jira
      # ticket to Ready For QA, unassign, clean cached review files.
      #
      # All API work goes through lib/gitlab.sh + lib/jira.sh so this handler
      # stays declarative. Each step tracks its own success into a WARN_*
      # variable so partial failures surface clearly in Telegram without
      # aborting the whole flow (approving an MR is worth continuing through
      # even if, say, the Jira transition hits a transient error).
      MR_IID=$(echo "$CMD" | awk '{print $2}')
      RFILE=$(ls -t "$CACHE_DIR/reviews/${MR_IID}-"*.json 2>/dev/null | grep -v discussions | head -1)
      if [ -z "$RFILE" ]; then
        send_telegram "Review file missing for !$MR_IID"
        continue
      fi

      # Extract the handful of fields we actually need from the cached review.
      PROJECT=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("project_path",""))' "$RFILE")
      TICKET=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("ticket_key",""))' "$RFILE")

      if [[ -z "$PROJECT" || -z "$TICKET" ]]; then
        send_telegram "Cannot approve !$MR_IID — review file is missing project_path or ticket_key"
        continue
      fi

      WARN_LINES=""
      _warn() { WARN_LINES="${WARN_LINES}${WARN_LINES:+$'\n'}WARN: $*"; }

      # 1) Approve MR (idempotent — "already approved" is treated as success).
      if ! APPROVE_OUT=$(gl_mr_approve "$PROJECT" "$MR_IID"); then
        # Hard failure — don't continue to Jira changes on a broken MR action.
        send_telegram "Approval issues on !$MR_IID: gl_mr_approve failed
$(printf '%s' "$APPROVE_OUT" | head -3)"
        continue
      fi

      # 2) Auto-resolve should_resolve threads (Phase 8 thread hygiene).
      RESOLVED_COUNT=0
      while IFS= read -r DID; do
        [[ -z "$DID" ]] && continue
        if gl_mr_resolve_discussion "$PROJECT" "$MR_IID" "$DID" >/dev/null 2>&1; then
          RESOLVED_COUNT=$((RESOLVED_COUNT + 1))
        fi
      done < <(python3 -c '
import json, sys
r = json.load(open(sys.argv[1]))
for t in r.get("thread_audit", []) or []:
    if t.get("status") == "should_resolve" and t.get("discussion_id"):
        print(t["discussion_id"])
' "$RFILE")

      # 3) Transition ticket through the "after_approve" semantic intent.
      #    workflow.sh resolves the exact transition id for this project
      #    (Ready For QA on most teams, some variant of it on others). Falls
      #    back to the name-match path if the workflow cache hasn't been
      #    populated yet — safe on first run.
      workflow_transition "$TICKET" after_approve || _warn "Jira transition (after_approve) failed"

      # 4) Unassign.
      jira_unassign "$TICKET" || _warn "unassign failed"

      # 5) Cleanup cached review + discussions files.
      rm -f "$RFILE"
      rm -f "$CACHE_DIR/reviews/${MR_IID}-discussions.json"

      # 6) Emit a Tempo capture event so Phase 2 can measure review time.
      tl_emit mr_approved ticket="$TICKET" mr_iid="$MR_IID"

      # 7) Telegram message — assemble once from the tracked results.
      RESOLVED_LINE=""
      if [[ "$RESOLVED_COUNT" -gt 0 ]]; then
        RESOLVED_LINE="
Auto-resolved $RESOLVED_COUNT carried-over thread(s) that were addressed by later commits."
      fi
      if [[ -n "$WARN_LINES" ]]; then
        send_telegram "Approved !$MR_IID → $TICKET, but:
$WARN_LINES${RESOLVED_LINE}"
      else
        send_telegram "Approved !$MR_IID → $TICKET moved to Ready For QA + unassigned.${RESOLVED_LINE}"
      fi

      # 8) Immediate Tempo suggestion — we just closed a review round, so
      #    tempo-suggest.py can now compute review_time for today. Silent
      #    no-op if below 15-min floor, already logged, or user previously
      #    tm_skip'd this (ticket, today).
      if type tempo_suggest_now >/dev/null 2>&1; then
        tempo_suggest_now "$TICKET" "Review done on !$MR_IID → $TICKET. Log review time?"
      fi
      ;;

    rv_sendtodev\ *)
      # rv_sendtodev <mr_iid> — transition Jira to In Progress + assign to MR author, cleanup cache
      MR_IID=$(echo "$CMD" | awk '{print $2}')
      RFILE=$(ls -t "$CACHE_DIR/reviews/${MR_IID}-"*.json 2>/dev/null | grep -v discussions | head -1)
      if [ -z "$RFILE" ]; then
        send_telegram "Review file missing for !$MR_IID"
        continue
      fi

      SEND_RESULT=$(MR_IID="$MR_IID" RFILE="$RFILE" \
        ATLASSIAN_EMAIL="$ATLASSIAN_EMAIL" ATLASSIAN_API_TOKEN="$ATLASSIAN_API_TOKEN" \
        CONFIG_FILE="$SKILL_DIR/config.json" CACHE_DIR="$CACHE_DIR" python3 <<'PYEOF' 2>&1
import json, os, subprocess, urllib.parse, urllib.request, base64, glob

r = json.load(open(os.environ["RFILE"]))
ticket = r.get('ticket_key', '')
author = r.get('author', '')  # GitLab username of MR author
mr_iid = r.get('mr_iid')

if not ticket or not author:
    print(f"ERR: missing ticket or author in review cache")
    raise SystemExit(1)

email_addr = os.environ["ATLASSIAN_EMAIL"]
token = os.environ["ATLASSIAN_API_TOKEN"]
auth = base64.b64encode(f"{email_addr}:{token}".encode()).decode()
headers = {"Authorization": f"Basic {auth}", "Content-Type": "application/json"}

# --- 1) Resolve GitLab author -> Jira accountId ---
# Strategy A: reviewer pool in config.json (gitlabUsername)
# Strategy B: cached user-map file
# Strategy C: glab user -> email -> Jira user search by email
# Strategy D: glab user -> full name -> Jira user search by name
user_map_file = os.environ.get("GITLAB_JIRA_USERS_FILE") or \
    os.path.join(os.environ["CACHE_DIR"], "gitlab-jira-users.json")
user_map = {}
if os.path.exists(user_map_file):
    try: user_map = json.load(open(user_map_file))
    except Exception: user_map = {}

jira_account_id = None

# A) config reviewer pool
# Reviewers live at projects[0].reviewers in v0.3 configs, owner stays at
# root. Without the projects[0] fallback this Strategy-A path silently
# misses every configured reviewer on v0.3 installs, kicking every lookup
# out to the slower Strategy-C+D live GitLab/Jira search.
try:
    cfg = json.load(open(os.environ["CONFIG_FILE"]))
    _proj0 = (cfg.get("projects") or [{}])[0] if isinstance(cfg.get("projects"), list) else {}
    _reviewers = cfg.get("reviewers") or _proj0.get("reviewers") or []
    for rv in _reviewers:
        if rv.get("gitlabUsername") == author:
            jira_account_id = rv["jiraAccountId"]
            break
    if not jira_account_id and cfg.get("owner", {}).get("gitlabUsername") == author:
        jira_account_id = cfg["owner"]["jiraAccountId"]
except Exception as e:
    print(f"WARN: config lookup failed: {e}")

# B) cached map
if not jira_account_id and author in user_map:
    jira_account_id = user_map[author]

# C+D) live lookup via GitLab + Jira
if not jira_account_id:
    try:
        res = subprocess.run(["glab","api",f"users?username={urllib.parse.quote(author)}"],
                             capture_output=True, text=True)
        users = json.loads(res.stdout or '[]')
        if users:
            u = users[0]
            public_email = u.get("public_email") or u.get("email") or ""
            full_name = u.get("name") or ""

            candidates = []
            if public_email:
                candidates.append(public_email)
            if full_name:
                candidates.append(full_name)

            for q in candidates:
                req = urllib.request.Request(
                    f"{os.environ['JIRA_SITE']}/rest/api/3/user/search?query={urllib.parse.quote(q)}",
                    headers=headers
                )
                try:
                    jr = json.loads(urllib.request.urlopen(req, timeout=15).read())
                    if jr:
                        jira_account_id = jr[0].get("accountId")
                        if jira_account_id:
                            break
                except Exception as e:
                    print(f"WARN: Jira search for '{q}' failed: {e}")
    except Exception as e:
        print(f"WARN: GitLab user lookup failed: {e}")

if not jira_account_id:
    print(f"ERR: could not resolve Jira accountId for GitLab user '{author}'. "
          f"Add gitlabUsername to config.json reviewers or manually assign on Jira.")
    raise SystemExit(1)

# Cache the mapping for next time
user_map[author] = jira_account_id
json.dump(user_map, open(user_map_file, 'w'), indent=2)

# --- 2) Find transition to "Work In Progress" (In Progress) ---
req = urllib.request.Request(
    f"{os.environ['JIRA_SITE']}/rest/api/3/issue/{ticket}/transitions",
    headers=headers
)
tdata = json.loads(urllib.request.urlopen(req, timeout=15).read())
available = [t['name'] for t in tdata.get('transitions', [])]
tid = None
preferred = ['work in progress', 'in progress', 'to in progress', 'start progress', 'start work']
for pref in preferred:
    for t in tdata.get('transitions', []):
        if t['name'].lower() == pref:
            tid = t['id']
            break
    if tid: break
# Fuzzy fallback
if not tid:
    for t in tdata.get('transitions', []):
        if 'progress' in t['name'].lower():
            tid = t['id']
            break

if not tid:
    print(f"WARN: no 'In Progress' transition available. Available: {available}")
    print("HINT: run `/workflow refresh` in Telegram or add a `workflow.aliases.start` pattern to config.json")
else:
    body = json.dumps({"transition": {"id": tid}}).encode()
    req = urllib.request.Request(
        f"{os.environ['JIRA_SITE']}/rest/api/3/issue/{ticket}/transitions",
        data=body, headers=headers, method="POST"
    )
    try:
        urllib.request.urlopen(req, timeout=15)
    except Exception as e:
        print(f"WARN: Jira transition failed: {e}")

# --- 3) Assign ticket to MR author ---
try:
    body = json.dumps({"accountId": jira_account_id}).encode()
    req = urllib.request.Request(
        f"{os.environ['JIRA_SITE']}/rest/api/3/issue/{ticket}/assignee",
        data=body, headers=headers, method="PUT"
    )
    urllib.request.urlopen(req, timeout=15)
except Exception as e:
    print(f"ERR: assign to {author} failed: {e}")
    raise SystemExit(1)

# --- 4) Cleanup cache ---
os.remove(os.environ["RFILE"])
for f in glob.glob(f"{os.path.dirname(os.environ['RFILE'])}/{mr_iid}-discussions.json"):
    os.remove(f)

print(f"OK:{ticket}:{author}")
PYEOF
)
      if [[ "$SEND_RESULT" == OK:* ]]; then
        INFO="${SEND_RESULT#OK:}"
        TICKET="${INFO%%:*}"
        AUTHOR="${INFO##*:}"
        # Tempo: close review-time window (I finished deciding, sent back to dev).
        tl_emit review_sent_to_dev ticket="$TICKET" mr_iid="$MR_IID" to_author="$AUTHOR"
        send_telegram "Sent !$MR_IID back to dev → $TICKET assigned to @$AUTHOR, moved to In Progress."
      else
        send_telegram "Send-to-dev issues on !$MR_IID:
$SEND_RESULT"
      fi
      ;;

    rv_skipmr\ *)
      # rv_skipmr <mr_iid> — remove the review cache so the next run re-discovers it
      MR_IID=$(echo "$CMD" | awk '{print $2}')
      rm -f "$CACHE_DIR/reviews/${MR_IID}-"*.json 2>/dev/null
      # Tempo: close review-time window (I deferred the review — still counts as
      # time spent looking at it).
      tl_emit review_skipped mr_iid="$MR_IID"
      send_telegram "Skipped review for !$MR_IID. It will reappear on the next agent run."
      ;;

    mr_assign\ *)
      # mr_assign <repo_id> <TICKET_KEY> <MR_IID> <gitlab_username>
      #   One-tap reviewer assignment from the "MR opened" card posted by
      #   scripts/notify-mr-opened.sh. Does BOTH halves of the hand-off that
      #   previously required opening GitLab + Jira manually:
      #     1. Replaces the MR's reviewer list with this user.
      #     2. Sets the Jira ticket's assignee to the same person.
      #   Both steps are tracked into WARN_LINES so a partial success (e.g.
      #   GitLab ok, Jira rate-limited) surfaces clearly instead of silently
      #   half-applying.
      REPO_ID=$(echo "$CMD" | awk '{print $2}')
      TICKET=$(echo "$CMD"  | awk '{print $3}')
      MR_IID=$(echo "$CMD"  | awk '{print $4}')
      USERNAME=$(echo "$CMD"| awk '{print $5}')

      if [[ -z "$TICKET" || -z "$MR_IID" || -z "$USERNAME" ]]; then
        send_telegram "mr_assign: malformed callback ($CMD)"
        continue
      fi

      # Resolve repo → GitLab project path and reviewer → display/jira IDs
      # from the live config.json. Keeping this in one Python pass means the
      # handler reads the file exactly once and never trusts stale env vars.
      read -r GITLAB_PROJECT REVIEWER_NAME REVIEWER_JIRA_ID REVIEWER_SLACK_ID < <(
        CONFIG_FILE="${CONFIG_FILE:-$SKILL_DIR/config.json}" \
        REPO_ID="$REPO_ID" USERNAME="$USERNAME" python3 <<'PY'
import json, os
cfg = json.load(open(os.environ["CONFIG_FILE"]))
if "projects" not in cfg:
    cfg = {"projects": [{"id": "default", **cfg}]}
proj = cfg["projects"][0]
repos = proj.get("repositories") or {}
repo_id = os.environ["REPO_ID"]
gp = ""
if repo_id and isinstance(repos.get(repo_id), dict):
    gp = repos[repo_id].get("gitlabProject") or ""
# Fallback: single-repo projects can omit repo_id in callback; grab the first.
if not gp and len(repos) == 1:
    gp = list(repos.values())[0].get("gitlabProject") or ""
name = ""
jid  = ""
sid  = ""
for r in (proj.get("reviewers") or []):
    if r.get("gitlabUsername") == os.environ["USERNAME"]:
        name = r.get("name") or ""
        jid  = r.get("jiraAccountId") or ""
        sid  = r.get("slackUserId") or ""
        break
print(gp or "-", name or "-", jid or "-", sid or "-")
PY
      )

      if [[ "$GITLAB_PROJECT" == "-" ]]; then
        send_telegram "mr_assign: unknown repo_id \"$REPO_ID\" — update config.json or pass an existing key"
        continue
      fi

      WARN_LINES=""
      _warn() { WARN_LINES="${WARN_LINES}${WARN_LINES:+$'\n'}WARN: $*"; }

      # 1) GitLab reviewer. gl_mr_set_reviewer does username→id resolution,
      #    so we can surface "unknown user" distinctly from "PUT failed".
      if ! GL_OUT=$(gl_mr_set_reviewer "$GITLAB_PROJECT" "$MR_IID" "$USERNAME" 2>&1); then
        _warn "GitLab reviewer update failed: $(printf '%s' "$GL_OUT" | head -1)"
      fi

      # 2) Jira assignee. Skip with a warning when the reviewer has no
      #    jiraAccountId (possible for GitLab-only collaborators), because
      #    we don't want to silently unassign the ticket in that case.
      if [[ "$REVIEWER_JIRA_ID" == "-" || -z "$REVIEWER_JIRA_ID" ]]; then
        _warn "No jiraAccountId in config for $USERNAME — Jira ticket not reassigned"
      else
        if ! jira_assign "$TICKET" "$REVIEWER_JIRA_ID" 2>/dev/null; then
          _warn "Jira assignee update failed for $TICKET"
        fi
      fi

      DISPLAY_NAME="${REVIEWER_NAME:-$USERNAME}"
      [[ "$DISPLAY_NAME" == "-" ]] && DISPLAY_NAME="$USERNAME"

      # Replace the original card with a final, buttonless state so it's
      # obvious the action completed (tapping again would re-trigger).
      if [[ -n "$CB_MSG_ID" && "$CB_MSG_ID" != "-" ]]; then
        FINAL="Assigned: $TICKET → $DISPLAY_NAME
MR: !$MR_IID ($GITLAB_PROJECT)
Jira: ticket reassigned"
        [[ -n "$WARN_LINES" ]] && FINAL="$FINAL
$WARN_LINES"
        tg_edit_text "$CB_MSG_ID" "$FINAL" >/dev/null 2>&1 || true
      else
        MSG="Assigned !$MR_IID + $TICKET to $DISPLAY_NAME"
        [[ -n "$WARN_LINES" ]] && MSG="$MSG
$WARN_LINES"
        send_telegram "$MSG"
      fi

      # 3) Slack DM to the reviewer so they know a review is waiting.
      if [[ -n "$REVIEWER_SLACK_ID" && "$REVIEWER_SLACK_ID" != "-" ]]; then
        MR_LINK="https://gitlab.com/${GITLAB_PROJECT}/-/merge_requests/${MR_IID}"
        JIRA_LINK="${JIRA_SITE:-}/browse/${TICKET}"
        FIRST_NAME="${DISPLAY_NAME%% *}"
        DM_MSG="Hi ${FIRST_NAME}, can you please review?
MR: ${MR_LINK}
Ticket: ${JIRA_LINK}"
        if DM_OUT=$(python3 "$SKILL_DIR/scripts/send-slack-dm.py" \
             --channel "$REVIEWER_SLACK_ID" --message "$DM_MSG" 2>&1); then
          echo "[mr_assign] Slack DM sent to $DISPLAY_NAME ($REVIEWER_SLACK_ID)"
        else
          _warn "Slack DM to $DISPLAY_NAME failed: $(printf '%s' "$DM_OUT" | head -1)"
          send_telegram "WARN: Slack DM to $DISPLAY_NAME failed — $(printf '%s' "$DM_OUT" | head -1)"
        fi
      fi
      ;;

    mr_dismiss\ *)
      # mr_dismiss <mr_iid> — user tapped Dismiss on the MR-opened card.
      # No action needed beyond stripping the keyboard, which tg_edit_text
      # does implicitly (editMessageText drops reply_markup when omitted).
      MR_IID=$(echo "$CMD" | awk '{print $2}')
      if [[ -n "$CB_MSG_ID" && "$CB_MSG_ID" != "-" ]]; then
        tg_edit_text "$CB_MSG_ID" "MR !$MR_IID — dismissed (no reviewer assigned)." >/dev/null 2>&1 || true
      fi
      ;;

    ci_fix\ *)
      # ci_fix <repo> <mr_iid> — trigger agent in CI auto-fix mode
      REPO_SLUG=$(echo "$CMD" | awk '{print $2}')
      MR_IID=$(echo "$CMD" | awk '{print $3}')
      export FORCE_MR="$MR_IID"
      export FORCE_REPO="$REPO_SLUG"
      export FORCE_MODE="ci-fix"
      _spawn_agent "!$MR_IID ci-fix" "Launching CI auto-fix for !$MR_IID ($REPO_SLUG)…"
      unset FORCE_MR FORCE_REPO FORCE_MODE
      ;;

    fb_fix\ *)
      # fb_fix <repo> <mr_iid> — trigger agent to apply new reviewer feedback
      REPO_SLUG=$(echo "$CMD" | awk '{print $2}')
      MR_IID=$(echo "$CMD" | awk '{print $3}')
      export FORCE_MR="$MR_IID"
      export FORCE_REPO="$REPO_SLUG"
      export FORCE_MODE="feedback"
      _spawn_agent "!$MR_IID feedback" "Launching feedback-fix for !$MR_IID ($REPO_SLUG)…"
      unset FORCE_MR FORCE_REPO FORCE_MODE
      ;;

    fb_seen\ *)
      # fb_seen <repo> <mr_iid> — acknowledge new comments without agent action.
      # Watcher state already stores the latest note_id, so nothing more to do.
      REPO_SLUG=$(echo "$CMD" | awk '{print $2}')
      MR_IID=$(echo "$CMD" | awk '{print $3}')
      send_telegram "Marked feedback seen on !$MR_IID ($REPO_SLUG)."
      ;;

    stopall)
      cmd_stopall
      ;;

    rn_log\ *)
      handler_rn_log "$CMD"
      ;;

    rn_stop\ *)
      handler_rn_stop "$CMD"
      ;;

    tk_status\ *)
      # tk_status <ticket_key> — ticket-scoped status view
      TK_KEY=$(echo "$CMD" | awk '{print $2}' | tr '[:lower:]' '[:upper:]')
      # shellcheck disable=SC1091
      source "$SKILL_DIR/scripts/active-run.sh"
      active_run_prune >/dev/null 2>&1 || true
      ACTIVE_RUNS_FILE="$SKILL_DIR/cache/active-runs.json"
      TK_INFO=$(TK_KEY="$TK_KEY" ACTIVE_RUNS_FILE="$ACTIVE_RUNS_FILE" python3 <<'PYEOF' 2>/dev/null
import json, os, time
try:
    d = json.load(open(os.environ['ACTIVE_RUNS_FILE']))
    if not isinstance(d, dict): d = {}
except Exception:
    d = {}
tk = os.environ['TK_KEY'].upper()
hits = [(pid, r) for pid, r in d.items() if (r.get('ticket') or '').upper() == tk]
if not hits:
    print('IDLE')
else:
    now = int(time.time())
    for pid, r in hits:
        age = max(0, now - int(r.get('started_at', now)))
        print(f"{pid}\t{r.get('mode','?')}\t{r.get('phase','?')}\t{int(r.get('round') or 1)}\t{age}\t{r.get('log_path') or ''}")
PYEOF
)
      if [ "$TK_INFO" = "IDLE" ] || [ -z "$TK_INFO" ]; then
        send_telegram "$TK_KEY is not running right now."
      else
        printf '%s\n' "$TK_INFO" | while IFS=$'\t' read -r PID MODE PHASE RND AGE LOGP; do
          [ -z "$PID" ] && continue
          if [ "$AGE" -lt 60 ]; then AGEF="${AGE}s"
          elif [ "$AGE" -lt 3600 ]; then AGEF="$((AGE/60))m"
          else AGEF="$((AGE/3600))h$(( (AGE%3600)/60 ))m"; fi
          ROUND_TAG=""
          [ "$RND" -gt 1 ] 2>/dev/null && ROUND_TAG=" · round $RND"
          TAIL=$(tail -n 20 "$LOGP" 2>/dev/null | tail -c 2500)
          send_telegram "$TK_KEY — running ${MODE}${ROUND_TAG}
Phase: $PHASE · pid $PID · for $AGEF

$TAIL"
        done
      fi
      ;;

    tk_stop\ *)
      # tk_stop <ticket_key> — kill the live run-agent.sh process working on this ticket
      TK_KEY=$(echo "$CMD" | awk '{print $2}' | tr '[:lower:]' '[:upper:]')
      # shellcheck disable=SC1091
      source "$SKILL_DIR/scripts/active-run.sh"
      active_run_prune >/dev/null 2>&1 || true
      ACTIVE_RUNS_FILE="$SKILL_DIR/cache/active-runs.json"
      STOP_OUT=$(TK_KEY="$TK_KEY" ACTIVE_RUNS_FILE="$ACTIVE_RUNS_FILE" python3 <<'PYE'
import json, os, signal, sys
tk = os.environ["TK_KEY"].upper()
path = os.environ["ACTIVE_RUNS_FILE"]
try:
    data = json.load(open(path))
except Exception:
    data = {}
victims = [pid for pid, r in data.items() if (r.get("ticket") or "").upper() == tk]
if not victims:
    print(f"ERR:no-live-run-for:{tk}")
    sys.exit(0)
killed = []
for pid in victims:
    try:
        os.kill(int(pid), signal.SIGTERM)
        killed.append(pid)
    except ProcessLookupError:
        killed.append(f"{pid}(gone)")
    except Exception as e:
        print(f"ERR:{pid}:{e}")
        sys.exit(0)
print("OK:" + ",".join(killed))
PYE
      )
      if [[ "$STOP_OUT" == OK:* ]]; then
        send_telegram "Stopped run for $TK_KEY (${STOP_OUT#OK:}). Use /tickets to re-run."
      elif [[ "$STOP_OUT" == ERR:no-live-run-for:* ]]; then
        send_telegram "No live run to stop for $TK_KEY."
      else
        send_telegram "Could not stop $TK_KEY: $STOP_OUT"
      fi
      ;;

    tk_start\ *)
      # tk_start <ticket_key> — run agent immediately on a single ticket
      TK_KEY=$(echo "$CMD" | awk '{print $2}' | tr '[:lower:]' '[:upper:]')
      # Record the user override so the blocker check in phase2 doesn't re-block this ticket
      mkdir -p "$SKILL_DIR/cache"
      TK_OVERRIDES="$SKILL_DIR/cache/tk-overrides.json"
      [[ -f "$TK_OVERRIDES" ]] || echo '{}' > "$TK_OVERRIDES"
      TK_KEY="$TK_KEY" python3 <<'PYEOF' >/dev/null 2>&1
import os, json, time
p = os.environ.get('SKILL_DIR', os.path.expanduser('~/.cursor/skills/autonomous-dev-agent')) + '/cache/tk-overrides.json'
try: d = json.load(open(p))
except Exception: d = {}
d[os.environ['TK_KEY']] = {'override': 'proceed', 'ts': int(time.time())}
json.dump(d, open(p,'w'))
PYEOF
      # If this is a re-review (prior review cache exists), hint the round
      FORCE_ROUND=$(TK_KEY="$TK_KEY" SKILL_DIR="$SKILL_DIR" python3 <<'PYEOF' 2>/dev/null
import glob, json, os, re
reviews_dir = os.environ["SKILL_DIR"] + "/cache/reviews"
rx = re.compile(r'^\d+-[0-9a-f]{8}\.json$')
tk = os.environ["TK_KEY"]
n = 0
for p in glob.glob(os.path.join(reviews_dir, '*.json')):
    if not rx.match(os.path.basename(p)): continue
    try:
        if json.load(open(p)).get('ticket_key') == tk: n += 1
    except Exception: pass
print(n + 1 if n > 0 else 1)
PYEOF
)
      export FORCE_TICKET="$TK_KEY"
      [[ "${FORCE_ROUND:-1}" -gt 1 ]] && export FORCE_ROUND
      _spawn_agent "$TK_KEY" "Starting agent for $TK_KEY…"
      unset FORCE_TICKET FORCE_ROUND
      ;;

    tk_ship\ *)
      # tk_ship <ticket_key> — find open MR, verify approvals, merge, transition ticket, assign to Sreela
      TK_KEY=$(echo "$CMD" | awk '{print $2}' | tr '[:lower:]' '[:upper:]')
      send_telegram "Shipping $TK_KEY… (finding MR, checking approvals)"
      SHIP_RESULT=$(
        TK_KEY="$TK_KEY" \
        ATLASSIAN_EMAIL="$ATLASSIAN_EMAIL" \
        ATLASSIAN_API_TOKEN="$ATLASSIAN_API_TOKEN" \
        SHIP_ASSIGNEE_NAME="${SHIP_ASSIGNEE_NAME:-Sreela}" \
        CONFIG_PATH="$SKILL_DIR/config.json" \
        python3 <<'PYEOF' 2>&1
import os, json, subprocess, urllib.parse, urllib.request, base64

TK_KEY = os.environ["TK_KEY"]
config = json.load(open(os.environ["CONFIG_PATH"]))
# v0.2 flat schema vs v0.3 projects[] schema — same fallback used in cherries.
_proj0 = (config.get("projects") or [{}])[0] if isinstance(config.get("projects"), list) else {}
repos = config.get("repositories") or _proj0.get("repositories") or {}

def run(cmd, cwd=None, timeout=30):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout, r.stderr

# --- 1) find the open MR across repos ---
found = None
for slug, meta in repos.items():
    local = meta.get("localPath")
    if not local or not os.path.isdir(local):
        continue
    rc, out, err = run(["glab", "mr", "list", "--search", TK_KEY,
                        "--state", "opened", "--output", "json"], cwd=local)
    try:
        mrs = json.loads(out or "[]")
    except Exception:
        mrs = []
    for m in mrs:
        branch = (m.get("source_branch","") or "")
        title = (m.get("title","") or "")
        if TK_KEY in branch or TK_KEY in title:
            found = {
                "repo": slug,
                "local": local,
                "project": meta.get("gitlabProject"),
                "iid": m.get("iid"),
                "title": title,
                "web_url": m.get("web_url"),
                "target_branch": m.get("target_branch"),
                "source_branch": branch,
            }
            break
    if found:
        break

if not found:
    print(f"ERR: no open MR found for {TK_KEY} in any configured repo.")
    raise SystemExit(1)

mr = found
proj_enc = urllib.parse.quote(mr["project"], safe="")

# --- 2) check approvals ---
rc, out, err = run(["glab", "api",
                    f"projects/{proj_enc}/merge_requests/{mr['iid']}/approvals"])
if rc != 0:
    print(f"ERR: approvals fetch failed: {err[:200]}")
    raise SystemExit(1)
try:
    ap = json.loads(out)
except Exception:
    print(f"ERR: bad approvals JSON: {out[:200]}")
    raise SystemExit(1)

approvals_left = ap.get("approvals_left")
approved_by = [a.get("user",{}).get("username","?") for a in ap.get("approved_by",[]) or []]
is_approved = ap.get("approved") is True or (isinstance(approvals_left, int) and approvals_left == 0) or (approved_by and approvals_left is None)

if not is_approved:
    msg = f"NOT APPROVED: !{mr['iid']} ({TK_KEY})\n"
    msg += f"  approvals_left = {approvals_left}\n"
    msg += f"  approved_by    = {approved_by or '(none)'}\n"
    msg += f"  MR: {mr['web_url']}"
    print(msg)
    raise SystemExit(2)

# --- 3) merge MR ---
rc, out, err = run(["glab", "api", "--method", "PUT",
                    f"projects/{proj_enc}/merge_requests/{mr['iid']}/merge",
                    "--field", "should_remove_source_branch=true",
                    "--field", "merge_when_pipeline_succeeds=true"])
merged_state = None
if rc == 0:
    try:
        merge_info = json.loads(out)
        merged_state = merge_info.get("state")
    except Exception:
        pass
else:
    # Retry without merge_when_pipeline_succeeds if pipeline isn't running
    rc2, out2, err2 = run(["glab", "api", "--method", "PUT",
                           f"projects/{proj_enc}/merge_requests/{mr['iid']}/merge",
                           "--field", "should_remove_source_branch=true"])
    if rc2 == 0:
        try:
            merged_state = json.loads(out2).get("state")
        except Exception:
            pass
    else:
        print(f"ERR: merge failed: {err[:200]} || {err2[:200]}")
        raise SystemExit(1)

# --- 4) Jira transitions + assignment ---
email = os.environ["ATLASSIAN_EMAIL"]
token = os.environ["ATLASSIAN_API_TOKEN"]
auth = base64.b64encode(f"{email}:{token}".encode()).decode()
hdrs = {"Authorization": f"Basic {auth}", "Content-Type": "application/json"}

# 4a. find "Integration Testing" transition
req = urllib.request.Request(
    f"{os.environ['JIRA_SITE']}/rest/api/3/issue/{TK_KEY}/transitions",
    headers=hdrs)
try:
    tdata = json.loads(urllib.request.urlopen(req, timeout=15).read())
except Exception as e:
    print(f"MERGED but Jira transitions fetch failed: {e}")
    raise SystemExit(1)

target = None
for t in tdata.get("transitions", []):
    if t["name"].lower().replace("-"," ").strip() in ("integration testing", "integration-testing", "integration"):
        target = t; break
if not target:
    available = [t["name"] for t in tdata.get("transitions",[])]
    print(f"MERGED, but 'Integration Testing' transition not available. Options: {available}")
    print("HINT: run `/workflow refresh` or add `workflow.aliases.after_merge` in config.json")
    raise SystemExit(1)

body = json.dumps({"transition": {"id": target["id"]}}).encode()
req = urllib.request.Request(
    f"{os.environ['JIRA_SITE']}/rest/api/3/issue/{TK_KEY}/transitions",
    data=body, headers=hdrs, method="POST")
try:
    urllib.request.urlopen(req, timeout=15)
except Exception as e:
    print(f"MERGED but Jira transition failed: {e}")
    raise SystemExit(1)

# 4b. find assignee account id by display name
name = os.environ["SHIP_ASSIGNEE_NAME"]
req = urllib.request.Request(
    f"{os.environ['JIRA_SITE']}/rest/api/3/user/search?query={urllib.parse.quote(name)}",
    headers=hdrs)
try:
    users = json.loads(urllib.request.urlopen(req, timeout=15).read())
except Exception as e:
    print(f"MERGED and transitioned, but user search for '{name}' failed: {e}")
    raise SystemExit(1)

cand = None
for u in users or []:
    if u.get("accountType") != "atlassian":
        continue
    disp = u.get("displayName","")
    if name.lower() in disp.lower():
        cand = u; break

if not cand:
    print(f"MERGED and transitioned, but couldn't find Jira user matching '{name}'. Users returned: {[u.get('displayName') for u in users or []]}")
    raise SystemExit(1)

body = json.dumps({"accountId": cand["accountId"]}).encode()
req = urllib.request.Request(
    f"{os.environ['JIRA_SITE']}/rest/api/3/issue/{TK_KEY}/assignee",
    data=body, headers=hdrs, method="PUT")
try:
    urllib.request.urlopen(req, timeout=15)
except Exception as e:
    print(f"MERGED and transitioned, but assign to '{cand['displayName']}' failed: {e}")
    raise SystemExit(1)

print(f"OK: merged !{mr['iid']} ({mr['repo']}), {TK_KEY} → Integration Testing, assigned to {cand['displayName']}")
PYEOF
      )
      if [[ "$SHIP_RESULT" == OK:* ]]; then
        send_telegram "$SHIP_RESULT"
      else
        send_telegram "Ship failed:
$SHIP_RESULT"
      fi
      ;;

    tk_cherryall\ *)
      # tk_cherryall <repo_slug> <KEY1,KEY2,...>
      # Cherry-picks all commits from the given tickets onto a SINGLE new
      # branch off origin/main and opens ONE MR containing all of them.
      # Triggered from the "Cherry-pick ALL … to main" summary card in
      # /cherries when multiple tickets share a repo.
      CA_REPO=$(echo "$CMD" | awk '{print $2}')
      CA_KEYS=$(echo "$CMD" | awk '{print $3}' | tr '[:lower:]' '[:upper:]')
      if [ -z "$CA_REPO" ] || [ -z "$CA_KEYS" ]; then
        send_telegram "Usage: tk_cherryall <repo> <KEY1,KEY2,...>"
        continue
      fi
      send_telegram "Cherry-picking ${CA_KEYS//,/ + } onto main as a single branch ($CA_REPO)…"
      CA_RESULT=$(
        TK_KEYS="$CA_KEYS" \
        FORCE_REPO="$CA_REPO" \
        CONFIG_PATH="$SKILL_DIR/config.json" \
        PROMOTED_FILE="$CACHE_DIR/promoted.json" \
        python3 "$SKILL_DIR/scripts/cherry-pick-combined.py" 2>&1
      )
      # NOTE: cherry-pick-combined.py writes diagnostic breadcrumbs to
      # stderr BEFORE the final OK:/INFO:/ERR: line (see 1.0.18 where
      # `-X theirs` retries print `[cherry-pick-combined] <sha>: auto-
      # resolved ...` to stderr). Because we captured with 2>&1, those
      # breadcrumbs become the prefix of $CA_RESULT, so `[[ == OK:* ]]`
      # — a glob anchored at the start — never matched and every
      # success fell through to the failure branch (user saw the
      # "Try each ticket on its own" fallback card even when the
      # combined promote actually succeeded). Match on a LINE prefix
      # instead of the whole-string prefix.
      if printf '%s\n' "$CA_RESULT" | grep -q '^OK:'; then
        send_telegram "$CA_RESULT"
        # Follow-up with DM Approver / Open MR / Open tickets buttons.
        # The combined entry in promoted.json is keyed by __combined__<joined_keys>
        # AND mirrored under each individual ticket key so rel_dm:<any> works.
        FOLLOWUP=$(
          TK_KEYS="$CA_KEYS" \
          CONFIG_PATH="$SKILL_DIR/config.json" \
          CACHE_DIR="$CACHE_DIR" \
          CHAT_ID="$TELEGRAM_CHAT_ID" \
          python3 <<'PYE'
import os, json
keys = [k for k in os.environ["TK_KEYS"].split(",") if k]
cache_dir = os.environ["CACHE_DIR"]
chat_id = os.environ["CHAT_ID"]
config = json.load(open(os.environ["CONFIG_PATH"]))
approvers = config.get("releaseApprovers") or []
try:
    promoted = json.load(open(os.environ.get("PROMOTED_FILE") or os.path.join(cache_dir, "promoted.json")))
except Exception:
    promoted = {}
# any individual key will carry the shared MR url + combined_siblings
info = {}
for k in keys:
    info = promoted.get(k) or {}
    if info.get("url"):
        break
mr_url = info.get("url", "")
jira_site = os.environ.get("JIRA_SITE", "")
# Pick the first key as the DM anchor — the combined_siblings entry makes
# sure the DM message lists every ticket in the MR, not just this one.
dm_key = keys[0] if keys else ""
buttons_row1 = []
if approvers and dm_key:
    appr = approvers[0]
    buttons_row1.append({"text": f"DM {appr['name'].split()[0]}", "callback_data": f"rel_dm:{dm_key}"})
if mr_url:
    buttons_row1.append({"text": "Open MR", "url": mr_url})
buttons_row2 = []
for k in keys[:5]:
    buttons_row2.append({"text": f"Open {k}", "url": f"{jira_site}/browse/{k}"})
kb_rows = [r for r in (buttons_row1, buttons_row2) if r]
kb = {"inline_keyboard": kb_rows}
appr_name = approvers[0]["name"] if approvers else "<approver>"
text = (f"Combined promote to main covers: {', '.join(keys)}.\n"
        f"Next step: ask {appr_name} to merge that one MR.")
msg = {"chat_id": chat_id, "text": text, "reply_markup": kb}
print(json.dumps(msg))
PYE
        )
        [ -n "$FOLLOWUP" ] && send_telegram_raw "$FOLLOWUP"
      elif printf '%s\n' "$CA_RESULT" | grep -q '^INFO:'; then
        send_telegram "$CA_RESULT"
      else
        # Combined cherry-pick failed (typically a merge conflict). Surface
        # the full diagnostic message, then emit a fallback card with a
        # per-ticket "Cherry-pick <KEY>" button for each ticket that still
        # has un-applied commits. cherry-pick-combined.py embeds the list
        # as `FALLBACK_KEYS=UA-942,UA-843` on its last line — we parse that
        # here (falls back to the original CA_KEYS if the marker is absent).
        send_telegram "Combined cherry-pick failed:
$CA_RESULT"
        FB_KEYS=$(printf '%s\n' "$CA_RESULT" | awk -F= '/^FALLBACK_KEYS=/{print $2; exit}' | tr -d ' ')
        [ -z "$FB_KEYS" ] && FB_KEYS="$CA_KEYS"
        if [ -n "$FB_KEYS" ]; then
          FB=$(
            TK_KEYS="$FB_KEYS" \
            CHAT_ID="$TELEGRAM_CHAT_ID" \
            python3 <<'PYE'
import os, json
keys = [k for k in os.environ["TK_KEYS"].split(",") if k]
chat_id = os.environ["CHAT_ID"]
jira_site = os.environ.get("JIRA_SITE", "")
buttons = []
for k in keys[:6]:
    buttons.append([
        {"text": f"Cherry-pick {k} alone", "callback_data": f"tk_cherry:{k}"},
        {"text": f"Open {k}", "url": f"{jira_site}/browse/{k}"},
    ])
msg = {
    "chat_id": chat_id,
    "text": ("Try each ticket on its own — the per-ticket MR is smaller and\n"
             "conflicts (if any) are easier to resolve one at a time:"),
    "reply_markup": {"inline_keyboard": buttons},
}
print(json.dumps(msg))
PYE
          )
          [ -n "$FB" ] && send_telegram_raw "$FB"
        fi
      fi
      ;;

    tk_cherry\ *|cherry\ *)
      # tk_cherry <ticket_key> — cherry-pick ticket's merged commits onto a new branch from main, open MR to main
      TK_KEY=$(echo "$CMD" | awk '{print $2}' | tr '[:lower:]' '[:upper:]')
      [ -z "$TK_KEY" ] && { send_telegram "Usage: /cherry PROJ-XXX"; continue; }
      send_telegram "Cherry-picking $TK_KEY onto main… (finding merged MR)"
      CHERRY_RESULT=$(
        TK_KEY="$TK_KEY" \
        CONFIG_PATH="$SKILL_DIR/config.json" \
        python3 "$SKILL_DIR/scripts/cherry-pick.py" 2>&1
      )
      # See tk_cherryall above — cherry-pick.py also writes `-X theirs`
      # breadcrumbs to stderr before the final OK:/INFO:/ERR: line, so
      # `[[ == OK:* ]]` glob prefix never matches once 2>&1 is merged.
      if printf '%s\n' "$CHERRY_RESULT" | grep -q '^OK:'; then
        send_telegram "$CHERRY_RESULT"
        # Follow-up with action buttons (DM Approver / Open MR / Open in Jira)
        FOLLOWUP=$(
          TK_KEY="$TK_KEY" \
          CONFIG_PATH="$SKILL_DIR/config.json" \
          CACHE_DIR="$CACHE_DIR" \
          CHAT_ID="$TELEGRAM_CHAT_ID" \
          python3 <<'PYE'
import os, json, sys

tk_key = os.environ["TK_KEY"]
cache_dir = os.environ["CACHE_DIR"]
chat_id = os.environ["CHAT_ID"]
config = json.load(open(os.environ["CONFIG_PATH"]))
approvers = config.get("releaseApprovers") or []

try:
    promoted = json.load(open(os.environ.get("PROMOTED_FILE") or os.path.join(cache_dir, "promoted.json")))
    info = promoted.get(tk_key, {})
except Exception:
    info = {}

mr_url = info.get("url", "")
buttons_row1 = []
if approvers:
    # Primary approver = first entry. Extend later for multi-approver teams.
    appr = approvers[0]
    buttons_row1.append({"text": f"DM {appr['name'].split()[0]}", "callback_data": f"rel_dm:{tk_key}"})
if mr_url:
    buttons_row1.append({"text": "Open MR", "url": mr_url})
buttons_row2 = [
    {"text": "Open in Jira", "url": f"{os.environ['JIRA_SITE']}/browse/{tk_key}"},
    {"text": "Skip", "callback_data": f"rel_skip:{tk_key}"}
]
kb = {"inline_keyboard": [b for b in (buttons_row1, buttons_row2) if b]}
msg = {
    "chat_id": chat_id,
    "text": f"Next step for {tk_key}: ask {approvers[0]['name'] if approvers else '<approver>'} to merge to main and ship prod.",
    "reply_markup": kb,
}
print(json.dumps(msg))
PYE
        )
        [ -n "$FOLLOWUP" ] && send_telegram_raw "$FOLLOWUP"
      elif printf '%s\n' "$CHERRY_RESULT" | grep -q '^INFO:.*already has an open promote MR'; then
        send_telegram "$CHERRY_RESULT"
        FOLLOWUP=$(
          TK_KEY="$TK_KEY" \
          CONFIG_PATH="$SKILL_DIR/config.json" \
          CACHE_DIR="$CACHE_DIR" \
          CHAT_ID="$TELEGRAM_CHAT_ID" \
          python3 <<'PYE'
import os, json
tk_key = os.environ["TK_KEY"]
cache_dir = os.environ["CACHE_DIR"]
chat_id = os.environ["CHAT_ID"]
config = json.load(open(os.environ["CONFIG_PATH"]))
approvers = config.get("releaseApprovers") or []
try:
    promoted = json.load(open(os.environ.get("PROMOTED_FILE") or os.path.join(cache_dir, "promoted.json")))
    info = promoted.get(tk_key, {})
except Exception:
    info = {}
mr_url = info.get("url", "")
buttons_row1 = []
if approvers:
    appr = approvers[0]
    buttons_row1.append({"text": f"DM {appr['name'].split()[0]}", "callback_data": f"rel_dm:{tk_key}"})
if mr_url:
    buttons_row1.append({"text": "Open MR", "url": mr_url})
buttons_row2 = [
    {"text": "Open in Jira", "url": f"{os.environ['JIRA_SITE']}/browse/{tk_key}"},
    {"text": "Skip", "callback_data": f"rel_skip:{tk_key}"}
]
kb = {"inline_keyboard": [b for b in (buttons_row1, buttons_row2) if b]}
msg = {
    "chat_id": chat_id,
    "text": f"{tk_key} already promoted. Ask {approvers[0]['name'] if approvers else '<approver>'} to merge to main and ship prod?",
    "reply_markup": kb,
}
print(json.dumps(msg))
PYE
        )
        [ -n "$FOLLOWUP" ] && send_telegram_raw "$FOLLOWUP"
      elif printf '%s\n' "$CHERRY_RESULT" | grep -q '^INFO:'; then
        send_telegram "$CHERRY_RESULT"
      else
        send_telegram "Cherry-pick failed:
$CHERRY_RESULT"
      fi
      ;;

    rel_dm\ *)
      # rel_dm <ticket_key> — queue a Slack DM task for the Cursor IDE agent to send
      # (CLI cursor-agent can't load Slack MCP because of the OAuth redirect_uri bug,
      # so we hand the task to the IDE's already-authed Slack MCP instead)
      TK_KEY=$(echo "$CMD" | awk '{print $2}' | tr '[:lower:]' '[:upper:]')
      RESULT=$(
        TK_KEY="$TK_KEY" \
        CONFIG_PATH="$SKILL_DIR/config.json" \
        CACHE_DIR="$CACHE_DIR" \
        python3 <<'PYE'
import os, json, time, sys, subprocess, re
tk_key = os.environ["TK_KEY"]
cache_dir = os.environ["CACHE_DIR"]
config = json.load(open(os.environ["CONFIG_PATH"]))
approvers = config.get("releaseApprovers") or []
if not approvers:
    print("ERR: no releaseApprovers configured in config.json")
    sys.exit(1)
appr = approvers[0]
try:
    promoted = json.load(open(os.environ.get("PROMOTED_FILE") or os.path.join(cache_dir, "promoted.json")))
    info = promoted.get(tk_key, {})
except Exception:
    info = {}
mr_url = info.get("url", "")

# Verify the MR is still open — promoted.json can contain stale entries
# from closed/merged MRs (the combined cherry-pick flow writes entries
# that persist after an MR is manually closed).
if mr_url:
    iid_match = re.search(r'/merge_requests/(\d+)', mr_url)
    if iid_match:
        local = info.get("repo") or ""
        repos = config.get("repos") or {}
        repo_local = (repos.get(local) or {}).get("localPath") or ""
        if repo_local and os.path.isdir(repo_local):
            try:
                out = subprocess.check_output(
                    ["glab", "mr", "view", iid_match.group(1),
                     "-F", "json"],
                    cwd=repo_local, timeout=30,
                    stderr=subprocess.DEVNULL,
                ).decode()
                mr_data = json.loads(out)
                if mr_data.get("state") != "opened":
                    print(f"ERR: MR !{iid_match.group(1)} for {tk_key} is "
                          f"{mr_data.get('state','unknown')} — re-run "
                          f"cherry-pick first to create a new open MR.")
                    sys.exit(1)
            except subprocess.TimeoutExpired:
                pass  # proceed with cached URL if glab is slow
            except Exception:
                pass  # proceed with cached URL if glab fails

# If this MR is a COMBINED promote covering multiple tickets, enumerate
# every sibling in the Slack DM so the approver sees the full scope of the MR.
siblings = info.get("combined_siblings") or []
siblings = [s for s in siblings if isinstance(s, str) and s]
jira_site = os.environ["JIRA_SITE"]
jira_url = f"{jira_site}/browse/{tk_key}"
first_name = appr["name"].split()[0]
msg_lines = [f"Hi {first_name}, can you merge this to prod?"]
if siblings and len(siblings) > 1:
    msg_lines.append(f"This MR covers {len(siblings)} tickets: {', '.join(siblings)}")
if mr_url:
    msg_lines.append(f"MR: {mr_url}")
if siblings and len(siblings) > 1:
    # One Jira link per ticket so the approver can cross-check each one.
    for _k in siblings:
        msg_lines.append(f"{_k}: {jira_site}/browse/{_k}")
else:
    msg_lines.append(f"Jira: {jira_site}/browse/{tk_key}")
msg_text = "\n".join(msg_lines)

# Write the pending-DM task file
pending_dir = os.environ.get("PENDING_DM_DIR") or os.path.join(cache_dir, "pending-dm")
os.makedirs(pending_dir, exist_ok=True)
task_path = os.path.join(pending_dir, f"{tk_key}.json")
task = {
    "ticket_key": tk_key,
    "slack_user_id": appr["slackUserId"],
    "approver_name": appr["name"],
    "message": msg_text,
    "mr_url": mr_url,
    "jira_url": jira_url,
    "queued_at": int(time.time()),
}
json.dump(task, open(task_path, "w"), indent=2)
print(f"OK:{tk_key}:{appr['name']}:{task_path}")
PYE
      )
      if [[ "$RESULT" == ERR:* ]]; then
        send_telegram "$RESULT"
      elif [[ "$RESULT" == OK:* ]]; then
        APPR_NAME=$(echo "$RESULT" | cut -d: -f3)
        send_telegram "Sending DM to $APPR_NAME for $TK_KEY via Cursor's Slack token…"
        # Call Slack directly using the OAuth token from Cursor IDE's state.vscdb.
        # The helper script also posts a Telegram confirmation on success / failure.
        DM_OUT=$(TK_KEY="$TK_KEY" python3 "$SKILL_DIR/scripts/send-slack-dm.py" --ticket "$TK_KEY" 2>&1)
        if [[ "$DM_OUT" != OK:* ]]; then
          # send-slack-dm.py already pinged Telegram on errors; keep a breadcrumb in the log
          echo "[$(date)] rel_dm $TK_KEY failed: $DM_OUT" >> "$LOG_DIR/rel-dm.log"
        fi
      else
        send_telegram "Queue failed: $RESULT"
      fi
      ;;

    rel_unqueue\ *)
      # rel_unqueue <ticket_key> — remove pending-DM task file
      TK_KEY=$(echo "$CMD" | awk '{print $2}' | tr '[:lower:]' '[:upper:]')
      TASK="${PENDING_DM_DIR:-$CACHE_DIR/pending-dm}/$TK_KEY.json"
      if [ -f "$TASK" ]; then
        rm -f "$TASK"
        send_telegram "Removed queued DM for $TK_KEY."
      else
        send_telegram "No queued DM for $TK_KEY."
      fi
      ;;

    rel_skip\ *)
      TK_KEY=$(echo "$CMD" | awk '{print $2}' | tr '[:lower:]' '[:upper:]')
      send_telegram "Skipped DM for $TK_KEY."
      ;;

    tk_later\ *)
      # tk_later <ticket_key> — silence the Jira watcher for this ticket for 1 day
      TK_KEY=$(echo "$CMD" | awk '{print $2}' | tr '[:lower:]' '[:upper:]')
      SILENCE_FILE="$CACHE_DIR/tk-silenced.json"
      [ ! -f "$SILENCE_FILE" ] && echo '{}' > "$SILENCE_FILE"
      TK_KEY="$TK_KEY" python3 <<PY
import json, os, time
p = "$SILENCE_FILE"
d = json.load(open(p))
d[os.environ['TK_KEY']] = int(time.time()) + 86400
json.dump(d, open(p, 'w'), indent=2)
PY
      send_telegram "Will remind about $TK_KEY tomorrow."
      ;;

    snooze\ *)
      handler_snooze "$CMD"
      ;;

    unsnooze)
      cmd_unsnooze
      ;;

    ask\ *)
      handler_ask "$CMD"
      ;;

    watch)
      cmd_watch
      ;;

    menu|hide)
      cmd_hide_menu
      ;;

    help)
      cmd_help
      ;;

    # --- Tempo (worklog suggestions, Phase 2) ------------------------------
    # /tempo [window]   window = "" (yesterday) | today | yesterday | week
    # Emits one interactive card per ticket×day with unlogged time ≥15min.
    # Phase-1 event capture runs regardless; /tempo just surfaces the results
    # on demand (complementary to the immediate triggers fired from watcher
    # and rv_approve).
    tempo)
      cmd_tempo ""
      ;;

    tempo\ *)
      # e.g. "tempo today", "tempo week", "tempo yesterday"
      cmd_tempo "$(echo "$CMD_LOWER" | awk '{print $2}')"
      ;;

    # --- Tempo callback taps ----------------------------------------------
    # These are produced by _tempo_card_kb in handlers/tempo.sh. The Python
    # parser (see MULTI_SPLIT_PREFIXES above) turns colon-separated
    # callback_data like "tm_log:UA-997:2026-04-15:5400" into the
    # space-separated CMD string we match here. CB_MSG_ID lets handlers
    # edit the original card in place (e.g. swap [Log] → [Undo]).
    tm_log\ *)
      handler_tm_log "$CMD" "$CB_MSG_ID"
      ;;

    tm_skip\ *)
      handler_tm_skip "$CMD" "$CB_MSG_ID"
      ;;

    tm_edit\ *)
      handler_tm_edit "$CMD"
      ;;

    tm_undo\ *)
      handler_tm_undo "$CMD" "$CB_MSG_ID"
      ;;

    tm_editapply\ *)
      # Produced by the force-reply parser in the Python input loop after
      # the user types a custom duration in reply to "How long for PROJ-XXX
      # on YYYY-MM-DD?". Shape: "tm_editapply <ticket> <date> <raw text>".
      TM_TK=$(echo "$CMD" | awk '{print $2}')
      TM_DT=$(echo "$CMD" | awk '{print $3}')
      TM_DUR=$(echo "$CMD" | cut -d' ' -f4-)
      if [ -n "$TM_TK" ] && [ -n "$TM_DT" ] && [ -n "$TM_DUR" ]; then
        # Reuse the existing reply handler so the duration-parse + log path
        # is identical whether the user tapped Edit from a card or from the
        # daily-digest flow. Synthesize a "replied_to" string that matches
        # the regex in handler_tm_edit_reply.
        handler_tm_edit_reply "How long for ${TM_TK} on ${TM_DT}? " "$TM_DUR"
      else
        send_telegram "tm_editapply: malformed payload — expected 'tm_editapply <ticket> <YYYY-MM-DD> <duration>'"
      fi
      ;;

    *)
      # Ignore unrecognized commands — they may be for the Cursor agent (review, fix, approve, etc.)
      ;;

  esac
done

# LAST_LOOP_END is already reset at the TOP of the loop (unconditional, before
# any `continue` can short-circuit it). Just clear UPDATES for the next iter.
UPDATES=""

done  # end of outer while-true long-polling loop
