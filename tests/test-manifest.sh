#!/usr/bin/env bash
# Alps AGY Harness - Manifest & Root Configuration Tests
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"

test_plugin_json_valid_and_strict_keys() {
  [ -f "$REPO_ROOT/plugin.json" ] || { echo "plugin.json does not exist" >&2; return 1; }
  jq -e '.name == "alps-agy-harness" and .logo == "assets/logo.svg" and (.suggestedPrompts | length == 3)' "$REPO_ROOT/plugin.json" >/dev/null
  local extra_keys
  extra_keys=$(jq -r 'keys - ["name","displayName","version","description","logo","suggestedPrompts","author","homepage","repository","disabled"] | length' "$REPO_ROOT/plugin.json")
  assert_eq "0" "$extra_keys" "plugin.json must not contain unknown top-level keys"
}

test_plugin_json_required_fields() {
  [ -f "$REPO_ROOT/plugin.json" ] || { echo "plugin.json does not exist" >&2; return 1; }
  assert_json_field "$REPO_ROOT/plugin.json" ".name" "alps-agy-harness"
  assert_json_field "$REPO_ROOT/plugin.json" ".displayName" "Alps AGY Engineering Harness"
  assert_json_field "$REPO_ROOT/plugin.json" ".version" "1.0.0"

  # Verify suggestedPrompts structure (array of 3 non-empty strings per Antigravity plugin.json schema)
  jq -e '(.suggestedPrompts | type == "array") and (.suggestedPrompts | length == 3) and (.suggestedPrompts | all(type == "string" and length > 0))' "$REPO_ROOT/plugin.json" >/dev/null
}

test_hooks_json_root_wiring() {
  [ -f "$REPO_ROOT/hooks.json" ] || { echo "hooks.json does not exist" >&2; return 1; }
  jq -e '
    .["alps-agy-harness"].SessionStart[0].command == "./scripts/hooks/session-start.sh" and
    (.["alps-agy-harness"].PreToolUse | map(.matcher) == ["write_file|edit_file","run_command","invoke_subagent"]) and
    .["alps-agy-harness"].PostToolUse[0].matcher == "run_command" and
    .["alps-agy-harness"].Stop[0].command == "./scripts/hooks/stop-gate.sh"
  ' "$REPO_ROOT/hooks.json" >/dev/null
}

test_hooks_json_timeouts() {
  [ -f "$REPO_ROOT/hooks.json" ] || { echo "hooks.json does not exist" >&2; return 1; }
  jq -e '
    .["alps-agy-harness"].SessionStart[0].timeout == 15 and
    .["alps-agy-harness"].PreToolUse[0].hooks[0].timeout == 15 and
    .["alps-agy-harness"].PreToolUse[1].hooks[0].timeout == 15 and
    .["alps-agy-harness"].PreToolUse[2].hooks[0].timeout == 15 and
    .["alps-agy-harness"].PostToolUse[0].hooks[0].timeout == 30 and
    .["alps-agy-harness"].Stop[0].timeout == 15
  ' "$REPO_ROOT/hooks.json" >/dev/null
}

test_logo_svg_square_and_present() {
  [ -s "$REPO_ROOT/assets/logo.svg" ] || { echo "assets/logo.svg does not exist or is empty" >&2; return 1; }
  grep -Eq 'viewBox="0 0 256 256"' "$REPO_ROOT/assets/logo.svg"
}

test_gitignore_entries() {
  [ -f "$REPO_ROOT/.gitignore" ] || { echo ".gitignore does not exist" >&2; return 1; }
  grep -Fqx ".harness/" "$REPO_ROOT/.gitignore"
  grep -Fqx ".worktrees/" "$REPO_ROOT/.gitignore"
  grep -Fqx ".superpowers/" "$REPO_ROOT/.gitignore"
  grep -Fqx "*.tmp" "$REPO_ROOT/.gitignore"
  grep -Fqx ".DS_Store" "$REPO_ROOT/.gitignore"
}

test_helpers_temp_repo() {
  local repo
  repo=$(make_temp_repo)
  [ -d "$repo/.git" ]
  assert_eq "Harness Test" "$(git -C "$repo" config user.name)"
  assert_eq "harness@test.local" "$(git -C "$repo" config user.email)"
}

test_runner_fails_on_intermediate_command_failure() {
  local runner_test
  runner_test=$(bash -c '
    source "'"$REPO_ROOT"'/tests/test-helpers.sh"
    test_sub_intermediate_fail() {
      false
      true
    }
    run_tests test_sub_intermediate_fail
  ' 2>&1 || true)
  assert_contains "$runner_test" "FAIL" "Test runner must report FAIL when intermediate command fails"
  assert_contains "$runner_test" "0 passed, 1 failed" "Test runner summary must show failure"
}

test_helpers_temp_repo_cleanup_on_process_exit() {
  local repo_before repo_after parent_tracker
  repo_before=$(make_temp_repo)
  parent_tracker="$_HARNESS_TEMP_TRACKER"

  local script_output
  script_output=$(bash -c '
    source "'"$REPO_ROOT"'/tests/test-helpers.sh"
    repo=$(make_temp_repo)
    echo "REPO=$repo"
    echo "TRACKER=$_HARNESS_TEMP_TRACKER"
  ')
  local child_repo_dir child_tracker_file
  child_repo_dir=$(echo "$script_output" | grep '^REPO=' | cut -d= -f2-)
  child_tracker_file=$(echo "$script_output" | grep '^TRACKER=' | cut -d= -f2-)

  if [ -z "$child_repo_dir" ] || [ -z "$child_tracker_file" ]; then
    echo "Failed to capture child_repo_dir or child_tracker_file from child process" >&2
    return 1
  fi

  # Child process resources must be cleaned up on child exit
  if [ -d "$child_repo_dir" ]; then
    echo "Temporary directory $child_repo_dir was NOT cleaned up on child process exit" >&2
    return 1
  fi
  if [ -f "$child_tracker_file" ]; then
    echo "Tracker file $child_tracker_file was NOT cleaned up on child process exit" >&2
    return 1
  fi

  # Child tracker file must be distinct from parent tracker file
  assert_eq "1" "$([ "$child_tracker_file" != "$parent_tracker" ] && echo 1 || echo 0)" \
    "Child tracker file must be isolated from parent tracker file"

  repo_after=$(make_temp_repo)

  # Parent tracker and repos created before and after child exit must still exist
  if [ ! -f "$_HARNESS_TEMP_TRACKER" ]; then
    echo "Parent tracker file $_HARNESS_TEMP_TRACKER was prematurely deleted by child process" >&2
    return 1
  fi
  if [ ! -d "$repo_before" ]; then
    echo "Parent repo_before $repo_before was prematurely deleted by child process" >&2
    return 1
  fi
  if [ ! -d "$repo_after" ]; then
    echo "Parent repo_after $repo_after was not created or was deleted" >&2
    return 1
  fi
}

run_tests "$@"
