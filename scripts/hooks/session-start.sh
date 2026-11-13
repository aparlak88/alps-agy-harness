#!/usr/bin/env bash
# Alps AGY Harness - SessionStart Hook (session-start.sh)
# Injects workspace branch status, canon and graphify readiness, tool warnings, and protocols.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

harness_read_stdin

if harness_is_ignored "$WORKSPACE_ROOT"; then
  echo "{}"
  exit 0
fi

branch="$(harness_branch_name "$WORKSPACE_ROOT")"
parent_model="$(printf '%s\n' "$HOOK_INPUT" | jq -r '.modelName // empty' 2>/dev/null || true)"
parent_family="$(harness_classify_parent_model "$parent_model")"
parent_model_display="${parent_model:-unspecified}"

# Check canon files
canon_glossary="missing"
canon_flows="missing"
canon_lessons="missing"
[ -f "$WORKSPACE_ROOT/docs/canon/glossary.md" ] && canon_glossary="present"
[ -f "$WORKSPACE_ROOT/docs/canon/flows.md" ] && canon_flows="present"
[ -f "$WORKSPACE_ROOT/docs/canon/lessons.md" ] && canon_lessons="present"

# Check graphify
graphify_status="missing"
[ -f "$WORKSPACE_ROOT/graphify-out/graph.json" ] && graphify_status="present"

# Check required CLI tools (test override via HARNESS_CHECK_BINS)
missing_bins=()
check_bins="${HARNESS_CHECK_BINS:-gh jq}"
for b in $check_bins; do
  if ! command -v "$b" >/dev/null 2>&1; then
    missing_bins+=("$b")
  fi
done

tool_warning=""
if [ ${#missing_bins[@]} -gt 0 ]; then
  tool_warning="[WARNING] Missing required tool(s): ${missing_bins[*]}. Run scripts/harness-doctor.sh to diagnose and resolve environment prerequisites."
fi

# Build context injection message
msg="[Alps AGY Harness - Active Session Context]
- Active Git Branch: $branch
- Active Session Model: $parent_model_display (family: $parent_family)
- Canon Status:
  - glossary.md: $canon_glossary
  - flows.md: $canon_flows
  - lessons.md: $canon_lessons
- Graphify Status: $graphify_status (graphify-out/graph.json)
- Protocols:
  - Use jev_classify, jev_check, and jev_ask for intent, architecture trade-offs, and verification.
  - Parent-aware Gemini 4 / Orchestrator subagent routing is enforced by pre-subagent-guard.sh (never downgrades Carbon/Orchestrator/Argon-High audits; escalates Hydrogen/Flash audits to Argon via pro).
  - Wrap high-output shell commands with scripts/run-quiet.sh.
  - All documentation must conclude with a ## Teknik Terimler Sözlüğü or ## Technical Glossary section."

if [ -n "$tool_warning" ]; then
  msg="$msg
$tool_warning"
fi

jq -nc --arg msg "$msg" '{injectSteps: [{systemMessage: {systemMessage: $msg}}]}'
