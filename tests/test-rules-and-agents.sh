#!/usr/bin/env bash
# Alps AGY Harness - Rules & Agents Contract Tests (test-rules-and-agents.sh)
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-helpers.sh"

RULES_DIR="$REPO_ROOT/rules"
AGENTS_DIR="$REPO_ROOT/agents"

# Helper: extract YAML frontmatter block (lines between first --- and second ---)
extract_frontmatter() {
  local file="$1"
  awk '
    NR == 1 {
      if ($0 != "---") exit 1
      in_fm = 1
      next
    }
    in_fm && $0 == "---" {
      found_end = 1
      exit 0
    }
    in_fm { print }
    END {
      if (!in_fm || !found_end) exit 1
    }
  ' "$file"
}

test_agents_md_no_frontmatter_and_under_8kb() {
  local agents_md="$RULES_DIR/AGENTS.md"
  [ -f "$agents_md" ] || { echo "Missing rules/AGENTS.md: $agents_md" >&2; return 1; }

  local first_line
  first_line="$(head -n 1 "$agents_md")"
  if [ "$first_line" = "---" ]; then
    echo "rules/AGENTS.md must NOT start with YAML frontmatter '---'" >&2
    return 1
  fi

  local byte_size
  byte_size="$(wc -c < "$agents_md" | tr -d ' ')"
  if [ "$byte_size" -le 0 ] || [ "$byte_size" -ge 8192 ]; then
    echo "rules/AGENTS.md byte size must be > 0 and < 8192, got: $byte_size" >&2
    return 1
  fi

  local content
  content="$(cat "$agents_md")"

  # Core orchestration, tools, and deterministic gate contracts
  assert_contains "$content" "harness-orchestrator" "AGENTS.md must reference harness-orchestrator"
  assert_contains "$content" "jev_classify" "AGENTS.md must reference jev_classify"
  assert_contains "$content" "TYPESAFE_API_KEY" "AGENTS.md must enforce zero-fallback TYPESAFE_API_KEY check"
  assert_contains "$content" "harness-doctor.sh" "AGENTS.md must reference harness-doctor.sh"
  assert_contains "$content" "dependency-versions" "AGENTS.md must reference dependency-versions"
  assert_contains "$content" "context7" "AGENTS.md must reference context7"
  assert_contains "$content" "architecture-tradeoffs" "AGENTS.md must reference architecture-tradeoffs"
  assert_contains "$content" "ADR" "AGENTS.md must reference ADR"
  assert_contains "$content" "domain-canon" "AGENTS.md must reference domain-canon"
  assert_contains "$content" "docs/canon/glossary.md" "AGENTS.md must reference docs/canon/glossary.md"
  assert_contains "$content" "docs/canon/flows.md" "AGENTS.md must reference docs/canon/flows.md"
  assert_contains "$content" "docs/canon/lessons.md" "AGENTS.md must reference docs/canon/lessons.md"
  assert_contains "$content" "Rule of Three" "AGENTS.md must enforce Rule of Three"
  assert_contains "$content" "parking-lot.md" "AGENTS.md must reference docs/parking-lot.md"
  assert_contains "$content" "stamp-gate.sh" "AGENTS.md must reference stamp-gate.sh"
  assert_contains "$content" "trivial_lookup" "AGENTS.md must list subagent tier trivial_lookup"
  assert_contains "$content" "bounded_execution" "AGENTS.md must list subagent tier bounded_execution"
  assert_contains "$content" "multi_module_integration" "AGENTS.md must list subagent tier multi_module_integration"
  assert_contains "$content" "critical_architecture_or_audit" "AGENTS.md must list subagent tier critical_architecture_or_audit"
  assert_contains "$content" "Orchestrator" "AGENTS.md must document Orchestrator subagent routing"
  assert_contains "$content" "Carbon" "AGENTS.md must document Gemini 4 Carbon subagent routing"
  assert_contains "$content" "Argon" "AGENTS.md must document Gemini 4 Argon subagent routing"
  assert_contains "$content" "Hydrogen" "AGENTS.md must document Gemini 4 Hydrogen subagent routing"
  assert_contains "$content" "XHIGH" "AGENTS.md must document XHIGH effort profile"
  assert_contains "$content" "run-quiet.sh" "AGENTS.md must reference run-quiet.sh"
  assert_contains "$content" "mobile-logs.sh" "AGENTS.md must reference mobile-logs.sh"
  assert_contains "$content" "Teknik Terimler Sözlüğü" "AGENTS.md must enforce Teknik Terimler Sözlüğü section"
  assert_contains "$content" "REMEDIATION:" "AGENTS.md must mandate English REMEDIATION: fitness messages"
  assert_contains "$content" "pre-pr-readiness" "AGENTS.md must reference pre-pr-readiness"
  assert_contains "$content" "Dosya Bazlı Değişiklik Analizi" "AGENTS.md must enforce per-file walkthrough analysis"
  assert_contains "$content" "canon-auditor" "AGENTS.md must reference canon-auditor"
  assert_contains "$content" "security-reviewer" "AGENTS.md must reference security-reviewer"
  assert_contains "$content" "review-pr" "AGENTS.md must reference review-pr"
  assert_contains "$content" "pr-auditor" "AGENTS.md must reference pr-auditor"
}

assert_platform_rule_contract() {
  local filename="$1"
  local expected_globs="$2"
  local doc_standard="$3"
  shift 3
  local required_tokens=("$@")

  local filepath="$RULES_DIR/$filename"
  [ -f "$filepath" ] || { echo "Missing platform rule: $filepath" >&2; return 1; }

  local byte_size
  byte_size="$(wc -c < "$filepath" | tr -d ' ')"
  if [ "$byte_size" -le 500 ] || [ "$byte_size" -ge 24000 ]; then
    echo "$filename byte size must be > 500 and < 24000 (Antigravity 24 KB rule limit), got: $byte_size" >&2
    return 1
  fi

  local fm
  if ! fm="$(extract_frontmatter "$filepath")"; then
    echo "$filename does not have valid opening/closing '---' YAML frontmatter" >&2
    return 1
  fi

  assert_contains "$fm" "trigger: glob" "$filename frontmatter must set 'trigger: glob'"
  assert_contains "$fm" "description:" "$filename frontmatter must include 'description:'"

  local globs_line
  globs_line="$(printf '%s\n' "$fm" | grep -E '^globs:' || true)"
  [ -n "$globs_line" ] || { echo "$filename frontmatter missing 'globs:' line" >&2; return 1; }
  assert_not_contains "$globs_line" "{" "$filename globs line must NOT contain '{'"
  assert_not_contains "$globs_line" "}" "$filename globs line must NOT contain '}'"
  assert_eq "globs: $expected_globs" "$globs_line" "$filename globs must match exact spec pattern"

  local content
  content="$(cat "$filepath")"
  assert_contains "$content" "REMEDIATION:" "$filename must include concrete English REMEDIATION: fitness example"
  assert_contains "$content" "$doc_standard" "$filename must enforce $doc_standard documentation contract"
  assert_contains "$content" "docs/canon/glossary.md" "$filename must align identifiers/docstrings with docs/canon/glossary.md"
  assert_contains "$content" "run-quiet.sh" "$filename must wrap build/test verification in run-quiet.sh"

  local tok
  for tok in "${required_tokens[@]}"; do
    assert_contains "$content" "$tok" "$filename missing required contract token: $tok"
  done
}

test_platform_rules_valid_glob_frontmatter_and_under_24kb() {
  assert_platform_rule_contract \
    "dotnet-clean-arch.md" \
    "**/*.cs, **/*.xaml, **/*.csproj, **/*.sln, **/*.slnx, **/Directory.Packages.props" \
    "XMLDoc" \
    "Domain" "Application" "Infrastructure" "Presentation" "RFC 7807" "NetArchTest" "csharp-lsp" "xaml_validate"

  assert_platform_rule_contract \
    "angular-typescript.md" \
    "**/*.ts, **/*.tsx, **/*.html, **/angular.json, **/tsconfig*.json" \
    "TSDoc" \
    "model/" "application/" "infrastructure/" "presentation/" "@softarc/sheriff" "eslint-plugin-boundaries" "typescript-lsp" "@playwright/mcp" "Chrome DevTools"

  assert_platform_rule_contract \
    "ios-swift.md" \
    "**/*.swift, **/Package.swift, **/*.xcodeproj/**" \
    "DocC" \
    "Package.swift" "Domain" "Data" "Features" "@Observable" "mobile-logs.sh --platform ios" "XcodeBuildMCP"

  assert_platform_rule_contract \
    "android-kotlin.md" \
    "**/*.kt, **/*.kts, **/libs.versions.toml" \
    "KDoc" \
    ":domain" ":data" ":features" "StateFlow" "Konsist" "mobile-logs.sh --platform android" "Android CLI"
}

assert_subagent_frontmatter() {
  local filename="$1"
  local expected_name="$2"
  local filepath="$AGENTS_DIR/$filename"

  [ -f "$filepath" ] || { echo "Missing subagent file: $filepath" >&2; return 1; }

  local byte_size
  byte_size="$(wc -c < "$filepath" | tr -d ' ')"
  if [ "$byte_size" -le 500 ] || [ "$byte_size" -ge 24000 ]; then
    echo "$filename byte size must be > 500 and < 24000 (Antigravity 24 KB limit), got: $byte_size" >&2
    return 1
  fi

  local fm
  if ! fm="$(extract_frontmatter "$filepath")"; then
    echo "$filename does not have valid opening/closing '---' YAML frontmatter" >&2
    return 1
  fi

  if printf '%s\n' "$fm" | grep -Eq '^model:'; then
    echo "$filename frontmatter must NOT contain '^model:'" >&2
    return 1
  fi

  if printf '%s\n' "$fm" | grep -Eq '^color:'; then
    echo "$filename frontmatter must NOT contain '^color:'" >&2
    return 1
  fi

  # Strict frontmatter schema: only name, description, subagent, mainAgent, tools allowed
  local unexpected_lines
  unexpected_lines="$(printf '%s\n' "$fm" | grep -Ev '^(name|description|subagent|mainAgent|tools):' || true)"
  if [ -n "$unexpected_lines" ]; then
    echo "$filename frontmatter contains unexpected lines/fields: $unexpected_lines" >&2
    return 1
  fi

  local line_count
  line_count="$(printf '%s\n' "$fm" | wc -l | tr -d ' ')"
  assert_eq "5" "$line_count" "$filename frontmatter must have exactly 5 single-line YAML fields"

  local name_line subagent_line main_line tools_line desc_line
  name_line="$(printf '%s\n' "$fm" | grep -E '^name:' || true)"
  desc_line="$(printf '%s\n' "$fm" | grep -E '^description:' || true)"
  subagent_line="$(printf '%s\n' "$fm" | grep -E '^subagent:' || true)"
  main_line="$(printf '%s\n' "$fm" | grep -E '^mainAgent:' || true)"
  tools_line="$(printf '%s\n' "$fm" | grep -E '^tools:' || true)"

  assert_eq "name: $expected_name" "$name_line" "$filename frontmatter name must equal $expected_name"
  [ -n "$desc_line" ] || { echo "$filename frontmatter missing description:" >&2; return 1; }
  assert_eq "subagent: true" "$subagent_line" "$filename frontmatter must set subagent: true"
  assert_eq "mainAgent: false" "$main_line" "$filename frontmatter must set mainAgent: false"
  assert_eq "tools: [read_file, run_command, manage_task, call_mcp_tool, send_message]" "$tools_line" "$filename frontmatter tools must match exact list"

  local content
  content="$(cat "$filepath")"
  assert_contains "$content" "[EFFORT_PROFILE:" "$filename must honor injected [EFFORT_PROFILE: ...] directives"
  assert_contains "$content" "TYPESAFE_API_KEY" "$filename must enforce zero-fallback jev / TYPESAFE_API_KEY policy"
  assert_contains "$content" "harness-doctor.sh" "$filename must instruct running harness-doctor.sh on jev failure"
}

test_subagents_frontmatter_and_audit_contracts() {
  assert_subagent_frontmatter "canon-auditor.md" "canon-auditor"
  assert_subagent_frontmatter "security-reviewer.md" "security-reviewer"
  assert_subagent_frontmatter "pr-auditor.md" "pr-auditor"

  local canon_content sec_content pr_content
  canon_content="$(cat "$AGENTS_DIR/canon-auditor.md")"
  sec_content="$(cat "$AGENTS_DIR/security-reviewer.md")"
  pr_content="$(cat "$AGENTS_DIR/pr-auditor.md")"

  # 1. canon-auditor contracts
  assert_contains "$canon_content" "Intent Backtranslation" "canon-auditor must include Intent Backtranslation"
  assert_contains "$canon_content" "docs/canon/glossary.md" "canon-auditor must check docs/canon/glossary.md"
  assert_contains "$canon_content" "docs/canon/flows.md" "canon-auditor must check docs/canon/flows.md"
  assert_contains "$canon_content" "docs/canon/lessons.md" "canon-auditor must check docs/canon/lessons.md"
  assert_contains "$canon_content" "jev_ask" "canon-auditor must call jev_ask for simplicity/canon check"
  assert_contains "$canon_content" "0.60" "canon-auditor must reject >= 0.60 bloat/overengineering probability"
  assert_contains "$canon_content" "Rule of Three" "canon-auditor must enforce Rule of Three"
  assert_contains "$canon_content" "docs/parking-lot.md" "canon-auditor must route out-of-scope items to docs/parking-lot.md"
  assert_contains "$canon_content" "REMEDIATION:" "canon-auditor must verify Clean Architecture REMEDIATION: fitness checks"
  assert_contains "$canon_content" "## Teknik Terimler Sözlüğü" "canon-auditor must verify Turkish glossary section"
  assert_contains "$canon_content" "## Technical Glossary" "canon-auditor must verify English glossary section"
  assert_contains "$canon_content" "Dosya Bazlı Değişiklik Analizi" "canon-auditor must enforce per-file walkthrough coverage"
  assert_contains "$canon_content" "stamp-gate.sh canon" "canon-auditor must invoke stamp-gate.sh canon"
  assert_contains "$canon_content" "--verdict PASS" "canon-auditor must document exact --verdict PASS flag"
  assert_contains "$canon_content" "--allow-file" "canon-auditor must document exact --allow-file flag"
  assert_contains "$canon_content" "--plan" "canon-auditor must document exact --plan flag"

  # 2. security-reviewer contracts
  assert_contains "$sec_content" "jev_triage" "security-reviewer must pre-screen diff via jev_triage"
  assert_contains "$sec_content" "jev_score" "security-reviewer must calibrate findings via jev_score"
  assert_contains "$sec_content" "IDOR" "security-reviewer must check Authn/Authz and IDOR"
  assert_contains "$sec_content" "firestore.rules" "security-reviewer must audit Firebase firestore.rules"
  assert_contains "$sec_content" "storage.rules" "security-reviewer must audit Firebase storage.rules"
  assert_contains "$sec_content" "Keychain" "security-reviewer must verify iOS Keychain storage"
  assert_contains "$sec_content" "EncryptedSharedPreferences" "security-reviewer must verify Android EncryptedSharedPreferences/Keystore"
  assert_contains "$sec_content" "Keystore" "security-reviewer must verify Android Keystore"
  assert_contains "$sec_content" "UserDefaults" "security-reviewer must forbid plaintext tokens/PII in UserDefaults"
  assert_contains "$sec_content" "SharedPreferences" "security-reviewer must forbid plaintext tokens/PII in SharedPreferences"
  assert_contains "$sec_content" "stamp-gate.sh security" "security-reviewer must invoke stamp-gate.sh security"
  assert_contains "$sec_content" "--verdict PASS --critical 0 --important 0" "security-reviewer must document exact zero-finding PASS stamp command"

  # 3. pr-auditor contracts & all 7 mandatory audit dimensions
  assert_contains "$pr_content" "Intent Backtranslation" "pr-auditor must include 2-sentence Intent Backtranslation"
  assert_contains "$pr_content" "jev_triage" "pr-auditor must pre-screen diff via jev_triage"
  assert_contains "$pr_content" "jev_check" "pr-auditor must filter speculative comments via jev_check"
  assert_contains "$pr_content" "0.70" "pr-auditor must discard speculative findings scoring < 0.70"
  assert_contains "$pr_content" "jev_score" "pr-auditor must calibrate surviving findings via jev_score"
  assert_contains "$pr_content" "stamp-gate.sh clear-pr-audit" "pr-auditor must invoke stamp-gate.sh clear-pr-audit"

  # Verify all 7 numbered dimensions explicitly exist in pr-auditor.md
  assert_contains "$pr_content" "1. Code Documentation Quality" "pr-auditor must define Dimension 1: Code Documentation Quality"
  assert_contains "$pr_content" "XMLDoc" "pr-auditor Dimension 1 must cover XMLDoc"
  assert_contains "$pr_content" "TSDoc" "pr-auditor Dimension 1 must cover TSDoc"
  assert_contains "$pr_content" "DocC" "pr-auditor Dimension 1 must cover Swift DocC"
  assert_contains "$pr_content" "KDoc" "pr-auditor Dimension 1 must cover KDoc"
  assert_contains "$pr_content" "parrot" "pr-auditor Dimension 1 must flag parrot comments"
  assert_contains "$pr_content" "stale" "pr-auditor Dimension 1 must flag stale comments"

  assert_contains "$pr_content" "2. Test Coverage & Behavioral Rigor" "pr-auditor must define Dimension 2: Test Coverage & Behavioral Rigor"
  assert_contains "$pr_content" "3. Type Safety & API/Schema Contract Integrity" "pr-auditor must define Dimension 3: Type Safety & API/Schema Contract Integrity"
  assert_contains "$pr_content" "RFC 7807" "pr-auditor Dimension 3 must check RFC 7807 error contracts"
  assert_contains "$pr_content" "4. Silent Failure & Error Handling Analysis" "pr-auditor must define Dimension 4: Silent Failure & Error Handling Analysis"
  assert_contains "$pr_content" "5. DDD & Clean Architecture Boundary Compliance" "pr-auditor must define Dimension 5: DDD & Clean Architecture Boundary Compliance"
  assert_contains "$pr_content" "REMEDIATION:" "pr-auditor Dimension 5 must check English REMEDIATION: fitness rules"
  assert_contains "$pr_content" "6. Anti-Overengineering & Scope Creep Penalty" "pr-auditor must define Dimension 6: Anti-Overengineering & Scope Creep Penalty"
  assert_contains "$pr_content" "Rule of Three" "pr-auditor Dimension 6 must enforce Rule of Three"
  assert_contains "$pr_content" "docs/parking-lot.md" "pr-auditor Dimension 6 must enforce docs/parking-lot.md routing"
  assert_contains "$pr_content" "7. Readability, Naming & Ubiquitous Language" "pr-auditor must define Dimension 7: Readability, Naming & Ubiquitous Language"
  assert_contains "$pr_content" "docs/canon/glossary.md" "pr-auditor Dimension 7 must check docs/canon/glossary.md"
  assert_contains "$pr_content" "## Teknik Terimler Sözlüğü" "pr-auditor Dimension 7 must check mandatory end-of-doc glossary"
  assert_contains "$pr_content" "Dosya Bazlı Değişiklik Analizi" "pr-auditor Dimension 7 must check deep per-file walkthrough coverage"
}

run_tests "test_"
