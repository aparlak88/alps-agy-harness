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

  # Leading-hyphen conversationId passes safely through to python argparse
  "$STAMP_GATE" dispatch --role "Dash Conv" --type "self" --tier "bounded_execution" --conversation-id "-conv-dash" --workspace "$repo"
  assert_json_field "$dispatch_file" '.entries["Dash Conv"].conversationId' "-conv-dash" "Leading-hyphen conversationId must be preserved"

  # Invalid tier must fail
  if "$STAMP_GATE" dispatch --role "Bad" --type "self" --tier "unknown_tier" --workspace "$repo" >/dev/null 2>&1; then
    echo "dispatch with invalid tier must fail" >&2
    return 1
  fi
}

test_gemini4_and_orchestrator_parent_model_classification_and_selector() {
  [ -x "$COMMON_SH" ] || { echo "common.sh missing or not executable" >&2; return 1; }
  [ -x "$STAMP_GATE" ] || { echo "stamp-gate.sh missing or not executable" >&2; return 1; }
  # shellcheck source=/dev/null
  source "$COMMON_SH"

  assert_eq "unset" "$(harness_classify_parent_model "")" "Empty modelName -> unset"
  assert_eq "carbon" "$(harness_classify_parent_model "gemini-4-carbon-high")" "Carbon slug -> carbon"
  assert_eq "carbon" "$(harness_classify_parent_model "Gemini 4 Carbon (Medium)")" "Carbon display -> carbon"
  assert_eq "orchestrator" "$(harness_classify_parent_model "gemini-pro-orchestrator")" "Orchestrator slug -> orchestrator"
  assert_eq "orchestrator" "$(harness_classify_parent_model "Orchestrator")" "Orchestrator display -> orchestrator"
  assert_eq "orchestrator" "$(harness_classify_parent_model "auto")" "auto -> orchestrator"
  assert_eq "orchestrator_neon" "$(harness_classify_parent_model "gemini-pro-orchestrator-neon")" "Orchestrator Neon slug -> orchestrator_neon"
  assert_eq "orchestrator_neon" "$(harness_classify_parent_model "Orchestrator (Neon)")" "Orchestrator Neon display -> orchestrator_neon"
  assert_eq "orchestrator_carbon" "$(harness_classify_parent_model "Orchestrator (Carbon)")" "Orchestrator Carbon display -> orchestrator_carbon"
  assert_eq "orchestrator_argon" "$(harness_classify_parent_model "Orchestrator (Argon)")" "Orchestrator Argon display -> orchestrator_argon"
  assert_eq "argon" "$(harness_classify_parent_model "gemini-4-argon-high")" "Argon High -> argon"
  assert_eq "argon" "$(harness_classify_parent_model "Gemini 4 Argon (Medium)")" "Argon Medium -> argon"
  assert_eq "frontier_low" "$(harness_classify_parent_model "gemini-4-argon-low")" "Argon Low slug -> frontier_low"
  assert_eq "frontier_low" "$(harness_classify_parent_model "Gemini 4 Argon (Low)")" "Argon Low display -> frontier_low"
  assert_eq "hydrogen" "$(harness_classify_parent_model "gemini-4-hydrogen-xhigh")" "Hydrogen XHigh -> hydrogen"
  assert_eq "claude_opus" "$(harness_classify_parent_model "claude-opus-5-5-high")" "Claude Opus -> claude_opus"
  assert_eq "claude_sonnet" "$(harness_classify_parent_model "Claude Sonnet 5.5")" "Claude Sonnet -> claude_sonnet"
  assert_eq "flash" "$(harness_classify_parent_model "gemini-3.8-flash-low")" "Gemini 3.8 Flash -> flash"
  assert_eq "flash" "$(harness_classify_parent_model "gpt-oss-120b-medium")" "GPT-OSS -> flash"
  assert_eq "custom" "$(harness_classify_parent_model "enterprise-tuned-v1")" "Unknown non-empty -> custom"

  assert_eq "XHIGH" "$(harness_detect_parent_effort_hint "Gemini 4 Neon (Extra)")" "Extra effort label -> XHIGH"
  assert_eq "XHIGH" "$(harness_detect_parent_effort_hint "gemini-4-hydrogen-xhigh")" "xhigh effort slug -> XHIGH"
  assert_eq "LOW" "$(harness_detect_parent_effort_hint "Gemini 4 Carbon (Low)")" "Low effort label -> LOW"
  assert_eq "HIGH" "$(harness_detect_parent_effort_hint "gemini-4-neon-high")" "High effort label -> HIGH"
  assert_eq "" "$(harness_detect_parent_effort_hint "gemini-4-pro")" "Unmarked model -> empty effort hint"

  harness_is_deprecated_model "gemini-4-argon-high" || { echo "Argon should be deprecated" >&2; return 1; }
  harness_is_deprecated_model "Orchestrator (Argon)" || { echo "Orchestrator (Argon) should be deprecated" >&2; return 1; }
  harness_is_deprecated_model "Claude Sonnet 4.6" || { echo "Claude 4.6 should be deprecated" >&2; return 1; }
  if harness_is_deprecated_model "Gemini 4 Neon (High)"; then echo "Neon should not be deprecated" >&2; return 1; fi
  if harness_is_deprecated_model "Orchestrator (Neon)"; then echo "Orchestrator (Neon) should not be deprecated" >&2; return 1; fi

  local repo state_dir
  repo=$(make_temp_repo)
  state_dir=$(harness_state_dir "$repo")

  # Verify select-model CLI subcommand across Carbon, Orchestrator, Hydrogen, Argon, Neon Extra, Claude, and Flash
  local sel_carbon_bounded sel_carbon_crit sel_carbon_multi_default sel_carbon_multi_inherit sel_orch_bounded sel_orch_crit sel_hyd_bounded sel_hyd_crit sel_flash_multi sel_neon_extra
  sel_carbon_bounded=$("$STAMP_GATE" select-model --tier "bounded_execution" --parent-model "gemini-4-carbon-high" --workspace "$repo")
  assert_json_field "$sel_carbon_bounded" ".model" "pro" "Carbon bounded_execution steps down to pro"
  assert_json_field "$sel_carbon_bounded" ".parentFamily" "carbon" "Carbon family reported"
  assert_json_field "$sel_carbon_bounded" ".deprecated" "false" "Carbon is not deprecated"

  sel_carbon_crit=$("$STAMP_GATE" select-model --tier "critical_architecture_or_audit" --parent-model "gemini-4-carbon-high" --workspace "$repo")
  assert_json_field "$sel_carbon_crit" ".model" "inherit" "Carbon critical audit stays on inherit (Carbon)"

  sel_carbon_multi_default=$("$STAMP_GATE" select-model --tier "multi_module_integration" --parent-model "gemini-4-carbon-medium" --workspace "$repo")
  assert_json_field "$sel_carbon_multi_default" ".model" "pro" "Carbon multi_module defaults to pro"

  sel_carbon_multi_inherit=$("$STAMP_GATE" select-model --tier "multi_module_integration" --parent-model "gemini-4-carbon-medium" --caller-model "inherit" --workspace "$repo")
  assert_json_field "$sel_carbon_multi_inherit" ".model" "inherit" "Carbon multi_module preserves explicit inherit"

  sel_orch_bounded=$("$STAMP_GATE" select-model --tier "bounded_execution" --parent-model "gemini-pro-orchestrator-neon" --workspace "$repo")
  assert_json_field "$sel_orch_bounded" ".parentFamily" "orchestrator_neon" "Orchestrator Neon family reported"
  assert_json_field "$sel_orch_bounded" ".model" "inherit" "Orchestrator bounded_execution uses inherit (-> Hydrogen)"

  sel_orch_crit=$("$STAMP_GATE" select-model --tier "critical_architecture_or_audit" --parent-model "Orchestrator (Neon)" --workspace "$repo")
  assert_json_field "$sel_orch_crit" ".model" "pro" "Orchestrator critical audit escalates to pro"

  sel_neon_extra=$("$STAMP_GATE" select-model --tier "critical_architecture_or_audit" --parent-model "Gemini 4 Neon (Extra)" --workspace "$repo")
  assert_json_field "$sel_neon_extra" ".parentEffortHint" "XHIGH" "Extra effort label emits XHIGH parentEffortHint"

  sel_hyd_bounded=$("$STAMP_GATE" select-model --tier "bounded_execution" --parent-model "gemini-4-hydrogen-xhigh" --effort "XHIGH" --workspace "$repo")
  assert_json_field "$sel_hyd_bounded" ".model" "inherit" "Hydrogen bounded_execution keeps inherit (Hydrogen)"
  assert_json_field "$sel_hyd_bounded" ".effortProfile" "XHIGH" "select-model supports explicit XHIGH effort"

  sel_hyd_crit=$("$STAMP_GATE" select-model --tier "critical_architecture_or_audit" --parent-model "gemini-4-hydrogen-xhigh" --workspace "$repo")
  assert_json_field "$sel_hyd_crit" ".model" "pro" "Hydrogen critical audit escalates to pro"

  sel_flash_multi=$("$STAMP_GATE" select-model --tier "multi_module_integration" --parent-model "gemini-3.8-flash-low" --workspace "$repo")
  assert_json_field "$sel_flash_multi" ".model" "pro" "Flash multi_module escalates to pro"
  assert_json_field "$sel_flash_multi" ".deprecated" "true" "Gemini 3.8 Flash reports deprecated: true"

  # Verify dispatch with --parent-model and --effort XHIGH
  "$STAMP_GATE" dispatch --role "Hydrogen Worker" --type "self" --tier "bounded_execution" --parent-model "gemini-4-hydrogen-xhigh" --effort "XHIGH" --workspace "$repo"
  assert_json_field "$state_dir/subagent-dispatch.json" '.entries["Hydrogen Worker"].model' "inherit" "Dispatch with Hydrogen parent stores inherit"
  assert_json_field "$state_dir/subagent-dispatch.json" '.entries["Hydrogen Worker"].effortProfile' "XHIGH" "Dispatch stores XHIGH effortProfile"
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

test_harness_read_stdin_whitespace_and_large_utf8_on_bin_bash() {
  [ -x "$COMMON_SH" ] || { echo "common.sh missing or not executable" >&2; return 1; }

  local repo
  repo=$(make_temp_repo)

  python3 -B - "$COMMON_SH" "$repo" <<'PY'
import json
import subprocess
import sys
import time

common_sh, repo = sys.argv[1], sys.argv[2]

# 1. >= 120 KB whitespace-only payload on /bin/bash -> HOOK_INPUT == "{}" in < 2s
ws_only = ("   \t \n\r  " * 16000)
assert len(ws_only.encode("utf-8")) >= 120 * 1024
t0 = time.monotonic()
p1 = subprocess.run(
    ["/bin/bash", "-c", 'source "$1"; harness_read_stdin; printf "%s" "$HOOK_INPUT"', "_", common_sh],
    input=ws_only,
    text=True,
    capture_output=True,
    timeout=5,
)
dt1 = time.monotonic() - t0
assert p1.returncode == 0, p1.stderr
assert dt1 < 2.0, f"whitespace harness_read_stdin too slow: {dt1:.3f}s"
assert p1.stdout == "{}", f"Expected '{{}}', got {p1.stdout!r}"

# 2. >= 120 KB UTF-8 + multiline JSON payload on /bin/bash -> < 2s
big_utf8 = ("Türkçe ğüşıöçĞÜŞİÖÇ 🚀 çok satırlı JSON   \n\t " * 2400)
payload = json.dumps({"workspacePaths": [repo], "Content": big_utf8}, ensure_ascii=False)
assert len(payload.encode("utf-8")) >= 120 * 1024
t1 = time.monotonic()
p2 = subprocess.run(
    ["/bin/bash", "-c", 'source "$1"; harness_read_stdin; printf "%s\\n%s" "$WORKSPACE_ROOT" "${#HOOK_INPUT}"', "_", common_sh],
    input=payload,
    text=True,
    capture_output=True,
    timeout=5,
)
dt2 = time.monotonic() - t1
assert p2.returncode == 0, p2.stderr
assert dt2 < 2.0, f"UTF-8 harness_read_stdin too slow: {dt2:.3f}s"
lines = p2.stdout.splitlines()
assert lines[0] == repo, lines
assert int(lines[1]) == len(payload), (lines[1], len(payload))
PY
}

test_detached_head_linked_worktree_stable_slug_across_commits() {
  [ -x "$COMMON_SH" ] || { echo "common.sh missing or not executable" >&2; return 1; }
  [ -x "$STAMP_GATE" ] || { echo "stamp-gate.sh missing or not executable" >&2; return 1; }
  # shellcheck source=/dev/null
  source "$COMMON_SH"

  local py_slug_cmd='import sys; from pathlib import Path; sys.path.insert(0, sys.argv[1]); import harness_core; print(harness_core.get_branch_slug(Path(sys.argv[2])))'

  local repo
  repo=$(make_temp_repo)
  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: init" --quiet

  # 1. Main repo detached HEAD must preserve detached-<7sha> (including via /tmp symlink)
  git -C "$repo" checkout --detach --quiet
  local main_sha main_slug_sh main_slug_py
  main_sha=$(git -C "$repo" rev-parse --short=7 HEAD)
  main_slug_sh=$(harness_branch_slug "$repo")
  main_slug_py=$(python3 -B -c "$py_slug_cmd" "$REPO_ROOT/scripts/lib" "$repo")
  assert_eq "detached-$main_sha" "$main_slug_sh" "Main repo detached HEAD must stay detached-<7sha> in common.sh"
  assert_eq "$main_slug_sh" "$main_slug_py" "Main repo detached HEAD parity between common.sh and harness_core.py"

  local sym_root
  sym_root=$(mktemp -d "/tmp/harness-wt-sym.XXXXXX")
  echo "$sym_root" >> "$_HARNESS_TEMP_TRACKER"
  ln -s "$repo" "$sym_root/main-link"
  assert_eq "detached-$main_sha" "$(harness_branch_slug "$sym_root/main-link")" "Symlinked main repo detached HEAD must not false-match worktree"
  assert_eq "detached-$main_sha" "$(python3 -B -c "$py_slug_cmd" "$REPO_ROOT/scripts/lib" "$sym_root/main-link")" "Python symlinked main repo detached HEAD must stay detached-<7sha>"

  # 2. Linked detached worktree must produce stable detached-wt-<name> across common.sh and harness_core.py
  local wt_parent wt_alpha wt_dotted
  wt_parent=$(mktemp -d "/tmp/harness-wt-detached.XXXXXX")
  echo "$wt_parent" >> "$_HARNESS_TEMP_TRACKER"
  wt_alpha="$wt_parent/worker-alpha"
  wt_dotted="$wt_parent/worker.v1_2"
  git -C "$repo" worktree add --detach "$wt_alpha" --quiet
  git -C "$repo" worktree add --detach "$wt_dotted" --quiet

  assert_eq "HEAD" "$(harness_branch_name "$wt_alpha")" "Detached linked worktree branch name must remain HEAD"
  local wt_slug_sh wt_slug_py wt_dotted_sh wt_dotted_py
  wt_slug_sh=$(harness_branch_slug "$wt_alpha")
  wt_slug_py=$(python3 -B -c "$py_slug_cmd" "$REPO_ROOT/scripts/lib" "$wt_alpha")
  assert_eq "detached-wt-worker-alpha" "$wt_slug_sh" "Detached linked worktree slug in common.sh"
  assert_eq "$wt_slug_sh" "$wt_slug_py" "Detached linked worktree slug parity between common.sh and harness_core.py"

  wt_dotted_sh=$(harness_branch_slug "$wt_dotted")
  wt_dotted_py=$(python3 -B -c "$py_slug_cmd" "$REPO_ROOT/scripts/lib" "$wt_dotted")
  assert_eq "detached-wt-worker-v1-2" "$wt_dotted_sh" "Punctuated linked worktree name must slugify identically"
  assert_eq "$wt_dotted_sh" "$wt_dotted_py" "Punctuated linked worktree parity"

  # Symlink + subdirectory invocation inside detached linked worktree
  mkdir -p "$wt_alpha/src"
  ln -s "$wt_alpha" "$sym_root/wt-link"
  assert_eq "detached-wt-worker-alpha" "$(harness_branch_slug "$wt_alpha/src")" "Subdir in detached linked worktree (common.sh)"
  assert_eq "detached-wt-worker-alpha" "$(python3 -B -c "$py_slug_cmd" "$REPO_ROOT/scripts/lib" "$wt_alpha/src")" "Subdir in detached linked worktree (python)"
  assert_eq "detached-wt-worker-alpha" "$(harness_branch_slug "$sym_root/wt-link")" "Symlink to detached linked worktree (common.sh)"
  assert_eq "detached-wt-worker-alpha" "$(python3 -B -c "$py_slug_cmd" "$REPO_ROOT/scripts/lib" "$sym_root/wt-link")" "Symlink to detached linked worktree (python)"

  # 3. Stamp context7, make a new commit in detached worktree, verify slug and state survive
  "$STAMP_GATE" context7 --workspace "$wt_alpha" --package "zod" --version "3.24.0" --source "locked"
  local state_dir_before
  state_dir_before=$(harness_state_dir "$wt_alpha")
  assert_eq "$wt_alpha/.harness/state/detached-wt-worker-alpha" "$state_dir_before" "State dir must use detached-wt-<name>"
  [ -f "$state_dir_before/context7-verified.json" ] || { echo "context7-verified.json missing before commit" >&2; return 1; }

  echo "export const x = 1;" > "$wt_alpha/src/index.ts"
  git -C "$wt_alpha" add src/index.ts
  git -C "$wt_alpha" commit -m "feat: detached commit" --quiet

  assert_eq "detached-wt-worker-alpha" "$(harness_branch_slug "$wt_alpha")" "Slug must survive new commit in common.sh"
  assert_eq "detached-wt-worker-alpha" "$(python3 -B -c "$py_slug_cmd" "$REPO_ROOT/scripts/lib" "$wt_alpha")" "Slug must survive new commit in harness_core.py"
  assert_eq "$state_dir_before" "$(harness_state_dir "$wt_alpha")" "State dir path must stay identical after commit"
  assert_json_field "$state_dir_before/context7-verified.json" '.packages["zod"].version' "3.24.0" "context7-verified.json must remain valid after commit"
}

test_neon_gemini4_and_custom_model_classification_parity() {
  [ -x "$COMMON_SH" ] || { echo "common.sh missing or not executable" >&2; return 1; }
  [ -x "$STAMP_GATE" ] || { echo "stamp-gate.sh missing or not executable" >&2; return 1; }
  # shellcheck source=/dev/null
  source "$COMMON_SH"

  local repo
  repo=$(make_temp_repo)

  # 1. Bash vs Python classify_parent_model parity across new Gemini 4 families and existing ones
  local py_cls='import sys; sys.path.insert(0, sys.argv[1]); import harness_core; print(harness_core.classify_parent_model(sys.argv[2]))'
  local model expected sh_cls py_cls_out
  local cases=(
    "gemini-4-neon-high|neon"
    "Gemini 4 Neon (Medium)|neon"
    "Gemini 4 Neon (Extra)|neon"
    "gemini-4-neon-low|frontier_low"
    "Gemini 4 Neon (Low)|frontier_low"
    "gemini-4-neon low|frontier_low"
    "Gemini 4 Carbon (Low)|frontier_low"
    "Orchestrator (Neon)|orchestrator_neon"
    "Orchestrator (Carbon)|orchestrator_carbon"
    "Orchestrator (Argon)|orchestrator_argon"
    "gemini-4-pro|neon"
    "Gemini 4 Ultra (High)|neon"
    "gemini-4-pro-low|frontier_low"
    "Gemini 4 (Low)|frontier_low"
    "Claude Opus 5.5 (Thinking)|claude_opus"
    "Claude Sonnet 5.5|claude_sonnet"
    "gemini-4-flash|flash"
    "gemini-4-flash-low|flash"
    "enterprise-tuned-v1|custom"
    "|unset"
  )
  local pair
  for pair in "${cases[@]}"; do
    model="${pair%%|*}"
    expected="${pair##*|}"
    sh_cls=$(harness_classify_parent_model "$model")
    py_cls_out=$(python3 -B -c "$py_cls" "$REPO_ROOT/scripts/lib" "$model")
    assert_eq "$expected" "$sh_cls" "common.sh classify('$model')"
    assert_eq "$expected" "$py_cls_out" "harness_core.py classify('$model')"
  done

  # 2. Bash vs Python resolve_subagent_model parity across all tiers, caller_model, and floor_upgraded
  local py_res='import sys; sys.path.insert(0, sys.argv[1]); import harness_core; print(harness_core.resolve_subagent_model(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5] == "true"))'
  local tier caller floor sh_res py_res_out
  local m_list=("gemini-4-neon-high" "gemini-4-neon-low" "Orchestrator (Neon)" "Orchestrator (Carbon)" "Claude Opus 5.5" "Claude Sonnet 5.5" "gemini-4-hydrogen-xhigh" "gemini-4-pro" "gemini-4-flash" "enterprise-tuned-v1" "")
  local t_list=("trivial_lookup" "bounded_execution" "multi_module_integration" "critical_architecture_or_audit")
  for model in "${m_list[@]}"; do
    for tier in "${t_list[@]}"; do
      for caller in "" "inherit"; do
        for floor in "false" "true"; do
          sh_res=$(harness_resolve_subagent_model "$model" "$tier" "$caller" "$floor")
          py_res_out=$(python3 -B -c "$py_res" "$REPO_ROOT/scripts/lib" "$model" "$tier" "$caller" "$floor")
          assert_eq "$py_res_out" "$sh_res" "Parity failed for model='$model' tier='$tier' caller='$caller' floor='$floor'"
        done
      done
    done
  done

  # 2b. Bash vs Python detect_parent_effort_hint & is_deprecated_parent_model parity
  local py_eff='import sys; sys.path.insert(0, sys.argv[1]); import harness_core; print(harness_core.detect_parent_effort_hint(sys.argv[2]))'
  local py_dep='import sys; sys.path.insert(0, sys.argv[1]); import harness_core; print("true" if harness_core.is_deprecated_parent_model(sys.argv[2]) else "false")'
  local meta_models=("Gemini 4 Neon (Extra)" "gemini-4-hydrogen-xhigh" "Gemini 4 Neon (Low)" "gemini-4-argon-high" "Orchestrator (Argon)" "gemini-3.8-flash-low" "gpt-oss-120b-medium" "Claude 4.6 Sonnet" "Orchestrator (Neon)" "Claude Opus 5.5" "")
  for model in "${meta_models[@]}"; do
    local sh_eff py_eff_out sh_dep py_dep_out
    sh_eff=$(harness_detect_parent_effort_hint "$model")
    py_eff_out=$(python3 -B -c "$py_eff" "$REPO_ROOT/scripts/lib" "$model")
    assert_eq "$py_eff_out" "$sh_eff" "Effort hint parity failed for '$model'"
    if harness_is_deprecated_model "$model"; then sh_dep="true"; else sh_dep="false"; fi
    py_dep_out=$(python3 -B -c "$py_dep" "$REPO_ROOT/scripts/lib" "$model")
    assert_eq "$py_dep_out" "$sh_dep" "Deprecation parity failed for '$model'"
  done

  # 3. Specific routing contracts via stamp-gate.sh select-model
  local sel_neon_bounded sel_neon_multi_def sel_neon_multi_inh sel_neon_crit sel_custom_bounded sel_unset_bounded sel_flash_bounded sel_g4_pro_bounded
  sel_neon_bounded=$("$STAMP_GATE" select-model --tier "bounded_execution" --parent-model "gemini-4-neon-high" --workspace "$repo")
  assert_json_field "$sel_neon_bounded" ".parentFamily" "neon"
  assert_json_field "$sel_neon_bounded" ".model" "pro" "neon bounded_execution -> pro"

  sel_neon_multi_def=$("$STAMP_GATE" select-model --tier "multi_module_integration" --parent-model "gemini-4-neon-high" --workspace "$repo")
  assert_json_field "$sel_neon_multi_def" ".model" "pro" "neon multi_module default -> pro"

  sel_neon_multi_inh=$("$STAMP_GATE" select-model --tier "multi_module_integration" --parent-model "gemini-4-neon-high" --caller-model "inherit" --workspace "$repo")
  assert_json_field "$sel_neon_multi_inh" ".model" "inherit" "neon multi_module with caller inherit -> inherit"

  sel_neon_crit=$("$STAMP_GATE" select-model --tier "critical_architecture_or_audit" --parent-model "gemini-4-neon-high" --workspace "$repo")
  assert_json_field "$sel_neon_crit" ".model" "inherit" "neon critical_architecture_or_audit -> inherit"

  sel_custom_bounded=$("$STAMP_GATE" select-model --tier "bounded_execution" --parent-model "enterprise-tuned-v1" --workspace "$repo")
  assert_json_field "$sel_custom_bounded" ".parentFamily" "custom"
  assert_json_field "$sel_custom_bounded" ".model" "pro" "custom bounded_execution -> pro"

  sel_unset_bounded=$("$STAMP_GATE" select-model --tier "bounded_execution" --parent-model "" --workspace "$repo")
  assert_json_field "$sel_unset_bounded" ".model" "flash" "unset bounded_execution remains flash"

  sel_flash_bounded=$("$STAMP_GATE" select-model --tier "bounded_execution" --parent-model "gemini-4-flash" --workspace "$repo")
  assert_json_field "$sel_flash_bounded" ".model" "flash" "flash bounded_execution remains flash"

  sel_g4_pro_bounded=$("$STAMP_GATE" select-model --tier "bounded_execution" --parent-model "gemini-4-pro" --workspace "$repo")
  assert_json_field "$sel_g4_pro_bounded" ".parentFamily" "neon"
  assert_json_field "$sel_g4_pro_bounded" ".model" "pro" "unmatched gemini-4-pro classifies as neon and routes bounded_execution -> pro"
}

test_ui_stamp_web_detect_enforcement_and_native_p0_p1_validation() {
  # shellcheck source=/dev/null
  source "$COMMON_SH"
  local repo mock_bin mock_cfg env_log
  repo=$(make_temp_repo)
  mock_bin="$repo/.mock-impeccable"
  mock_cfg="$repo/.mock-cfg"
  env_log="$repo/.mock-detect-env.log"
  mkdir -p "$mock_cfg"

  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: init" --quiet
  git -C "$repo" checkout -b "feat/ui-card" --quiet

  # 1. Pure backend change does NOT require ui-pass.json even when Impeccable is installed
  mkdir -p "$repo/src"
  echo "export class Order {}" > "$repo/src/Order.cs"
  git -C "$repo" add src/Order.cs
  git -C "$repo" commit -m "feat: backend order" --quiet
  "$STAMP_GATE" canon --workspace "$repo" --verdict PASS --allow-file "src/Order.cs"
  "$STAMP_GATE" security --workspace "$repo" --verdict PASS --critical 0 --important 0
  "$STAMP_GATE" tdd --workspace "$repo" --verdict PASS --critical-gaps 0 --important-gaps 0 --provider claude-cli --model sonnet --effort high

  cat << 'EOF' > "$mock_bin"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$mock_bin"
  HARNESS_CONFIG_DIR="$mock_cfg" HARNESS_IMPECCABLE_BIN="$mock_bin" \
    "$STAMP_GATE" verify-pr-stamps --workspace "$repo"

  # 2. Add Web UI file -> verify-pr-stamps requires ui-pass.json when Impeccable is present,
  #    and does NOT require it when Impeccable is absent
  mkdir -p "$repo/src/app"
  echo "<section class='hero'><h1>Hello</h1></section>" > "$repo/src/app/Hero.html"
  git -C "$repo" add src/app/Hero.html
  git -C "$repo" commit -m "feat: add Hero.html" --quiet
  "$STAMP_GATE" canon --workspace "$repo" --verdict PASS --allow-file "src/Order.cs" --allow-file "src/app/Hero.html"
  "$STAMP_GATE" security --workspace "$repo" --verdict PASS --critical 0 --important 0
  "$STAMP_GATE" tdd --workspace "$repo" --verdict PASS --critical-gaps 0 --important-gaps 0 --provider claude-cli --model sonnet --effort high

  # Without Impeccable installed -> verify-pr-stamps passes without ui-pass.json
  HARNESS_CONFIG_DIR="$mock_cfg" env -u HARNESS_IMPECCABLE_BIN -u HARNESS_IMPECCABLE_SKILL_DIR \
    "$STAMP_GATE" verify-pr-stamps --workspace "$repo"

  # With Impeccable installed -> verify-pr-stamps fails until ui-pass.json is stamped
  local missing_ui_err
  if missing_ui_err=$(HARNESS_CONFIG_DIR="$mock_cfg" HARNESS_IMPECCABLE_BIN="$mock_bin" \
      "$STAMP_GATE" verify-pr-stamps --workspace "$repo" 2>&1); then
    echo "verify-pr-stamps must fail when Web UI changed and Impeccable is installed without ui-pass.json" >&2
    return 1
  fi
  assert_contains "$missing_ui_err" "ui stamp"

  # 3. Mock detector returning exit 2 (slop findings) blocks PASS stamp
  cat << 'EOF' > "$mock_bin"
#!/usr/bin/env bash
echo '[{"rule":"overused-font","file":"src/app/Hero.html"}]'
exit 2
EOF
  chmod +x "$mock_bin"

  set +e
  local detect_fail_err rc_detect=0
  detect_fail_err=$(HARNESS_CONFIG_DIR="$mock_cfg" HARNESS_IMPECCABLE_BIN="$mock_bin" \
    "$STAMP_GATE" ui --workspace "$repo" --verdict PASS --p0 0 --p1 0 2>&1)
  rc_detect=$?
  set -e
  assert_eq "2" "$rc_detect" "Detector findings (exit 2) must reject ui PASS stamp with exit 2"
  assert_contains "$detect_fail_err" "overused-font"

  local state_dir
  state_dir="$(harness_state_dir "$repo")"
  [ ! -f "$state_dir/ui-pass.json" ] || { echo "ui-pass.json must not be written when detector exits 2" >&2; return 1; }

  # 4. Non-zero p0 or p1 rejects PASS stamp (exit 1)
  if HARNESS_CONFIG_DIR="$mock_cfg" HARNESS_IMPECCABLE_BIN="$mock_bin" \
      "$STAMP_GATE" ui --workspace "$repo" --verdict PASS --p0 1 --p1 0 >/dev/null 2>&1; then
    echo "ui PASS with p0=1 must be rejected" >&2
    return 1
  fi
  if HARNESS_CONFIG_DIR="$mock_cfg" HARNESS_IMPECCABLE_BIN="$mock_bin" \
      "$STAMP_GATE" ui --workspace "$repo" --verdict PASS --p0 0 --p1 2 >/dev/null 2>&1; then
    echo "ui PASS with p1=2 must be rejected" >&2
    return 1
  fi

  # 5. Clean detector (exit 0) verifies safe env and writes valid ui-pass.json
  cat << EOF > "$mock_bin"
#!/usr/bin/env bash
printf 'DO_NOT_TRACK=%s\nIMPECCABLE_LIVE_COPY_AGENT=%s\nARGS=%s\n' \
  "\${DO_NOT_TRACK:-}" "\${IMPECCABLE_LIVE_COPY_AGENT:-}" "\$*" > "$env_log"
echo '[]'
exit 0
EOF
  chmod +x "$mock_bin"

  HARNESS_CONFIG_DIR="$mock_cfg" HARNESS_IMPECCABLE_BIN="$mock_bin" \
    "$STAMP_GATE" ui --workspace "$repo" --verdict PASS --p0 0 --p1 0
  [ -f "$state_dir/ui-pass.json" ] || { echo "ui-pass.json must be created on clean detector pass" >&2; return 1; }
  assert_json_field "$state_dir/ui-pass.json" ".verdict" "PASS"
  assert_json_field "$state_dir/ui-pass.json" ".p0Count" "0"
  assert_json_field "$state_dir/ui-pass.json" ".p1Count" "0"
  assert_json_field "$state_dir/ui-pass.json" ".scannedWebFiles[0]" "src/app/Hero.html"

  local env_dump
  env_dump=$(cat "$env_log")
  assert_contains "$env_dump" "DO_NOT_TRACK=1"
  assert_contains "$env_dump" "IMPECCABLE_LIVE_COPY_AGENT=off"
  assert_contains "$env_dump" "detect --json src/app/Hero.html"

  HARNESS_CONFIG_DIR="$mock_cfg" HARNESS_IMPECCABLE_BIN="$mock_bin" \
    "$STAMP_GATE" verify-pr-stamps --workspace "$repo"

  # 6. Modifying Hero.html after stamping invalidates ui-pass.json (stale codeTreeSha)
  echo "<section class='hero'><h1>Updated</h1></section>" > "$repo/src/app/Hero.html"
  git -C "$repo" add src/app/Hero.html
  git -C "$repo" commit -m "feat: update Hero.html" --quiet
  "$STAMP_GATE" canon --workspace "$repo" --verdict PASS --allow-file "src/Order.cs" --allow-file "src/app/Hero.html"
  "$STAMP_GATE" security --workspace "$repo" --verdict PASS --critical 0 --important 0
  "$STAMP_GATE" tdd --workspace "$repo" --verdict PASS --critical-gaps 0 --important-gaps 0 --provider claude-cli --model sonnet --effort high

  local stale_err
  if stale_err=$(HARNESS_CONFIG_DIR="$mock_cfg" HARNESS_IMPECCABLE_BIN="$mock_bin" \
      "$STAMP_GATE" verify-pr-stamps --workspace "$repo" 2>&1); then
    echo "verify-pr-stamps must reject stale ui-pass.json after UI commit" >&2
    return 1
  fi
  assert_contains "$stale_err" "ui-pass.json codeTreeSha"

  # 7. Native SwiftUI change with SKILL.md only (no web files) requires ui-pass.json and passes without binary detector
  local native_repo native_skill_dir
  native_repo=$(make_temp_repo)
  native_skill_dir="$native_repo/.mock-skill"
  mkdir -p "$native_skill_dir" "$native_repo/Sources/Features"
  echo "# Impeccable" > "$native_skill_dir/SKILL.md"
  echo "init" > "$native_repo/README.md"
  git -C "$native_repo" add README.md
  git -C "$native_repo" commit -m "chore: init" --quiet
  git -C "$native_repo" checkout -b "feat/paywall-view" --quiet
  echo "struct PaywallView {}" > "$native_repo/Sources/Features/PaywallView.swift"
  git -C "$native_repo" add Sources/Features/PaywallView.swift
  git -C "$native_repo" commit -m "feat: add PaywallView" --quiet
  "$STAMP_GATE" canon --workspace "$native_repo" --verdict PASS --allow-file "Sources/Features/PaywallView.swift"
  "$STAMP_GATE" security --workspace "$native_repo" --verdict PASS --critical 0 --important 0
  "$STAMP_GATE" tdd --workspace "$native_repo" --verdict PASS --critical-gaps 0 --important-gaps 0 --provider claude-cli --model sonnet --effort high

  if HARNESS_CONFIG_DIR="$mock_cfg" HARNESS_IMPECCABLE_SKILL_DIR="$native_skill_dir" \
      "$STAMP_GATE" verify-pr-stamps --workspace "$native_repo" >/dev/null 2>&1; then
    echo "Native SwiftUI UI change with Impeccable skill must require ui-pass.json" >&2
    return 1
  fi

  HARNESS_CONFIG_DIR="$mock_cfg" HARNESS_IMPECCABLE_SKILL_DIR="$native_skill_dir" \
    "$STAMP_GATE" ui --workspace "$native_repo" --verdict PASS --p0 0 --p1 0
  local native_state_dir
  native_state_dir="$(harness_state_dir "$native_repo")"
  assert_json_field "$native_state_dir/ui-pass.json" ".auditedNativeFiles[0]" "Sources/Features/PaywallView.swift"
  HARNESS_CONFIG_DIR="$mock_cfg" HARNESS_IMPECCABLE_SKILL_DIR="$native_skill_dir" \
    "$STAMP_GATE" verify-pr-stamps --workspace "$native_repo"

  # 8. --target cannot bypass changed Web UI files when --verdict PASS, and non-executable repo scripts are not executed via /bin/sh
  local partial_err
  if partial_err=$(HARNESS_CONFIG_DIR="$mock_cfg" HARNESS_IMPECCABLE_BIN="$repo/.missing-bin" "$STAMP_GATE" ui --workspace "$repo" --verdict PASS --p0 0 --p1 0 --target README.md 2>&1); then
    echo "stamp-gate ui --verdict PASS --target README.md must still scan changed Hero.html and require valid detector" >&2
    return 1
  fi
  mkdir -p "$repo/.agent/skills/impeccable/scripts"
  cat << 'EOF' > "$repo/.agent/skills/impeccable/scripts/impeccable"
#!/usr/bin/env bash
echo '[]'
exit 0
EOF
  # Deliberately NOT chmod +x: must NOT run via /bin/sh fallback
  echo "# Skill" > "$repo/.agent/skills/impeccable/SKILL.md"
  if HARNESS_CONFIG_DIR="$mock_cfg" env -u HARNESS_IMPECCABLE_BIN -u HARNESS_IMPECCABLE_SKILL_DIR \
      "$STAMP_GATE" ui --workspace "$repo" --verdict PASS --p0 0 --p1 0 --target README.md >/dev/null 2>&1; then
    echo "Non-executable .agent/skills/impeccable/scripts/impeccable must not be executed via /bin/sh" >&2
    return 1
  fi

  # 9. Angular .component.ts files classify as webFiles (not nativeFiles)
  local comp_cls
  comp_cls=$(python3 -B -c 'import json, sys; sys.path.insert(0, sys.argv[1]); import harness_core; print(json.dumps(harness_core.classify_ui_files(["src/app/hero.component.ts"])))' "$REPO_ROOT/scripts/lib")
  assert_json_field "$comp_cls" ".webFiles[0]" "src/app/hero.component.ts" ".component.ts classifies into webFiles"
  assert_eq "0" "$(printf '%s\n' "$comp_cls" | jq '.nativeFiles | length')" ".component.ts must not fall into nativeFiles"
}

test_claude_cli_review_fallback_and_tdd_stamp_gate() {
  local repo mock_claude mock_agy arg_log
  repo=$(make_temp_repo)
  mock_claude="$repo/.mock-claude"
  mock_agy="$repo/.mock-agy"
  arg_log="$repo/.review-args.log"

  echo "# Init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: init" --quiet
  git -C "$repo" checkout -b "feat/review-tdd" --quiet

  mkdir -p "$repo/src" "$repo/tests" "$repo/docs/superpowers/specs"
  echo "export const double = (n: number) => n * 2;" > "$repo/src/Math.ts"
  echo "test('double', () => expect(double(2)).toBe(4));" > "$repo/tests/Math.test.ts"
  echo "# Spec" > "$repo/docs/superpowers/specs/math-spec.md"
  git -C "$repo" add src/Math.ts tests/Math.test.ts docs/superpowers/specs/math-spec.md
  git -C "$repo" commit -m "feat: add Math and test" --quiet

  # 1. Primary claude -p Spec/Plan review (opus / medium, read-only flags, sensitive env scrubbed, stdin prompt verified)
  local prompt_log="$repo/.review-prompt.log"
  cat << EOF > "$mock_claude"
#!/usr/bin/env bash
cat > "$prompt_log"
printf 'CLAUDECODE=%s\nTYPESAFE_API_KEY=%s\nGITHUB_TOKEN=%s\nAWS_SECRET_ACCESS_KEY=%s\nOPENAI_API_KEY=%s\nSTRIPE_SECRET_KEY=%s\nARGS=%s\n' \
  "\${CLAUDECODE:-}" "\${TYPESAFE_API_KEY:-}" "\${GITHUB_TOKEN:-}" "\${AWS_SECRET_ACCESS_KEY:-}" "\${OPENAI_API_KEY:-}" "\${STRIPE_SECRET_KEY:-}" "\$*" > "$arg_log"
echo "Spec looks solid."
echo 'VERDICT_JSON: {"verdict":"PASS","criticalGaps":0,"importantGaps":0,"summary":"Spec approved"}'
exit 0
EOF
  chmod +x "$mock_claude"

  local out_spec_ok
  out_spec_ok=$(CLAUDECODE="nested-parent" TYPESAFE_API_KEY="ts_live_secret_must_not_leak" GITHUB_TOKEN="ghp_secret" AWS_SECRET_ACCESS_KEY="aws_secret" OPENAI_API_KEY="sk-openai" STRIPE_SECRET_KEY="sk-stripe" HARNESS_CLAUDE_BIN="$mock_claude" \
    "$STAMP_GATE" review --workspace "$repo" --kind spec-plan --target "docs/superpowers/specs/math-spec.md" --auto-stamp)
  assert_json_field "$out_spec_ok" ".status" "ok"
  assert_json_field "$out_spec_ok" ".provider" "claude-cli"
  assert_json_field "$out_spec_ok" ".model" "opus"
  assert_json_field "$out_spec_ok" ".effort" "medium"
  assert_json_field "$out_spec_ok" ".verdict" "PASS"
  assert_json_field "$out_spec_ok" ".stamped" "false" "spec-plan --auto-stamp must never write tdd-pass.json"
  [ ! -f "$repo/.harness/state/feat-review-tdd/tdd-pass.json" ] || { echo "spec-plan --auto-stamp must not create tdd-pass.json" >&2; return 1; }

  local logged_spec logged_prompt
  logged_spec=$(cat "$arg_log")
  logged_prompt=$(cat "$prompt_log")
  assert_contains "$logged_spec" "CLAUDECODE="
  assert_not_contains "$logged_spec" "nested-parent"
  assert_not_contains "$logged_spec" "ts_live_secret_must_not_leak"
  assert_not_contains "$logged_spec" "ghp_secret"
  assert_not_contains "$logged_spec" "aws_secret"
  assert_not_contains "$logged_spec" "sk-openai"
  assert_not_contains "$logged_spec" "sk-stripe"
  assert_contains "$logged_spec" "--model opus"
  assert_contains "$logged_spec" "--effort medium"
  assert_contains "$logged_spec" "--permission-mode plan"
  assert_contains "$logged_spec" "--no-session-persistence"
  assert_contains "$logged_spec" "--tools Read,Grep,Glob"
  assert_contains "$logged_prompt" "docs/superpowers/specs/math-spec.md"
  assert_contains "$logged_prompt" "Spec & Implementation Plan Review"

  # 2. Primary claude -p TDD review (sonnet / high + --auto-stamp writes tdd-pass.json, prompt lists changed code/tests)
  local out_tdd_ok state_dir
  out_tdd_ok=$(HARNESS_CLAUDE_BIN="$mock_claude" \
    "$STAMP_GATE" review --workspace "$repo" --kind tdd --auto-stamp)
  assert_json_field "$out_tdd_ok" ".status" "ok"
  assert_json_field "$out_tdd_ok" ".model" "sonnet"
  assert_json_field "$out_tdd_ok" ".effort" "high"
  assert_json_field "$out_tdd_ok" ".stamped" "true"
  assert_contains "$(cat "$prompt_log")" "src/Math.ts"
  assert_contains "$(cat "$prompt_log")" "tests/Math.test.ts"
  state_dir="$repo/.harness/state/feat-review-tdd"
  [ -f "$state_dir/tdd-pass.json" ] || { echo "Expected tdd-pass.json after --auto-stamp" >&2; return 1; }
  assert_json_field "$state_dir/tdd-pass.json" ".verdict" "PASS"
  assert_json_field "$state_dir/tdd-pass.json" ".provider" "claude-cli"

  # 3. Missing claude CLI -> exit 42 with structured reason & fallbackChoices (no silent fallback)
  set +e
  local out_missing rc_missing=0
  out_missing=$(PATH="/usr/bin:/bin" HARNESS_CLAUDE_BIN="" \
    "$STAMP_GATE" review --workspace "$repo" --kind spec-plan 2>/dev/null)
  rc_missing=$?
  set -e
  assert_eq "42" "$rc_missing" "Missing claude binary must exit 42"
  assert_json_field "$out_missing" ".status" "claude_unavailable"
  assert_json_field "$out_missing" ".fallbackChoices.agyClaudeModel" "claude-opus-5-5-medium"
  assert_json_field "$out_missing" ".fallbackChoices.agyDefaultModel" "gemini-4-carbon-high"
  assert_json_field "$out_missing" ".fallbackChoices.timeoutSeconds" "30"

  # 4. Failing claude CLI (quota/rate limit) -> exit 42 with exact stderr reason
  cat << 'EOF' > "$mock_claude"
#!/usr/bin/env bash
echo "Error: rate limit exceeded for Claude Pro" >&2
exit 1
EOF
  chmod +x "$mock_claude"
  set +e
  local out_quota rc_quota=0
  out_quota=$(HARNESS_CLAUDE_BIN="$mock_claude" \
    "$STAMP_GATE" review --workspace "$repo" --kind tdd 2>/dev/null)
  rc_quota=$?
  set -e
  assert_eq "42" "$rc_quota" "Failing claude -p must exit 42"
  assert_json_field "$out_quota" ".status" "claude_unavailable"
  assert_contains "$(printf '%s' "$out_quota" | jq -r '.reason')" "rate limit exceeded"
  assert_json_field "$out_quota" ".fallbackChoices.agyClaudeModel" "claude-sonnet-5-5-high"
  assert_json_field "$out_quota" ".fallbackChoices.agyDefaultModel" "gemini-4-neon-medium"

  # 5. agy -p explicit fallback (default timeout models + explicit Claude models + env scrubbing & --disable-slash-commands)
  cat << EOF > "$mock_agy"
#!/usr/bin/env bash
cat >/dev/null
printf 'TYPESAFE_API_KEY=%s\nGITHUB_TOKEN=%s\nAGY_ARGS=%s\n' "\${TYPESAFE_API_KEY:-}" "\${GITHUB_TOKEN:-}" "\$*" > "$arg_log"
echo "Fallback review complete."
echo 'VERDICT_JSON: {"verdict":"PASS","criticalGaps":0,"importantGaps":0,"summary":"TDD coverage verified"}'
exit 0
EOF
  chmod +x "$mock_agy"

  local out_agy_spec out_agy_tdd out_agy_explicit
  out_agy_spec=$(TYPESAFE_API_KEY="ts_live_agy_secret" GITHUB_TOKEN="ghp_agy_secret" HARNESS_AGY_BIN="$mock_agy" \
    "$STAMP_GATE" review --workspace "$repo" --kind spec-plan --provider agy)
  assert_json_field "$out_agy_spec" ".status" "ok"
  assert_json_field "$out_agy_spec" ".provider" "agy-cli"
  assert_json_field "$out_agy_spec" ".model" "gemini-4-carbon-high"
  assert_contains "$(cat "$arg_log")" "--model gemini-4-carbon-high"
  assert_contains "$(cat "$arg_log")" "--mode plan"
  assert_contains "$(cat "$arg_log")" "--disable-slash-commands"
  assert_not_contains "$(cat "$arg_log")" "ts_live_agy_secret"
  assert_not_contains "$(cat "$arg_log")" "ghp_agy_secret"

  out_agy_explicit=$(HARNESS_AGY_BIN="$mock_agy" \
    "$STAMP_GATE" review --workspace "$repo" --kind tdd --provider agy --model claude-sonnet-5-5-high --effort high)
  assert_json_field "$out_agy_explicit" ".model" "claude-sonnet-5-5-high"
  assert_contains "$(cat "$arg_log")" "--model claude-sonnet-5-5-high"
  assert_contains "$(cat "$arg_log")" "--effort high"

  out_agy_tdd=$(HARNESS_AGY_BIN="$mock_agy" \
    "$STAMP_GATE" review --workspace "$repo" --kind tdd --provider agy --auto-stamp)
  assert_json_field "$out_agy_tdd" ".status" "ok"
  assert_json_field "$out_agy_tdd" ".provider" "agy-cli"
  assert_json_field "$out_agy_tdd" ".model" "gemini-4-neon-medium"
  assert_json_field "$out_agy_tdd" ".stamped" "true"
  assert_json_field "$state_dir/tdd-pass.json" ".provider" "agy-cli"
  assert_json_field "$state_dir/tdd-pass.json" ".model" "gemini-4-neon-medium"

  # 6. Fail-closed tdd stamp: PASS with non-zero critical/important gaps must be rejected
  rm -f "$state_dir/tdd-pass.json"
  if "$STAMP_GATE" tdd --workspace "$repo" --verdict PASS --critical-gaps 1 --important-gaps 0 --provider claude-cli --model sonnet >/dev/null 2>&1; then
    echo "tdd PASS with criticalGaps=1 must be rejected" >&2
    return 1
  fi
  if "$STAMP_GATE" tdd --workspace "$repo" --verdict PASS --critical-gaps 0 --important-gaps 2 --provider claude-cli --model sonnet >/dev/null 2>&1; then
    echo "tdd PASS with importantGaps=2 must be rejected" >&2
    return 1
  fi
  [ ! -f "$state_dir/tdd-pass.json" ] || { echo "Rejected tdd PASS must not write tdd-pass.json" >&2; return 1; }

  # 7. verify-pr-stamps requires fresh tdd-pass.json on code changes; modifying code invalidates it
  "$STAMP_GATE" canon --workspace "$repo" --verdict PASS --allow-file "src/Math.ts" --allow-file "tests/Math.test.ts"
  "$STAMP_GATE" security --workspace "$repo" --verdict PASS --critical 0 --important 0
  if "$STAMP_GATE" verify-pr-stamps --workspace "$repo" >/dev/null 2>&1; then
    echo "verify-pr-stamps must fail when tdd-pass.json is missing on code branch" >&2
    return 1
  fi

  "$STAMP_GATE" tdd --workspace "$repo" --verdict PASS --critical-gaps 0 --important-gaps 0 --provider claude-cli --model sonnet --effort high
  "$STAMP_GATE" verify-pr-stamps --workspace "$repo"

  echo "export const double = (n: number) => n + n;" > "$repo/src/Math.ts"
  git -C "$repo" add src/Math.ts
  git -C "$repo" commit -m "refactor: double implementation" --quiet
  "$STAMP_GATE" canon --workspace "$repo" --verdict PASS --allow-file "src/Math.ts" --allow-file "tests/Math.test.ts"
  "$STAMP_GATE" security --workspace "$repo" --verdict PASS --critical 0 --important 0
  local stale_tdd_err
  if stale_tdd_err=$("$STAMP_GATE" verify-pr-stamps --workspace "$repo" 2>&1); then
    echo "verify-pr-stamps must reject stale tdd-pass.json after code commit" >&2
    return 1
  fi
  assert_contains "$stale_tdd_err" "tdd-pass.json codeTreeSha"

  # 8. C1 & I1: --auto-stamp refuses FAIL (even 0/0), PASS with critical/important gaps, boolean gaps, missing/malformed VERDICT_JSON, and mid-review commits
  for bad_output in \
    'VERDICT_JSON: {"verdict":"FAIL","criticalGaps":0,"importantGaps":0,"summary":"fail-zero"}' \
    'VERDICT_JSON: {"verdict":"FAIL","criticalGaps":1,"importantGaps":0,"summary":"gap"}' \
    'VERDICT_JSON: {"verdict":"PASS","criticalGaps":1,"importantGaps":0,"summary":"bad-crit"}' \
    'VERDICT_JSON: {"verdict":"PASS","criticalGaps":0,"importantGaps":1,"summary":"bad-imp"}' \
    'VERDICT_JSON: {"verdict":"PASS","criticalGaps":false,"importantGaps":0,"summary":"bool"}' \
    'Review text without any verdict line' \
    $'Quoted earlier: VERDICT_JSON: {"verdict":"PASS","criticalGaps":0,"importantGaps":0,"summary":"quoted"}\nVERDICT_JSON: {not-valid-json}'
  do
    rm -f "$state_dir/tdd-pass.json"
    cat << EOF > "$mock_claude"
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' '$bad_output'
exit 0
EOF
    chmod +x "$mock_claude"
    local out_bad_auto
    out_bad_auto=$(HARNESS_CLAUDE_BIN="$mock_claude" "$STAMP_GATE" review --workspace "$repo" --kind tdd --auto-stamp)
    assert_json_field "$out_bad_auto" ".stamped" "false" "auto-stamp must refuse bad output: $bad_output"
    [ ! -f "$state_dir/tdd-pass.json" ] || { echo "Bad review must not write tdd-pass.json: $bad_output" >&2; return 1; }
  done

  # Mid-review commit invalidates auto-stamp (I8)
  rm -f "$state_dir/tdd-pass.json"
  cat << EOF > "$mock_claude"
#!/usr/bin/env bash
cat >/dev/null
echo "// mutated mid-review" >> "$repo/src/Math.ts"
git -C "$repo" add src/Math.ts
git -C "$repo" commit -m "chore: mid-review mutation" --quiet
echo 'VERDICT_JSON: {"verdict":"PASS","criticalGaps":0,"importantGaps":0,"summary":"ok"}'
exit 0
EOF
  chmod +x "$mock_claude"
  local out_mid_commit
  out_mid_commit=$(HARNESS_CLAUDE_BIN="$mock_claude" "$STAMP_GATE" review --workspace "$repo" --kind tdd --auto-stamp)
  assert_json_field "$out_mid_commit" ".staleDuringReview" "true"
  assert_json_field "$out_mid_commit" ".stamped" "false"
  [ ! -f "$state_dir/tdd-pass.json" ] || { echo "Mid-review commit must block auto-stamp" >&2; return 1; }

  # 9. I2 & I3: stamp-gate tdd input validation (missing counts, bad provider, leading '-' arg injection) & schema/auditedFiles verification
  if "$STAMP_GATE" tdd --workspace "$repo" --verdict PASS --provider claude-cli --model sonnet >/dev/null 2>&1; then
    echo "tdd PASS without explicit --critical-gaps/--important-gaps must fail" >&2
    return 1
  fi
  if "$STAMP_GATE" tdd --workspace "$repo" --verdict PASS --critical-gaps 0 --important-gaps 0 --provider bogus --model sonnet >/dev/null 2>&1; then
    echo "tdd with invalid provider must fail" >&2
    return 1
  fi
  if "$STAMP_GATE" tdd --workspace "$repo" --verdict PASS --critical-gaps 0 --important-gaps 0 --provider claude-cli --model=-evil >/dev/null 2>&1; then
    echo "tdd with leading '-' model must fail" >&2
    return 1
  fi
  if HARNESS_CLAUDE_BIN="$mock_claude" "$STAMP_GATE" review --workspace "$repo" --kind tdd --model=-evil >/dev/null 2>&1; then
    echo "review with leading '-' model must fail" >&2
    return 1
  fi
  "$STAMP_GATE" canon --workspace "$repo" --verdict PASS --allow-file "src/Math.ts" --allow-file "tests/Math.test.ts"
  "$STAMP_GATE" security --workspace "$repo" --verdict PASS --critical 0 --important 0
  "$STAMP_GATE" tdd --workspace "$repo" --verdict PASS --critical-gaps 0 --important-gaps 0 --provider claude-cli --model sonnet --effort high --file "src/Math.ts" --file "tests/Math.test.ts"
  assert_json_field "$state_dir/tdd-pass.json" ".criticalGaps" "0"
  assert_json_field "$state_dir/tdd-pass.json" ".importantGaps" "0"
  assert_json_field "$state_dir/tdd-pass.json" ".effort" "high"
  assert_json_field "$state_dir/tdd-pass.json" ".auditedFiles[0]" "src/Math.ts"
  assert_json_field "$state_dir/tdd-pass.json" ".auditedFiles[1]" "tests/Math.test.ts"
  assert_json_field "$state_dir/tdd-pass.json" ".codeTreeSha" "$("$STAMP_GATE" tree-sha --workspace "$repo")"

  # 10. C2: verify-pr-stamps rejects FAIL 0/0, PASS with importantGaps=1, PASS with boolean gaps, and corrupt JSON (each unmasked)
  "$STAMP_GATE" tdd --workspace "$repo" --verdict FAIL --critical-gaps 0 --important-gaps 0 --provider claude-cli --model sonnet
  if "$STAMP_GATE" verify-pr-stamps --workspace "$repo" >/dev/null 2>&1; then
    echo "verify-pr-stamps must reject FAIL 0/0 tdd-pass.json" >&2
    return 1
  fi
  jq -c '.verdict = "PASS" | .criticalGaps = 0 | .importantGaps = 1' "$state_dir/tdd-pass.json" > "$state_dir/tdd-pass.json.tmp" && mv "$state_dir/tdd-pass.json.tmp" "$state_dir/tdd-pass.json"
  if "$STAMP_GATE" verify-pr-stamps --workspace "$repo" >/dev/null 2>&1; then
    echo "verify-pr-stamps must reject importantGaps=1 in tdd-pass.json" >&2
    return 1
  fi
  jq -c '.verdict = "PASS" | .criticalGaps = false | .importantGaps = 0' "$state_dir/tdd-pass.json" > "$state_dir/tdd-pass.json.tmp" && mv "$state_dir/tdd-pass.json.tmp" "$state_dir/tdd-pass.json"
  if "$STAMP_GATE" verify-pr-stamps --workspace "$repo" >/dev/null 2>&1; then
    echo "verify-pr-stamps must reject boolean criticalGaps in tdd-pass.json" >&2
    return 1
  fi
  printf '{corrupt-json\n' > "$state_dir/tdd-pass.json"
  if "$STAMP_GATE" verify-pr-stamps --workspace "$repo" >/dev/null 2>&1; then
    echo "verify-pr-stamps must reject corrupt tdd-pass.json" >&2
    return 1
  fi

  # 11. I4 & Security: secret redaction in failure reason, claude timeout, agy error paths, and symlink-safe report write
  cat << 'EOF' > "$mock_claude"
#!/usr/bin/env bash
echo "Auth failed for Bearer secret_tok_123456789 and ts_live_abcdef1234567890" >&2
exit 1
EOF
  chmod +x "$mock_claude"
  set +e
  local out_redact rc_redact=0
  out_redact=$(HARNESS_CLAUDE_BIN="$mock_claude" "$STAMP_GATE" review --workspace "$repo" --kind tdd 2>/dev/null)
  rc_redact=$?
  set -e
  assert_eq "42" "$rc_redact"
  assert_not_contains "$out_redact" "secret_tok_123456789"
  assert_not_contains "$out_redact" "ts_live_abcdef1234567890"
  assert_contains "$out_redact" "[REDACTED]"

  # Timeout path for claude
  cat << 'EOF' > "$mock_claude"
#!/usr/bin/env bash
sleep 3
EOF
  chmod +x "$mock_claude"
  set +e
  local out_to rc_to=0
  out_to=$(HARNESS_REVIEW_TIMEOUT_SEC=1 HARNESS_CLAUDE_BIN="$mock_claude" "$STAMP_GATE" review --workspace "$repo" --kind tdd 2>/dev/null)
  rc_to=$?
  set -e
  assert_eq "42" "$rc_to"
  assert_contains "$out_to" "timed out"

  # agy failure path (exit 1)
  cat << 'EOF' > "$mock_agy"
#!/usr/bin/env bash
echo "agy backend unavailable" >&2
exit 1
EOF
  chmod +x "$mock_agy"
  set +e
  local out_agy_err rc_agy_err=0
  out_agy_err=$(HARNESS_AGY_BIN="$mock_agy" "$STAMP_GATE" review --workspace "$repo" --kind tdd --provider agy 2>/dev/null)
  rc_agy_err=$?
  set -e
  assert_eq "1" "$rc_agy_err"
  assert_json_field "$out_agy_err" ".status" "agy_error"

  # Symlink-safe atomic report write (symlink must be replaced, target untouched)
  local outside_target="$repo/outside-sentinel.txt"
  echo "DO_NOT_OVERWRITE" > "$outside_target"
  ln -sf "$outside_target" "$state_dir/tdd-review.md"
  cat << 'EOF' > "$mock_claude"
#!/usr/bin/env bash
cat >/dev/null
echo 'Clean report'
echo 'VERDICT_JSON: {"verdict":"PASS","criticalGaps":0,"importantGaps":0,"summary":"ok"}'
exit 0
EOF
  chmod +x "$mock_claude"
  HARNESS_CLAUDE_BIN="$mock_claude" "$STAMP_GATE" review --workspace "$repo" --kind tdd >/dev/null
  assert_eq "DO_NOT_OVERWRITE" "$(cat "$outside_target")" "Atomic report write must not follow symlink target"
  [ ! -L "$state_dir/tdd-review.md" ] || { echo "Report symlink should be atomically replaced" >&2; return 1; }

  # Narrow --target review must not auto-stamp the entire branch
  rm -f "$state_dir/tdd-pass.json"
  local out_narrow_auto
  out_narrow_auto=$(HARNESS_CLAUDE_BIN="$mock_claude" "$STAMP_GATE" review --workspace "$repo" --kind tdd --target "README.md" --auto-stamp)
  assert_json_field "$out_narrow_auto" ".stamped" "false" "Narrow --target review must not auto-stamp full branch"
  [ ! -f "$state_dir/tdd-pass.json" ] || { echo "Narrow --target review must not write tdd-pass.json" >&2; return 1; }

  # 12. C4 & C5: dotfile/dot-dir exemptions & deletion-only code branch still requires TDD stamp
  local dot_chk
  dot_chk=$(python3 -B -c 'import json, sys; sys.path.insert(0, sys.argv[1]); import harness_core; req, files = harness_core.requires_tdd_stamp(harness_core.Path("."), [".gitignore", ".harness-ignore", ".impeccable/cfg.json", ".superpowers/s.json", ".harness/state/x.json", "./docs/a.md", "./.github/workflows/ci.yml"]); print(json.dumps({"req": req, "files": files}))' "$REPO_ROOT/scripts/lib")
  assert_json_field "$dot_chk" ".req" "true"
  assert_eq "1" "$(printf '%s\n' "$dot_chk" | jq '.files | length')" "Only .github/workflows/ci.yml should remain non-exempt"
  assert_json_field "$dot_chk" ".files[0]" ".github/workflows/ci.yml" "Dotfile prefix must be preserved intact"

  local del_repo
  del_repo=$(make_temp_repo)
  mkdir -p "$del_repo/src"
  echo "export const x = 1;" > "$del_repo/src/Old.ts"
  git -C "$del_repo" add src/Old.ts
  git -C "$del_repo" commit -m "chore: init" --quiet
  git -C "$del_repo" checkout -b "feat/delete-only" --quiet
  git -C "$del_repo" rm -f src/Old.ts --quiet
  git -C "$del_repo" commit -m "refactor: delete Old.ts" --quiet
  "$STAMP_GATE" canon --workspace "$del_repo" --verdict PASS --allow-file "src/Old.ts"
  "$STAMP_GATE" security --workspace "$del_repo" --verdict PASS --critical 0 --important 0
  if "$STAMP_GATE" verify-pr-stamps --workspace "$del_repo" >/dev/null 2>&1; then
    echo "Deletion-only code branch must still require tdd-pass.json" >&2
    return 1
  fi
}

run_tests "$@"
