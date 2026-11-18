#!/usr/bin/env bash
# Alps AGY Harness - PostToolUse Command Automation (post-command-hooks.sh)
# Marks pr-audit-pending.json on gh pr create and enqueues async graphify updates via harness-daemon (or runs sync fallback).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

harness_read_stdin

if harness_is_ignored "$WORKSPACE_ROOT"; then
  echo "{}"
  exit 0
fi

# Preserve explicit caller HARNESS_GRAPHIFY_BIN overrides (e.g. direct unit-test mocks)
# by running synchronous local evaluation when the caller explicitly overrides the binary.
if [ -z "${HARNESS_GRAPHIFY_BIN:-}" ]; then
  req_payload="$(jq -nc \
    --argjson orig "$HOOK_INPUT" \
    --arg ws "$WORKSPACE_ROOT" \
    '($orig | if type == "object" then . else {} end) + {workspace: $ws}' 2>/dev/null || true)"

  if [ -n "$req_payload" ] && \
     daemon_resp="$(harness_daemon_call "/hook/post-command" "$req_payload")" && \
     printf '%s' "$daemon_resp" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "{}"
    exit 0
  fi
fi

printf '%s' "$HOOK_INPUT" | python3 -B "$(harness_core_python)" eval-post-command --workspace "$WORKSPACE_ROOT"
