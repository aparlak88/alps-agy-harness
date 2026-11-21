#!/usr/bin/env bash
# Alps AGY Harness - SessionStart Hook (session-start.sh)
# Uses warm harness-daemon when available, falling back deterministically to harness_core.py.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

harness_read_stdin

if harness_is_ignored "$WORKSPACE_ROOT"; then
  echo "{}"
  exit 0
fi

harness_ensure_daemon >/dev/null 2>&1 || true

# Evaluate client-side PATH bins locally for strict test/env parity
missing_bins=()
check_bins="${HARNESS_CHECK_BINS:-gh jq}"
for b in $check_bins; do
  if ! command -v "$b" >/dev/null 2>&1; then
    missing_bins+=("$b")
  fi
done
missing_bins_json="[]"
if [ ${#missing_bins[@]} -gt 0 ]; then
  missing_bins_json="$(printf '%s\n' "${missing_bins[@]}" | jq -R . | jq -sc .)"
fi

# Share boolean-only key presence hint (never the secret string itself)
env_key_present=false
trimmed_key="$(printf '%s' "${TYPESAFE_API_KEY:-}" | LC_ALL=C tr -d '[:space:]')"
if [ -n "$trimmed_key" ]; then
  case "$trimmed_key" in
    \<*\>) ;;
    *) env_key_present=true ;;
  esac
fi

req_payload="$(printf '%s\n' "$HOOK_INPUT" | jq -c \
  --arg ws "$WORKSPACE_ROOT" \
  --argjson missing "$missing_bins_json" \
  --argjson ekp "$env_key_present" \
  '(if type == "object" then . else {} end) + {workspace: $ws, missingBins: $missing, envKeyPresent: $ekp}' 2>/dev/null \
  || jq -nc --arg ws "$WORKSPACE_ROOT" --argjson missing "$missing_bins_json" --argjson ekp "$env_key_present" \
     '{workspace: $ws, missingBins: $missing, envKeyPresent: $ekp}')"

if daemon_resp="$(harness_daemon_call "/hook/session-start" "$req_payload")" && \
   printf '%s' "$daemon_resp" | jq -e 'type == "object" and (.injectSteps | type == "array") and ((.injectSteps[0].systemMessage.systemMessage // "") | length > 0)' >/dev/null 2>&1; then
  printf '%s\n' "$daemon_resp"
  exit 0
fi

printf '%s' "$HOOK_INPUT" | python3 -B "$(harness_core_python)" eval-session-start --workspace "$WORKSPACE_ROOT"
