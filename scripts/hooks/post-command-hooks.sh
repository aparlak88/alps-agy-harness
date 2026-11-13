#!/usr/bin/env bash
# Alps AGY Harness - PostToolUse Command Automation (post-command-hooks.sh)
# Automates:
#   1. Sets pr-audit-pending.json on successful `gh pr create`
#   2. Triggers incremental graphify update on `gh pr merge` or on main/master `git merge`/`git pull`
# Always outputs `{}` on stdout as per Antigravity PostToolUse contract.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

harness_read_stdin

# Respect .harness-ignore
if harness_is_ignored "$WORKSPACE_ROOT"; then
  echo "{}"
  exit 0
fi

# Only process run_command tool calls
tool_name="$(printf '%s' "$HOOK_INPUT" | jq -r '.toolCall.name // empty' 2>/dev/null || true)"
if [ "$tool_name" != "run_command" ]; then
  echo "{}"
  exit 0
fi

# Only trigger when command execution was successful (no error)
has_error="$(printf '%s' "$HOOK_INPUT" | jq -r '(.error // .toolOutput.error // .toolError // empty) | tostring' 2>/dev/null || true)"
if [ -n "$has_error" ]; then
  echo "{}"
  exit 0
fi

cmd_line="$(printf '%s' "$HOOK_INPUT" | jq -r '.toolCall.args.CommandLine // empty' 2>/dev/null || true)"
if [ -z "$cmd_line" ]; then
  echo "{}"
  exit 0
fi

segments_json="$(harness_parse_command_segments "$cmd_line")"
if [ -z "$segments_json" ] || [ "$segments_json" = "[]" ]; then
  echo "{}"
  exit 0
fi

trigger_graphify() {
  if [ -d "$WORKSPACE_ROOT/graphify-out" ]; then
    mkdir -p "$WORKSPACE_ROOT/.harness/logs"
    local log_file="$WORKSPACE_ROOT/.harness/logs/graphify-hook.log"
    if [ -x "$WORKSPACE_ROOT/graphify-out/.graphify_python" ]; then
      (cd "$WORKSPACE_ROOT" && "$WORKSPACE_ROOT/graphify-out/.graphify_python" -m graphify --update --no-viz >> "$log_file" 2>&1) || true
    else
      local bin="${HARNESS_GRAPHIFY_BIN:-graphify}"
      (cd "$WORKSPACE_ROOT" && "$bin" --update --no-viz >> "$log_file" 2>&1) || true
    fi
  fi
}

active_branch="$(harness_branch_name "$WORKSPACE_ROOT")"
num_segments="$(jq -r 'length' <<< "$segments_json" 2>/dev/null || echo 0)"

for ((s_idx = 0; s_idx < num_segments; s_idx++)); do
  seg_json="$(jq -c ".[$s_idx]" <<< "$segments_json")"
  exe="$(jq -r '.[0] // empty' <<< "$seg_json")"
  [ -n "$exe" ] || continue
  exe_base="$(basename "$exe")"

  if [ "$exe_base" = "gh" ]; then
    is_pr_create="$(jq -r '
      (to_entries | map(select(.value == "pr")) | .[0].key) as $pr_i
      | (to_entries | map(select(.value == "create")) | .[0].key) as $create_i
      | if $pr_i != null and $create_i != null and $create_i == ($pr_i + 1) then "true" else "false" end
    ' <<< "$seg_json" 2>/dev/null || echo "false")"

    if [ "$is_pr_create" = "true" ]; then
      raw_out="$(printf '%s' "$HOOK_INPUT" | jq -r '(.toolOutput.output // .toolOutput // .output // "") | tostring' 2>/dev/null || true)"
      pr_url="$(grep -Eo 'https?://[^ ]+/pull/[0-9]+' <<< "$raw_out" | head -n 1 || true)"
      if [ -z "$pr_url" ]; then
        pr_url="$(printf '%s' "$raw_out" | tr -d '\n' | sed -E 's/[[:space:]]+$//')"
      fi

      state_dir="$(harness_state_dir "$WORKSPACE_ROOT")"
      payload="$(jq -nc --arg url "$pr_url" '{prUrl: $url, stopRetries: 0}')"
      atomic_write_json "$state_dir" "pr-audit-pending.json" "$payload"
    fi

    is_pr_merge="$(jq -r '
      (to_entries | map(select(.value == "pr")) | .[0].key) as $pr_i
      | (to_entries | map(select(.value == "merge")) | .[0].key) as $merge_i
      | if $pr_i != null and $merge_i != null and $merge_i == ($pr_i + 1) then "true" else "false" end
    ' <<< "$seg_json" 2>/dev/null || echo "false")"

    if [ "$is_pr_merge" = "true" ]; then
      trigger_graphify
    fi

  elif [ "$exe_base" = "git" ]; then
    git_subcmd="$(jq -r '
      . as $arr
      | if ($arr | length) <= 1 then ""
      else
        reduce range(1; $arr | length) as $i (
          {found: "", skip_next: false};
          if .found != "" then .
          elif .skip_next then .skip_next = false
          elif $arr[$i] == "-C" or $arr[$i] == "-c" or $arr[$i] == "--git-dir" or $arr[$i] == "--work-tree" then .skip_next = true
          elif ($arr[$i] | startswith("-")) then .
          else .found = $arr[$i]
          end
        ) | .found
      end
    ' <<< "$seg_json" 2>/dev/null || true)"

    if [ "$active_branch" = "main" ] || [ "$active_branch" = "master" ]; then
      if [ "$git_subcmd" = "merge" ] || [ "$git_subcmd" = "pull" ]; then
        trigger_graphify
      fi
    fi
  fi
done

echo "{}"
exit 0
