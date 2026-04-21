#!/bin/bash
# test_tempo_lib.sh — lib/tempo.sh loads cleanly, guards against missing
# config, and correctly classifies Tempo API responses in tempo_ping.
#
# We can't call the real api.tempo.io here (no creds in CI, and we don't
# want CI tests mutating real worklogs), so every response-code path is
# exercised via a fake `curl` shimmed onto PATH — same technique as
# test_gitlab_lib.sh's fake `glab`.

set -euo pipefail
source "$HOME/.cursor/skills/autonomous-dev-agent/scripts/lib/env.sh"
source "$HOME/.cursor/skills/autonomous-dev-agent/scripts/lib/tempo.sh"

# 1) Idempotent load guard — second source is a no-op.
source "$HOME/.cursor/skills/autonomous-dev-agent/scripts/lib/tempo.sh"
[[ "$_DEV_AGENT_TEMPO_LOADED" == "1" ]] || { echo "load guard missing"; exit 1; }

# 2) All public functions are defined.
for fn in tempo_api tempo_get tempo_post tempo_delete tempo_ping \
          tempo_list_worklogs tempo_post_worklog tempo_delete_worklog; do
  declare -F "$fn" >/dev/null || { echo "missing function: $fn"; exit 1; }
done

# 3) Missing TEMPO_API_TOKEN → non-zero + diagnostic on stderr (no crash).
OUT_ERR=$(TEMPO_API_TOKEN="" tempo_api GET /worklogs 2>&1 >/dev/null || true)
echo "$OUT_ERR" | grep -q "TEMPO_API_TOKEN not set" \
  || { echo "expected 'TEMPO_API_TOKEN not set' message, got: $OUT_ERR"; exit 1; }
# And the exit code should be non-zero.
if TEMPO_API_TOKEN="" tempo_api GET /worklogs >/dev/null 2>&1; then
  echo "expected non-zero rc when TEMPO_API_TOKEN missing"; exit 1
fi

# ---------------------------------------------------------------------------
# Fake curl helper — returns body + __HTTP__<code> footer the way the real
# curl does when invoked with -w '\n__HTTP__%{http_code}'. Every branch in
# tempo_ping is exercised below.
#
# Fake curl is scoped per-subshell so we don't leak into later tests.
# ---------------------------------------------------------------------------
make_fake_curl() {
  local bin="$1" body="$2" http="$3"
  mkdir -p "$bin"
  # We intentionally only honour the -w flag when present; otherwise we print
  # the body (used by tempo_api, not tempo_ping). That way the same fake
  # works for both entry points.
  cat > "$bin/curl" <<EOF
#!/bin/bash
_body=$(printf %q "$body")
_http=$(printf %q "$http")
want_w=0
for a in "\$@"; do
  case "\$a" in
    -w) want_w=1;;
  esac
done
if [[ "\$want_w" == "1" ]]; then
  # Mimic: <body>\n__HTTP__<code>
  printf '%b\n__HTTP__%s' "\$_body" "\$_http"
else
  printf '%b' "\$_body"
fi
exit 0
EOF
  chmod +x "$bin/curl"
}

# 4) tempo_ping 200 → OK + N worklog(s) readable
(
  FAKE_BIN="$TEST_TMP/bin-200"
  body='{"metadata":{"count":42},"results":[]}'
  make_fake_curl "$FAKE_BIN" "$body" "200"
  export PATH="$FAKE_BIN:$PATH"
  export TEMPO_API_TOKEN="fake-token"

  OUT=$(tempo_ping)
  echo "$OUT" | grep -q '^OK: 42 worklog' \
    || { echo "200 case: expected 'OK: 42 worklog…', got: $OUT"; exit 1; }
) || exit 1

# 5) tempo_ping 401 → ERR auth
(
  FAKE_BIN="$TEST_TMP/bin-401"
  body='{"errors":[{"message":"invalid token"}]}'
  make_fake_curl "$FAKE_BIN" "$body" "401"
  export PATH="$FAKE_BIN:$PATH"
  export TEMPO_API_TOKEN="bad-token"

  if OUT=$(tempo_ping 2>&1); then
    echo "401 case: tempo_ping should exit non-zero, got 0"; exit 1
  fi
  echo "$OUT" | grep -q '^ERR auth' \
    || { echo "401 case: expected 'ERR auth', got: $OUT"; exit 1; }
) || exit 1

# 6) tempo_ping 403 → ERR scope
(
  FAKE_BIN="$TEST_TMP/bin-403"
  body='{"errors":[{"message":"missing scope"}]}'
  make_fake_curl "$FAKE_BIN" "$body" "403"
  export PATH="$FAKE_BIN:$PATH"
  export TEMPO_API_TOKEN="scoped-token"

  if OUT=$(tempo_ping 2>&1); then
    echo "403 case: tempo_ping should exit non-zero"; exit 1
  fi
  echo "$OUT" | grep -q '^ERR scope' \
    || { echo "403 case: expected 'ERR scope', got: $OUT"; exit 1; }
  echo "$OUT" | grep -qi 'view worklogs' \
    || { echo "403 case: diagnostic should mention 'View Worklogs' scope, got: $OUT"; exit 1; }
) || exit 1

# 7) tempo_ping unknown status (e.g. 500) → generic ERR http N
(
  FAKE_BIN="$TEST_TMP/bin-500"
  body='{"error":"internal"}'
  make_fake_curl "$FAKE_BIN" "$body" "500"
  export PATH="$FAKE_BIN:$PATH"
  export TEMPO_API_TOKEN="tok"

  if OUT=$(tempo_ping 2>&1); then
    echo "500 case: tempo_ping should exit non-zero"; exit 1
  fi
  echo "$OUT" | grep -q '^ERR http 500' \
    || { echo "500 case: expected 'ERR http 500', got: $OUT"; exit 1; }
) || exit 1

# 8) tempo_post_worklog parses the created id from the response body.
(
  FAKE_BIN="$TEST_TMP/bin-post"
  body='{"tempoWorklogId":987654,"timeSpentSeconds":3600}'
  make_fake_curl "$FAKE_BIN" "$body" "200"
  export PATH="$FAKE_BIN:$PATH"
  export TEMPO_API_TOKEN="tok"

  ID=$(tempo_post_worklog '{"issueKey":"PROJ-100","timeSpentSeconds":3600}')
  [[ "$ID" == "987654" ]] \
    || { echo "expected tempoWorklogId=987654, got: $ID"; exit 1; }
) || exit 1

# 9) tempo_post_worklog with a malformed response → non-zero rc, body on stderr.
(
  FAKE_BIN="$TEST_TMP/bin-post-bad"
  body='{"errors":[{"message":"start date in future"}]}'
  make_fake_curl "$FAKE_BIN" "$body" "400"
  export PATH="$FAKE_BIN:$PATH"
  export TEMPO_API_TOKEN="tok"

  if OUT=$(tempo_post_worklog '{}' 2>&1); then
    echo "malformed response case: should have non-zero rc"; exit 1
  fi
  echo "$OUT" | grep -q "start date in future" \
    || { echo "expected body echoed on stderr, got: $OUT"; exit 1; }
) || exit 1

# 10) tempo_list_worklogs composes the expected JSON body.
#     We verify by capturing the body the fake curl received via -d.
(
  CAP="$TEST_TMP/tempo-list-body.json"
  FAKE_BIN="$TEST_TMP/bin-list"
  mkdir -p "$FAKE_BIN"
  cat > "$FAKE_BIN/curl" <<EOF
#!/bin/bash
# Snapshot the -d arg so the test can inspect it.
cap=$(printf %q "$CAP")
prev=""
for a in "\$@"; do
  if [[ "\$prev" == "-d" ]]; then
    printf '%s' "\$a" > "\$cap"
  fi
  prev="\$a"
done
printf '{"results":[]}'
EOF
  chmod +x "$FAKE_BIN/curl"
  export PATH="$FAKE_BIN:$PATH"
  export TEMPO_API_TOKEN="tok"

  tempo_list_worklogs "acc-123" "2026-04-10" "2026-04-15" >/dev/null
  [[ -s "$CAP" ]] || { echo "expected body capture at $CAP"; exit 1; }

  python3 - <<PY
import json
with open("$CAP") as fh:
    body = json.load(fh)
assert body == {
    "authorIds": ["acc-123"],
    "from": "2026-04-10",
    "to": "2026-04-15",
}, body
PY
) || exit 1

# 11) TEMPO_API_BASE override is respected (so alt. instances could work).
(
  FAKE_BIN="$TEST_TMP/bin-base"
  mkdir -p "$FAKE_BIN"
  # This fake curl just prints the URL it was asked to fetch (last arg before
  # any data flags). That's sufficient to prove the base URL wiring.
  cat > "$FAKE_BIN/curl" <<'EOF'
#!/bin/bash
# The URL is the first non-flag argument after the options.
url=""
for a in "$@"; do
  case "$a" in
    http*://*) url="$a" ;;
  esac
done
printf 'URL=%s' "$url"
EOF
  chmod +x "$FAKE_BIN/curl"
  export PATH="$FAKE_BIN:$PATH"
  export TEMPO_API_TOKEN="tok"
  export TEMPO_API_BASE="https://tempo.example.com/api"

  OUT=$(tempo_get /worklogs/1 2>/dev/null || true)
  echo "$OUT" | grep -q '^URL=https://tempo.example.com/api/worklogs/1$' \
    || { echo "TEMPO_API_BASE override not applied; got: $OUT"; exit 1; }
) || exit 1

echo "all checks passed"
