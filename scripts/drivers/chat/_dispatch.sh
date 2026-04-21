#!/bin/bash
# scripts/drivers/chat/_dispatch.sh
# Source the right chat driver based on CHAT_KIND (default: telegram).

[[ -n "${_DEV_AGENT_CHAT_DISPATCH_LOADED:-}" ]] && return 0
_DEV_AGENT_CHAT_DISPATCH_LOADED=1

_chat_kind="${CHAT_KIND:-telegram}"
_chat_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_chat_file="$_chat_dir/${_chat_kind}.sh"

if [[ ! -f "$_chat_file" ]]; then
  echo "chat-dispatch: no driver for CHAT_KIND='$_chat_kind'" >&2
  echo "  available: $(cd "$_chat_dir" && ls *.sh 2>/dev/null | grep -v '^_' | sed 's/\.sh$//' | tr '\n' ' ')" >&2
  return 1
fi

# shellcheck disable=SC1090
source "$_chat_file"
