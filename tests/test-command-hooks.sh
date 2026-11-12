#!/usr/bin/env bash
# Alps AGY Harness - PreToolUse & PostToolUse Command Hook Tests (test-command-hooks.sh)
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-helpers.sh"

PRE_COMMAND_GUARD="$REPO_ROOT/scripts/hooks/pre-command-guard.sh"
POST_COMMAND_HOOKS="$REPO_ROOT/scripts/hooks/post-command-hooks.sh"
STAMP_GATE="$REPO_ROOT/scripts/stamp-gate.sh"

test_infinite_mobile_log_streams_blocked_but_snapshot_allowed() {
  [ -x "$PRE_COMMAND_GUARD" ] || { echo "pre-command-guard.sh missing or not executable: $PRE_COMMAND_GUARD" >&2; return 1; }

  local repo
  repo=$(make_temp_repo)

  # 1. adb logcat without -d -> deny
  local p_adb_deny
  p_adb_deny=$(jq -nc --arg ws "$repo" --arg cmd "adb logcat" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_adb_deny
  out_adb_deny=$(printf '%s' "$p_adb_deny" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_adb_deny" ".decision" "deny" "adb logcat must be denied"
  local reason_adb
  reason_adb=$(printf '%s' "$out_adb_deny" | jq -r '.reason // empty')
  assert_contains "$reason_adb" "scripts/mobile-logs.sh" "Reason must suggest scripts/mobile-logs.sh"

  # 2. adb with target device flag without -d -> deny
  local p_adb_dev
  p_adb_dev=$(jq -nc --arg ws "$repo" --arg cmd "adb -s emulator-5554 logcat" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_adb_dev
  out_adb_dev=$(printf '%s' "$p_adb_dev" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_adb_dev" ".decision" "deny" "adb -s emulator-5554 logcat must be denied"

  # 3. xcrun simctl spawn booted log stream without --timeout / --last -> deny
  local p_simctl_deny
  p_simctl_deny=$(jq -nc --arg ws "$repo" --arg cmd "xcrun simctl spawn booted log stream" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_simctl_deny
  out_simctl_deny=$(printf '%s' "$p_simctl_deny" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_simctl_deny" ".decision" "deny" "xcrun simctl log stream must be denied"
  local reason_simctl
  reason_simctl=$(printf '%s' "$out_simctl_deny" | jq -r '.reason // empty')
  assert_contains "$reason_simctl" "scripts/mobile-logs.sh" "Reason must suggest scripts/mobile-logs.sh"

  # 4. simctl log stream without xcrun -> deny
  local p_bare_simctl
  p_bare_simctl=$(jq -nc --arg ws "$repo" --arg cmd "simctl log stream" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_bare_simctl
  out_bare_simctl=$(printf '%s' "$p_bare_simctl" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_bare_simctl" ".decision" "deny" "simctl log stream must be denied"

  # 5. adb logcat with -d and --pid -> allow
  local p_adb_allow
  p_adb_allow=$(jq -nc --arg ws "$repo" --arg cmd "adb logcat -d --pid=123" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_adb_allow
  out_adb_allow=$(printf '%s' "$p_adb_allow" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_adb_allow" ".decision" "allow" "adb logcat -d must be allowed"

  # 6. xcrun simctl with --timeout -> allow
  local p_simctl_allow
  p_simctl_allow=$(jq -nc --arg ws "$repo" --arg cmd "xcrun simctl spawn booted log stream --timeout 5" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_simctl_allow
  out_simctl_allow=$(printf '%s' "$p_simctl_allow" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_simctl_allow" ".decision" "allow" "simctl log stream with --timeout must be allowed"

  # 7. simctl with --last -> allow
  local p_simctl_last
  p_simctl_last=$(jq -nc --arg ws "$repo" --arg cmd "simctl log stream --last 2m" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_simctl_last
  out_simctl_last=$(printf '%s' "$p_simctl_last" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_simctl_last" ".decision" "allow" "simctl log stream with --last must be allowed"
}

test_quoted_commit_message_does_not_trigger_gates() {
  [ -x "$PRE_COMMAND_GUARD" ] || { echo "pre-command-guard.sh missing or not executable: $PRE_COMMAND_GUARD" >&2; return 1; }

  local repo
  repo=$(make_temp_repo)

  # 1. Commit message mentioning dangerous commands in quotes
  local p_commit
  p_commit=$(jq -nc --arg ws "$repo" --arg cmd 'git commit -m "chore: ready for gh pr create and adb logcat"' \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_commit
  out_commit=$(printf '%s' "$p_commit" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_commit" ".decision" "allow" "Quoted commit message mentioning gates must be allowed"

  # 2. Echo with npm install
  local p_echo
  p_echo=$(jq -nc --arg ws "$repo" --arg cmd 'echo "npm install foo"' \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_echo
  out_echo=$(printf '%s' "$p_echo" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_echo" ".decision" "allow" "Echoing package install command must be allowed"

  # 3. Commit message mentioning push to main
  local p_commit2
  p_commit2=$(jq -nc --arg ws "$repo" --arg cmd 'git commit -m "git push origin main fixed"' \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_commit2
  out_commit2=$(printf '%s' "$p_commit2" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_commit2" ".decision" "allow" "Quoted commit message mentioning push to main must be allowed"
}

test_chained_package_install_requires_context7_stamp() {
  [ -x "$PRE_COMMAND_GUARD" ] || { echo "pre-command-guard.sh missing or not executable: $PRE_COMMAND_GUARD" >&2; return 1; }

  local repo
  repo=$(make_temp_repo)
  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: init" --quiet
  git -C "$repo" checkout -b "feature/pkg-test" --quiet

  # 1. Bare npm ci and npm install are always allowed
  local p_bare_ci
  p_bare_ci=$(jq -nc --arg ws "$repo" --arg cmd "npm ci" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_bare_ci
  out_bare_ci=$(printf '%s' "$p_bare_ci" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_bare_ci" ".decision" "allow" "Bare npm ci must be allowed"

  local p_bare_install
  p_bare_install=$(jq -nc --arg ws "$repo" --arg cmd "npm install" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_bare_install
  out_bare_install=$(printf '%s' "$p_bare_install" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_bare_install" ".decision" "allow" "Bare npm install must be allowed"

  # 2. Chained npm install with version and flags without stamp -> deny
  local p_pkg_deny
  p_pkg_deny=$(jq -nc --arg ws "$repo" --arg cmd "cd app && npm install zod@^3.23.0 --save-dev" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_pkg_deny
  out_pkg_deny=$(printf '%s' "$p_pkg_deny" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_pkg_deny" ".decision" "deny" "Unverified package install must be denied"
  local reason_pkg
  reason_pkg=$(printf '%s' "$out_pkg_deny" | jq -r '.reason // empty')
  assert_contains "$reason_pkg" "zod" "Reason must name unverified package 'zod'"
  assert_contains "$reason_pkg" "context7" "Reason must mention context7"

  # 3. Stamp context7 for zod
  "$STAMP_GATE" context7 --package zod --version 3.23.8 --source greenfield-latest --workspace "$repo"

  # 4. Same chained npm install now allowed
  local out_pkg_allow
  out_pkg_allow=$(printf '%s' "$p_pkg_deny" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_pkg_allow" ".decision" "allow" "Verified package install must be allowed"

  # 5. Scoped package @angular/core@19.0.0
  local p_scoped_deny
  p_scoped_deny=$(jq -nc --arg ws "$repo" --arg cmd "pnpm add @angular/core@19.0.0" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_scoped_deny
  out_scoped_deny=$(printf '%s' "$p_scoped_deny" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_scoped_deny" ".decision" "deny" "Unverified scoped package must be denied"
  local reason_scoped
  reason_scoped=$(printf '%s' "$out_scoped_deny" | jq -r '.reason // empty')
  assert_contains "$reason_scoped" "@angular/core" "Reason must name unverified scoped package"

  # 6. Verify package via ## Global Constraints in docs/superpowers/specs/*.md
  mkdir -p "$repo/docs/superpowers/specs"
  cat << 'EOF' > "$repo/docs/superpowers/specs/01-auth-spec.md"
# Spec: Auth

## Global Constraints

- **Packages:**
  - `@angular/core`: Angular framework version 19
  - `express`: Minimalist web framework
- **Limits:** Query results return at most 100 rows per page.
EOF

  local out_scoped_allow
  out_scoped_allow=$(printf '%s' "$p_scoped_deny" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_scoped_allow" ".decision" "allow" "Package declared in Global Constraints must be allowed"

  # 6b. Short package name 'ws' must NOT false-match 'rows' in Global Constraints
  local p_ws_deny
  p_ws_deny=$(jq -nc --arg ws "$repo" --arg cmd "npm install ws" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_ws_deny
  out_ws_deny=$(printf '%s' "$p_ws_deny" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_ws_deny" ".decision" "deny" "Short package 'ws' must not substring-match 'rows' in Global Constraints"
  assert_contains "$(printf '%s' "$out_ws_deny" | jq -r '.reason')" "ws"

  # 7. dotnet add package Foo -> deny, dotnet package add Foo -> deny, dotnet package search Foo -> allow
  local p_dotnet_search
  p_dotnet_search=$(jq -nc --arg ws "$repo" --arg cmd "dotnet package search Serilog" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_dotnet_search
  out_dotnet_search=$(printf '%s' "$p_dotnet_search" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_dotnet_search" ".decision" "allow" "dotnet package search Serilog must be allowed without context7 stamp"

  local p_dotnet_pkg_add
  p_dotnet_pkg_add=$(jq -nc --arg ws "$repo" --arg cmd "dotnet package add Serilog" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_dotnet_pkg_add
  out_dotnet_pkg_add=$(printf '%s' "$p_dotnet_pkg_add" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_dotnet_pkg_add" ".decision" "deny" "dotnet package add Serilog must be denied before Context7 stamp"
  assert_contains "$(printf '%s' "$out_dotnet_pkg_add" | jq -r '.reason')" "Serilog"

  local p_dotnet_deny
  p_dotnet_deny=$(jq -nc --arg ws "$repo" --arg cmd "dotnet add app.csproj package Serilog.AspNetCore --version 8.0.0" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_dotnet_deny
  out_dotnet_deny=$(printf '%s' "$p_dotnet_deny" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_dotnet_deny" ".decision" "deny" "Unverified dotnet package must be denied"
  assert_contains "$(printf '%s' "$out_dotnet_deny" | jq -r '.reason')" "Serilog.AspNetCore"
}

test_pr_only_main_blocks_direct_push_and_local_merge_when_remote_exists() {
  [ -x "$PRE_COMMAND_GUARD" ] || { echo "pre-command-guard.sh missing or not executable: $PRE_COMMAND_GUARD" >&2; return 1; }

  local repo
  repo=$(make_temp_repo)
  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: init" --quiet

  # Add dummy origin remote
  git -C "$repo" remote add origin "https://github.com/example/alps-repo.git"

  # 1. git push origin main -> deny
  local p_push_main
  p_push_main=$(jq -nc --arg ws "$repo" --arg cmd "git push origin main" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_push_main
  out_push_main=$(printf '%s' "$p_push_main" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_push_main" ".decision" "deny" "git push origin main must be denied"

  # 2. git push origin HEAD:main -> deny
  local p_push_refspec
  p_push_refspec=$(jq -nc --arg ws "$repo" --arg cmd "git push origin HEAD:main" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_push_refspec
  out_push_refspec=$(printf '%s' "$p_push_refspec" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_push_refspec" ".decision" "deny" "git push origin HEAD:main must be denied"

  # 3. Active branch is main, bare git push -> deny
  local p_push_bare
  p_push_bare=$(jq -nc --arg ws "$repo" --arg cmd "git push" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_push_bare
  out_push_bare=$(printf '%s' "$p_push_bare" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_push_bare" ".decision" "deny" "Bare git push while on main must be denied"

  # 4. Active branch is main, git merge feat-x -> deny
  local p_merge_feat
  p_merge_feat=$(jq -nc --arg ws "$repo" --arg cmd "git merge feat-x" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_merge_feat
  out_merge_feat=$(printf '%s' "$p_merge_feat" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_merge_feat" ".decision" "deny" "git merge into main must be denied when remote exists"

  # 5. Active branch is main, git merge --ff-only origin/main -> allow
  local p_merge_ff
  p_merge_ff=$(jq -nc --arg ws "$repo" --arg cmd "git merge --ff-only origin/main" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_merge_ff
  out_merge_ff=$(printf '%s' "$p_merge_ff" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_merge_ff" ".decision" "allow" "git merge --ff-only must be allowed"

  # 6. On feature branch, git push origin feature-x -> allow
  git -C "$repo" checkout -b "feature-x" --quiet
  local p_push_feat
  p_push_feat=$(jq -nc --arg ws "$repo" --arg cmd "git push origin feature-x" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_push_feat
  out_push_feat=$(printf '%s' "$p_push_feat" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_push_feat" ".decision" "allow" "git push feature branch must be allowed"
}

test_hard_pr_gate_all_five_checks() {
  [ -x "$PRE_COMMAND_GUARD" ] || { echo "pre-command-guard.sh missing or not executable: $PRE_COMMAND_GUARD" >&2; return 1; }

  local repo
  repo=$(make_temp_repo)
  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: init" --quiet

  git -C "$repo" checkout -b "feature/hard-gate" --quiet

  local p_pr_create
  p_pr_create=$(jq -nc --arg ws "$repo" --arg cmd "gh pr create --fill" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')

  # Check 1: Dirty working tree -> deny
  echo "uncommitted change" > "$repo/dirty.txt"
  local out_dirty
  out_dirty=$(printf '%s' "$p_pr_create" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_dirty" ".decision" "deny" "Dirty tree must deny gh pr create"
  assert_contains "$(printf '%s' "$out_dirty" | jq -r '.reason')" "dirty" "Reason must mention dirty tree"
  rm -f "$repo/dirty.txt"

  # Check 2: Missing walkthrough or < 2 Mermaid diagrams -> deny
  echo "console.log('work');" > "$repo/src.js"
  git -C "$repo" add src.js
  git -C "$repo" commit -m "feat: add src" --quiet

  local out_no_walkthrough
  out_no_walkthrough=$(printf '%s' "$p_pr_create" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_no_walkthrough" ".decision" "deny" "Missing walkthrough must deny gh pr create"
  assert_contains "$(printf '%s' "$out_no_walkthrough" | jq -r '.reason')" "walkthrough"

  # Add walkthrough with only 1 mermaid block -> deny
  mkdir -p "$repo/docs/walkthroughs"
  cat << 'EOF' > "$repo/docs/walkthroughs/01-feature.md"
# Feature Walkthrough

```mermaid
graph TD;
  A-->B;
```
EOF
  git -C "$repo" add docs/walkthroughs/01-feature.md
  git -C "$repo" commit -m "docs: 1 mermaid" --quiet

  local out_1_mermaid
  out_1_mermaid=$(printf '%s' "$p_pr_create" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_1_mermaid" ".decision" "deny" "Walkthrough with < 2 Mermaid blocks must deny"
  assert_contains "$(printf '%s' "$out_1_mermaid" | jq -r '.reason')" "Mermaid"

  # Fix walkthrough with 2 mermaid blocks and glossary
  cat << 'EOF' >> "$repo/docs/walkthroughs/01-feature.md"

```mermaid
sequenceDiagram
  Client->>Server: Request
```

## Technical Glossary

| Term | Definition |
| :--- | :--- |
| Flow | Sequential process |
EOF
  git -C "$repo" add docs/walkthroughs/01-feature.md
  git -C "$repo" commit -m "docs: 2 mermaids" --quiet

  # Check 3: Modified technical doc missing Technical Glossary -> deny
  mkdir -p "$repo/docs/canon"
  cat << 'EOF' > "$repo/docs/canon/arch.md"
# Architecture

Some architecture description without glossary.
EOF
  git -C "$repo" add docs/canon/arch.md
  git -C "$repo" commit -m "docs: add arch without glossary" --quiet

  local out_no_glossary
  out_no_glossary=$(printf '%s' "$p_pr_create" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_no_glossary" ".decision" "deny" "Doc without glossary must deny gh pr create"
  assert_contains "$(printf '%s' "$out_no_glossary" | jq -r '.reason')" "Glossary"

  # Fix doc with Technical Glossary
  cat << 'EOF' >> "$repo/docs/canon/arch.md"

## Technical Glossary

| Term | Definition |
| :--- | :--- |
| API | Application Programming Interface |
EOF
  git -C "$repo" add docs/canon/arch.md
  git -C "$repo" commit -m "docs: fix glossary" --quiet

  # Check 4: Missing or stale stamps -> deny
  local out_no_stamps
  out_no_stamps=$(printf '%s' "$p_pr_create" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_no_stamps" ".decision" "deny" "Missing stamps must deny gh pr create"

  # Create valid stamps for current codeTreeSha
  "$STAMP_GATE" canon --verdict PASS --workspace "$repo"
  "$STAMP_GATE" security --verdict PASS --critical 0 --important 0 --workspace "$repo"

  # Check 5: Drive-by modified file outside allowedFiles -> deny
  # Add drive-by file
  mkdir -p "$repo/src"
  echo "drive by" > "$repo/src/unrelated.ts"
  git -C "$repo" add src/unrelated.ts
  git -C "$repo" commit -m "drive by edit" --quiet
  # Restamp canon with allowedFiles restricting to src.js (current sha, but unrelated.ts not in allowedFiles)
  "$STAMP_GATE" canon --verdict PASS --allow-file "src.js" --workspace "$repo"
  # Re-stamp security for current sha so stamp is fresh, but allowedFiles violation remains
  "$STAMP_GATE" security --verdict PASS --critical 0 --important 0 --workspace "$repo"

  local out_driveby
  out_driveby=$(printf '%s' "$p_pr_create" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_driveby" ".decision" "deny" "Drive-by file outside allowedFiles must deny"
  assert_contains "$(printf '%s' "$out_driveby" | jq -r '.reason')" "allowedFiles"

  # Now fix: remove drive-by file, update stamps to match HEAD
  git -C "$repo" rm -f src/unrelated.ts
  git -C "$repo" commit -m "revert drive by edit" --quiet

  "$STAMP_GATE" canon --verdict PASS --allow-file "src.js" --workspace "$repo"
  "$STAMP_GATE" security --verdict PASS --critical 0 --important 0 --workspace "$repo"

  # All 5 checks satisfied -> allow!
  local out_all_pass
  out_all_pass=$(printf '%s' "$p_pr_create" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_all_pass" ".decision" "allow" "When all 5 checks pass, gh pr create must be allowed"
}

test_post_command_sets_pr_audit_flag_and_triggers_graphify_on_merge() {
  [ -x "$POST_COMMAND_HOOKS" ] || { echo "post-command-hooks.sh missing or not executable: $POST_COMMAND_HOOKS" >&2; return 1; }

  local repo
  repo=$(make_temp_repo)
  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: init" --quiet
  git -C "$repo" checkout -b "feature/post-test" --quiet

  # 1. Successful gh pr create triggers pr-audit-pending.json
  local p_pr_create
  p_pr_create=$(jq -nc --arg ws "$repo" --arg cmd "gh pr create --fill" --arg url "https://github.com/example/repo/pull/42" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}, toolOutput: {output: $url}}')
  local out_pr_create
  out_pr_create=$(printf '%s' "$p_pr_create" | "$POST_COMMAND_HOOKS")
  assert_eq "{}" "$out_pr_create" "PostToolUse must output {} on stdout"

  local state_dir
  state_dir="$(cd "$REPO_ROOT" && ./scripts/stamp-gate.sh tree-sha --workspace "$repo" >/dev/null && source "$REPO_ROOT/scripts/hooks/common.sh" && harness_state_dir "$repo")"
  [ -f "$state_dir/pr-audit-pending.json" ] || { echo "Expected pr-audit-pending.json to be created" >&2; return 1; }
  assert_json_field "$state_dir/pr-audit-pending.json" ".stopRetries" "0"
  assert_json_field "$state_dir/pr-audit-pending.json" ".prUrl" "https://github.com/example/repo/pull/42"

  # 2. Failed gh pr create (error present) does NOT write flag
  rm -f "$state_dir/pr-audit-pending.json"
  local p_pr_err
  p_pr_err=$(jq -nc --arg ws "$repo" --arg cmd "gh pr create --fill" --arg err "GraphQL error: pull request already exists" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}, error: $err}')
  local out_pr_err
  out_pr_err=$(printf '%s' "$p_pr_err" | "$POST_COMMAND_HOOKS")
  assert_eq "{}" "$out_pr_err" "PostToolUse must output {} on error"
  [ ! -f "$state_dir/pr-audit-pending.json" ] || { echo "pr-audit-pending.json should not exist on command error" >&2; return 1; }

  # 3. Quoted command string does NOT trigger pr-audit-pending.json
  local p_commit
  p_commit=$(jq -nc --arg ws "$repo" --arg cmd 'git commit -m "gh pr create"' \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}, toolOutput: {output: "commit created"}}')
  local out_commit
  out_commit=$(printf '%s' "$p_commit" | "$POST_COMMAND_HOOKS")
  assert_eq "{}" "$out_commit" "PostToolUse must output {}"
  [ ! -f "$state_dir/pr-audit-pending.json" ] || { echo "Quoted command must not trigger pr-audit-pending.json" >&2; return 1; }

  # 4. Trigger graphify on gh pr merge
  local mock_log="$repo/.mock_graphify.log"
  local mock_graphify="$repo/mock-graphify.sh"
  cat << EOF > "$mock_graphify"
#!/usr/bin/env bash
echo "GRAPHIFY_CALLED: \$*" >> "$mock_log"
EOF
  chmod +x "$mock_graphify"

  mkdir -p "$repo/graphify-out"
  local p_merge
  p_merge=$(jq -nc --arg ws "$repo" --arg cmd "gh pr merge --auto --squash" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}, toolOutput: {output: "Merged"}}')

  local out_merge
  out_merge=$(printf '%s' "$p_merge" | HARNESS_GRAPHIFY_BIN="$mock_graphify" "$POST_COMMAND_HOOKS")
  assert_eq "{}" "$out_merge" "PostToolUse must output {}"
  [ -f "$mock_log" ] || { echo "Expected mock graphify to have been called" >&2; return 1; }
  local log_content
  log_content=$(cat "$mock_log")
  assert_contains "$log_content" "--update --no-viz" "Graphify must be invoked with --update --no-viz"
  [ -f "$repo/.harness/logs/graphify-hook.log" ] || { echo "Expected graphify-hook.log to exist" >&2; return 1; }

  # 5. Respect .harness-ignore
  touch "$repo/.harness-ignore"
  rm -f "$mock_log"
  local out_ignored
  out_ignored=$(printf '%s' "$p_merge" | HARNESS_GRAPHIFY_BIN="$mock_graphify" "$POST_COMMAND_HOOKS")
  assert_eq "{}" "$out_ignored"
  [ ! -f "$mock_log" ] || { echo "Ignored workspace must not invoke graphify" >&2; return 1; }
}

run_tests
