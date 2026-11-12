#!/usr/bin/env bash
# Alps AGY Harness - Shared Hook Library (common.sh) & Stamp Gate CLI Tests
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-helpers.sh"

COMMON_SH="$REPO_ROOT/scripts/hooks/common.sh"
STAMP_GATE="$REPO_ROOT/scripts/stamp-gate.sh"

test_branch_slug_slashes_and_detached_head() {
  [ -x "$COMMON_SH" ] || { echo "common.sh missing or not executable: $COMMON_SH" >&2; return 1; }
  # shellcheck source=/dev/null
  source "$COMMON_SH"

  local repo
  repo=$(make_temp_repo)

  # Unborn main branch still resolves symbolic branch name and slug
  assert_eq "main" "$(harness_branch_name "$repo")" "Unborn repo on main should return main"
  assert_eq "main" "$(harness_branch_slug "$repo")" "Unborn repo on main should have slug main"

  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: init" --quiet

  git -C "$repo" checkout -b "feature/auth/jwt-refresh" --quiet
  assert_eq "feature/auth/jwt-refresh" "$(harness_branch_name "$repo")" "Nested slash branch name"
  assert_eq "feature-auth-jwt-refresh" "$(harness_branch_slug "$repo")" "Nested slash branch slug"

  git -C "$repo" checkout -b "feat/v1.2_user--scope" --quiet
  assert_eq "feat-v1-2-user-scope" "$(harness_branch_slug "$repo")" "Non-alphanumeric chars collapse to single hyphen"

  git -C "$repo" checkout --detach --quiet
  local expected_short_sha
  expected_short_sha=$(git -C "$repo" rev-parse --short=7 HEAD)
  assert_eq "HEAD" "$(harness_branch_name "$repo")" "Detached HEAD should return HEAD"
  assert_eq "detached-$expected_short_sha" "$(harness_branch_slug "$repo")" "Detached slug must be detached-<7char>"
  if [[ ! "$(harness_branch_slug "$repo")" =~ ^detached-[0-9a-f]{7}$ ]]; then
    echo "Detached slug did not match ^detached-[0-9a-f]{7}$: $(harness_branch_slug "$repo")" >&2
    return 1
  fi
}

test_code_tree_sha_ignores_walkthrough_and_parking_lot_but_changes_on_src_and_lessons() {
  [ -x "$COMMON_SH" ] || { echo "common.sh missing or not executable" >&2; return 1; }
  [ -x "$STAMP_GATE" ] || { echo "stamp-gate.sh missing or not executable" >&2; return 1; }
  # shellcheck source=/dev/null
  source "$COMMON_SH"

  local repo
  repo=$(make_temp_repo)

  # Unborn repo returns UNBORN and verify-pr-stamps fails
  assert_eq "UNBORN" "$(harness_code_tree_sha "$repo")" "Unborn repo must return UNBORN"
  assert_eq "UNBORN" "$("$STAMP_GATE" tree-sha --workspace "$repo")" "tree-sha CLI on unborn repo must return UNBORN"
  if "$STAMP_GATE" verify-pr-stamps --workspace "$repo" >/dev/null 2>&1; then
    echo "verify-pr-stamps must fail on UNBORN repo" >&2
    return 1
  fi

  # Edge case: repo containing ONLY docs/parking-lot.md must not fail under pipefail
  mkdir -p "$repo/docs"
  echo "# Parking Lot" > "$repo/docs/parking-lot.md"
  git -C "$repo" add docs/parking-lot.md
  git -C "$repo" commit -m "docs: initial parking lot" --quiet
  local empty_filtered_sha
  empty_filtered_sha=$("$STAMP_GATE" tree-sha --workspace "$repo")
  if [[ ! "$empty_filtered_sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Expected valid 40-char SHA when only parking-lot exists, got: $empty_filtered_sha" >&2
    return 1
  fi

  # Commit src/app.ts -> tree-sha changes
  mkdir -p "$repo/src"
  echo "export const x = 1;" > "$repo/src/app.ts"
  git -C "$repo" add src/app.ts
  git -C "$repo" commit -m "feat: add app" --quiet
  local sha_initial
  sha_initial=$("$STAMP_GATE" tree-sha --workspace "$repo")
  if [ "$sha_initial" = "$empty_filtered_sha" ]; then
    echo "tree-sha should change after adding src/app.ts" >&2
    return 1
  fi

  # Stamp canon and security PASS
  "$STAMP_GATE" canon --verdict PASS --plan "docs/plans/plan.md" --allow-file "src/app.ts" --workspace "$repo"
  "$STAMP_GATE" security --verdict PASS --critical 0 --important 0 --workspace "$repo"
  "$STAMP_GATE" verify-pr-stamps --workspace "$repo"

  # Commit walkthrough -> tree-sha stays identical and verify-pr-stamps stays valid
  mkdir -p "$repo/docs/walkthroughs"
  echo "# Walkthrough" > "$repo/docs/walkthroughs/2026-11-12-demo.md"
  git -C "$repo" add docs/walkthroughs/2026-11-12-demo.md
  git -C "$repo" commit -m "docs: add walkthrough" --quiet
  assert_eq "$sha_initial" "$("$STAMP_GATE" tree-sha --workspace "$repo")" "Walkthrough commit must not alter tree-sha"
  "$STAMP_GATE" verify-pr-stamps --workspace "$repo"

  # Update parking-lot -> tree-sha stays identical and verify-pr-stamps stays valid
  echo "- Deferred item" >> "$repo/docs/parking-lot.md"
  git -C "$repo" add docs/parking-lot.md
  git -C "$repo" commit -m "docs: update parking lot" --quiet
  assert_eq "$sha_initial" "$("$STAMP_GATE" tree-sha --workspace "$repo")" "parking-lot.md commit must not alter tree-sha"
  "$STAMP_GATE" verify-pr-stamps --workspace "$repo"

  # Modify src/app.ts -> tree-sha changes and verify-pr-stamps fails
  echo "export const x = 2;" > "$repo/src/app.ts"
  git -C "$repo" add src/app.ts
  git -C "$repo" commit -m "feat: update app" --quiet
  local sha_after_src
  sha_after_src=$("$STAMP_GATE" tree-sha --workspace "$repo")
  if [ "$sha_after_src" = "$sha_initial" ]; then
    echo "src/app.ts change must alter tree-sha" >&2
    return 1
  fi
  local err_out
  if err_out=$("$STAMP_GATE" verify-pr-stamps --workspace "$repo" 2>&1); then
    echo "verify-pr-stamps must fail when src/app.ts changed after stamps" >&2
    return 1
  fi
  assert_contains "$err_out" "codeTreeSha" "Failure stderr should mention stale codeTreeSha"

  # Re-stamp, then modify docs/canon/lessons.md -> tree-sha changes and verify-pr-stamps fails
  "$STAMP_GATE" canon --verdict PASS --workspace "$repo"
  "$STAMP_GATE" security --verdict PASS --critical 0 --important 0 --workspace "$repo"
  "$STAMP_GATE" verify-pr-stamps --workspace "$repo"

  mkdir -p "$repo/docs/canon"
  echo "## Lesson 1" > "$repo/docs/canon/lessons.md"
  git -C "$repo" add docs/canon/lessons.md
  git -C "$repo" commit -m "docs(canon): add lesson" --quiet
  local sha_after_lessons
  sha_after_lessons=$("$STAMP_GATE" tree-sha --workspace "$repo")
  if [ "$sha_after_lessons" = "$sha_after_src" ]; then
    echo "docs/canon/lessons.md change must alter tree-sha" >&2
    return 1
  fi
  if "$STAMP_GATE" verify-pr-stamps --workspace "$repo" >/dev/null 2>&1; then
    echo "verify-pr-stamps must fail when docs/canon/lessons.md changed after stamps" >&2
    return 1
  fi
}

test_security_stamp_rejects_pass_when_important_nonzero() {
  [ -x "$COMMON_SH" ] || { echo "common.sh missing or not executable" >&2; return 1; }
  [ -x "$STAMP_GATE" ] || { echo "stamp-gate.sh missing or not executable" >&2; return 1; }
  # shellcheck source=/dev/null
  source "$COMMON_SH"

  local repo
  repo=$(make_temp_repo)
  echo "a" > "$repo/a.txt"
  git -C "$repo" add a.txt
  git -C "$repo" commit -m "init" --quiet

  local state_dir
  state_dir=$(harness_state_dir "$repo")

  # Rejects PASS when important > 0
  local err_msg
  if err_msg=$("$STAMP_GATE" security --verdict PASS --critical 0 --important 1 --workspace "$repo" 2>&1); then
    echo "security PASS with important=1 must fail" >&2
    return 1
  fi
  [ -n "$err_msg" ] || { echo "Expected error message on stderr" >&2; return 1; }
  if [ -f "$state_dir/security-pass.json" ]; then
    echo "security-pass.json must not be created when PASS is rejected" >&2
    return 1
  fi

  # Rejects PASS when critical > 0
  if "$STAMP_GATE" security --verdict PASS --critical 2 --important 0 --workspace "$repo" >/dev/null 2>&1; then
    echo "security PASS with critical=2 must fail" >&2
    return 1
  fi

  # Allows FAIL with non-zero counts and stores numeric counts
  "$STAMP_GATE" security --verdict FAIL --critical 1 --important 3 --workspace "$repo"
  assert_json_field "$state_dir/security-pass.json" ".verdict" "FAIL"
  assert_json_field "$state_dir/security-pass.json" ".criticalCount" "1"
  assert_json_field "$state_dir/security-pass.json" ".importantCount" "3"
  jq -e '(.criticalCount | type == "number") and (.importantCount | type == "number")' "$state_dir/security-pass.json" >/dev/null
}

test_dispatch_tier_mapping() {
  [ -x "$COMMON_SH" ] || { echo "common.sh missing or not executable" >&2; return 1; }
  [ -x "$STAMP_GATE" ] || { echo "stamp-gate.sh missing or not executable" >&2; return 1; }
  # shellcheck source=/dev/null
  source "$COMMON_SH"

  local repo
  repo=$(make_temp_repo)
  local state_dir
  state_dir=$(harness_state_dir "$repo")

  "$STAMP_GATE" dispatch --role "Log Finder" --type "research" --tier "trivial_lookup" --workspace "$repo"
  "$STAMP_GATE" dispatch --role "Unit Implementer" --type "self" --tier "bounded_execution" --workspace "$repo"
  "$STAMP_GATE" dispatch --role "Auth Integrator" --type "self" --tier "multi_module_integration" --workspace "$repo"
  "$STAMP_GATE" dispatch --role "Security Auditor" --type "research" --tier "critical_architecture_or_audit" --workspace "$repo"

  local dispatch_file="$state_dir/subagent-dispatch.json"
  [ -f "$dispatch_file" ] || { echo "subagent-dispatch.json not created" >&2; return 1; }

  jq -e '
    .entries["Log Finder"].model == "flash_lite" and
    .entries["Log Finder"].effortProfile == "LOW" and
    .entries["Log Finder"].typeName == "research" and
    .entries["Log Finder"].tier == "trivial_lookup" and
    .entries["Log Finder"].consumed == false and

    .entries["Unit Implementer"].model == "flash" and
    .entries["Unit Implementer"].effortProfile == "MEDIUM" and
    .entries["Unit Implementer"].consumed == false and

    .entries["Auth Integrator"].model == "inherit" and
    .entries["Auth Integrator"].effortProfile == "HIGH" and
    .entries["Auth Integrator"].consumed == false and

    .entries["Security Auditor"].model == "pro" and
    .entries["Security Auditor"].effortProfile == "MAX" and
    .entries["Security Auditor"].consumed == false
  ' "$dispatch_file" >/dev/null

  # Invalid tier must fail
  if "$STAMP_GATE" dispatch --role "Bad" --type "self" --tier "unknown_tier" --workspace "$repo" >/dev/null 2>&1; then
    echo "dispatch with invalid tier must fail" >&2
    return 1
  fi
}

test_harness_ignore_detection() {
  [ -x "$COMMON_SH" ] || { echo "common.sh missing or not executable" >&2; return 1; }
  # shellcheck source=/dev/null
  source "$COMMON_SH"

  local repo
  repo=$(make_temp_repo)

  if harness_is_ignored "$repo"; then
    echo "Repo without .harness-ignore should not be ignored" >&2
    return 1
  fi

  : > "$repo/.harness-ignore"
  if ! harness_is_ignored "$repo"; then
    echo "Repo with .harness-ignore must return 0 from harness_is_ignored" >&2
    return 1
  fi
}

test_harness_read_stdin_and_workspace_resolution() {
  [ -x "$COMMON_SH" ] || { echo "common.sh missing or not executable" >&2; return 1; }

  local repo
  repo=$(make_temp_repo)

  local out
  out=$(printf '{"workspacePaths":["%s","/other"],"toolName":"write_file"}' "$repo" | bash -c '
    source "'"$COMMON_SH"'"
    harness_read_stdin
    printf "WS=%s\nTOOL=%s\n" "$WORKSPACE_ROOT" "$(printf "%s" "$HOOK_INPUT" | jq -r .toolName)"
  ')
  assert_contains "$out" "WS=$repo" "WORKSPACE_ROOT must resolve from .workspacePaths[0]"
  assert_contains "$out" "TOOL=write_file" "HOOK_INPUT must preserve stdin JSON"

  local fallback_out expected_pwd
  expected_pwd=$(cd "$repo" && pwd)
  fallback_out=$(cd "$repo" && bash -c '
    source "'"$COMMON_SH"'"
    harness_read_stdin < /dev/null
    printf "WS=%s\nJSON=%s\n" "$WORKSPACE_ROOT" "$HOOK_INPUT"
  ')
  assert_contains "$fallback_out" "WS=$expected_pwd" "Empty stdin must fall back WORKSPACE_ROOT to PWD"
  assert_contains "$fallback_out" "JSON={}" "Empty stdin must default HOOK_INPUT to {}"
}

test_harness_state_dir_and_worktree_exclude() {
  [ -x "$COMMON_SH" ] || { echo "common.sh missing or not executable" >&2; return 1; }
  # shellcheck source=/dev/null
  source "$COMMON_SH"

  local repo
  repo=$(make_temp_repo)
  echo "hello" > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -m "init" --quiet

  # Call from outside $repo to verify relative --git-path resolution works
  local sdir1 sdir2
  sdir1=$(cd /tmp && harness_state_dir "$repo")
  sdir2=$(cd /tmp && harness_state_dir "$repo")
  assert_eq "$repo/.harness/state/main" "$sdir1" "State dir path for main"
  assert_eq "$sdir1" "$sdir2" "Idempotent state dir path"
  [ -d "$sdir1" ] || { echo "State dir must exist" >&2; return 1; }

  local exclude_count
  exclude_count=$(grep -Fxc ".harness/" "$repo/.git/info/exclude")
  assert_eq "1" "$exclude_count" ".harness/ must be added idempotently once to info/exclude"

  # Linked git worktree test (where .git is a file, not a directory)
  local wt_dir="${repo}-wt"
  echo "$wt_dir" >> "$_HARNESS_TEMP_TRACKER"
  git -C "$repo" worktree add -b "feat/wt-test" "$wt_dir" --quiet
  [ -f "$wt_dir/.git" ] || { echo "Expected linked worktree .git to be a file" >&2; return 1; }

  local wt_sdir
  wt_sdir=$(cd /tmp && harness_state_dir "$wt_dir")
  assert_eq "$wt_dir/.harness/state/feat-wt-test" "$wt_sdir" "Linked worktree state dir"
  [ -d "$wt_sdir" ] || { echo "Linked worktree state dir must be created" >&2; return 1; }
}

test_glossary_section_validation() {
  [ -x "$COMMON_SH" ] || { echo "common.sh missing or not executable" >&2; return 1; }
  # shellcheck source=/dev/null
  source "$COMMON_SH"

  # Valid Turkish numbered bullet glossary
  local valid_tr
  valid_tr="$(cat <<'EOF'
# Mimari Belge

## 1. Özet
Detaylar burada.

```markdown
## Sahte Başlık Kod Bloğu İçinde
```

## 2. Teknik Terimler Sözlüğü
- **Damga Kapısı**: Deterministik durum doğrulayıcısı.
EOF
)"
  harness_has_glossary_section "$valid_tr"

  # Valid English table glossary
  local valid_en_table
  valid_en_table="$(cat <<'EOF'
# Plan

## Overview
Text.

## Technical Glossary
| Term | Definition |
| :--- | :--- |
| **Tree SHA** | Filtered git tree hash |
EOF
)"
  harness_has_glossary_section "$valid_en_table"

  # Invalid: Glossary is NOT the last ## heading
  local not_last
  not_last="$(cat <<'EOF'
## Teknik Terimler Sözlüğü
- **Terim**: Açıklama

## Ek Notlar
Burada başka bir bölüm var.
EOF
)"
  if harness_has_glossary_section "$not_last"; then
    echo "Glossary must be rejected when followed by another ## heading" >&2
    return 1
  fi

  # Invalid: Empty table (header + separator only, no data rows)
  local empty_table
  empty_table="$(cat <<'EOF'
## Teknik Terimler Sözlüğü
| Terim | Açıklama |
| --- | --- |
EOF
)"
  if harness_has_glossary_section "$empty_table"; then
    echo "Header+separator-only empty table must be rejected" >&2
    return 1
  fi

  # Invalid: Empty heading or fake bullet only inside fenced code block
  local fenced_fake
  fenced_fake="$(cat <<'EOF'
## Teknik Terimler Sözlüğü
```markdown
- **Sahte**: Kod bloğu içinde madde
```
EOF
)"
  if harness_has_glossary_section "$fenced_fake"; then
    echo "Bullets inside fenced code blocks must not satisfy glossary check" >&2
    return 1
  fi
}

test_pre_tool_use_json_emitters() {
  [ -x "$COMMON_SH" ] || { echo "common.sh missing or not executable" >&2; return 1; }
  # shellcheck source=/dev/null
  source "$COMMON_SH"

  assert_json_field "$(emit_allow)" ".decision" "allow"

  local deny_json
  deny_json=$(emit_deny 'Line 1 "quoted"'$'\n''Line 2')
  assert_json_field "$deny_json" ".decision" "deny"
  assert_contains "$(printf '%s' "$deny_json" | jq -r '.reason')" 'Line 1 "quoted"'

  local ask_json
  ask_json=$(emit_force_ask "Confirm push")
  assert_json_field "$ask_json" ".decision" "force_ask"
  assert_json_field "$ask_json" ".reason" "Confirm push"

  local ow_no_reason ow_with_reason
  ow_no_reason=$(emit_overwrite '{"Model":"flash"}')
  assert_json_field "$ow_no_reason" ".decision" "allow"
  assert_json_field "$ow_no_reason" ".overwrite.Model" "flash"
  jq -e 'has("reason") | not' <<<"$ow_no_reason" >/dev/null

  ow_with_reason=$(emit_overwrite '{"Model":"pro"}' "Escalated tier")
  assert_json_field "$ow_with_reason" ".decision" "allow"
  assert_json_field "$ow_with_reason" ".overwrite.Model" "pro"
  assert_json_field "$ow_with_reason" ".reason" "Escalated tier"
}

test_context7_merge_and_workspace_flag_positions_and_clear_pr_audit() {
  [ -x "$COMMON_SH" ] || { echo "common.sh missing or not executable" >&2; return 1; }
  [ -x "$STAMP_GATE" ] || { echo "stamp-gate.sh missing or not executable" >&2; return 1; }
  # shellcheck source=/dev/null
  source "$COMMON_SH"

  local repo
  repo=$(make_temp_repo)
  echo "v1" > "$repo/index.ts"
  git -C "$repo" add index.ts
  git -C "$repo" commit -m "init" --quiet

  local state_dir
  state_dir=$(harness_state_dir "$repo")

  # --workspace before subcommand, in middle of flags, and at end
  "$STAMP_GATE" --workspace "$repo" context7 --package "zod" --version "3.23.8" --source "locked"
  "$STAMP_GATE" context7 --package "hono" --workspace "$repo" --version "4.6.0" --source "greenfield-latest"

  jq -e '
    .packages["zod"].version == "3.23.8" and
    .packages["zod"].source == "locked" and
    .packages["hono"].version == "4.6.0" and
    .packages["hono"].source == "greenfield-latest"
  ' "$state_dir/context7-verified.json" >/dev/null

  # Invalid context7 source fails
  if "$STAMP_GATE" context7 --package "x" --version "1.0.0" --source "guessed" --workspace "$repo" >/dev/null 2>&1; then
    echo "context7 must reject invalid --source" >&2
    return 1
  fi

  # Canon multiple --allow-file values and leading ./ normalization
  "$STAMP_GATE" --workspace "$repo" canon --allow-file "src/a.ts" --verdict PASS --allow-file "src/b.ts" --allow-file "./src/foo.ts" --plan "docs/plans/p.md"
  jq -e '
    .verdict == "PASS" and
    .planPath == "docs/plans/p.md" and
    .allowedFiles == ["src/a.ts", "src/b.ts", "src/foo.ts"]
  ' "$state_dir/canon-pass.json" >/dev/null

  # clear-pr-audit removes pr-audit-pending.json
  echo '{"pending":true}' > "$state_dir/pr-audit-pending.json"
  [ -f "$state_dir/pr-audit-pending.json" ]
  "$STAMP_GATE" --workspace "$repo" clear-pr-audit
  if [ -f "$state_dir/pr-audit-pending.json" ]; then
    echo "clear-pr-audit must remove pr-audit-pending.json" >&2
    return 1
  fi
  # Idempotent when file does not exist
  "$STAMP_GATE" clear-pr-audit --workspace "$repo"

  # Ensure no leftover atomic temp files remain in state_dir
  local leftover_tmps
  leftover_tmps=$(find "$state_dir" -name '.*.tmp.*' | wc -l | tr -d ' ')
  assert_eq "0" "$leftover_tmps" "Atomic JSON writes must leave zero temp files"
}

test_verify_pr_stamps_missing_and_fail_verdicts() {
  [ -x "$STAMP_GATE" ] || { echo "stamp-gate.sh missing or not executable" >&2; return 1; }

  local repo
  repo=$(make_temp_repo)
  echo "code" > "$repo/main.ts"
  git -C "$repo" add main.ts
  git -C "$repo" commit -m "init" --quiet

  # Missing both stamps -> fail
  if "$STAMP_GATE" verify-pr-stamps --workspace "$repo" >/dev/null 2>&1; then
    echo "verify-pr-stamps must fail when stamps are missing" >&2
    return 1
  fi

  # Only canon PASS -> still missing security -> fail
  "$STAMP_GATE" canon --verdict PASS --workspace "$repo"
  if "$STAMP_GATE" verify-pr-stamps --workspace "$repo" >/dev/null 2>&1; then
    echo "verify-pr-stamps must fail when security-pass.json is missing" >&2
    return 1
  fi

  # Security FAIL -> fail
  "$STAMP_GATE" security --verdict FAIL --critical 0 --important 1 --workspace "$repo"
  if "$STAMP_GATE" verify-pr-stamps --workspace "$repo" >/dev/null 2>&1; then
    echo "verify-pr-stamps must fail when security verdict is FAIL" >&2
    return 1
  fi

  # Security PASS, Canon FAIL -> fail
  "$STAMP_GATE" security --verdict PASS --critical 0 --important 0 --workspace "$repo"
  "$STAMP_GATE" canon --verdict FAIL --workspace "$repo"
  if "$STAMP_GATE" verify-pr-stamps --workspace "$repo" >/dev/null 2>&1; then
    echo "verify-pr-stamps must fail when canon verdict is FAIL" >&2
    return 1
  fi

  # Both PASS -> pass
  "$STAMP_GATE" canon --verdict PASS --workspace "$repo"
  "$STAMP_GATE" verify-pr-stamps --workspace "$repo"
}

run_tests "$@"
