#!/bin/bash
# scripts/tests/test_transcribe.sh
#
# Offline unit test for lib/transcribe.sh. We can't actually run a real
# transcription in CI (no audio file, no API key), so we only assert
# the "no backend configured" exit-11 behaviour, which is the most common
# misconfiguration a user can hit.

set -uo pipefail
SKILL_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export SKILL_DIR

# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/transcribe.sh"

fail=0
report() { echo "FAIL: $1"; fail=1; }

# 1) Missing file → exit 2.
out=$(transcribe_audio /nope/doesnt/exist.ogg 2>&1 || echo "RC=$?")
[[ "$out" == *"RC=2"* ]] || report "expected RC=2 for missing file, got: $out"

# 2) No backend configured → exit 11.
unset OPENAI_API_KEY WHISPER_CPP_BIN WHISPER_CPP_MODEL
tmp=$(mktemp)
echo "stub" > "$tmp"
out=$(transcribe_audio "$tmp" 2>&1 || echo "RC=$?")
rm -f "$tmp"
[[ "$out" == *"no backend configured"* ]] || report "expected 'no backend configured', got: $out"
[[ "$out" == *"RC=11"* ]] || report "expected RC=11, got: $out"

if [[ $fail -eq 0 ]]; then
  echo "OK test_transcribe"
  exit 0
fi
exit 1
