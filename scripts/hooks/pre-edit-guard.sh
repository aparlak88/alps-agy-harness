#!/usr/bin/env bash
# Alps AGY Harness - PreToolUse Guard for write_file & edit_file (pre-edit-guard.sh)
# Queries warm harness-daemon over Unix socket and fails closed to harness_core.py fallback.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

harness_read_stdin

if harness_is_ignored "$WORKSPACE_ROOT"; then
  emit_allow
  exit 0
fi

req_payload="$(jq -nc \
  --argjson orig "$HOOK_INPUT" \
  --arg ws "$WORKSPACE_ROOT" \
  '($orig | if type == "object" then . else {} end) + {workspace: $ws}' 2>/dev/null || true)"

if [ -n "$req_payload" ] && \
   daemon_resp="$(harness_daemon_call "/hook/pre-edit" "$req_payload")" && \
   printf '%s' "$daemon_resp" | jq -e 'type == "object" and (.decision == "allow" or .decision == "deny" or .decision == "force_ask")' >/dev/null 2>&1; then
  printf '%s\n' "$daemon_resp"
  exit 0
fi

printf '%s' "$HOOK_INPUT" | python3 -B "$(harness_core_python)" eval-pre-edit --workspace "$WORKSPACE_ROOT"
