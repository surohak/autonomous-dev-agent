#!/bin/bash
# scripts/drivers/host/_dispatch.sh
# Source the right host driver based on HOST_KIND (default: gitlab).

[[ -n "${_DEV_AGENT_HOST_DISPATCH_LOADED:-}" ]] && return 0
_DEV_AGENT_HOST_DISPATCH_LOADED=1

_host_kind="${HOST_KIND:-gitlab}"
_host_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_host_file="$_host_dir/${_host_kind}.sh"

if [[ ! -f "$_host_file" ]]; then
  echo "host-dispatch: no driver for HOST_KIND='$_host_kind'" >&2
  echo "  available: $(cd "$_host_dir" && ls *.sh 2>/dev/null | grep -v '^_' | sed 's/\.sh$//' | tr '\n' ' ')" >&2
  return 1
fi

# shellcheck disable=SC1090
source "$_host_file"
