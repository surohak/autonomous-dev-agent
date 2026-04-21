#!/bin/bash
# scripts/lib/transcribe.sh
#
# Thin wrapper around speech-to-text for voice notes. Two backends:
#
#   1. OpenAI Whisper API (preferred; zero local install).
#      - Config: OPENAI_API_KEY in secrets.env.
#      - Model:  whisper-1 (cheapest + most accurate for short clips).
#   2. Local whisper.cpp (optional).
#      - Config: WHISPER_CPP_BIN pointing at the compiled binary,
#                WHISPER_CPP_MODEL pointing at a .bin model file.
#
# Callers:
#   transcribe_audio <path-to-ogg-or-m4a> [lang]
#     → echoes the transcript to stdout on success (exit 0)
#     → echoes a short diagnostic to stderr + exit 1/2 on failure
#
# Designed for voice notes ≤ 2 minutes. Longer clips work but cost
# proportionally.

[[ -n "${_DEV_AGENT_TRANSCRIBE_LOADED:-}" ]] && return 0
_DEV_AGENT_TRANSCRIBE_LOADED=1

_transcribe_openai() {
  local audio="$1" lang="${2:-}"
  local key="${OPENAI_API_KEY:-}"
  [[ -z "$key" ]] && return 10

  # `curl -F` handles multipart for us.
  local args=(
    -s
    -H "Authorization: Bearer $key"
    -F "file=@${audio}"
    -F "model=whisper-1"
    -F "response_format=text"
  )
  [[ -n "$lang" ]] && args+=(-F "language=${lang}")

  local out
  out=$(curl "${args[@]}" https://api.openai.com/v1/audio/transcriptions 2>&1) || {
    echo "transcribe: openai request failed: $out" >&2
    return 1
  }
  # The API returns either raw text (response_format=text) or JSON on error.
  if printf '%s' "$out" | grep -q '"error"'; then
    local msg
    msg=$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("error") or {}).get("message",""))' 2>/dev/null || echo "unknown")
    echo "transcribe: openai error: $msg" >&2
    return 1
  fi
  # Trim.
  printf '%s' "$out" | awk 'BEGIN{first=1} {sub(/^[[:space:]]+/,""); sub(/[[:space:]]+$/,""); if (NF) {if (!first) printf " "; printf "%s", $0; first=0}} END{print ""}'
}

_transcribe_whisper_cpp() {
  local audio="$1" lang="${2:-}"
  local bin="${WHISPER_CPP_BIN:-}" model="${WHISPER_CPP_MODEL:-}"
  [[ -z "$bin" || ! -x "$bin" ]] && return 10
  [[ -z "$model" || ! -f "$model" ]] && return 10
  command -v ffmpeg >/dev/null 2>&1 || { echo "transcribe: ffmpeg needed by whisper.cpp" >&2; return 2; }

  # whisper.cpp needs 16kHz mono WAV.
  local tmp_wav="${audio%.*}.tmp-$$.wav"
  ffmpeg -nostdin -loglevel error -y -i "$audio" -ac 1 -ar 16000 "$tmp_wav" || {
    rm -f "$tmp_wav"
    echo "transcribe: ffmpeg failed to convert $audio" >&2
    return 1
  }
  local lang_arg=()
  [[ -n "$lang" ]] && lang_arg=(-l "$lang")
  local raw
  raw=$("$bin" -m "$model" -f "$tmp_wav" -nt "${lang_arg[@]}" 2>/dev/null) || {
    rm -f "$tmp_wav"
    echo "transcribe: whisper.cpp failed" >&2
    return 1
  }
  rm -f "$tmp_wav"
  printf '%s\n' "$raw" | tr -s '\n ' ' ' | sed 's/^ *//; s/ *$//'
}

transcribe_audio() {
  local audio="$1" lang="${2:-}"
  [[ -f "$audio" ]] || { echo "transcribe: file not found: $audio" >&2; return 2; }

  # Prefer OpenAI; fall back to whisper.cpp. Rationale: Whisper API works
  # out-of-the-box, whisper.cpp requires a model download and build.
  local text rc
  text=$(_transcribe_openai "$audio" "$lang")
  rc=$?
  if [[ $rc -eq 0 && -n "$text" ]]; then
    printf '%s' "$text"
    return 0
  fi
  # rc=10 means "not configured", try local.
  if [[ $rc -eq 10 ]]; then
    text=$(_transcribe_whisper_cpp "$audio" "$lang")
    rc=$?
    if [[ $rc -eq 0 && -n "$text" ]]; then
      printf '%s' "$text"
      return 0
    fi
    if [[ $rc -eq 10 ]]; then
      echo "transcribe: no backend configured (set OPENAI_API_KEY or WHISPER_CPP_BIN+MODEL)" >&2
      return 11
    fi
  fi
  return 1
}
