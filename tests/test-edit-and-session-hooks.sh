#!/usr/bin/env bash
# Alps AGY Harness - SessionStart & PreToolUse (pre-edit-guard) Hook Tests
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-helpers.sh"

SESSION_START="$REPO_ROOT/scripts/hooks/session-start.sh"
PRE_EDIT_GUARD="$REPO_ROOT/scripts/hooks/pre-edit-guard.sh"
PRE_SUBAGENT_GUARD="$REPO_ROOT/scripts/hooks/pre-subagent-guard.sh"
STAMP_GATE="$REPO_ROOT/scripts/stamp-gate.sh"

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

test_large_utf8_multiline_payload_completes_under_2s_on_bin_bash() {
  local repo
  repo=$(make_temp_repo)
  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: init" --quiet
  git -C "$repo" checkout -b "feat/utf8-perf" --quiet

  "$STAMP_GATE" dispatch --role "Big UTF-8 Worker" --type "self" --tier "bounded_execution" --workspace "$repo"

  python3 -B - "$repo" "$PRE_EDIT_GUARD" "$PRE_SUBAGENT_GUARD" <<'PY'
import json
import os
import subprocess
import sys
import time

repo, pre_edit, pre_subagent = sys.argv[1], sys.argv[2], sys.argv[3]
chunk = "Türkçe ğüşıöçĞÜŞİÖÇ 🚀 çok satırlı içerik   \t\n  const val = 42;\n"
big_text = chunk * 1800
assert len(big_text.encode("utf-8")) >= 120 * 1024

env = dict(os.environ)
env["HARNESS_DISABLE_DAEMON"] = "1"
env["HARNESS_AUTO_START_DAEMON"] = "0"

# 1. >= 120 KB UTF-8 write_file payload through /bin/bash
edit_payload = json.dumps(
    {
        "workspacePaths": [repo],
        "toolCall": {
            "name": "write_file",
            "args": {"Path": os.path.join(repo, "src/BigModule.ts"), "Content": big_text},
        },
    },
    ensure_ascii=False,
)
t0 = time.monotonic()
p1 = subprocess.run(["/bin/bash", pre_edit], input=edit_payload, text=True, capture_output=True, env=env, timeout=5)
dt1 = time.monotonic() - t0
assert p1.returncode == 0, f"pre-edit failed: {p1.stderr}"
assert dt1 < 2.0, f"pre-edit took too long on /bin/bash: {dt1:.3f}s"
assert json.loads(p1.stdout).get("decision") == "allow", p1.stdout

# 2. >= 120 KB UTF-8 invoke_subagent payload through /bin/bash
sub_payload = json.dumps(
    {
        "workspacePaths": [repo],
        "toolCall": {
            "name": "invoke_subagent",
            "args": {"TypeName": "self", "Role": "Big UTF-8 Worker", "Prompt": big_text},
        },
    },
    ensure_ascii=False,
)
t1 = time.monotonic()
p2 = subprocess.run(["/bin/bash", pre_subagent], input=sub_payload, text=True, capture_output=True, env=env, timeout=5)
dt2 = time.monotonic() - t1
assert p2.returncode == 0, f"pre-subagent failed: {p2.stderr}"
assert dt2 < 2.0, f"pre-subagent took too long on /bin/bash: {dt2:.3f}s"
parsed = json.loads(p2.stdout)
assert parsed.get("decision") == "allow", parsed
ow = parsed.get("overwrite") or {}
assert ow.get("Model") == "flash", ow
assert ow.get("Prompt", "").startswith("[EFFORT_PROFILE: MEDIUM"), ow.get("Prompt", "")[:80]
assert ow.get("Prompt", "").endswith(chunk), "UTF-8 multiline suffix truncated"
PY
}

test_sibling_git_worktree_pre_edit_enforces_rules_while_unrelated_external_allows() {
  local main_repo wt_parent wt_feat other_repo
  main_repo=$(make_temp_repo)
  echo "init" > "$main_repo/README.md"
  git -C "$main_repo" add README.md
  git -C "$main_repo" commit -m "chore: init" --quiet

  wt_parent=$(mktemp -d "${TMPDIR:-/tmp}/harness-wt-edit.XXXXXX")
  echo "$wt_parent" >> "$_HARNESS_TEMP_TRACKER"
  wt_feat="$wt_parent/kedo-admin"
  git -C "$main_repo" worktree add "$wt_feat" -b "feat/admin" --quiet

  other_repo=$(make_temp_repo)
  echo "other" > "$other_repo/README.md"
  git -C "$other_repo" add README.md
  git -C "$other_repo" commit -m "chore: other init" --quiet
  git -C "$other_repo" checkout -b "feat/other" --quiet

  # 1. Sibling worktree doc without glossary -> deny (even though workspacePaths[0] is main_repo on main)
  local p_wt_doc out_wt_doc
  p_wt_doc=$(jq -nc --arg ws "$main_repo" --arg path "$wt_feat/docs/plan.md" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: "# Admin Plan\n\nNo glossary."}}}')
  out_wt_doc=$(printf '%s' "$p_wt_doc" | HARNESS_DISABLE_DAEMON=1 "$PRE_EDIT_GUARD")
  assert_json_field "$out_wt_doc" ".decision" "deny" "Sibling worktree doc without glossary must be denied"
  assert_contains "$(printf '%s' "$out_wt_doc" | jq -r '.reason')" "Glossary"

  # 2. Sibling worktree dangerous eval() in non-existent src/ -> deny
  local p_wt_eval out_wt_eval
  p_wt_eval=$(jq -nc --arg ws "$main_repo" --arg path "$wt_feat/src/eval.ts" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: "export const bad = (s: string) => eval(s);"}}}')
  out_wt_eval=$(printf '%s' "$p_wt_eval" | HARNESS_DISABLE_DAEMON=1 "$PRE_EDIT_GUARD")
  assert_json_field "$out_wt_eval" ".decision" "deny" "Sibling worktree eval() must be denied"

  # 3. Sibling worktree clean code on feat/admin -> allow (not blocked by main_repo main lock)
  local p_wt_clean out_wt_clean
  p_wt_clean=$(jq -nc --arg ws "$main_repo" --arg path "$wt_feat/src/clean.ts" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: "export const ok = 1;"}}}')
  out_wt_clean=$(printf '%s' "$p_wt_clean" | HARNESS_DISABLE_DAEMON=1 "$PRE_EDIT_GUARD")
  assert_json_field "$out_wt_clean" ".decision" "allow" "Clean code in sibling feature worktree must be allowed"

  # 4. Write directly in main_repo on main -> deny
  local p_main_src out_main_src
  p_main_src=$(jq -nc --arg ws "$main_repo" --arg path "$main_repo/src/bad.ts" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: "export const x = 1;"}}}')
  out_main_src=$(printf '%s' "$p_main_src" | HARNESS_DISABLE_DAEMON=1 "$PRE_EDIT_GUARD")
  assert_json_field "$out_main_src" ".decision" "deny" "Direct write to main_repo must stay locked"

  # 5. Unrelated external git repo -> allow (external path behavior preserved)
  local p_ext out_ext
  p_ext=$(jq -nc --arg ws "$main_repo" --arg path "$other_repo/src/eval.ts" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: "export const bad = eval(\"1\");"}}}')
  out_ext=$(printf '%s' "$p_ext" | HARNESS_DISABLE_DAEMON=1 "$PRE_EDIT_GUARD")
  assert_json_field "$out_ext" ".decision" "allow" "Unrelated external git repo must preserve external allow behavior"
}

test_hook_input_cwd_relative_edit_in_sibling_worktree() {
  [ -x "$PRE_EDIT_GUARD" ] || { echo "pre-edit-guard.sh missing or not executable: $PRE_EDIT_GUARD" >&2; return 1; }
  export HARNESS_DISABLE_DAEMON=1

  local main_repo wt_parent wt_feat other_repo
  main_repo=$(make_temp_repo)
  echo "init" > "$main_repo/README.md"
  git -C "$main_repo" add README.md
  git -C "$main_repo" commit -m "chore: init" --quiet

  wt_parent=$(mktemp -d "${TMPDIR:-/tmp}/harness-wt-cwd-edit.XXXXXX")
  echo "$wt_parent" >> "$_HARNESS_TEMP_TRACKER"
  wt_feat="$wt_parent/worker-edit"
  git -C "$main_repo" worktree add "$wt_feat" -b "feat/cwd-edit" --quiet

  other_repo=$(make_temp_repo)
  echo "other" > "$other_repo/README.md"
  git -C "$other_repo" add README.md
  git -C "$other_repo" commit -m "chore: other" --quiet
  git -C "$other_repo" checkout -b "feat/other" --quiet

  # 1. Relative write_file with HOOK_INPUT.cwd in sibling worktree -> allow (not blocked by main_repo main lock!)
  local out_rel_clean out_rel_no_cwd out_rel_doc out_rel_eval out_rel_ext
  out_rel_clean=$(jq -nc --arg ws "$main_repo" --arg cwd "$wt_feat" \
    '{workspacePaths: [$ws], cwd: $cwd, toolCall: {name: "write_file", args: {Path: "src/Clean.ts", Content: "export const ok = 1;"}}}' \
    | "$PRE_EDIT_GUARD")
  assert_json_field "$out_rel_clean" ".decision" "allow" "Relative write_file in cwd sibling feature worktree must allow"

  # 2. Same relative write_file without cwd -> resolves to main_repo on main -> deny
  out_rel_no_cwd=$(jq -nc --arg ws "$main_repo" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: "src/Clean.ts", Content: "export const ok = 1;"}}}' \
    | "$PRE_EDIT_GUARD")
  assert_json_field "$out_rel_no_cwd" ".decision" "deny" "Relative write_file without cwd resolves to main_repo on main -> deny"

  # 3. Relative doc without glossary in cwd sibling worktree -> deny
  out_rel_doc=$(jq -nc --arg ws "$main_repo" --arg cwd "$wt_feat" \
    '{workspacePaths: [$ws], cwd: $cwd, toolCall: {name: "write_file", args: {Path: "docs/plan.md", Content: "# Plan\n\nNo glossary."}}}' \
    | "$PRE_EDIT_GUARD")
  assert_json_field "$out_rel_doc" ".decision" "deny" "Relative doc missing glossary in cwd sibling worktree must deny"
  assert_contains "$(printf '%s' "$out_rel_doc" | jq -r '.reason')" "Glossary"

  # 4. Relative dangerous eval() in cwd sibling worktree -> deny
  out_rel_eval=$(jq -nc --arg ws "$main_repo" --arg cwd "$wt_feat" \
    '{workspacePaths: [$ws], cwd: $cwd, toolCall: {name: "write_file", args: {Path: "src/Bad.ts", Content: "export const bad = eval(\"1\");"}}}' \
    | "$PRE_EDIT_GUARD")
  assert_json_field "$out_rel_eval" ".decision" "deny" "Relative eval() in cwd sibling worktree must deny"

  # 5. Relative edit in unrelated external repo via cwd preserves external allow
  out_rel_ext=$(jq -nc --arg ws "$main_repo" --arg cwd "$other_repo" \
    '{workspacePaths: [$ws], cwd: $cwd, toolCall: {name: "write_file", args: {Path: "src/Bad.ts", Content: "export const bad = eval(\"1\");"}}}' \
    | "$PRE_EDIT_GUARD")
  assert_json_field "$out_rel_ext" ".decision" "allow" "Relative edit in unrelated external repo via cwd must preserve external allow"
}

test_nested_git_worktree_pre_edit_enforces_rules() {
  [ -x "$PRE_EDIT_GUARD" ] || { echo "pre-edit-guard.sh missing or not executable: $PRE_EDIT_GUARD" >&2; return 1; }
  local DAEMON_PY="$REPO_ROOT/sidecars/harness-daemon/daemon.py"
  [ -x "$DAEMON_PY" ] || { echo "daemon.py missing or not executable: $DAEMON_PY" >&2; return 1; }

  local main_repo wt_nested wt_ignored other_nested
  main_repo=$(make_temp_repo)
  echo "init" > "$main_repo/README.md"
  git -C "$main_repo" add README.md
  git -C "$main_repo" commit -m "chore: init" --quiet

  mkdir -p "$main_repo/.worktrees"
  wt_nested="$main_repo/.worktrees/worker-nested"
  wt_ignored="$main_repo/.worktrees/worker-ignored"
  git -C "$main_repo" worktree add "$wt_nested" -b "feat/nested" --quiet
  git -C "$main_repo" worktree add "$wt_ignored" -b "feat/ignored" --quiet
  : > "$wt_ignored/.harness-ignore"

  other_nested="$main_repo/vendor/other-repo"
  mkdir -p "$other_nested"
  (
    cd "$other_nested"
    git init --quiet -b main 2>/dev/null || (git init --quiet && git checkout -b main --quiet)
    git config user.name "Harness Test"
    git config user.email "harness@test.local"
    echo "other" > README.md
    git add README.md
    git commit -m "chore: other" --quiet
    git checkout -b "feat/other" --quiet
  )

  # 1. Cold fallback (HARNESS_DISABLE_DAEMON=1): absolute + relative writes inside nested .worktrees/worker-nested
  local p_abs_clean p_rel_clean p_abs_eval p_rel_eval p_abs_doc p_rel_doc p_doc_good p_main_direct p_ignored
  local out_abs_clean out_rel_clean out_abs_eval out_rel_eval out_abs_doc out_rel_doc out_doc_good out_main_direct out_ignored

  p_abs_clean=$(jq -nc --arg ws "$main_repo" --arg path "$wt_nested/src/CleanAbs.ts" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: "export const ok = 1;"}}}')
  out_abs_clean=$(printf '%s' "$p_abs_clean" | HARNESS_DISABLE_DAEMON=1 "$PRE_EDIT_GUARD")
  assert_json_field "$out_abs_clean" ".decision" "allow" "Absolute clean write in nested feature worktree must be allowed while main_repo is on main"

  p_rel_clean=$(jq -nc --arg ws "$main_repo" --arg cwd "$wt_nested" \
    '{workspacePaths: [$ws], cwd: $cwd, toolCall: {name: "write_file", args: {Path: "src/CleanRel.ts", Content: "export const rel = 1;"}}}')
  out_rel_clean=$(printf '%s' "$p_rel_clean" | HARNESS_DISABLE_DAEMON=1 "$PRE_EDIT_GUARD")
  assert_json_field "$out_rel_clean" ".decision" "allow" "Relative clean write via cwd in nested feature worktree must be allowed while main_repo is on main"

  p_abs_eval=$(jq -nc --arg ws "$main_repo" --arg path "$wt_nested/src/BadAbs.ts" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: "export const bad = eval(\"1\");"}}}')
  out_abs_eval=$(printf '%s' "$p_abs_eval" | HARNESS_DISABLE_DAEMON=1 "$PRE_EDIT_GUARD")
  assert_json_field "$out_abs_eval" ".decision" "deny" "Absolute eval() in nested worktree must be denied"
  assert_contains "$(printf '%s' "$out_abs_eval" | jq -r '.reason')" "eval()" "Nested worktree deny must be Rule 3 eval() error, not main branch lock"

  p_rel_eval=$(jq -nc --arg ws "$main_repo" --arg cwd "$wt_nested" \
    '{workspacePaths: [$ws], cwd: $cwd, toolCall: {name: "write_file", args: {Path: "src/BadRel.ts", Content: "export const bad = eval(\"1\");"}}}')
  out_rel_eval=$(printf '%s' "$p_rel_eval" | HARNESS_DISABLE_DAEMON=1 "$PRE_EDIT_GUARD")
  assert_json_field "$out_rel_eval" ".decision" "deny" "Relative eval() in nested worktree must be denied"
  assert_contains "$(printf '%s' "$out_rel_eval" | jq -r '.reason')" "eval()"

  p_abs_doc=$(jq -nc --arg ws "$main_repo" --arg path "$wt_nested/docs/plan.md" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: "# Nested Plan\n\nNo glossary."}}}')
  out_abs_doc=$(printf '%s' "$p_abs_doc" | HARNESS_DISABLE_DAEMON=1 "$PRE_EDIT_GUARD")
  assert_json_field "$out_abs_doc" ".decision" "deny" "Absolute doc without glossary in nested worktree must be denied"
  assert_contains "$(printf '%s' "$out_abs_doc" | jq -r '.reason')" "Glossary" "Nested worktree doc deny must enforce Rule 2 Glossary"

  p_rel_doc=$(jq -nc --arg ws "$main_repo" --arg cwd "$wt_nested" \
    '{workspacePaths: [$ws], cwd: $cwd, toolCall: {name: "write_file", args: {Path: "docs/plan-rel.md", Content: "# Nested Rel Plan\n\nNo glossary."}}}')
  out_rel_doc=$(printf '%s' "$p_rel_doc" | HARNESS_DISABLE_DAEMON=1 "$PRE_EDIT_GUARD")
  assert_json_field "$out_rel_doc" ".decision" "deny" "Relative doc without glossary in nested worktree must be denied"
  assert_contains "$(printf '%s' "$out_rel_doc" | jq -r '.reason')" "Glossary"

  local valid_doc_content
  valid_doc_content=$(cat <<'EOF'
# Nested Plan

Details.

## Technical Glossary

| Term | Description |
| :--- | :--- |
| Worktree | Linked git checkout |
EOF
)
  p_doc_good=$(jq -nc --arg ws "$main_repo" --arg path "$wt_nested/docs/plan-good.md" --arg content "$valid_doc_content" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: $content}}}')
  out_doc_good=$(printf '%s' "$p_doc_good" | HARNESS_DISABLE_DAEMON=1 "$PRE_EDIT_GUARD")
  assert_json_field "$out_doc_good" ".decision" "allow" "Nested worktree doc with glossary must be allowed"

  p_main_direct=$(jq -nc --arg ws "$main_repo" --arg path "$main_repo/src/DirectMain.ts" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: "export const m = 1;"}}}')
  out_main_direct=$(printf '%s' "$p_main_direct" | HARNESS_DISABLE_DAEMON=1 "$PRE_EDIT_GUARD")
  assert_json_field "$out_main_direct" ".decision" "deny" "Direct write in main_repo on main must remain denied"

  p_ignored=$(jq -nc --arg ws "$main_repo" --arg path "$wt_ignored/src/Ignored.ts" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: "export const bad = eval(\"1\");"}}}')
  out_ignored=$(printf '%s' "$p_ignored" | HARNESS_DISABLE_DAEMON=1 "$PRE_EDIT_GUARD")
  assert_json_field "$out_ignored" ".decision" "allow" "Nested linked worktree with .harness-ignore must allow"

  # 2. Direct Python on_worktree_resolved callback parity (and non-resolution of unrelated nested repo)
  python3 -B - "$REPO_ROOT/scripts/lib" "$main_repo" "$wt_nested" "$other_nested" <<'PY'
import os
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
import harness_core

main_repo = Path(sys.argv[2])
wt_nested = Path(sys.argv[3])
other_nested = Path(sys.argv[4])
expected_wt = Path(os.path.realpath(str(wt_nested)))

seen_abs = []
res_abs = harness_core.evaluate_pre_edit(
    main_repo,
    {"toolCall": {"name": "write_file", "args": {"Path": str(wt_nested / "src" / "CbAbs.ts"), "Content": "export const x = 1;"}}},
    on_worktree_resolved=seen_abs.append,
)
assert res_abs.get("decision") == "allow", res_abs
assert seen_abs == [expected_wt], f"Expected on_worktree_resolved={[expected_wt]}, got {seen_abs}"

seen_rel = []
res_rel = harness_core.evaluate_pre_edit(
    main_repo,
    {"cwd": str(wt_nested), "toolCall": {"name": "write_file", "args": {"Path": "src/CbRel.ts", "Content": "export const y = 1;"}}},
    on_worktree_resolved=seen_rel.append,
)
assert res_rel.get("decision") == "allow", res_rel
assert seen_rel == [expected_wt], f"Expected relative on_worktree_resolved={[expected_wt]}, got {seen_rel}"

seen_other = []
res_other = harness_core.evaluate_pre_edit(
    main_repo,
    {"toolCall": {"name": "write_file", "args": {"Path": str(other_nested / "src" / "Other.ts"), "Content": "export const z = 1;"}}},
    on_worktree_resolved=seen_other.append,
)
assert res_other.get("decision") == "deny", res_other
assert seen_other == [], f"Unrelated nested git repo must not resolve as linked worktree: {seen_other}"
PY

  # 3. Warm daemon parity + auto-registration of nested worktree
  _NESTED_SOCK_DIR=$(mktemp -d "/tmp/hd-nested.XXXXXX")
  _NESTED_DATA_DIR=$(mktemp -d "${TMPDIR:-/tmp}/hd-nested-data.XXXXXX")
  _NESTED_DAEMON_PID=""
  local sock_path="$_NESTED_SOCK_DIR/d.sock"
  _nested_wt_cleanup() {
    if [ -n "${_NESTED_DAEMON_PID:-}" ]; then
      kill "$_NESTED_DAEMON_PID" 2>/dev/null || true
      wait "$_NESTED_DAEMON_PID" 2>/dev/null || true
      _NESTED_DAEMON_PID=""
    fi
    rm -rf "${_NESTED_SOCK_DIR:-}" "${_NESTED_DATA_DIR:-}" 2>/dev/null || true
  }
  trap _nested_wt_cleanup EXIT INT TERM

  HARNESS_DAEMON_SOCK="$sock_path" \
  HARNESS_DAEMON_DATA_DIR="$_NESTED_DATA_DIR" \
  HARNESS_SKIP_SHELL_PATH_SYNC="1" \
  HARNESS_DAEMON_POLL_INTERVAL_SEC="0.1" \
  python3 -B "$DAEMON_PY" >/dev/null 2>&1 &
  _NESTED_DAEMON_PID=$!

  local tries=0 ready=0
  while [ "$tries" -lt 40 ]; do
    if [ -S "$sock_path" ] && curl -fsS --max-time 0.2 --unix-socket "$sock_path" "http://localhost/health" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 0.1
    tries=$((tries + 1))
  done
  [ "$ready" -eq 1 ] || { echo "Ephemeral daemon did not start for nested worktree test" >&2; return 1; }

  local d_abs_clean d_rel_clean d_abs_eval d_abs_doc active_cnt
  d_abs_clean=$(printf '%s' "$p_abs_clean" | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_EDIT_GUARD")
  assert_json_field "$d_abs_clean" ".decision" "allow" "Warm daemon must allow clean absolute write in nested worktree"

  d_rel_clean=$(printf '%s' "$p_rel_clean" | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_EDIT_GUARD")
  assert_json_field "$d_rel_clean" ".decision" "allow" "Warm daemon must allow clean relative write in nested worktree"

  d_abs_eval=$(printf '%s' "$p_abs_eval" | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_EDIT_GUARD")
  assert_json_field "$d_abs_eval" ".decision" "deny" "Warm daemon must deny eval() in nested worktree"
  assert_contains "$(printf '%s' "$d_abs_eval" | jq -r '.reason')" "eval()"

  d_abs_doc=$(printf '%s' "$p_abs_doc" | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_EDIT_GUARD")
  assert_json_field "$d_abs_doc" ".decision" "deny" "Warm daemon must deny doc without glossary in nested worktree"
  assert_contains "$(printf '%s' "$d_abs_doc" | jq -r '.reason')" "Glossary"

  active_cnt=$(curl -fsS --unix-socket "$sock_path" "http://localhost/health" | jq -r '.activeWorkspaces')
  [ "$active_cnt" -ge 2 ] || { echo "Expected nested worktree auto-registered in daemon (activeWorkspaces=$active_cnt)" >&2; return 1; }
}

test_git_submodule_pre_edit_resolves_submodule_branch_independently() {
  [ -x "$PRE_EDIT_GUARD" ] || { echo "pre-edit-guard.sh missing or not executable: $PRE_EDIT_GUARD" >&2; return 1; }
  local DAEMON_PY="$REPO_ROOT/sidecars/harness-daemon/daemon.py"
  [ -x "$DAEMON_PY" ] || { echo "daemon.py missing or not executable: $DAEMON_PY" >&2; return 1; }

  local super_repo sub_origin sub_path
  super_repo=$(make_temp_repo)
  echo "super" > "$super_repo/README.md"
  git -C "$super_repo" add README.md
  git -C "$super_repo" commit -m "chore: init super" --quiet

  sub_origin=$(make_temp_repo)
  echo "sub" > "$sub_origin/README.md"
  git -C "$sub_origin" add README.md
  git -C "$sub_origin" commit -m "chore: init sub" --quiet

  git -C "$super_repo" -c protocol.file.allow=always submodule add --quiet "$sub_origin" libs/submod
  git -C "$super_repo" commit -m "chore: add submodule" --quiet
  sub_path="$super_repo/libs/submod"

  # Case A: superproject on main, submodule on fix/sub-task -> edits inside submodule ALLOWED, superproject main still DENIED
  git -C "$sub_path" checkout -b "fix/sub-task" --quiet

  local p_sub_clean p_sub_eval p_super_main out_sub_clean out_sub_eval out_super_main
  p_sub_clean=$(jq -nc --arg ws "$super_repo" --arg path "$sub_path/src/Sub.ts" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: "export const ok = 1;"}}}')
  out_sub_clean=$(printf '%s' "$p_sub_clean" | HARNESS_DISABLE_DAEMON=1 "$PRE_EDIT_GUARD")
  assert_json_field "$out_sub_clean" ".decision" "allow" "Clean write in submodule on fix/* must be allowed while superproject is on main"

  p_sub_eval=$(jq -nc --arg ws "$super_repo" --arg path "$sub_path/src/BadSub.ts" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: "export const bad = eval(\"1\");"}}}')
  out_sub_eval=$(printf '%s' "$p_sub_eval" | HARNESS_DISABLE_DAEMON=1 "$PRE_EDIT_GUARD")
  assert_json_field "$out_sub_eval" ".decision" "deny" "eval() in submodule must still be denied by Rule 3"
  assert_contains "$(printf '%s' "$out_sub_eval" | jq -r '.reason')" "eval()"

  p_super_main=$(jq -nc --arg ws "$super_repo" --arg path "$super_repo/src/Super.ts" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: "export const x = 1;"}}}')
  out_super_main=$(printf '%s' "$p_super_main" | HARNESS_DISABLE_DAEMON=1 "$PRE_EDIT_GUARD")
  assert_json_field "$out_super_main" ".decision" "deny" "Direct write in superproject on main must remain denied"

  # Case B: superproject on feat/super-task, submodule on main -> edits inside submodule DENIED (submodule main lock!), superproject ALLOWED
  git -C "$super_repo" checkout -b "feat/super-task" --quiet
  git -C "$sub_path" checkout main --quiet

  local out_sub_locked out_super_feat
  out_sub_locked=$(printf '%s' "$p_sub_clean" | HARNESS_DISABLE_DAEMON=1 "$PRE_EDIT_GUARD")
  assert_json_field "$out_sub_locked" ".decision" "deny" "Write inside submodule on main must be denied even when superproject is on feat/*"
  assert_contains "$(printf '%s' "$out_sub_locked" | jq -r '.reason')" "branch 'main'"

  out_super_feat=$(printf '%s' "$p_super_main" | HARNESS_DISABLE_DAEMON=1 "$PRE_EDIT_GUARD")
  assert_json_field "$out_super_feat" ".decision" "allow" "Write in superproject on feat/* must be allowed"

  # Case C: Warm daemon parity
  _SUBMOD_SOCK_DIR=$(mktemp -d "/tmp/hd-submod.XXXXXX")
  _SUBMOD_DATA_DIR=$(mktemp -d "${TMPDIR:-/tmp}/hd-submod-data.XXXXXX")
  _SUBMOD_DAEMON_PID=""
  local sock_path="$_SUBMOD_SOCK_DIR/d.sock"
  _submod_cleanup() {
    if [ -n "${_SUBMOD_DAEMON_PID:-}" ]; then
      kill "$_SUBMOD_DAEMON_PID" 2>/dev/null || true
      wait "$_SUBMOD_DAEMON_PID" 2>/dev/null || true
      _SUBMOD_DAEMON_PID=""
    fi
    rm -rf "${_SUBMOD_SOCK_DIR:-}" "${_SUBMOD_DATA_DIR:-}" 2>/dev/null || true
  }
  trap _submod_cleanup EXIT INT TERM

  HARNESS_DAEMON_SOCK="$sock_path" \
  HARNESS_DAEMON_DATA_DIR="$_SUBMOD_DATA_DIR" \
  HARNESS_SKIP_SHELL_PATH_SYNC="1" \
  HARNESS_DAEMON_POLL_INTERVAL_SEC="0.1" \
  python3 -B "$DAEMON_PY" >/dev/null 2>&1 &
  _SUBMOD_DAEMON_PID=$!

  local tries=0 ready=0
  while [ "$tries" -lt 40 ]; do
    if [ -S "$sock_path" ] && curl -fsS --max-time 0.2 --unix-socket "$sock_path" "http://localhost/health" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 0.1
    tries=$((tries + 1))
  done
  [ "$ready" -eq 1 ] || { echo "Ephemeral daemon did not start for submodule test" >&2; return 1; }

  local d_sub_locked d_sub_allowed
  d_sub_locked=$(printf '%s' "$p_sub_clean" | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_EDIT_GUARD")
  assert_json_field "$d_sub_locked" ".decision" "deny" "Warm daemon must deny write in submodule on main"

  git -C "$super_repo" checkout main --quiet
  git -C "$sub_path" checkout "fix/sub-task" --quiet

  d_sub_allowed=$(printf '%s' "$p_sub_clean" | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_EDIT_GUARD")
  assert_json_field "$d_sub_allowed" ".decision" "allow" "Warm daemon must allow write in submodule on fix/* while superproject is on main"
}

test_session_start_swarm_protocol_branch_guard_and_detached_head() {
  [ -x "$SESSION_START" ] || { echo "session-start.sh missing or not executable: $SESSION_START" >&2; return 1; }
  export HARNESS_DISABLE_DAEMON=1

  local repo
  repo=$(make_temp_repo)

  # 1. Unborn main -> Swarm Worker Mode present, no [BRANCH GUARD], no [DETACHED HEAD]
  local msg_unborn
  msg_unborn=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws]}' | "$SESSION_START" | jq -r '.injectSteps[0].systemMessage.systemMessage')
  assert_contains "$msg_unborn" "Swarm Worker Mode" "SessionStart must inject Swarm Worker Mode protocol"
  assert_not_contains "$msg_unborn" "[BRANCH GUARD]" "Unborn main must not emit [BRANCH GUARD]"
  assert_not_contains "$msg_unborn" "[DETACHED HEAD]" "Unborn main must not emit [DETACHED HEAD]"

  # 2. Committed main -> [BRANCH GUARD] present, no [DETACHED HEAD]
  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: init" --quiet
  local msg_main
  msg_main=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws]}' | "$SESSION_START" | jq -r '.injectSteps[0].systemMessage.systemMessage')
  assert_contains "$msg_main" "Swarm Worker Mode"
  assert_contains "$msg_main" "[BRANCH GUARD]" "Committed main must emit [BRANCH GUARD]"
  assert_not_contains "$msg_main" "[DETACHED HEAD]"

  # 3. Detached HEAD -> [DETACHED HEAD] present, no [BRANCH GUARD]
  git -C "$repo" checkout --detach --quiet
  local msg_detached
  msg_detached=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws]}' | "$SESSION_START" | jq -r '.injectSteps[0].systemMessage.systemMessage')
  assert_contains "$msg_detached" "Swarm Worker Mode"
  assert_contains "$msg_detached" "[DETACHED HEAD]" "Detached HEAD must emit [DETACHED HEAD]"
  assert_not_contains "$msg_detached" "[BRANCH GUARD]"

  # 4. Feature branch -> neither [BRANCH GUARD] nor [DETACHED HEAD]
  git -C "$repo" checkout -b "feat/swarm-session" --quiet
  local msg_feat
  msg_feat=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws]}' | "$SESSION_START" | jq -r '.injectSteps[0].systemMessage.systemMessage')
  assert_contains "$msg_feat" "Swarm Worker Mode"
  assert_not_contains "$msg_feat" "[BRANCH GUARD]" "Feature branch must not emit [BRANCH GUARD]"
  assert_not_contains "$msg_feat" "[DETACHED HEAD]" "Feature branch must not emit [DETACHED HEAD]"

  # 5. Non-git directory -> neither [BRANCH GUARD] nor [DETACHED HEAD]
  local nongit_dir msg_nongit
  nongit_dir=$(mktemp -d "${TMPDIR:-/tmp}/harness-nongit.XXXXXX")
  echo "$nongit_dir" >> "$_HARNESS_TEMP_TRACKER"
  msg_nongit=$(jq -nc --arg ws "$nongit_dir" '{workspacePaths: [$ws]}' | "$SESSION_START" | jq -r '.injectSteps[0].systemMessage.systemMessage')
  assert_contains "$msg_nongit" "Swarm Worker Mode"
  assert_not_contains "$msg_nongit" "[BRANCH GUARD]" "Non-git directory must not emit [BRANCH GUARD]"
  assert_not_contains "$msg_nongit" "[DETACHED HEAD]" "Non-git directory must not emit [DETACHED HEAD]"
}

test_impeccable_workspace_paths_and_session_start_ui_status() {
  export HARNESS_DISABLE_DAEMON=1
  local repo mock_cfg mock_skill
  repo=$(make_temp_repo)
  mock_cfg="$repo/.mock-cfg"
  mock_skill="$repo/.mock-impeccable-skill"
  mkdir -p "$mock_cfg" "$mock_skill"
  echo "# Impeccable" > "$mock_skill/SKILL.md"

  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: init" --quiet

  # 1. .impeccable/ writes allowed on main without glossary, but private key inside .impeccable/ is denied
  local p_imp_cache p_imp_md p_imp_key out_imp_cache out_imp_md out_imp_key
  p_imp_cache=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: ".impeccable/hook.cache.json", Content: "{}"}}}')
  out_imp_cache=$(printf '%s' "$p_imp_cache" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_imp_cache" ".decision" "allow" ".impeccable/hook.cache.json must be allowed on main"

  p_imp_md=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: ".impeccable/review/report.md", Content: "# Review\nNo glossary needed"}}}')
  out_imp_md=$(printf '%s' "$p_imp_md" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_imp_md" ".decision" "allow" ".impeccable/review/report.md must be allowed without glossary"

  p_imp_key=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: ".impeccable/secret.txt", Content: "-----BEGIN RSA PRIVATE KEY-----\nABC\n-----END RSA PRIVATE KEY-----"}}}')
  out_imp_key=$(printf '%s' "$p_imp_key" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_imp_key" ".decision" "deny" "Private key inside .impeccable/ must still be denied"

  # 2. PRODUCT.md and DESIGN.md allowed on main without glossary, while src/App.tsx on main is still denied
  local p_prod p_design p_tsx out_prod out_design out_tsx
  p_prod=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: "PRODUCT.md", Content: "# Product\n## Platform\nweb"}}}')
  out_prod=$(printf '%s' "$p_prod" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_prod" ".decision" "allow" "PRODUCT.md draft on main must be allowed"

  p_design=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: "DESIGN.md", Content: "# Design System"}}}')
  out_design=$(printf '%s' "$p_design" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_design" ".decision" "allow" "DESIGN.md draft on main must be allowed"

  p_tsx=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: "src/App.tsx", Content: "export const App = () => null;"}}}')
  out_tsx=$(printf '%s' "$p_tsx" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_tsx" ".decision" "deny" "src/App.tsx on main must still be denied"

  # 3. SessionStart UI Gate status: dormant -> advisory -> active
  local msg_dormant msg_advisory msg_active
  msg_dormant=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws]}' \
    | HARNESS_CONFIG_DIR="$mock_cfg" env -u HARNESS_IMPECCABLE_SKILL_DIR -u HARNESS_IMPECCABLE_BIN "$SESSION_START" \
    | jq -r '.injectSteps[0].systemMessage.systemMessage')
  assert_contains "$msg_dormant" "Impeccable UI Gate: dormant"
  assert_not_contains "$msg_dormant" "[UI ADVISORY]"

  mkdir -p "$repo/src"
  echo "export const App = () => <main />;" > "$repo/src/App.tsx"

  msg_advisory=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws]}' \
    | HARNESS_CONFIG_DIR="$mock_cfg" env -u HARNESS_IMPECCABLE_SKILL_DIR -u HARNESS_IMPECCABLE_BIN "$SESSION_START" \
    | jq -r '.injectSteps[0].systemMessage.systemMessage')
  assert_contains "$msg_advisory" "Impeccable UI Gate: advisory"
  assert_contains "$msg_advisory" "[UI ADVISORY]"

  msg_active=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws]}' \
    | HARNESS_CONFIG_DIR="$mock_cfg" HARNESS_IMPECCABLE_SKILL_DIR="$mock_skill" "$SESSION_START" \
    | jq -r '.injectSteps[0].systemMessage.systemMessage')
  assert_contains "$msg_active" "Impeccable UI Gate: active"
  assert_not_contains "$msg_active" "[UI ADVISORY]"
}

test_session_start_model_deprecation_warnings() {
  local repo
  repo=$(make_temp_repo)

  local m
  for m in "gemini-4-argon-high" "Orchestrator (Argon)" "gemini-3.8-flash-low" "gpt-oss-120b-medium" "Claude 4.6 Sonnet"; do
    local out msg
    out=$(jq -nc --arg ws "$repo" --arg mn "$m" '{workspacePaths: [$ws], modelName: $mn}' | "$SESSION_START")
    msg=$(printf '%s\n' "$out" | jq -r '.injectSteps[0].systemMessage.systemMessage')
    assert_contains "$msg" "[MODEL DEPRECATION WARNING]" "SessionStart warns on deprecated model: $m"
    assert_contains "$msg" "2026-11-30" "SessionStart includes retirement date for: $m"
  done

  for m in "Gemini 4 Neon (Extra)" "gemini-4-carbon-high" "gemini-4-hydrogen-xhigh" "Orchestrator (Neon)" "Claude Opus 5.5 (Thinking)"; do
    local out_ok msg_ok
    out_ok=$(jq -nc --arg ws "$repo" --arg mn "$m" '{workspacePaths: [$ws], modelName: $mn}' | "$SESSION_START")
    msg_ok=$(printf '%s\n' "$out_ok" | jq -r '.injectSteps[0].systemMessage.systemMessage')
    assert_not_contains "$msg_ok" "[MODEL DEPRECATION WARNING]" "SessionStart does not warn on active model: $m"
  done
}

test_swarm_coordinator_only_pre_edit_and_session_start() {
  export HARNESS_DISABLE_DAEMON=1
  local repo ext_dir
  repo=$(make_temp_repo)
  ext_dir=$(mktemp -d "${TMPDIR:-/tmp}/swarm-ext.XXXXXX")
  echo "$ext_dir" >> "$_HARNESS_TEMP_TRACKER"

  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: init" --quiet
  git -C "$repo" checkout -b "feat/swarm-coord" --quiet

  # 1. Non-swarm prompt mentioning "swarm" in prose must NOT trigger Coordinator-Only guard
  local p_prose out_prose
  p_prose=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    conversationId: "conv-normal",
    lastUserInput: "Explain how swarm architecture works in general.",
    toolCall: {name: "write_file", args: {Path: "src/Normal.ts", Content: "export const ok = 1;"}}
  }')
  out_prose=$(printf '%s' "$p_prose" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_prose" ".decision" "allow" "Prose mentioning swarm without /swarm must NOT trigger Coordinator-Only"

  # 2. Turn-1 explicit /swarm slash command triggers Coordinator-Only guard immediately
  local p_slash out_slash
  p_slash=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    conversationId: "conv-turn1",
    lastUserInput: "/swarm refactor auth module",
    toolCall: {name: "write_file", args: {Path: "src/Auth.ts", Content: "export const a = 1;"}}
  }')
  out_slash=$(printf '%s' "$p_slash" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_slash" ".decision" "deny" "Turn-1 /swarm coordinator must be denied write_file"
  assert_contains "$(printf '%s' "$out_slash" | jq -r '.reason')" "Coordinator-Only"

  # 3. Register coordinator via swarm(action="title") -> denies src, specs, walkthroughs, .superpowers, and .harness/state/swarm/*; allows external plan.json
  local p_title
  p_title=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    conversationId: "conv-coord",
    toolCall: {name: "swarm", args: {action: "title", title: "Auth Swarm"}}
  }')
  printf '%s' "$p_title" | "$PRE_SUBAGENT_GUARD" >/dev/null

  local rel
  for rel in "src/Auth.ts" "docs/superpowers/specs/2026-11-26-s.md" "docs/walkthroughs/2026-11-26-w.md" ".superpowers/tmp.md" ".harness/state/swarm/swarm-coordinator.json" ".harness/state/swarm/swarm-quota-wait.json" ".harness/state/swarm/note.json"; do
    local p_den out_den
    p_den=$(jq -nc --arg ws "$repo" --arg path "$rel" '{
      workspacePaths: [$ws],
      conversationId: "conv-coord",
      toolCall: {name: "write_file", args: {Path: $path, Content: "x"}}
    }')
    out_den=$(printf '%s' "$p_den" | "$PRE_EDIT_GUARD")
    assert_json_field "$out_den" ".decision" "deny" "Active coordinator must be denied write_file on $rel"
  done

  local p_edit_den out_edit_den
  p_edit_den=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    conversationId: "conv-coord",
    toolCall: {name: "edit_file", args: {Path: "README.md", Replacement: "edited"}}
  }')
  out_edit_den=$(printf '%s' "$p_edit_den" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_edit_den" ".decision" "deny" "Active coordinator must be denied edit_file on README.md"

  local p_ext out_ext
  p_ext=$(jq -nc --arg ws "$repo" --arg path "$ext_dir/plan.json" '{
    workspacePaths: [$ws],
    conversationId: "conv-coord",
    toolCall: {name: "write_file", args: {Path: $path, Content: "{\"goal\":{}}"}}
  }')
  out_ext=$(printf '%s' "$p_ext" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_ext" ".decision" "allow" "External Swarm UI plan.json path stays allowed"

  # 4. Worker exemption markers ([SWARM_WORKER_CONTRACT], [SWARM_INTEGRATOR_CONTRACT], <swarm_worker>) isolate even on registered conv-coord ID
  local wmarker out_wmarker
  for wmarker in "[SWARM_WORKER_CONTRACT] task" "[SWARM_INTEGRATOR_CONTRACT] merge" "<swarm_worker>implement</swarm_worker>"; do
    out_wmarker=$(jq -nc --arg ws "$repo" --arg lu "$wmarker" '{
      workspacePaths: [$ws],
      conversationId: "conv-coord",
      lastUserInput: $lu,
      toolCall: {name: "write_file", args: {Path: "src/WorkerOk.ts", Content: "export const w = 1;"}}
    }' | "$PRE_EDIT_GUARD")
    assert_json_field "$out_wmarker" ".decision" "allow" "Worker prompt marker ($wmarker) must bypass Coordinator-Only even on registered convId"
  done

  # 4b. Linked worktree cwd with /swarm must NOT trigger Coordinator-Only; __default__ key works when convId empty;
  #     swarm-coordinator off unblocks edits and overrides /swarm; corrupt JSON fails safe without crash.
  local wt_dir
  wt_dir=$(mktemp -d "${TMPDIR:-/tmp}/swarm-wt-edit.XXXXXX")
  echo "$wt_dir" >> "$_HARNESS_TEMP_TRACKER"
  git -C "$repo" worktree add "$wt_dir" -b "feat/wt-worker" --quiet
  local out_wt_slash
  out_wt_slash=$(jq -nc --arg ws "$repo" --arg cwd "$wt_dir" '{
    workspacePaths: [$ws],
    cwd: $cwd,
    conversationId: "conv-wt",
    lastUserInput: "/swarm run in worktree",
    toolCall: {name: "write_file", args: {Path: "src/Wt.ts", Content: "export const wt = 1;"}}
  }' | "$PRE_EDIT_GUARD")
  assert_json_field "$out_wt_slash" ".decision" "allow" "Worker inside different linked worktree must not trigger Coordinator-Only on /swarm"

  "$STAMP_GATE" swarm-coordinator off --workspace "$repo" --conversation-id "conv-coord" >/dev/null
  local out_off_unblock
  out_off_unblock=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    conversationId: "conv-coord",
    lastUserInput: "/swarm still in history",
    toolCall: {name: "write_file", args: {Path: "src/Unblocked.ts", Content: "export const u = 1;"}}
  }' | "$PRE_EDIT_GUARD")
  assert_json_field "$out_off_unblock" ".decision" "allow" "swarm-coordinator off must unblock writes and override /swarm"

  "$STAMP_GATE" swarm-coordinator on --workspace "$repo" --title "Default Coord" >/dev/null
  local out_def_deny
  out_def_deny=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {name: "write_file", args: {Path: "src/Def.ts", Content: "export const d = 1;"}}
  }' | "$PRE_EDIT_GUARD")
  assert_json_field "$out_def_deny" ".decision" "deny" "__default__ key must enforce Coordinator-Only when conversationId omitted"
  "$STAMP_GATE" swarm-coordinator off --workspace "$repo" >/dev/null

  # 5. SessionStart omits [SWARM COORDINATOR MODE] & [SWARM QUOTA WAIT ACTIVE] when inactive,
  #    and surfaces both when active; corrupt swarm-coordinator.json fails safe.
  local ss_inactive
  ss_inactive=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], conversationId: "conv-coord"}' | "$SESSION_START" | jq -r '.injectSteps[0].systemMessage.systemMessage')
  assert_not_contains "$ss_inactive" "[SWARM COORDINATOR MODE]"
  assert_not_contains "$ss_inactive" "[SWARM QUOTA WAIT ACTIVE]"

  "$STAMP_GATE" swarm-coordinator on --workspace "$repo" --conversation-id "conv-coord" --title "Active Again" >/dev/null
  "$STAMP_GATE" swarm-quota pause --workspace "$repo" --conversation-id "conv-coord" --wait-seconds 300 --buffer-seconds 0 --window 5h --member "auth-worker" --reason "5-hour quota reached" >/dev/null
  local ss_msg
  ss_msg=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], conversationId: "conv-coord"}' | "$SESSION_START" | jq -r '.injectSteps[0].systemMessage.systemMessage')
  assert_contains "$ss_msg" "[SWARM COORDINATOR MODE]"
  assert_contains "$ss_msg" "[SWARM QUOTA WAIT ACTIVE]"
  assert_contains "$ss_msg" "auth-worker"

  printf '{corrupt json' > "$repo/.harness/state/swarm/swarm-coordinator.json"
  local out_corrupt
  out_corrupt=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    conversationId: "conv-coord",
    toolCall: {name: "write_file", args: {Path: "src/Safe.ts", Content: "export const s = 1;"}}
  }' | "$PRE_EDIT_GUARD")
  assert_json_field "$out_corrupt" ".decision" "allow" "Corrupt swarm-coordinator.json must fail safe without crashing"
}

run_tests "$@"
