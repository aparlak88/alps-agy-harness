#!/usr/bin/env bash
# Alps AGY Harness - Post-PR Stop Continuation Gate (stop-gate.sh)
# When pr-audit-pending.json exists and terminationReason == "NO_TOOL_CALL":
#   - If stopRetries < 2: atomically increments stopRetries by +1 and returns {"decision":"continue","reason":"..."}
#   - If stopRetries >= 2 (or non-NO_TOOL_CALL / .harness-ignore / file absent): returns {}
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

harness_read_stdin

if harness_is_ignored "$WORKSPACE_ROOT"; then
  echo "{}"
  exit 0
fi

term_reason="$(printf '%s\n' "$HOOK_INPUT" | jq -r '.terminationReason // empty' 2>/dev/null || true)"
if [ "$term_reason" != "NO_TOOL_CALL" ]; then
  echo "{}"
  exit 0
fi

slug="$(harness_branch_slug "$WORKSPACE_ROOT")"
state_dir="$WORKSPACE_ROOT/.harness/state/$slug"
pending_file="$state_dir/pr-audit-pending.json"

if [ ! -f "$pending_file" ]; then
  echo "{}"
  exit 0
fi

retries="$(jq -r '.stopRetries // 0' "$pending_file" 2>/dev/null || echo "2")"
if [[ ! "$retries" =~ ^[0-9]+$ ]] || [ "$retries" -ge 2 ]; then
  echo "{}"
  exit 0
fi

updated_pending="$(jq -c '.stopRetries = ((.stopRetries // 0) + 1)' "$pending_file")"
atomic_write_json "$state_dir" "pr-audit-pending.json" "$updated_pending"

jq -nc \
  --arg reason "PR açıldı; oturumu kapatmadan önce review-pr skill'ini kullanarak pr-auditor değerlendirmesini çalıştır." \
  '{decision: "continue", reason: $reason}'
exit 0
