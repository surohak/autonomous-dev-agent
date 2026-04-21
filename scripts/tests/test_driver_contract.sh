#!/bin/bash
# scripts/tests/test_driver_contract.sh
#
# Table-driven interface-compliance test. Walks every driver under
# scripts/drivers/{tracker,host,chat}/ and asserts that each one exports
# the required public functions. The signatures themselves are documented
# in scripts/drivers/*/_interface.md — this test only checks that the
# name+"function declared" shows up after sourcing.
#
# No network calls; safe to run offline. New drivers added in
# scripts/drivers/*/ are picked up automatically.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export SKILL_DIR

# Required function sets per driver layer. Keep in sync with _interface.md.
TRACKER_REQUIRED=(
  tracker_probe tracker_search tracker_get tracker_transition
  tracker_comment tracker_assign
)
HOST_REQUIRED=(
  host_probe host_current_user host_mr_list host_mr_get
  host_mr_merge host_ci_status host_notes
  host_branch_exists host_repo_slug_for_alias
)
CHAT_REQUIRED=(
  chat_probe chat_send chat_send_interactive chat_edit chat_poll
)

fail=0
report() {
  local label="$1" msg="$2"
  echo "FAIL [$label]: $msg"
  fail=1
}

# A driver is tested by sourcing it in a fresh subshell so contract checks
# are independent. We also source the relevant lib/*.sh on the way in for
# drivers that wrap them. NOTE: macOS bash 3.2 has no namerefs or ${var^^},
# so we pick the required-function list with a plain case.
check_driver() {
  local layer="$1" driver_file="$2"
  local driver_name
  driver_name=$(basename "$driver_file" .sh)

  local required=()
  case "$layer" in
    tracker) required=("${TRACKER_REQUIRED[@]}") ;;
    host)    required=("${HOST_REQUIRED[@]}") ;;
    chat)    required=("${CHAT_REQUIRED[@]}") ;;
  esac

  # Source in a subshell; export env stubs so driver doesn't fail at load.
  local out
  out=$(bash -c "
    set -uo pipefail
    export SKILL_DIR='$SKILL_DIR'
    # Stub env for probes — drivers must load cleanly even without creds.
    export JIRA_SITE='https://example.com'
    export JIRA_PROJECT='TEST'
    export TRACKER_PROJECT='owner/repo'
    export HOST_GROUP='example'
    export CHAT_CHANNEL='C00000000'
    # Source the lib/ layer for wrappers that rely on it.
    # shellcheck disable=SC1091
    source '$SKILL_DIR/scripts/lib/env.sh' 2>/dev/null || true
    source '$driver_file' 2>/dev/null || { echo 'LOAD_ERR'; exit 1; }
    for fn in ${required[*]}; do
      if ! declare -F \$fn >/dev/null; then
        echo \"MISSING:\$fn\"
      fi
    done
  " 2>&1)

  if [[ "$out" == *"LOAD_ERR"* ]]; then
    report "$driver_name" "driver failed to source"
    return 1
  fi

  local missing
  missing=$(printf '%s\n' "$out" | grep '^MISSING:' | sed 's/^MISSING://' || true)
  if [[ -n "$missing" ]]; then
    while IFS= read -r fn; do
      report "$driver_name" "missing function $fn (required by $layer contract)"
    done <<< "$missing"
    return 1
  fi
  echo "PASS [$driver_name] ($layer) — all ${#required[@]} required functions exported"
}

# --- walk all drivers ------------------------------------------------------
for layer in tracker host chat; do
  dir="$SKILL_DIR/scripts/drivers/$layer"
  [[ -d "$dir" ]] || { report "$layer" "drivers/$layer/ missing"; continue; }
  for f in "$dir"/*.sh; do
    [[ -f "$f" ]] || continue
    # Skip dispatcher and any file starting with _
    base=$(basename "$f")
    [[ "$base" == _* ]] && continue
    check_driver "$layer" "$f"
  done
done

# --- dispatcher sanity -----------------------------------------------------
# Source each dispatcher with default KIND, make sure the fallback driver loads.
check_dispatcher() {
  local layer="$1" default_kind="$2"
  local disp="$SKILL_DIR/scripts/drivers/$layer/_dispatch.sh"
  [[ -f "$disp" ]] || { report "$layer" "_dispatch.sh missing"; return 1; }
  local out
  out=$(bash -c "
    set -uo pipefail
    export SKILL_DIR='$SKILL_DIR'
    # shellcheck disable=SC1091
    source '$SKILL_DIR/scripts/lib/env.sh' 2>/dev/null || true
    source '$disp' 2>/dev/null && echo OK
  " 2>&1)
  if [[ "$out" == *OK* ]]; then
    echo "PASS [$layer] dispatcher loads default=$default_kind"
  else
    report "$layer" "dispatcher failed to load default driver: $out"
  fi
}

check_dispatcher tracker jira-cloud
check_dispatcher host gitlab
check_dispatcher chat telegram

# --- bad-kind error path ---------------------------------------------------
# Setting an unknown kind should produce a descriptive error, not crash.
out=$(bash -c "
  set -uo pipefail
  export SKILL_DIR='$SKILL_DIR'
  export TRACKER_KIND=bogus-kind-that-doesnt-exist
  source '$SKILL_DIR/scripts/drivers/tracker/_dispatch.sh' 2>&1 || true
")
echo "$out" | grep -q "no driver for TRACKER_KIND='bogus-kind-that-doesnt-exist'" \
  || report "tracker-dispatch" "bad TRACKER_KIND error message unclear: $out"

if [[ $fail -eq 0 ]]; then
  echo "OK test_driver_contract"
  exit 0
fi
exit 1
