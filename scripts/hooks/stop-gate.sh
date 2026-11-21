#!/usr/bin/env bash
# Alps AGY Harness - Post-PR Stop Continuation Gate (stop-gate.sh)
# Queries warm harness-daemon over Unix socket and fails closed to harness_core.py fallback.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

harness_read_stdin

if harness_is_ignored "$WORKSPACE_ROOT"; then
  echo "{}"
  exit 0
fi

req_payload="$(printf '%s\n' "$HOOK_INPUT" | jq -c \
  --arg ws "$WORKSPACE_ROOT" \
  '(if type == "object" then . else {} end) + {workspace: $ws}' 2>/dev/null || true)"

if [ -n "$req_payload" ] && \
   daemon_resp="$(harness_daemon_call "/hook/stop-gate" "$req_payload")" && \
   printf '%s' "$daemon_resp" | jq -e 'type == "object" and ((keys | length == 0) or .decision == "continue")' >/dev/null 2>&1; then
  printf '%s\n' "$daemon_resp"
  exit 0
fi

printf '%s' "$HOOK_INPUT" | python3 -B "$(harness_core_python)" eval-stop-gate --workspace "$WORKSPACE_ROOT"
