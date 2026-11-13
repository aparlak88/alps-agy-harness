#!/usr/bin/env bash
# Alps AGY Harness - Plugin Bundle, Templates, README, and End-to-End Lifecycle Tests
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-helpers.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/hooks/common.sh"

SESSION_START="$REPO_ROOT/scripts/hooks/session-start.sh"
PRE_EDIT_GUARD="$REPO_ROOT/scripts/hooks/pre-edit-guard.sh"
PRE_COMMAND_GUARD="$REPO_ROOT/scripts/hooks/pre-command-guard.sh"
PRE_SUBAGENT_GUARD="$REPO_ROOT/scripts/hooks/pre-subagent-guard.sh"
POST_COMMAND_HOOKS="$REPO_ROOT/scripts/hooks/post-command-hooks.sh"
STOP_GATE="$REPO_ROOT/scripts/hooks/stop-gate.sh"
STAMP_GATE="$REPO_ROOT/scripts/stamp-gate.sh"

EXPECTED_SKILLS=(
  "harness-orchestrator"
  "harness-doctor"
  "architecture-tradeoffs"
  "dependency-versions"
  "domain-canon"
  "pre-pr-readiness"
  "review-pr"
  "entropy-sweep"
  "playwright-e2e"
  "mobile-diagnostics"
  "revenuecat-integration"
)

test_all_eleven_skills_frontmatter_and_folder_match() {
  # 1. Verify each of the 11 skill folders and its SKILL.md
  for skill in "${EXPECTED_SKILLS[@]}"; do
    local skill_dir="$REPO_ROOT/skills/$skill"
    local skill_file="$skill_dir/SKILL.md"

    [ -d "$skill_dir" ] || { echo "Skill directory missing: $skill_dir" >&2; return 1; }
    [ -f "$skill_file" ] || { echo "SKILL.md missing in: $skill_dir" >&2; return 1; }

    # Size check (< 24000 bytes Antigravity limit)
    local size
    size=$(wc -c < "$skill_file" | tr -d '[:space:]')
    [ "$size" -lt 24000 ] || { echo "Skill $skill_file exceeds 24000 bytes ($size bytes)" >&2; return 1; }
    [ "$size" -gt 100 ] || { echo "Skill $skill_file is suspiciously small ($size bytes)" >&2; return 1; }

    # Frontmatter check
    local first_line
    first_line=$(head -n 1 "$skill_file")
    assert_eq "---" "$first_line" "$skill_file must start with YAML frontmatter delimiter '---'"

    # Extract frontmatter name
    local name_val
    name_val=$(awk '/^name:[[:space:]]*/{sub(/^name:[[:space:]]*/, ""); print; exit}' "$skill_file")
    assert_eq "$skill" "$name_val" "$skill_file frontmatter 'name' must match folder name '$skill' verbatim"

    # Extract description
    local desc_val
    desc_val=$(awk '/^description:[[:space:]]*/{sub(/^description:[[:space:]]*/, ""); print; exit}' "$skill_file")
    [ -n "$desc_val" ] || { echo "$skill_file frontmatter 'description' must not be empty" >&2; return 1; }
  done

  # 2. Specific contract assertions on playwright-e2e/SKILL.md
  local pw_file="$REPO_ROOT/skills/playwright-e2e/SKILL.md"
  local pw_content
  pw_content=$(cat "$pw_file")
  assert_contains "$pw_content" "@playwright/mcp" "playwright-e2e must document @playwright/mcp"
  assert_contains "$pw_content" "browser_console_messages" "playwright-e2e must document browser_console_messages"
  assert_contains "$pw_content" "browser_network_requests" "playwright-e2e must document browser_network_requests"
  assert_contains "$pw_content" "page.on('pageerror')" "playwright-e2e must include page.on('pageerror') fixture"
  assert_contains "$pw_content" "REMEDIATION:" "playwright-e2e must include English REMEDIATION: messages"

  # 3. Specific contract assertions on mobile-diagnostics/SKILL.md
  local mob_file="$REPO_ROOT/skills/mobile-diagnostics/SKILL.md"
  local mob_content
  mob_content=$(cat "$mob_file")
  assert_contains "$mob_content" "mobile-logs.sh" "mobile-diagnostics must document mobile-logs.sh"
  assert_contains "$mob_content" "--screenshot .harness/logs/ios-screen.png" "mobile-diagnostics must pass explicit path to --screenshot for ios"
  assert_contains "$mob_content" "--screenshot .harness/logs/android-screen.png" "mobile-diagnostics must pass explicit path to --screenshot for android"
  if grep -Eq -- '--screenshot[[:space:]]*$' "$mob_file"; then
    echo "mobile-diagnostics/SKILL.md must not contain bare --screenshot without output file path argument!" >&2
    return 1
  fi

  # 4. Verify total tracked/staged/working plugin bundle file count (excluding project lifecycle docs)
  local bundle_count
  bundle_count=$(git -C "$REPO_ROOT" ls-files -c -o --exclude-standard | grep -Ev "^docs/(superpowers|walkthroughs|canon)/|^docs/parking-lot\.md$" | wc -l | tr -d '[:space:]')
  assert_eq "49" "$bundle_count" "Plugin bundle must have exactly 49 core files (excluding docs/superpowers/, docs/walkthroughs/, docs/canon/, docs/parking-lot.md)"
}

test_templates_and_readme_glossary_and_mermaid_contracts() {
  local wt_tpl="$REPO_ROOT/skills/pre-pr-readiness/templates/walkthrough-template.md"
  local flows_tpl="$REPO_ROOT/skills/domain-canon/templates/flows-template.md"
  local lessons_tpl="$REPO_ROOT/skills/domain-canon/templates/lessons-template.md"
  local glossary_tpl="$REPO_ROOT/skills/domain-canon/templates/glossary-template.md"
  local readme="$REPO_ROOT/README.md"

  # 1. Existence checks
  [ -f "$wt_tpl" ] || { echo "Walkthrough template missing: $wt_tpl" >&2; return 1; }
  [ -f "$flows_tpl" ] || { echo "Flows template missing: $flows_tpl" >&2; return 1; }
  [ -f "$lessons_tpl" ] || { echo "Lessons template missing: $lessons_tpl" >&2; return 1; }
  [ -f "$glossary_tpl" ] || { echo "Glossary template missing: $glossary_tpl" >&2; return 1; }
  [ -f "$readme" ] || { echo "README.md missing: $readme" >&2; return 1; }

  # 2. Glossary section contract: harness_has_glossary_section must return 0
  local docs_to_check=(
    "$readme"
    "$flows_tpl"
    "$lessons_tpl"
    "$wt_tpl"
  )
  for f in "$REPO_ROOT"/docs/superpowers/specs/*.md "$REPO_ROOT"/docs/superpowers/plans/*.md; do
    [ -f "$f" ] && docs_to_check+=("$f")
  done

  for doc in "${docs_to_check[@]}"; do
    local content
    content=$(cat "$doc")
    if ! harness_has_glossary_section "$content"; then
      echo "Document missing valid ending ## Teknik Terimler Sözlüğü section: $doc" >&2
      return 1
    fi
  done

  # 3. Glossary template specific check (is Ubiquitous Language table itself)
  local glossary_content
  glossary_content=$(cat "$glossary_tpl")
  assert_contains "$glossary_content" "İngilizce Kod Terimi" "Glossary template must have canonical identifier column"
  assert_contains "$glossary_content" "Türkçe Karşılığı" "Glossary template must have Turkish column"
  assert_contains "$glossary_content" "Bounded Context" "Glossary template must have Bounded Context column"
  assert_contains "$glossary_content" "Invariants" "Glossary template must have Invariants column"
  assert_contains "$glossary_content" "Forbidden Aliases" "Glossary template must have Forbidden Aliases column"

  # 4. Walkthrough template checks: >= 2 mermaid diagrams and all 6 mandatory deep engineering sections
  local wt_content
  wt_content=$(cat "$wt_tpl")
  local mermaid_count
  mermaid_count=$(grep -c '```mermaid' "$wt_tpl" || true)
  [ "$mermaid_count" -ge 2 ] || { echo "Walkthrough template must contain >= 2 mermaid blocks, found $mermaid_count" >&2; return 1; }

  assert_contains "$wt_content" "Problem Bağlamı ve Mimari Kararlar" "Walkthrough template Section 1 required"
  assert_contains "$wt_content" "Mimari ve Veri Akışı Diyagramları" "Walkthrough template Section 2 required"
  assert_contains "$wt_content" "Dosya Bazlı Değişiklik Analizi" "Walkthrough template Section 3 (per-file analysis) required"
  assert_contains "$wt_content" "Ne Değişti / Ne Üretildi" "Walkthrough template per-file 'What' prompt required"
  assert_contains "$wt_content" "Neden Değişti / Neden Üretildi" "Walkthrough template per-file 'Why' prompt required"
  assert_contains "$wt_content" "Kritik İş Mantığı, Kenar Durumlar (Edge Cases) ve Hata Yönetimi" "Walkthrough template Section 4 required"
  assert_contains "$wt_content" "Somut Doğrulama Kanıtları" "Walkthrough template Section 5 required"
  assert_contains "$wt_content" "Kapsam Dışı" "Walkthrough template Section 6 required"

  # 5. README.md contracts: all 8 mandatory MCPs + optional XcodeBuildMCP + .harness-ignore + zero secrets
  local readme_content
  readme_content=$(cat "$readme")
  local mandatory_mcps=(
    "jev"
    "context7"
    "csharp-lsp"
    "typescript-lsp"
    "playwright"
    "graphify"
    "revenuecat"
    "filesystem"
  )
  for mcp in "${mandatory_mcps[@]}"; do
    assert_contains "$readme_content" "$mcp" "README.md must document mandatory MCP '$mcp'"
  done
  assert_contains "$readme_content" "XcodeBuildMCP" "README.md must document optional XcodeBuildMCP"
  assert_contains "$readme_content" ".harness-ignore" "README.md must document .harness-ignore mechanism"
  assert_contains "$readme_content" "~/.gemini/config/plugins" "README.md must document Global installation path"
  assert_contains "$readme_content" ".agents/plugins" "README.md must document Project-based installation path"
  assert_contains "$readme_content" "superpowers" "README.md must document superpowers prerequisite"
  assert_contains "$readme_content" "run-jev-mcp.sh" "README.md must document TYPESAFE wrapper script"

  # Zero real secret patterns in README.md
  if grep -Eq 'ts_live_[a-zA-Z0-9]{16,}|sk-[a-zA-Z0-9]{16,}|ghp_[a-zA-Z0-9]{20,}|AIza[0-9A-Za-z-_]{35}' "$readme"; then
    echo "README.md contains real-looking secret token pattern! Must use <YOUR_TYPESAFE_API_KEY> placeholders." >&2
    return 1
  fi
}

test_end_to_end_simulated_feature_lifecycle() {
  local repo
  repo=$(make_temp_repo)

  # Initial commit on main
  echo "# Test Project" > "$repo/README.md"
  cat << 'EOF' >> "$repo/README.md"

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| CI | Continuous Integration |
EOF
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: initial commit" --quiet

  # ---------------------------------------------------------------------------
  # Step 1: SessionStart Hook
  # ---------------------------------------------------------------------------
  local p_start
  p_start=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws]}')
  local out_start
  out_start=$(printf '%s' "$p_start" | "$SESSION_START")

  # Verify nested protojson schema: .injectSteps[0].systemMessage.systemMessage
  local msg_start
  msg_start=$(printf '%s' "$out_start" | jq -r '.injectSteps[0].systemMessage.systemMessage // empty')
  [ -n "$msg_start" ] || { echo "SessionStart failed to output nested systemMessage: $out_start" >&2; return 1; }
  assert_contains "$msg_start" "jev_classify" "SessionStart must inject jev_classify protocol"
  assert_contains "$msg_start" "run-quiet.sh" "SessionStart must inject run-quiet.sh protocol"

  # ---------------------------------------------------------------------------
  # Step 2: PreToolUse (pre-edit-guard) blocks source write on main
  # ---------------------------------------------------------------------------
  local p_edit_main
  p_edit_main=$(jq -nc --arg ws "$repo" --arg path "$repo/src/Billing.ts" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: "export class Billing {}"}}}')
  local out_edit_main
  out_edit_main=$(printf '%s' "$p_edit_main" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_edit_main" ".decision" "deny" "Direct src write on main must be denied"

  # ---------------------------------------------------------------------------
  # Step 3: Switch to feat/billing -> allow src write, enforce doc glossary gate
  # ---------------------------------------------------------------------------
  git -C "$repo" checkout -b "feat/billing" --quiet

  local out_edit_feat
  out_edit_feat=$(printf '%s' "$p_edit_main" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_edit_feat" ".decision" "allow" "Src write on feature branch must be allowed"

  # Write spec doc without glossary -> denied
  local p_spec_bad
  p_spec_bad=$(jq -nc --arg ws "$repo" --arg path "$repo/docs/superpowers/specs/billing-spec.md" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: "# Billing Spec\n\nNo glossary here."}}}')
  local out_spec_bad
  out_spec_bad=$(printf '%s' "$p_spec_bad" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_spec_bad" ".decision" "deny" "Spec doc without glossary must be denied"

  # Write spec doc with valid glossary -> allowed
  local spec_good_content
  spec_good_content=$(cat << 'EOF'
# Billing Spec

Intent: Handle subscription billing.

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| Billing | Faturalandırma ve abonelik yönetimi |
EOF
)
  local p_spec_good
  p_spec_good=$(jq -nc --arg ws "$repo" --arg path "$repo/docs/superpowers/specs/billing-spec.md" --arg content "$spec_good_content" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: $content}}}')
  local out_spec_good
  out_spec_good=$(printf '%s' "$p_spec_good" | "$PRE_EDIT_GUARD")
  assert_json_field "$out_spec_good" ".decision" "allow" "Spec doc with glossary must be allowed"

  # Actually write the files into the workspace
  mkdir -p "$repo/src" "$repo/docs/superpowers/specs"
  printf '%s\n' "export class Billing { public amount = 100; }" > "$repo/src/Billing.ts"
  printf '%s\n' "$spec_good_content" > "$repo/docs/superpowers/specs/billing-spec.md"
  git -C "$repo" add src/Billing.ts docs/superpowers/specs/billing-spec.md
  git -C "$repo" commit -m "feat(billing): initial billing module and spec" --quiet

  # ---------------------------------------------------------------------------
  # Step 4: Package Installation Gate (pre-command-guard + stamp-gate context7)
  # ---------------------------------------------------------------------------
  local p_pkg_cmd
  p_pkg_cmd=$(jq -nc --arg ws "$repo" --arg cmd "npm install zod@^3.23.0" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_pkg_cmd
  out_pkg_cmd=$(printf '%s' "$p_pkg_cmd" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_pkg_cmd" ".decision" "deny" "Package install without context7 stamp must be denied"

  # Stamp context7 verification
  "$STAMP_GATE" context7 --workspace "$repo" --package "zod" --version "3.23.0" --source "greenfield-latest"

  # Now package install is allowed
  local out_pkg_cmd2
  out_pkg_cmd2=$(printf '%s' "$p_pkg_cmd" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_pkg_cmd2" ".decision" "allow" "Package install with context7 stamp must be allowed"

  # Verify .git/info/exclude has .harness/
  local exclude_content
  exclude_content=$(cat "$repo/.git/info/exclude" 2>/dev/null || true)
  assert_contains "$exclude_content" ".harness/" ".git/info/exclude must exclude .harness/"

  # ---------------------------------------------------------------------------
  # Step 5: Subagent Dispatch & Overwrite (pre-subagent-guard)
  # ---------------------------------------------------------------------------
  "$STAMP_GATE" dispatch --workspace "$repo" --role "Billing Subagent" --type "self" --tier "bounded_execution"

  local p_subagent
  p_subagent=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "self",
        Role: "Billing Subagent",
        Model: "inherit",
        Prompt: "Implement billing unit tests."
      }
    }
  }')
  local out_subagent
  out_subagent=$(printf '%s' "$p_subagent" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_subagent" ".decision" "allow" "Dispatched subagent must be allowed"
  assert_json_field "$out_subagent" ".overwrite.Model" "flash" "bounded_execution must overwrite Model to flash"
  assert_contains "$(printf '%s' "$out_subagent" | jq -r '.overwrite.Prompt')" "[EFFORT_PROFILE: MEDIUM" "Must inject MEDIUM effort header"

  # Verify dispatch entry marked consumed
  assert_json_field "$repo/.harness/state/feat-billing/subagent-dispatch.json" '.entries["Billing Subagent"].consumed' "true" "Dispatch entry must be marked consumed"

  # ---------------------------------------------------------------------------
  # Step 6: PR Preparation & 5-Point Hard PR Gate
  # ---------------------------------------------------------------------------
  # Create walkthrough document from template
  mkdir -p "$repo/docs/walkthroughs"
  local wt_doc_content
  wt_doc_content=$(cat << 'EOF'
# Pull Request Mühendislik Rehberi: Faturalandırma Modülü

## 1. Problem Bağlamı ve Mimari Kararlar
Abonelik ödemelerinde tutar hesaplamasını sunum katmanından ayırmak için saf `Billing` domain sınıfı ve ilgili abonelik tasarım spesifikasyonu oluşturuldu.

## 2. Mimari ve Veri Akışı Diyagramları
```mermaid
flowchart LR
    Spec["docs/superpowers/specs/billing-spec.md"] --> Billing["Domain: Billing (src/Billing.ts)"]
```

```mermaid
sequenceDiagram
    Client->>Billing: new Billing()
    Billing-->>Client: amount = 100
```

## 3. Dosya Bazlı Değişiklik Analizi

### `src/Billing.ts` — [ÜRETİLDİ] (`Domain`)
- **Ne Değişti / Ne Üretildi?:** Varsayılan faturalandırma tutarını (`amount = 100`) barındıran `Billing` domain sınıfı dışa aktarıldı.
- **Neden Değişti / Neden Üretildi?:** Abonelik ücretlendirme kurallarını altyapı ve arayüz bağımlılıklarından arındırılmış çekirdek modülde temsil etmek için üretildi.

### `docs/superpowers/specs/billing-spec.md` — [ÜRETİLDİ] (`Architecture Spec`)
- **Ne Değişti / Ne Üretildi?:** Faturalandırma modülünün iş amacını (`Intent`) ve temel terim sözlüğünü tanımlayan spesifikasyon dokümanı eklendi.
- **Neden Değişti / Neden Üretildi?:** Kodlama öncesinde abonelik faturalandırma kapsamını ve kanonik terimleri kayıt altına almak için üretildi.

## 4. Kritik İş Mantığı, Kenar Durumlar (Edge Cases) ve Hata Yönetimi
Varsayılan tutar sabit olarak başlatılır; negatif tutar girişleri sonraki iterasyonda Value Object doğrulaması ile engellenecektir.

## 5. Somut Doğrulama Kanıtları
`pre-edit-guard.sh`, `pre-command-guard.sh` ve `stamp-gate.sh` kontrolleri uçtan uca senaryo testinde sıfır hata ile doğrulandı.

## 6. Kapsam Dışı (`docs/parking-lot.md`) ve Operasyonel Notlar
Taksitli ödemeler V2 otoparkına bırakıldı.

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| Checkout | Satın alma ve ödeme adımı |
| PaymentGateway | Ödeme sağlayıcı adaptörü |
EOF
)
  printf '%s\n' "$wt_doc_content" > "$repo/docs/walkthroughs/2026-11-12-billing.md"
  git -C "$repo" add docs/walkthroughs/2026-11-12-billing.md
  git -C "$repo" commit -m "docs: add billing walkthrough" --quiet

  local p_pr_create
  p_pr_create=$(jq -nc --arg ws "$repo" --arg cmd "gh pr create --fill" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')

  # PR create before stamps -> blocked
  local out_pr_blocked
  out_pr_blocked=$(printf '%s' "$p_pr_create" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_pr_blocked" ".decision" "deny" "gh pr create before stamps must be denied"

  # Stamp canon and security
  "$STAMP_GATE" canon --workspace "$repo" --verdict PASS --allow-file "src/Billing.ts"
  "$STAMP_GATE" security --workspace "$repo" --verdict PASS --critical 0 --important 0

  # PR create after stamps -> allowed
  local out_pr_allowed
  out_pr_allowed=$(printf '%s' "$p_pr_create" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_pr_allowed" ".decision" "allow" "gh pr create with valid stamps must be allowed"

  # ---------------------------------------------------------------------------
  # Step 7: PostToolUse Hook sets pr-audit-pending.json
  # ---------------------------------------------------------------------------
  local p_post_pr
  p_post_pr=$(jq -nc --arg ws "$repo" --arg cmd "gh pr create --fill" --arg url "https://github.com/example/repo/pull/42" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}, toolOutput: {output: $url}}')
  local out_post_pr
  out_post_pr=$(printf '%s' "$p_post_pr" | "$POST_COMMAND_HOOKS")
  assert_eq "{}" "$out_post_pr" "PostToolUse must output {}"

  local pending_file="$repo/.harness/state/feat-billing/pr-audit-pending.json"
  [ -f "$pending_file" ] || { echo "pr-audit-pending.json was not created by PostToolUse" >&2; return 1; }
  assert_json_field "$pending_file" ".stopRetries" "0" "Initial stopRetries must be 0"

  # ---------------------------------------------------------------------------
  # Step 8: Stop Gate blocks premature stop requesting pr-auditor
  # ---------------------------------------------------------------------------
  local p_stop
  p_stop=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], terminationReason: "NO_TOOL_CALL"}')
  local out_stop
  out_stop=$(printf '%s' "$p_stop" | "$STOP_GATE")
  assert_json_field "$out_stop" ".decision" "continue" "Stop gate must block premature exit with continue"
  assert_contains "$(printf '%s' "$out_stop" | jq -r '.reason')" "pr-auditor" "Stop gate reason must request pr-auditor"
  assert_json_field "$pending_file" ".stopRetries" "1" "stopRetries must be incremented to 1"

  # ---------------------------------------------------------------------------
  # Step 9: Clear PR audit stamp -> Stop Gate allows clean termination
  # ---------------------------------------------------------------------------
  "$STAMP_GATE" clear-pr-audit --workspace "$repo"
  [ ! -f "$pending_file" ] || { echo "clear-pr-audit failed to remove pr-audit-pending.json" >&2; return 1; }

  local out_stop_clean
  out_stop_clean=$(printf '%s' "$p_stop" | "$STOP_GATE" | jq -c .)
  assert_eq "{}" "$out_stop_clean" "Stop gate after clearing pr-audit must output {} allowing clean exit"
}

run_tests
