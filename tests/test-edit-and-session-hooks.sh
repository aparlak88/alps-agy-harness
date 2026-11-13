#!/usr/bin/env bash
# Alps AGY Harness - SessionStart & PreToolUse (pre-edit-guard) Hook Tests
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-helpers.sh"

SESSION_START="$REPO_ROOT/scripts/hooks/session-start.sh"
PRE_EDIT_GUARD="$REPO_ROOT/scripts/hooks/pre-edit-guard.sh"

test_session_start_injects_status_and_respects_harness_ignore() {
  [ -x "$SESSION_START" ] || { echo "session-start.sh missing or not executable: $SESSION_START" >&2; return 1; }

  local repo
  repo=$(make_temp_repo)

  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: init" --quiet

  git -C "$repo" checkout -b "feature/auth-service" --quiet

  # 1. Normal session start with missing canon and missing graphify
  local payload
  payload=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws]}')
  local out
  out=$(printf '%s' "$payload" | "$SESSION_START")

  # Verify nested protojson schema: .injectSteps[0].systemMessage.systemMessage
  local msg
  msg=$(printf '%s' "$out" | jq -r '.injectSteps[0].systemMessage.systemMessage // empty')
  [ -n "$msg" ] || { echo "Expected nested .injectSteps[0].systemMessage.systemMessage to be non-empty, got: $out" >&2; return 1; }

  assert_contains "$msg" "feature/auth-service" "Must contain active branch name"
  assert_contains "$msg" "glossary.md: missing" "Must report glossary missing"
  assert_contains "$msg" "flows.md: missing" "Must report flows missing"
  assert_contains "$msg" "lessons.md: missing" "Must report lessons missing"
  assert_contains "$msg" "Graphify Status: missing" "Must report graphify status"
  assert_contains "$msg" "run-quiet.sh" "Must mention run-quiet protocol"
  assert_contains "$msg" "jev" "Must mention jev protocol"

  # 2. Present canon files and graphify
  mkdir -p "$repo/docs/canon" "$repo/graphify-out"
  echo "# Glossary" > "$repo/docs/canon/glossary.md"
  echo "# Flows" > "$repo/docs/canon/flows.md"
  echo "# Lessons" > "$repo/docs/canon/lessons.md"
  echo '{"nodes":[],"edges":[]}' > "$repo/graphify-out/graph.json"

  out=$(printf '%s' "$payload" | "$SESSION_START")
  msg=$(printf '%s' "$out" | jq -r '.injectSteps[0].systemMessage.systemMessage')
  assert_contains "$msg" "glossary.md: present" "Must report glossary present"
  assert_contains "$msg" "flows.md: present" "Must report flows present"
  assert_contains "$msg" "lessons.md: present" "Must report lessons present"
  assert_contains "$msg" "Graphify Status: present" "Must report graphify present"

  # 2b. Active modelName in HOOK_INPUT is surfaced with classified Gemini 4 / Orchestrator family
  local model_payload model_out model_msg
  model_payload=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], modelName: "gemini-4-carbon-high"}')
  model_out=$(printf '%s' "$model_payload" | "$SESSION_START")
  model_msg=$(printf '%s' "$model_out" | jq -r '.injectSteps[0].systemMessage.systemMessage')
  assert_contains "$model_msg" "Active Session Model: gemini-4-carbon-high (family: carbon)" "SessionStart must surface active modelName and family"

  # 3. Test missing CLI warning via HARNESS_CHECK_BINS
  local warned_out
  warned_out=$(printf '%s' "$payload" | HARNESS_CHECK_BINS="nonexistent_harness_binary_123" "$SESSION_START")
  local warned_msg
  warned_msg=$(printf '%s' "$warned_out" | jq -r '.injectSteps[0].systemMessage.systemMessage')
  assert_contains "$warned_msg" "nonexistent_harness_binary_123" "Must warn about missing required binary"
  assert_contains "$warned_msg" "harness-doctor.sh" "Must suggest harness-doctor.sh"

  # 4. Respect .harness-ignore -> returns {}
  touch "$repo/.harness-ignore"
  local ignored_out
  ignored_out=$(printf '%s' "$payload" | "$SESSION_START")
  assert_eq "{}" "$ignored_out" "Must return {} immediately when .harness-ignore is present"
}

test_main_branch_blocks_src_edit_but_allows_spec_and_canon_draft() {
  [ -x "$PRE_EDIT_GUARD" ] || { echo "pre-edit-guard.sh missing or not executable: $PRE_EDIT_GUARD" >&2; return 1; }

  local repo
  repo=$(make_temp_repo)

  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: init" --quiet

  # Branch is main with commit HEAD
  # (a) src/Order.cs write_file -> deny
  local p_src
  p_src=$(jq -nc --arg ws "$repo" --arg path "$repo/src/Order.cs" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: "public class Order {}"}}}')
  local out_src
  out_src=$(printf '%s' "$p_src" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_src" ".decision" "deny" "Direct src write on main must be denied"

  # (b) src/Order.cs edit_file -> deny
  local p_edit
  p_edit=$(jq -nc --arg ws "$repo" --arg path "src/Order.cs" \
    '{workspacePaths: [$ws], toolCall: {name: "edit_file", args: {Path: $path, Replacement: "public class Order {}"}}}')
  local out_edit
  out_edit=$(printf '%s' "$p_edit" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_edit" ".decision" "deny" "Direct src edit on main must be denied"

  # (c) docs/superpowers/specs/2026-11-12-x.md with glossary -> allow
  local valid_spec_content
  valid_spec_content=$(cat << 'EOF'
# Feature Spec

Some spec content.

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| Clean Arch | Temiz Mimari |
EOF
)
  local p_spec
  p_spec=$(jq -nc --arg ws "$repo" --arg path "$repo/docs/superpowers/specs/2026-11-12-x.md" --arg content "$valid_spec_content" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: $content}}}')
  local out_spec
  out_spec=$(printf '%s' "$p_spec" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_spec" ".decision" "allow" "Spec drafting on main with glossary must be allowed"

  # (d) docs/canon/glossary.md draft on main -> allow
  local p_glossary
  p_glossary=$(jq -nc --arg ws "$repo" --arg path "docs/canon/glossary.md" --arg content "# Domain Glossary" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: $content}}}')
  local out_glossary
  out_glossary=$(printf '%s' "$p_glossary" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_glossary" ".decision" "allow" "Canon glossary draft on main must be allowed"

  # (e) docs/canon/flows.md with glossary -> allow
  local valid_flows_content
  valid_flows_content=$(cat << 'EOF'
# Business Flows

Flow details.

## Technical Glossary

| Term | Description |
| :--- | :--- |
| Saga | Distributed transaction |
EOF
)
  local p_flows
  p_flows=$(jq -nc --arg ws "$repo" --arg path "docs/canon/flows.md" --arg content "$valid_flows_content" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: $content}}}')
  local out_flows
  out_flows=$(printf '%s' "$p_flows" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_flows" ".decision" "allow" "Canon flows draft on main with glossary must be allowed"

  # (f) Unborn repo on main without any commits should not block initial files
  local unborn_repo
  unborn_repo=$(make_temp_repo)
  local p_unborn
  p_unborn=$(jq -nc --arg ws "$unborn_repo" --arg path "src/Program.cs" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: "class Program {}"}}}')
  local out_unborn
  out_unborn=$(printf '%s' "$p_unborn" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_unborn" ".decision" "allow" "Unborn repo without commits must not be locked by Rule 1"
}

test_write_file_requires_non_empty_technical_glossary() {
  [ -x "$PRE_EDIT_GUARD" ] || { echo "pre-edit-guard.sh missing or not executable: $PRE_EDIT_GUARD" >&2; return 1; }

  local repo
  repo=$(make_temp_repo)
  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: init" --quiet
  git -C "$repo" checkout -b "feature/doc-updates" --quiet

  # (a) Plan file without any glossary -> deny
  local no_glossary_content
  no_glossary_content=$(cat << 'EOF'
# Implementation Plan

Task details without glossary.
EOF
)
  local p1
  p1=$(jq -nc --arg ws "$repo" --arg path "docs/superpowers/plans/2026-11-12-plan.md" --arg content "$no_glossary_content" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: $content}}}')
  local out1
  out1=$(printf '%s' "$p1" | "$PRE_EDIT_GUARD")
  assert_json_field "$out1" ".decision" "deny" "Plan without glossary must be denied"

  # (b) Plan file with ONLY empty heading ## Teknik Terimler Sözlüğü (no terms) -> deny (Review Focus #3)
  local empty_heading_content
  empty_heading_content=$(cat << 'EOF'
# Implementation Plan

Task details.

## Teknik Terimler Sözlüğü
EOF
)
  local p2
  p2=$(jq -nc --arg ws "$repo" --arg path "docs/superpowers/plans/2026-11-12-plan.md" --arg content "$empty_heading_content" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: $content}}}')
  local out2
  out2=$(printf '%s' "$p2" | "$PRE_EDIT_GUARD")
  assert_json_field "$out2" ".decision" "deny" "Empty glossary heading must be denied"

  # (c) Plan file with valid glossary table -> allow
  local valid_plan_content
  valid_plan_content=$(cat << 'EOF'
# Implementation Plan

Task details.

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| Idempotency | Aynı işlemin tekrarlanabilirliği |
EOF
)
  local p3
  p3=$(jq -nc --arg ws "$repo" --arg path "docs/superpowers/plans/2026-11-12-plan.md" --arg content "$valid_plan_content" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: $content}}}')
  local out3
  out3=$(printf '%s' "$p3" | "$PRE_EDIT_GUARD")
  assert_json_field "$out3" ".decision" "allow" "Plan with valid glossary table must be allowed"

  # (d) README.md without glossary -> deny, with glossary -> allow
  local readme_no_glossary="# Project Overview"
  local p_readme_bad
  p_readme_bad=$(jq -nc --arg ws "$repo" --arg path "README.md" --arg content "$readme_no_glossary" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: $content}}}')
  local out_readme_bad
  out_readme_bad=$(printf '%s' "$p_readme_bad" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_readme_bad" ".decision" "deny" "README.md without glossary must be denied"

  local readme_good
  readme_good=$(cat << 'EOF'
# Project Overview

Introduction.

## Technical Glossary

| Term | Definition |
| :--- | :--- |
| AGY | Antigravity Platform |
EOF
)
  local p_readme_good
  p_readme_good=$(jq -nc --arg ws "$repo" --arg path "README.md" --arg content "$readme_good" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: $content}}}')
  local out_readme_good
  out_readme_good=$(printf '%s' "$p_readme_good" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_readme_good" ".decision" "allow" "README.md with glossary must be allowed"

  # (e) Excluded files: docs/canon/glossary.md and docs/parking-lot.md -> allow even without glossary
  local p_canon_glossary
  p_canon_glossary=$(jq -nc --arg ws "$repo" --arg path "docs/canon/glossary.md" --arg content "# Root Glossary" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: $content}}}')
  local out_canon_glossary
  out_canon_glossary=$(printf '%s' "$p_canon_glossary" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_canon_glossary" ".decision" "allow" "docs/canon/glossary.md is exempt from self-glossary"

  local p_parking
  p_parking=$(jq -nc --arg ws "$repo" --arg path "docs/parking-lot.md" --arg content "# Parking Lot Notes\n- Deferred item 1" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: $content}}}')
  local out_parking
  out_parking=$(printf '%s' "$p_parking" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_parking" ".decision" "allow" "docs/parking-lot.md is exempt from glossary"

  # (f) Append: true on documentation bypasses Rule 2
  local p_append
  p_append=$(jq -nc --arg ws "$repo" --arg path "docs/superpowers/plans/2026-11-12-plan.md" --arg content "Appended line" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: $content, Append: true}}}')
  local out_append
  out_append=$(printf '%s' "$p_append" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_append" ".decision" "allow" "Append mode must bypass glossary check"

  # (g) edit_file on documentation bypasses Rule 2
  local p_edit_doc
  p_edit_doc=$(jq -nc --arg ws "$repo" --arg path "docs/superpowers/plans/2026-11-12-plan.md" --arg rep "Edited section" \
    '{workspacePaths: [$ws], toolCall: {name: "edit_file", args: {Path: $path, Replacement: $rep}}}')
  local out_edit_doc
  out_edit_doc=$(printf '%s' "$p_edit_doc" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_edit_doc" ".decision" "allow" "edit_file must bypass glossary check"
}

test_dangerous_patterns_blocked_in_production_files() {
  [ -x "$PRE_EDIT_GUARD" ] || { echo "pre-edit-guard.sh missing or not executable: $PRE_EDIT_GUARD" >&2; return 1; }

  local repo
  repo=$(make_temp_repo)
  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: init" --quiet
  git -C "$repo" checkout -b "feature/auth-guard" --quiet

  # (a) Private key block in src/auth.ts -> deny
  local p_key
  p_key=$(jq -nc --arg ws "$repo" --arg path "src/auth.ts" \
    --arg content "-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEA0
-----END RSA PRIVATE KEY-----" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: $content}}}')
  local out_key
  out_key=$(printf '%s' "$p_key" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_key" ".decision" "deny" "Private key in production file must be denied"

  # (b) eval( in src/auth.ts -> deny
  local p_eval
  p_eval=$(jq -nc --arg ws "$repo" --arg path "src/auth.ts" \
    --arg content "export const run = (code: string) => eval(code);" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: $content}}}')
  local out_eval
  out_eval=$(printf '%s' "$p_eval" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_eval" ".decision" "deny" "eval() in production file must be denied"

  # (c) dangerouslySetInnerHTML in src/Component.tsx -> deny
  local p_danger
  p_danger=$(jq -nc --arg ws "$repo" --arg path "src/Component.tsx" \
    --arg content "<div dangerouslySetInnerHTML={{ __html: rawHtml }} />" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: $content}}}')
  local out_danger
  out_danger=$(printf '%s' "$p_danger" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_danger" ".decision" "deny" "dangerouslySetInnerHTML in production file must be denied"

  # (d) Raw SQL concatenation in src/repo.ts -> deny, while SQL arithmetic is allowed
  local p_sql
  p_sql=$(jq -nc --arg ws "$repo" --arg path "src/repo.ts" \
    --arg content 'const sql = "SELECT * FROM users WHERE id = " + userId;' \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: $content}}}')
  local out_sql
  out_sql=$(printf '%s' "$p_sql" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_sql" ".decision" "deny" "Raw SQL concatenation must be denied"

  local p_sql_arith
  p_sql_arith=$(jq -nc --arg ws "$repo" --arg path "src/repo.ts" \
    --arg content 'const sql = "SELECT count + 1 FROM orders";' \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: $content}}}')
  local out_sql_arith
  out_sql_arith=$(printf '%s' "$p_sql_arith" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_sql_arith" ".decision" "allow" "Parameterized/static SQL arithmetic must be allowed"

  # (e) edit_file with eval( in Replacement -> deny
  local p_edit_eval
  p_edit_eval=$(jq -nc --arg ws "$repo" --arg path "src/auth.ts" \
    --arg rep "const result = eval(payload);" \
    '{workspacePaths: [$ws], toolCall: {name: "edit_file", args: {Path: $path, Replacement: $rep}}}')
  local out_edit_eval
  out_edit_eval=$(printf '%s' "$p_edit_eval" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_edit_eval" ".decision" "deny" "edit_file with eval() must be denied"

  # (f) bypassSecurityTrustHtml in src/viewer.ts -> force_ask
  local p_angular
  p_angular=$(jq -nc --arg ws "$repo" --arg path "src/viewer.ts" \
    --arg content "return this.sanitizer.bypassSecurityTrustHtml(cleanHtml);" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: $content}}}')
  local out_angular
  out_angular=$(printf '%s' "$p_angular" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_angular" ".decision" "force_ask" "bypassSecurityTrust pattern must trigger force_ask"

  # (g) Safe code in src/auth.ts -> allow
  local p_safe
  p_safe=$(jq -nc --arg ws "$repo" --arg path "src/auth.ts" \
    --arg content "export const login = (user: string) => ({ user, token: 'jwt' });" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: $content}}}')
  local out_safe
  out_safe=$(printf '%s' "$p_safe" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_safe" ".decision" "allow" "Safe code must be allowed"

  # (h) Dangerous pattern inside tests/ is exempt -> allow
  local p_test_file
  p_test_file=$(jq -nc --arg ws "$repo" --arg path "tests/auth.test.ts" \
    --arg content "const testEval = eval('1+1');" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: $content}}}')
  local out_test_file
  out_test_file=$(printf '%s' "$p_test_file" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_test_file" ".decision" "allow" "Dangerous patterns in tests/ must be allowed"
}

test_external_path_and_superpowers_and_harness_bypass() {
  [ -x "$PRE_EDIT_GUARD" ] || { echo "pre-edit-guard.sh missing or not executable: $PRE_EDIT_GUARD" >&2; return 1; }

  local repo
  repo=$(make_temp_repo)
  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: init" --quiet

  # (a) External path outside workspace (e.g. Antigravity brain artifact) -> allow
  local brain_path="/Users/test/.gemini/antigravity/brain/session-123/task.md"
  local p_brain
  p_brain=$(jq -nc --arg ws "$repo" --arg path "$brain_path" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: "brain note"}}}')
  local out_brain
  out_brain=$(printf '%s' "$p_brain" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_brain" ".decision" "allow" "Brain artifacts outside workspace must be allowed"

  # (b) .superpowers/ path inside workspace -> allow even without glossary or on main
  local p_sp
  p_sp=$(jq -nc --arg ws "$repo" --arg path "$repo/.superpowers/sdd/task-3-report.md" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: "internal report"}}}')
  local out_sp
  out_sp=$(printf '%s' "$p_sp" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_sp" ".decision" "allow" ".superpowers internal files must be allowed"

  # (c) .harness/ path inside workspace -> allow
  local p_harness
  p_harness=$(jq -nc --arg ws "$repo" --arg path ".harness/state/main/subagent-dispatch.json" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: "{}"}}}')
  local out_harness
  out_harness=$(printf '%s' "$p_harness" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_harness" ".decision" "allow" ".harness internal files must be allowed"

  # (d) .harness-ignore opt-out in repo -> allow everything
  touch "$repo/.harness-ignore"
  local p_ignored
  p_ignored=$(jq -nc --arg ws "$repo" --arg path "src/Order.cs" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: "public class Order {}"}}}')
  local out_ignored
  out_ignored=$(printf '%s' "$p_ignored" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_ignored" ".decision" "allow" "When .harness-ignore is present, all writes must be allowed"
}

run_tests
