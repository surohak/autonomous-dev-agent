#!/bin/bash
# test_gitlab_lib.sh — lib/gitlab.sh loads cleanly, encodes paths correctly,
# and degrades gracefully when glab is missing.
#
# We don't hit the real GitLab API here (no creds in CI, and we don't want
# test runs to mutate real MRs). Network-bound assertions belong in a separate
# manual smoke test.

set -euo pipefail
source "$HOME/.cursor/skills/autonomous-dev-agent/scripts/lib/env.sh"
source "$HOME/.cursor/skills/autonomous-dev-agent/scripts/lib/gitlab.sh"

# 1) Idempotent load guard.
source "$HOME/.cursor/skills/autonomous-dev-agent/scripts/lib/gitlab.sh"
[[ "$_DEV_AGENT_GITLAB_LOADED" == "1" ]] || { echo "load guard missing"; exit 1; }

# 2) Functions are exported/visible.
for fn in gl_encode gl_api gl_mr_get gl_mr_approve gl_mr_resolve_discussion; do
  declare -F "$fn" >/dev/null || { echo "missing function: $fn"; exit 1; }
done

# 3) gl_encode handles slashes, spaces, unicode.
[[ "$(gl_encode 'demo-org/app')" == 'demo-org%2Fapp' ]] \
  || { echo "encode slash failed"; exit 1; }
[[ "$(gl_encode 'my group/my repo')" == 'my%20group%2Fmy%20repo' ]] \
  || { echo "encode space failed"; exit 1; }
[[ "$(gl_encode 'café/naïve')" == 'caf%C3%A9%2Fna%C3%AFve' ]] \
  || { echo "encode unicode failed"; exit 1; }

# 4) Missing glab → controlled return code 2, no crash.
#    Simulate by overriding command lookup.
_run_without_glab() {
  (
    export PATH=/nonexistent
    source "$HOME/.cursor/skills/autonomous-dev-agent/scripts/lib/env.sh" 2>/dev/null || true
    # Re-source because the load guard blocked our override above.
    unset _DEV_AGENT_GITLAB_LOADED
    source "$HOME/.cursor/skills/autonomous-dev-agent/scripts/lib/gitlab.sh"
    gl_api GET "projects/1" 2>/dev/null
    echo "rc=$?"
  )
}
OUT=$(_run_without_glab)
echo "$OUT" | grep -q 'rc=2' || { echo "expected rc=2 when glab missing, got: $OUT"; exit 1; }

# 5) gl_mr_approve's "already approved" tolerance — we simulate glab by shadowing
#    it with a function that returns the expected error text. We have to do
#    this in a subshell so the fake glab doesn't leak into other tests.
(
  # A fake `glab` that prints the GitLab "already approved" response on stderr
  # and returns non-zero (mirroring the real behaviour).
  FAKE_BIN="$TEST_TMP/bin"
  mkdir -p "$FAKE_BIN"
  cat > "$FAKE_BIN/glab" <<'EOF'
#!/bin/bash
# Pretend we got {"message":"401 Unauthorized - Cannot approve... already approved"}
echo '{"message":"401 Unauthorized - Cannot approve your own merge request"}' >&2
echo 'already approved' >&2
exit 1
EOF
  chmod +x "$FAKE_BIN/glab"
  export PATH="$FAKE_BIN:$PATH"

  unset _DEV_AGENT_GITLAB_LOADED
  source "$HOME/.cursor/skills/autonomous-dev-agent/scripts/lib/gitlab.sh"

  if gl_mr_approve "demo-org/app" "9999" >/dev/null 2>&1; then
    echo "already-approved tolerated: OK"
  else
    echo "expected gl_mr_approve to tolerate 'already approved', got rc=$?"
    exit 1
  fi
) || exit 1

echo "all checks passed"
