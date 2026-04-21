#!/bin/bash
# scripts/drivers/tracker/_dispatch.sh
#
# Source the driver file appropriate for the active project's tracker kind.
# Canonical tracker_* functions become available in the caller's shell.
#
# Usage (from any script):
#   source "$SKILL_DIR/scripts/drivers/tracker/_dispatch.sh"
#   tracker_transition AL-123 push_review
#
# The dispatcher is stateless — every call site must re-source after a
# project switch (cfg_project_activate invalidates TRACKER_KIND).

[[ -n "${_DEV_AGENT_TRACKER_DISPATCH_LOADED:-}" ]] && return 0
_DEV_AGENT_TRACKER_DISPATCH_LOADED=1

# Resolve tracker kind with fallbacks. v0.3 installs that haven't set
# projects[].tracker.kind default to jira-cloud for back-compat.
_tracker_kind="${TRACKER_KIND:-jira-cloud}"

_tracker_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_tracker_file="$_tracker_dir/${_tracker_kind}.sh"

if [[ ! -f "$_tracker_file" ]]; then
  echo "tracker-dispatch: no driver for TRACKER_KIND='$_tracker_kind'" >&2
  echo "  available: $(cd "$_tracker_dir" && ls *.sh 2>/dev/null | grep -v '^_' | sed 's/\.sh$//' | tr '\n' ' ')" >&2
  return 1
fi

# shellcheck disable=SC1090
source "$_tracker_file"
