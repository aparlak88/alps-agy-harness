#!/usr/bin/env bash
# Alps AGY Harness - Subagent Overwrite Guard & Post-PR Stop Gate Tests (test-subagent-and-stop-hooks.sh)
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-helpers.sh"

PRE_SUBAGENT_GUARD="$REPO_ROOT/scripts/hooks/pre-subagent-guard.sh"
STOP_GATE="$REPO_ROOT/scripts/hooks/stop-gate.sh"
POST_COMMAND_HOOKS="$REPO_ROOT/scripts/hooks/post-command-hooks.sh"
STAMP_GATE="$REPO_ROOT/scripts/stamp-gate.sh"

EXPECTED_LOW="[EFFORT_PROFILE: LOW — Hedef odaklı çalış; en fazla 3 okuma turu yap, spekülatif dallanma yapma, yanıtı kısa tut.]"
EXPECTED_MEDIUM="[EFFORT_PROFILE: MEDIUM — Standart TDD döngüsü uygula; yalnız görev kapsamındaki dosyaları ve doğrudan bağımlılıklarını incele.]"
EXPECTED_HIGH="[EFFORT_PROFILE: HIGH — Katman sınırlarını, LSP tanılamalarını ve kenar durumları çapraz doğrula; her iddiayı dosya/satır kanıtına bağla.]"
EXPECTED_XHIGH="[EFFORT_PROFILE: XHIGH — Derin çok adımlı muhakeme uygula; katman sözleşmelerini, tip güvenliğini ve tüm hata/kenar yollarını uçtan uca doğrula.]"
EXPECTED_MAX="[EFFORT_PROFILE: MAX — Sıfır varsayım; tüm bağımlılık zincirini, karşı-örnekleri ve güvenlik/kanon değişmezlerini satır satır kanıtla.]"
EXPECTED_SWARM_CONTRACT="[SWARM_WORKER_CONTRACT — Koordinatör brief kapsamına sadık kal; yeniden jev_classify, brainstorming, Spec, Walkthrough veya gh pr create çalıştırma; docs/parking-lot.md ve docs/canon/* önerilerini panoda @coordinator'a bildir.]"
EXPECTED_SWARM_BRANCH_GUARD="[SWARM_BRANCH_GUARD — Koda dokunmadan önce kendi özellik dalını aç (git checkout -b feat/<konu>-<ad>); detached HEAD veya main üzerinde kalma.]"
EXPECTED_STOP_REASON="PR açıldı; oturumu kapatmadan önce review-pr skill'ini kullanarak pr-auditor değerlendirmesini çalıştır."

test_security_and_pr_auditor_auto_overwrite_to_pro() {
  [ -x "$PRE_SUBAGENT_GUARD" ] || { echo "pre-subagent-guard.sh missing or not executable: $PRE_SUBAGENT_GUARD" >&2; return 1; }

  local repo
  repo=$(make_temp_repo)

  # 1. security-reviewer called with flash_lite without pre-registration -> auto overwrite pro + MAX
  local p_sec
  p_sec=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "security-reviewer",
        Role: "Auth Security Audit",
        Model: "flash_lite",
        Prompt: "Audit authentication flow."
      }
    }
  }')
  local out_sec
  out_sec=$(printf '%s\n' "$p_sec" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_sec" ".decision" "allow" "security-reviewer should be allowed"
  assert_json_field "$out_sec" ".overwrite.Model" "pro" "security-reviewer must overwrite Model to pro"
  assert_json_field "$out_sec" ".overwrite.Prompt" "${EXPECTED_MAX}"$'\n\n'"Audit authentication flow." "security-reviewer must inject MAX effort profile"

  # 2. security-reviewer with pre-existing dispatch entry marks consumed = true cleanly
  "$STAMP_GATE" dispatch --role "Pre-registered Sec" --type "security-reviewer" --tier "bounded_execution" --workspace "$repo"
  local p_sec2
  p_sec2=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "security-reviewer",
        Role: "Pre-registered Sec",
        Prompt: "Check tokens."
      }
    }
  }')
  local out_sec2
  out_sec2=$(printf '%s\n' "$p_sec2" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_sec2" ".overwrite.Model" "pro" "security-reviewer still forces pro"
  assert_json_field "$out_sec2" ".overwrite.Prompt" "${EXPECTED_MAX}"$'\n\n'"Check tokens." "security-reviewer still forces MAX"
  assert_json_field "$repo/.harness/state/main/subagent-dispatch.json" '.entries["Pre-registered Sec"].consumed' "true" "Pre-registered security-reviewer entry marked consumed"

  # 3. pr-auditor without dispatch -> auto overwrite pro + HIGH
  local p_pr_default
  p_pr_default=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "pr-auditor",
        Role: "PR #42 Auditor",
        Model: "flash",
        Prompt: "Review PR #42."
      }
    }
  }')
  local out_pr_default
  out_pr_default=$(printf '%s\n' "$p_pr_default" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_pr_default" ".decision" "allow" "pr-auditor should be allowed"
  assert_json_field "$out_pr_default" ".overwrite.Model" "pro" "pr-auditor must overwrite Model to pro"
  assert_json_field "$out_pr_default" ".overwrite.Prompt" "${EXPECTED_HIGH}"$'\n\n'"Review PR #42." "pr-auditor defaults to HIGH effort profile"

  # 4. pr-auditor with MAX dispatch -> overwrite pro + MAX and consumed = true
  "$STAMP_GATE" dispatch --role "Critical PR #99 Auditor" --type "pr-auditor" --tier "critical_architecture_or_audit" --workspace "$repo"
  local p_pr_max
  p_pr_max=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "pr-auditor",
        Role: "Critical PR #99 Auditor",
        Model: "flash_lite",
        Prompt: "Deep review PR #99."
      }
    }
  }')
  local out_pr_max
  out_pr_max=$(printf '%s\n' "$p_pr_max" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_pr_max" ".overwrite.Model" "pro" "pr-auditor with MAX dispatch uses pro"
  assert_json_field "$out_pr_max" ".overwrite.Prompt" "${EXPECTED_MAX}"$'\n\n'"Deep review PR #99." "pr-auditor upgrades to MAX when dispatch specifies MAX"
  assert_json_field "$repo/.harness/state/main/subagent-dispatch.json" '.entries["Critical PR #99 Auditor"].consumed' "true" "pr-auditor dispatch entry marked consumed"
}

test_browser_and_image_generator_routing_and_harness_ignore() {
  [ -x "$PRE_SUBAGENT_GUARD" ] || { echo "pre-subagent-guard.sh missing or not executable: $PRE_SUBAGENT_GUARD" >&2; return 1; }
  [ -x "$STOP_GATE" ] || { echo "stop-gate.sh missing or not executable: $STOP_GATE" >&2; return 1; }

  local repo
  repo=$(make_temp_repo)

  # 1. browser with omitted Model -> overwrite Model to flash without touching Prompt
  local p_browser_empty
  p_browser_empty=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "browser",
        Role: "UI Smoke Tester",
        Prompt: "Open localhost:3000 and verify header."
      }
    }
  }')
  local out_browser_empty
  out_browser_empty=$(printf '%s\n' "$p_browser_empty" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_browser_empty" ".decision" "allow" "browser should be allowed"
  assert_json_field "$out_browser_empty" ".overwrite.Model" "flash" "browser without Model should overwrite to flash"
  assert_json_field "$out_browser_empty" ".overwrite | has(\"Prompt\")" "false" "browser overwrite must NOT touch Prompt"

  # 2. browser with explicit Model -> plain allow without overwrite
  local p_browser_explicit
  p_browser_explicit=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "browser",
        Role: "Complex UI Inspector",
        Model: "pro",
        Prompt: "Debug complex canvas state."
      }
    }
  }')
  local out_browser_explicit
  out_browser_explicit=$(printf '%s\n' "$p_browser_explicit" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_browser_explicit" ".decision" "allow" "browser with explicit Model should be allowed"
  assert_json_field "$out_browser_explicit" "has(\"overwrite\")" "false" "browser with explicit Model must not overwrite"

  # 3. image-generator -> direct allow
  local p_img
  p_img=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "image-generator",
        Role: "Hero Banner Designer",
        Prompt: "Generate minimalist hero icon."
      }
    }
  }')
  local out_img
  out_img=$(printf '%s\n' "$p_img" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_img" ".decision" "allow" "image-generator should be allowed"
  assert_json_field "$out_img" "has(\"overwrite\")" "false" "image-generator must not overwrite"

  # 4. .harness-ignore bypasses both pre-subagent-guard.sh and stop-gate.sh
  touch "$repo/.harness-ignore"
  mkdir -p "$repo/.harness/state/main"
  printf '{"prUrl":"https://github.com/org/repo/pull/1","stopRetries":0}\n' > "$repo/.harness/state/main/pr-audit-pending.json"

  local p_ignored_self
  p_ignored_self=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "self",
        Role: "Ignored Worker",
        Prompt: "Work freely."
      }
    }
  }')
  local out_ignored_self
  out_ignored_self=$(printf '%s\n' "$p_ignored_self" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_ignored_self" ".decision" "allow" ".harness-ignore must allow unregistered self"
  assert_json_field "$out_ignored_self" "has(\"overwrite\")" "false" ".harness-ignore must not overwrite"

  local p_ignored_stop
  p_ignored_stop=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], terminationReason: "NO_TOOL_CALL"}')
  local out_ignored_stop
  out_ignored_stop=$(printf '%s\n' "$p_ignored_stop" | "$STOP_GATE" | jq -c .)
  assert_eq "{}" "$out_ignored_stop" ".harness-ignore must return {} on Stop"
}

test_self_and_research_denied_without_jev_dispatch_and_consumed_once() {
  [ -x "$PRE_SUBAGENT_GUARD" ] || { echo "pre-subagent-guard.sh missing or not executable: $PRE_SUBAGENT_GUARD" >&2; return 1; }

  local repo
  repo=$(make_temp_repo)

  # 1. Unregistered self -> deny with actionable message
  local p_self
  p_self=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "self",
        Role: "Task 1 Implementer",
        Model: "pro",
        Prompt: "Implement Task 1."
      }
    }
  }')
  local out_deny1
  out_deny1=$(printf '%s\n' "$p_self" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_deny1" ".decision" "deny" "Unregistered self call must be denied"
  local deny_reason1
  deny_reason1=$(printf '%s\n' "$out_deny1" | jq -r '.reason // empty')
  assert_contains "$deny_reason1" "jev_classify" "Deny reason should mention jev_classify"
  assert_contains "$deny_reason1" "stamp-gate.sh dispatch" "Deny reason should mention stamp-gate.sh dispatch"

  # 2. Unregistered research -> deny
  local p_res_unreg
  p_res_unreg=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "research",
        Role: "Codebase Finder",
        Prompt: "Find config files."
      }
    }
  }')
  local out_res_unreg
  out_res_unreg=$(printf '%s\n' "$p_res_unreg" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_res_unreg" ".decision" "deny" "Unregistered research call must be denied"

  # 3. Dispatch Task 1 Implementer (self, bounded_execution -> flash + MEDIUM)
  "$STAMP_GATE" dispatch --role "Task 1 Implementer" --type "self" --tier "bounded_execution" --workspace "$repo"

  # Calling with wrong TypeName ("research") for that Role must deny without consuming
  local p_wrong_type
  p_wrong_type=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "research",
        Role: "Task 1 Implementer",
        Prompt: "Wrong type test."
      }
    }
  }')
  local out_wrong_type
  out_wrong_type=$(printf '%s\n' "$p_wrong_type" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_wrong_type" ".decision" "deny" "Mismatched TypeName must be denied"
  assert_json_field "$repo/.harness/state/main/subagent-dispatch.json" '.entries["Task 1 Implementer"].consumed' "false" "Mismatched TypeName must not consume entry"

  # 4. First valid call succeeds with flash + MEDIUM and marks consumed = true
  local out_allow1
  out_allow1=$(printf '%s\n' "$p_self" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_allow1" ".decision" "allow" "Dispatched self call should be allowed"
  assert_json_field "$out_allow1" ".overwrite.Model" "flash" "bounded_execution must overwrite Model to flash"
  assert_json_field "$out_allow1" ".overwrite.Prompt" "${EXPECTED_MEDIUM}"$'\n\n'"Implement Task 1." "bounded_execution must inject MEDIUM header"
  assert_json_field "$repo/.harness/state/main/subagent-dispatch.json" '.entries["Task 1 Implementer"].consumed' "true" "Entry must be marked consumed"

  # 5. Second call with same Role without re-dispatch -> deny (consumed == true)
  local out_deny2
  out_deny2=$(printf '%s\n' "$p_self" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_deny2" ".decision" "deny" "Second call on consumed Role must be denied"

  # 6. Verify research with trivial_lookup -> flash_lite + LOW, and custom subagent with multi_module_integration -> inherit + HIGH
  "$STAMP_GATE" dispatch --role "Quick Symbol Lookup" --type "research" --tier "trivial_lookup" --workspace "$repo"
  local p_res_ok
  p_res_ok=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "research",
        Role: "Quick Symbol Lookup",
        Prompt: "Locate AuthController."
      }
    }
  }')
  local out_res_ok
  out_res_ok=$(printf '%s\n' "$p_res_ok" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_res_ok" ".overwrite.Model" "flash_lite" "trivial_lookup must overwrite Model to flash_lite"
  assert_json_field "$out_res_ok" ".overwrite.Prompt" "${EXPECTED_LOW}"$'\n\n'"Locate AuthController." "trivial_lookup must inject LOW header"

  "$STAMP_GATE" dispatch --role "Cross-Module Integrator" --type "custom-integrator" --tier "multi_module_integration" --workspace "$repo"
  local p_custom
  p_custom=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "custom-integrator",
        Role: "Cross-Module Integrator",
        Prompt: "Wire API and DB adapters."
      }
    }
  }')
  local out_custom
  out_custom=$(printf '%s\n' "$p_custom" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_custom" ".overwrite.Model" "inherit" "multi_module_integration must overwrite Model to inherit"
  assert_json_field "$out_custom" ".overwrite.Prompt" "${EXPECTED_HIGH}"$'\n\n'"Wire API and DB adapters." "multi_module_integration must inject HIGH header"
}

test_canon_auditor_floor_upgrade() {
  [ -x "$PRE_SUBAGENT_GUARD" ] || { echo "pre-subagent-guard.sh missing or not executable: $PRE_SUBAGENT_GUARD" >&2; return 1; }

  local repo
  repo=$(make_temp_repo)

  # 1. trivial_lookup -> upgraded from flash_lite/LOW to pro/HIGH
  "$STAMP_GATE" dispatch --role "Canon Check 1" --type "canon-auditor" --tier "trivial_lookup" --workspace "$repo"
  local p1
  p1=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "canon-auditor",
        Role: "Canon Check 1",
        Model: "flash_lite",
        Prompt: "Verify spec compliance."
      }
    }
  }')
  local out1
  out1=$(printf '%s\n' "$p1" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out1" ".decision" "allow" "Dispatched canon-auditor should be allowed"
  assert_json_field "$out1" ".overwrite.Model" "pro" "canon-auditor trivial_lookup must upgrade Model to pro"
  assert_json_field "$out1" ".overwrite.Prompt" "${EXPECTED_HIGH}"$'\n\n'"Verify spec compliance." "canon-auditor trivial_lookup must upgrade effort to HIGH"

  # 2. bounded_execution -> upgraded from flash/MEDIUM to pro/HIGH
  "$STAMP_GATE" dispatch --role "Canon Check 2" --type "canon-auditor" --tier "bounded_execution" --workspace "$repo"
  local p2
  p2=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "canon-auditor",
        Role: "Canon Check 2",
        Prompt: "Verify plan compliance."
      }
    }
  }')
  local out2
  out2=$(printf '%s\n' "$p2" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out2" ".overwrite.Model" "pro" "canon-auditor bounded_execution must upgrade Model to pro"
  assert_json_field "$out2" ".overwrite.Prompt" "${EXPECTED_HIGH}"$'\n\n'"Verify plan compliance." "canon-auditor bounded_execution must upgrade effort to HIGH"

  # 3. multi_module_integration -> preserved as inherit/HIGH
  "$STAMP_GATE" dispatch --role "Canon Check 3" --type "canon-auditor" --tier "multi_module_integration" --workspace "$repo"
  local p3
  p3=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "canon-auditor",
        Role: "Canon Check 3",
        Prompt: "Verify module boundaries."
      }
    }
  }')
  local out3
  out3=$(printf '%s\n' "$p3" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out3" ".overwrite.Model" "inherit" "canon-auditor multi_module_integration preserves inherit"
  assert_json_field "$out3" ".overwrite.Prompt" "${EXPECTED_HIGH}"$'\n\n'"Verify module boundaries." "canon-auditor multi_module_integration uses HIGH"

  # 4. critical_architecture_or_audit -> preserved as pro/MAX
  "$STAMP_GATE" dispatch --role "Canon Check 4" --type "canon-auditor" --tier "critical_architecture_or_audit" --workspace "$repo"
  local p4
  p4=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "canon-auditor",
        Role: "Canon Check 4",
        Prompt: "Verify full architecture canon."
      }
    }
  }')
  local out4
  out4=$(printf '%s\n' "$p4" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out4" ".overwrite.Model" "pro" "canon-auditor critical_architecture_or_audit uses pro"
  assert_json_field "$out4" ".overwrite.Prompt" "${EXPECTED_MAX}"$'\n\n'"Verify full architecture canon." "canon-auditor critical_architecture_or_audit uses MAX"
}

test_gemini4_and_orchestrator_parent_aware_subagent_routing() {
  [ -x "$PRE_SUBAGENT_GUARD" ] || { echo "pre-subagent-guard.sh missing or not executable: $PRE_SUBAGENT_GUARD" >&2; return 1; }

  local repo
  repo=$(make_temp_repo)

  # 1. Gemini 4 Carbon parent:
  #    - security-reviewer & pr-auditor stay on inherit (Carbon, never downgraded to Argon!)
  #    - self bounded_execution steps down to pro (Argon)
  #    - canon-auditor multi_module_integration defaults to pro (Argon), or preserves explicit caller Model="inherit"
  #    - research trivial_lookup uses flash_lite
  local p_carbon_sec out_carbon_sec
  p_carbon_sec=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    modelName: "gemini-4-carbon-high",
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "security-reviewer",
        Role: "Carbon Sec Audit",
        Model: "pro",
        Prompt: "Audit Carbon auth."
      }
    }
  }')
  out_carbon_sec=$(printf '%s\n' "$p_carbon_sec" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_carbon_sec" ".overwrite.Model" "inherit" "Carbon parent must keep security-reviewer on inherit (Carbon)"
  assert_json_field "$out_carbon_sec" ".overwrite.Prompt" "${EXPECTED_MAX}"$'\n\n'"Audit Carbon auth." "Carbon security-reviewer uses MAX"

  local p_carbon_pr out_carbon_pr
  p_carbon_pr=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    modelName: "Gemini 4 Carbon (Medium)",
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "pr-auditor",
        Role: "Carbon PR Audit",
        Prompt: "Review PR on Carbon."
      }
    }
  }')
  out_carbon_pr=$(printf '%s\n' "$p_carbon_pr" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_carbon_pr" ".overwrite.Model" "inherit" "Carbon parent must keep pr-auditor on inherit (Carbon)"
  assert_json_field "$out_carbon_pr" ".overwrite.Prompt" "${EXPECTED_HIGH}"$'\n\n'"Review PR on Carbon." "Carbon pr-auditor uses HIGH"

  "$STAMP_GATE" dispatch --role "Carbon TDD Worker" --type "self" --tier "bounded_execution" --workspace "$repo"
  local p_carbon_self out_carbon_self
  p_carbon_self=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    modelName: "gemini-4-carbon-high",
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "self",
        Role: "Carbon TDD Worker",
        Prompt: "Implement OrderService."
      }
    }
  }')
  out_carbon_self=$(printf '%s\n' "$p_carbon_self" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_carbon_self" ".overwrite.Model" "pro" "Carbon bounded_execution must step down to pro (Gemini 4 Argon)"
  assert_json_field "$out_carbon_self" ".overwrite.Prompt" "${EXPECTED_MEDIUM}"$'\n\n'"Implement OrderService." "Carbon bounded_execution uses MEDIUM"

  "$STAMP_GATE" dispatch --role "Carbon Canon Default" --type "canon-auditor" --tier "multi_module_integration" --workspace "$repo"
  local p_carbon_canon1 out_carbon_canon1
  p_carbon_canon1=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    modelName: "gemini-4-carbon-high",
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "canon-auditor",
        Role: "Carbon Canon Default",
        Model: "pro",
        Prompt: "Check canon on Argon."
      }
    }
  }')
  out_carbon_canon1=$(printf '%s\n' "$p_carbon_canon1" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_carbon_canon1" ".overwrite.Model" "pro" "Carbon multi_module canon-auditor defaults to pro (Argon)"

  "$STAMP_GATE" dispatch --role "Carbon Canon Inherit" --type "canon-auditor" --tier "multi_module_integration" --workspace "$repo"
  local p_carbon_canon2 out_carbon_canon2
  p_carbon_canon2=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    modelName: "gemini-4-carbon-high",
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "canon-auditor",
        Role: "Carbon Canon Inherit",
        Model: "inherit",
        Prompt: "Check canon on Carbon."
      }
    }
  }')
  out_carbon_canon2=$(printf '%s\n' "$p_carbon_canon2" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_carbon_canon2" ".overwrite.Model" "inherit" "Carbon multi_module canon-auditor preserves explicit Model=inherit"

  "$STAMP_GATE" dispatch --role "Carbon Canon Crit LowEffort" --type "canon-auditor" --tier "critical_architecture_or_audit" --effort "LOW" --workspace "$repo"
  local p_carbon_canon3 out_carbon_canon3
  p_carbon_canon3=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    modelName: "gemini-4-carbon-high",
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "canon-auditor",
        Role: "Carbon Canon Crit LowEffort",
        Model: "pro",
        Prompt: "Audit critical canon on Carbon."
      }
    }
  }')
  out_carbon_canon3=$(printf '%s\n' "$p_carbon_canon3" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_carbon_canon3" ".overwrite.Model" "inherit" "Carbon critical_architecture_or_audit canon-auditor must not demote tier when lifting LOW effort floor"
  assert_json_field "$out_carbon_canon3" ".overwrite.Prompt" "${EXPECTED_HIGH}"$'\n\n'"Audit critical canon on Carbon." "canon-auditor lifts LOW effort up to HIGH floor"

  # 2. Orchestrator parent (gemini-pro-orchestrator):
  #    - bounded_execution, multi_module_integration, security-reviewer, pr-auditor -> inherit (Carbon <-> Hydrogen)
  #    - trivial_lookup -> flash_lite
  "$STAMP_GATE" dispatch --role "Orch Worker" --type "self" --tier "bounded_execution" --workspace "$repo"
  local p_orch_self out_orch_self
  p_orch_self=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    modelName: "gemini-pro-orchestrator",
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "self",
        Role: "Orch Worker",
        Model: "flash",
        Prompt: "Write unit test."
      }
    }
  }')
  out_orch_self=$(printf '%s\n' "$p_orch_self" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_orch_self" ".overwrite.Model" "inherit" "Orchestrator bounded_execution must use inherit (-> Hydrogen)"

  local p_orch_sec out_orch_sec
  p_orch_sec=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    modelName: "Orchestrator",
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "security-reviewer",
        Role: "Orch Sec",
        Prompt: "Audit under Orchestrator."
      }
    }
  }')
  out_orch_sec=$(printf '%s\n' "$p_orch_sec" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_orch_sec" ".overwrite.Model" "inherit" "Orchestrator security-reviewer must use inherit (-> Carbon)"

  # 3. Gemini 4 Hydrogen parent (gemini-4-hydrogen-xhigh):
  #    - bounded_execution with XHIGH -> inherit + XHIGH header (stays on Hydrogen!)
  #    - canon-auditor & security-reviewer -> pro (escalated up to Argon!)
  "$STAMP_GATE" dispatch --role "Hyd XHigh Worker" --type "self" --tier "bounded_execution" --effort "XHIGH" --workspace "$repo"
  local p_hyd_self out_hyd_self
  p_hyd_self=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    modelName: "gemini-4-hydrogen-xhigh",
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "self",
        Role: "Hyd XHigh Worker",
        Model: "flash",
        Prompt: "Implement parser."
      }
    }
  }')
  out_hyd_self=$(printf '%s\n' "$p_hyd_self" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_hyd_self" ".overwrite.Model" "inherit" "Hydrogen bounded_execution keeps inherit (Gemini 4 Hydrogen)"
  assert_json_field "$out_hyd_self" ".overwrite.Prompt" "${EXPECTED_XHIGH}"$'\n\n'"Implement parser." "Hydrogen XHIGH effort header injected"

  local p_hyd_sec out_hyd_sec
  p_hyd_sec=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    modelName: "gemini-4-hydrogen-medium",
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "security-reviewer",
        Role: "Hyd Sec",
        Prompt: "Audit on Hydrogen."
      }
    }
  }')
  out_hyd_sec=$(printf '%s\n' "$p_hyd_sec" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_hyd_sec" ".overwrite.Model" "pro" "Hydrogen security-reviewer escalates to pro (Argon)"

  # 4. Argon Low vs Argon High & Gemini 3.8 Flash:
  local p_argon_low_sec out_argon_low_sec p_argon_high_sec out_argon_high_sec
  p_argon_low_sec=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    modelName: "gemini-4-argon-low",
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "security-reviewer",
        Role: "Argon Low Sec",
        Prompt: "Audit Argon Low."
      }
    }
  }')
  out_argon_low_sec=$(printf '%s\n' "$p_argon_low_sec" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_argon_low_sec" ".overwrite.Model" "pro" "Argon Low security-reviewer upgrades to pro (Argon Medium)"

  p_argon_high_sec=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    modelName: "gemini-4-argon-high",
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "security-reviewer",
        Role: "Argon High Sec",
        Prompt: "Audit Argon High."
      }
    }
  }')
  out_argon_high_sec=$(printf '%s\n' "$p_argon_high_sec" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_argon_high_sec" ".overwrite.Model" "inherit" "Argon High security-reviewer stays on inherit (Argon High)"

  "$STAMP_GATE" dispatch --role "Flash Canon" --type "canon-auditor" --tier "multi_module_integration" --workspace "$repo"
  local p_flash_canon out_flash_canon
  p_flash_canon=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    modelName: "gemini-3.8-flash-low",
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "canon-auditor",
        Role: "Flash Canon",
        Prompt: "Check canon from Flash parent."
      }
    }
  }')
  out_flash_canon=$(printf '%s\n' "$p_flash_canon" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_flash_canon" ".overwrite.Model" "pro" "Flash parent canon-auditor escalates from Flash to pro (Argon)"
}

test_multiline_prompt_with_quotes_backticks_and_dollar_preserved_idempotently() {
  [ -x "$PRE_SUBAGENT_GUARD" ] || { echo "pre-subagent-guard.sh missing or not executable: $PRE_SUBAGENT_GUARD" >&2; return 1; }

  local repo
  repo=$(make_temp_repo)

  # Build input JSON completely inside jq so trailing newlines (\n\n\n), backticks, quotes,
  # backslashes, and shell variables ($HOME, $(whoami)) are encoded without bash stripping!
  local payload1
  payload1=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "security-reviewer",
        Role: "Complex Prompt Audit",
        Model: "flash",
        Prompt: "Line 1 with `inline_code()` and \"double quotes\" and \u0027single quotes\u0027.\nLine 2 with $HOME, ${USER}, $(id -u), and C:\\Users\\admin\\raw\\path.\n```bash\necho \"$HOME\" && printf \u0027%s\\n\u0027 `uname`\n```\nTrailing blank lines follow:\n\n\n"
      }
    }
  }')

  local out1
  out1=$(printf '%s\n' "$payload1" | "$PRE_SUBAGENT_GUARD")

  # Verify exact byte-for-byte preservation (including all 3 trailing newlines!) inside jq
  jq -e \
    --arg header "$EXPECTED_MAX" \
    --argjson req "$payload1" \
    '.decision == "allow"
     and .overwrite.Model == "pro"
     and .overwrite.Prompt == ($header + "\n\n" + $req.toolCall.args.Prompt)
     and (.overwrite.Prompt | endswith("Trailing blank lines follow:\n\n\n"))' \
    <<< "$out1" >/dev/null || {
      echo "First pass failed byte-for-byte prompt preservation check!" >&2
      echo "Output was: $out1" >&2
      return 1
    }

  # Second pass (idempotency): feed already-prefixed Prompt back into pre-subagent-guard.sh
  local payload2
  payload2=$(jq -nc --arg ws "$repo" --argjson prev "$out1" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "security-reviewer",
        Role: "Complex Prompt Audit Retry",
        Model: "flash_lite",
        Prompt: $prev.overwrite.Prompt
      }
    }
  }')

  local out2
  out2=$(printf '%s\n' "$payload2" | "$PRE_SUBAGENT_GUARD")

  jq -e \
    --argjson first "$out1" \
    '.decision == "allow"
     and .overwrite.Model == "pro"
     and .overwrite.Prompt == $first.overwrite.Prompt' \
    <<< "$out2" >/dev/null || {
      echo "Second pass failed idempotency check (double-prefixed or mutated Prompt)!" >&2
      echo "First:  $out1" >&2
      echo "Second: $out2" >&2
      return 1
    }
}

test_stop_gate_blocks_twice_then_releases_and_clears() {
  [ -x "$STOP_GATE" ] || { echo "stop-gate.sh missing or not executable: $STOP_GATE" >&2; return 1; }

  local repo
  repo=$(make_temp_repo)

  local stop_no_tool
  stop_no_tool=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], terminationReason: "NO_TOOL_CALL"}')

  # 1. No pr-audit-pending.json -> returns {}
  local out_initial
  out_initial=$(printf '%s\n' "$stop_no_tool" | "$STOP_GATE" | jq -c .)
  assert_eq "{}" "$out_initial" "Stop gate without pending PR audit must return {}"

  # 2. Trigger post-command-hooks.sh with gh pr create to write pr-audit-pending.json
  local pr_create_payload
  pr_create_payload=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "run_command",
      args: {CommandLine: "gh pr create --fill"}
    },
    toolOutput: {output: "https://github.com/alps/harness/pull/15\n"}
  }')
  printf '%s\n' "$pr_create_payload" | "$POST_COMMAND_HOOKS" >/dev/null
  assert_json_field "$repo/.harness/state/main/pr-audit-pending.json" ".stopRetries" "0" "Initial stopRetries must be 0"
  assert_json_field "$repo/.harness/state/main/pr-audit-pending.json" ".auditDispatched" "false" "Initial auditDispatched must be false"

  # 3. Non-NO_TOOL_CALL terminationReason returns {} without incrementing stopRetries
  local stop_other
  stop_other=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], terminationReason: "USER_ABORT"}')
  local out_other
  out_other=$(printf '%s\n' "$stop_other" | "$STOP_GATE" | jq -c .)
  assert_eq "{}" "$out_other" "Non-NO_TOOL_CALL terminationReason must return {}"
  assert_json_field "$repo/.harness/state/main/pr-audit-pending.json" ".stopRetries" "0" "stopRetries must stay 0 on USER_ABORT"

  # 4. 1st NO_TOOL_CALL -> continue (stopRetries becomes 1, auditDispatched stays false)
  local out_try1
  out_try1=$(printf '%s\n' "$stop_no_tool" | "$STOP_GATE")
  assert_json_field "$out_try1" ".decision" "continue" "1st NO_TOOL_CALL must return continue"
  assert_json_field "$out_try1" ".reason" "$EXPECTED_STOP_REASON" "1st NO_TOOL_CALL reason must match contract"
  assert_json_field "$repo/.harness/state/main/pr-audit-pending.json" ".stopRetries" "1" "stopRetries must increment to 1"
  assert_json_field "$repo/.harness/state/main/pr-audit-pending.json" ".auditDispatched" "false" "auditDispatched must remain false after 1st NO_TOOL_CALL"
  assert_json_field "$repo/.harness/state/main/pr-audit-pending.json" ".prUrl" "https://github.com/alps/harness/pull/15" "prUrl must be preserved"

  # 5. 2nd NO_TOOL_CALL -> continue (stopRetries becomes 2, auditDispatched stays false)
  local out_try2
  out_try2=$(printf '%s\n' "$stop_no_tool" | "$STOP_GATE")
  assert_json_field "$out_try2" ".decision" "continue" "2nd NO_TOOL_CALL must return continue"
  assert_json_field "$out_try2" ".reason" "$EXPECTED_STOP_REASON" "2nd NO_TOOL_CALL reason must match contract"
  assert_json_field "$repo/.harness/state/main/pr-audit-pending.json" ".stopRetries" "2" "stopRetries must increment to 2"
  assert_json_field "$repo/.harness/state/main/pr-audit-pending.json" ".auditDispatched" "false" "auditDispatched must remain false after 2nd NO_TOOL_CALL"

  # 6. 3rd NO_TOOL_CALL -> {} (escape hatch at stopRetries >= 2)
  local out_try3
  out_try3=$(printf '%s\n' "$stop_no_tool" | "$STOP_GATE" | jq -c .)
  assert_eq "{}" "$out_try3" "3rd NO_TOOL_CALL must return {} to prevent infinite loop"

  # 7. Re-create pending PR audit and clear via stamp-gate.sh clear-pr-audit -> 1st NO_TOOL_CALL returns {}
  printf '%s\n' "$pr_create_payload" | "$POST_COMMAND_HOOKS" >/dev/null
  assert_json_field "$repo/.harness/state/main/pr-audit-pending.json" ".stopRetries" "0" "Re-seeded stopRetries is 0"

  "$STAMP_GATE" clear-pr-audit --workspace "$repo"
  local out_after_clear
  out_after_clear=$(printf '%s\n' "$stop_no_tool" | "$STOP_GATE" | jq -c .)
  assert_eq "{}" "$out_after_clear" "After clear-pr-audit, 1st NO_TOOL_CALL must return {}"
}

test_stop_gate_allows_async_wait_when_pr_auditor_dispatched() {
  [ -x "$PRE_SUBAGENT_GUARD" ] || { echo "pre-subagent-guard.sh missing or not executable: $PRE_SUBAGENT_GUARD" >&2; return 1; }
  [ -x "$STOP_GATE" ] || { echo "stop-gate.sh missing or not executable: $STOP_GATE" >&2; return 1; }

  local repo
  repo=$(make_temp_repo)
  local pending_file="$repo/.harness/state/main/pr-audit-pending.json"
  local stop_no_tool
  stop_no_tool=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], terminationReason: "NO_TOOL_CALL"}')

  # 1. Trigger post-command-hooks.sh on gh pr create -> stopRetries=0, auditDispatched=false
  local pr_create_payload
  pr_create_payload=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "run_command",
      args: {CommandLine: "gh pr create --fill"}
    },
    toolOutput: {output: "https://github.com/alps/harness/pull/77\n"}
  }')
  printf '%s\n' "$pr_create_payload" | "$POST_COMMAND_HOOKS" >/dev/null
  assert_json_field "$pending_file" ".stopRetries" "0" "Initial stopRetries must be 0"
  assert_json_field "$pending_file" ".auditDispatched" "false" "Initial auditDispatched must be false"

  # 2. Dispatching pr-auditor flips auditDispatched=true while preserving stopRetries and prUrl
  local p_pr_auditor
  p_pr_auditor=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "pr-auditor",
        Role: "PR #77 Auditor",
        Prompt: "Audit PR #77."
      }
    }
  }')
  local out_pr_auditor
  out_pr_auditor=$(printf '%s\n' "$p_pr_auditor" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_pr_auditor" ".decision" "allow" "pr-auditor invocation must be allowed"
  assert_json_field "$pending_file" ".auditDispatched" "true" "pr-auditor invocation must set auditDispatched=true"
  assert_json_field "$pending_file" ".stopRetries" "0" "stopRetries must remain 0 after pr-auditor dispatch"
  assert_json_field "$pending_file" ".prUrl" "https://github.com/alps/harness/pull/77" "prUrl must be preserved"

  # 3. 1st NO_TOOL_CALL immediately returns {} without touching stopRetries
  local out_async_wait
  out_async_wait=$(printf '%s\n' "$stop_no_tool" | "$STOP_GATE" | jq -c .)
  assert_eq "{}" "$out_async_wait" "stop-gate must return {} immediately while pr-auditor is dispatched"
  assert_json_field "$pending_file" ".stopRetries" "0" "stopRetries must not increment when auditDispatched=true"

  # 4. Re-seed pending state; test unrelated self, unregistered self PR audit, and dispatched self PR audit
  printf '%s\n' "$pr_create_payload" | "$POST_COMMAND_HOOKS" >/dev/null
  assert_json_field "$pending_file" ".auditDispatched" "false" "Re-seeded auditDispatched must be false"

  # (a) Unrelated self worker must NOT set auditDispatched=true (even if prompt mentions pr-audit-pending or clear-pr-audit)
  "$STAMP_GATE" dispatch --role "Formatter Worker" --type "self" --tier "bounded_execution" --workspace "$repo"
  local p_unrelated_self
  p_unrelated_self=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "self",
        Role: "Formatter Worker",
        Prompt: "Format files and check pr-audit-pending / clear-pr-audit docs."
      }
    }
  }')
  local out_unrelated
  out_unrelated=$(printf '%s\n' "$p_unrelated_self" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_unrelated" ".decision" "allow" "Dispatched unrelated self worker must be allowed"
  assert_json_field "$pending_file" ".auditDispatched" "false" "Unrelated self worker mentioning pr-audit-pending must leave auditDispatched=false"

  # (b) Unregistered self PR audit must be denied and must NOT set auditDispatched=true
  local p_unreg_self_pr
  p_unreg_self_pr=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "self",
        Role: "PR Auditor",
        Prompt: "Execute review-pr and clear-pr-audit."
      }
    }
  }')
  local out_unreg_self_pr
  out_unreg_self_pr=$(printf '%s\n' "$p_unreg_self_pr" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_unreg_self_pr" ".decision" "deny" "Unregistered self PR auditor must be denied"
  assert_json_field "$pending_file" ".auditDispatched" "false" "Denied self PR auditor must leave auditDispatched=false"

  # (c) Dispatched self PR auditor sets auditDispatched=true and allows immediate {} stop
  "$STAMP_GATE" dispatch --role "Async PR Auditor" --type "self" --tier "critical_architecture_or_audit" --workspace "$repo"
  local p_dispatched_self_pr
  p_dispatched_self_pr=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "self",
        Role: "Async PR Auditor",
        Prompt: "Execute review-pr and clear-pr-audit."
      }
    }
  }')
  local out_dispatched_self_pr
  out_dispatched_self_pr=$(printf '%s\n' "$p_dispatched_self_pr" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_dispatched_self_pr" ".decision" "allow" "Dispatched self PR auditor must be allowed"
  assert_json_field "$pending_file" ".auditDispatched" "true" "Dispatched self PR auditor must set auditDispatched=true"

  local out_async_self_wait
  out_async_self_wait=$(printf '%s\n' "$stop_no_tool" | "$STOP_GATE" | jq -c .)
  assert_eq "{}" "$out_async_self_wait" "stop-gate must return {} immediately after self PR auditor dispatch"
  assert_json_field "$pending_file" ".stopRetries" "0" "stopRetries must stay 0 after self PR auditor dispatch"

  # 5. clear-pr-audit removes pr-audit-pending.json cleanly
  "$STAMP_GATE" clear-pr-audit --workspace "$repo"
  [ ! -f "$pending_file" ] || { echo "clear-pr-audit must remove pr-audit-pending.json" >&2; return 1; }
}

test_parallel_subagent_dispatch_locking_and_sibling_worktree_discovery() {
  local main_repo wt_parent wt_backend wt_ios
  main_repo=$(make_temp_repo)
  echo "init" > "$main_repo/README.md"
  git -C "$main_repo" add README.md
  git -C "$main_repo" commit -m "chore: init" --quiet

  # 1. Parallel dispatch registration under flock: 8 concurrent workers must leave all 8 entries intact
  local dpids=()
  for i in 1 2 3 4 5 6 7 8; do
    "$STAMP_GATE" dispatch --role "Worker $i" --type "self" --tier "bounded_execution" --workspace "$main_repo" &
    dpids+=("$!")
  done
  for p in "${dpids[@]}"; do
    wait "$p"
  done

  local dispatch_file="$main_repo/.harness/state/main/subagent-dispatch.json"
  local entry_count
  entry_count=$(jq -r '.entries | keys | length' "$dispatch_file")
  assert_eq "8" "$entry_count" "All 8 concurrent dispatch registrations must survive without lost updates"

  # 2. Parallel consumption + duplicate race: 8 unique + 2 duplicates -> exactly 8 allow and 2 deny
  local out_dir
  out_dir=$(mktemp -d "${TMPDIR:-/tmp}/harness-sub-race.XXXXXX")
  echo "$out_dir" >> "$_HARNESS_TEMP_TRACKER"
  local cpids=()
  for i in 1 2 3 4 5 6 7 8; do
    (
      jq -nc --arg ws "$main_repo" --arg role "Worker $i" \
        '{workspacePaths: [$ws], toolCall: {name: "invoke_subagent", args: {TypeName: "self", Role: $role, Prompt: "Run task."}}}' \
        | "$PRE_SUBAGENT_GUARD" > "$out_dir/w-$i.json"
    ) &
    cpids+=("$!")
  done
  for d in 1 2; do
    (
      jq -nc --arg ws "$main_repo" \
        '{workspacePaths: [$ws], toolCall: {name: "invoke_subagent", args: {TypeName: "self", Role: "Worker 1", Prompt: "Duplicate task."}}}' \
        | "$PRE_SUBAGENT_GUARD" > "$out_dir/dup-$d.json"
    ) &
    cpids+=("$!")
  done
  for p in "${cpids[@]}"; do
    wait "$p"
  done

  local allow_cnt=0 deny_cnt=0 f dec
  for f in "$out_dir"/*.json; do
    dec=$(jq -r '.decision' "$f")
    if [ "$dec" = "allow" ]; then
      allow_cnt=$((allow_cnt + 1))
    elif [ "$dec" = "deny" ]; then
      deny_cnt=$((deny_cnt + 1))
    fi
  done
  assert_eq "8" "$allow_cnt" "Exactly 8 parallel unique invocations must be allowed"
  assert_eq "2" "$deny_cnt" "Exactly 2 duplicate invocations for Worker 1 must be denied"
  jq -e 'type == "object" and ((.entries | to_entries | all(.value.consumed == true)))' "$dispatch_file" >/dev/null || {
    echo "subagent-dispatch.json corrupted or unconsumed entries remain" >&2
    return 1
  }

  # 3. Sibling worktree discovery: Prompt-mentioned worktree first, then git worktree list fallback
  wt_parent=$(mktemp -d "${TMPDIR:-/tmp}/harness-wt-sub.XXXXXX")
  echo "$wt_parent" >> "$_HARNESS_TEMP_TRACKER"
  wt_backend="$wt_parent/kedo-backend"
  wt_ios="$wt_parent/kedo-ios"
  git -C "$main_repo" worktree add "$wt_backend" -b "feat/backend" --quiet
  git -C "$main_repo" worktree add "$wt_ios" -b "feat/ios" --quiet

  "$STAMP_GATE" dispatch --role "Shared Implementer" --type "self" --tier "multi_module_integration" --workspace "$wt_backend"
  "$STAMP_GATE" dispatch --role "Shared Implementer" --type "self" --tier "trivial_lookup" --workspace "$wt_ios"

  local p_wt_prompt out_wt_prompt
  p_wt_prompt=$(jq -nc --arg ws "$main_repo" --arg prompt "Implement controller in $wt_backend/src/Api.cs" '{
    workspacePaths: [$ws],
    toolCall: {name: "invoke_subagent", args: {TypeName: "self", Role: "Shared Implementer", Prompt: $prompt}}
  }')
  out_wt_prompt=$(printf '%s\n' "$p_wt_prompt" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_wt_prompt" ".decision" "allow"
  assert_json_field "$out_wt_prompt" ".overwrite.Model" "inherit" "Prompt mentioning wt_backend must consume wt_backend entry first"
  assert_json_field "$wt_backend/.harness/state/feat-backend/subagent-dispatch.json" '.entries["Shared Implementer"].consumed' "true"
  assert_json_field "$wt_ios/.harness/state/feat-ios/subagent-dispatch.json" '.entries["Shared Implementer"].consumed' "false"

  local p_wt_fallback out_wt_fallback
  p_wt_fallback=$(jq -nc --arg ws "$main_repo" '{
    workspacePaths: [$ws],
    toolCall: {name: "invoke_subagent", args: {TypeName: "self", Role: "Shared Implementer", Prompt: "Lookup iOS target."}}
  }')
  out_wt_fallback=$(printf '%s\n' "$p_wt_fallback" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_wt_fallback" ".decision" "allow"
  assert_json_field "$out_wt_fallback" ".overwrite.Model" "flash_lite" "Without prompt path, worktree list discovery must consume wt_ios entry"
  assert_json_field "$wt_ios/.harness/state/feat-ios/subagent-dispatch.json" '.entries["Shared Implementer"].consumed' "true"
}

test_conversation_id_isolated_pr_audit_and_stop_gate() {
  local main_repo wt_parent wt_backend
  main_repo=$(make_temp_repo)
  echo "init" > "$main_repo/README.md"
  git -C "$main_repo" add README.md
  git -C "$main_repo" commit -m "chore: init" --quiet

  wt_parent=$(mktemp -d "${TMPDIR:-/tmp}/harness-wt-stop.XXXXXX")
  echo "$wt_parent" >> "$_HARNESS_TEMP_TRACKER"
  wt_backend="$wt_parent/kedo-backend"
  git -C "$main_repo" worktree add "$wt_backend" -b "feat/backend" --quiet

  # 1. post-command on cd <wt_backend> && gh pr create saves pr-audit-pending.json in wt_backend with conversationId
  local p_post_pr pending_be
  p_post_pr=$(jq -nc --arg ws "$main_repo" --arg cmd "cd \"$wt_backend\" && gh pr create --fill" '{
    workspacePaths: [$ws],
    conversationId: "conv-backend",
    toolCall: {name: "run_command", args: {CommandLine: $cmd}},
    toolOutput: {output: "https://github.com/org/kedo/pull/88"}
  }')
  printf '%s\n' "$p_post_pr" | "$POST_COMMAND_HOOKS" >/dev/null
  pending_be="$wt_backend/.harness/state/feat-backend/pr-audit-pending.json"
  [ -f "$pending_be" ] || { echo "Expected pr-audit-pending.json in wt_backend" >&2; return 1; }
  assert_json_field "$pending_be" ".conversationId" "conv-backend"

  # 2. Parallel sibling conversations are NOT blocked
  local cid out_other
  for cid in conv-admin conv-ios conv-android; do
    out_other=$(jq -nc --arg ws "$main_repo" --arg cid "$cid" \
      '{workspacePaths: [$ws], conversationId: $cid, terminationReason: "NO_TOOL_CALL"}' | "$STOP_GATE" | jq -c .)
    assert_eq "{}" "$out_other" "Unrelated conversation '$cid' must not be blocked"
  done
  assert_json_field "$pending_be" ".stopRetries" "0"

  # 3. Matching conversationId IS blocked
  local out_match
  out_match=$(jq -nc --arg ws "$main_repo" \
    '{workspacePaths: [$ws], conversationId: "conv-backend", terminationReason: "NO_TOOL_CALL"}' | "$STOP_GATE")
  assert_json_field "$out_match" ".decision" "continue"
  assert_json_field "$pending_be" ".stopRetries" "1"

  # 4. pr-auditor from a different conversation must not clear conv-backend's flag; matching conv-backend must set auditDispatched=true
  local p_other_auditor p_match_auditor
  p_other_auditor=$(jq -nc --arg ws "$main_repo" '{
    workspacePaths: [$ws],
    conversationId: "conv-other",
    toolCall: {name: "invoke_subagent", args: {TypeName: "pr-auditor", Role: "Other PR Audit", Prompt: "Audit other."}}
  }')
  printf '%s\n' "$p_other_auditor" | "$PRE_SUBAGENT_GUARD" >/dev/null
  assert_json_field "$pending_be" ".auditDispatched" "false" "Other conversation pr-auditor must not flip conv-backend auditDispatched"

  p_match_auditor=$(jq -nc --arg ws "$main_repo" '{
    workspacePaths: [$ws],
    conversationId: "conv-backend",
    toolCall: {name: "invoke_subagent", args: {TypeName: "pr-auditor", Role: "Backend PR Audit", Prompt: "Audit PR #88."}}
  }')
  printf '%s\n' "$p_match_auditor" | "$PRE_SUBAGENT_GUARD" >/dev/null
  assert_json_field "$pending_be" ".auditDispatched" "true"

  local out_after_dispatch
  out_after_dispatch=$(jq -nc --arg ws "$main_repo" \
    '{workspacePaths: [$ws], conversationId: "conv-backend", terminationReason: "NO_TOOL_CALL"}' | "$STOP_GATE" | jq -c .)
  assert_eq "{}" "$out_after_dispatch" "stop-gate must allow async wait after matching pr-auditor dispatch"

  # 5. clear-pr-audit clears dispatched sibling pending file cleanly
  "$STAMP_GATE" clear-pr-audit --workspace "$main_repo"
  [ ! -f "$pending_be" ] || { echo "clear-pr-audit must remove dispatched sibling pr-audit-pending.json" >&2; return 1; }
}

test_swarm_pre_tool_use_brief_enrichment_and_passthrough() {
  [ -x "$PRE_SUBAGENT_GUARD" ] || { echo "pre-subagent-guard.sh missing or not executable: $PRE_SUBAGENT_GUARD" >&2; return 1; }
  export HARNESS_DISABLE_DAEMON=1

  local repo
  repo=$(make_temp_repo)

  # 1. Non-add actions (status, models, title, model, kill) pass through without overwrite
  local act p_pass out_pass
  for act in status models title model kill; do
    p_pass=$(jq -nc --arg ws "$repo" --arg act "$act" '{
      workspacePaths: [$ws],
      toolCall: {
        name: "swarm",
        args: {
          action: $act,
          name: "worker-1",
          workspace: "share",
          brief: "Should not be overwritten."
        }
      }
    }')
    out_pass=$(printf '%s\n' "$p_pass" | "$PRE_SUBAGENT_GUARD")
    assert_json_field "$out_pass" ".decision" "allow" "swarm action=$act must allow"
    assert_json_field "$out_pass" "has(\"overwrite\")" "false" "swarm action=$act must not overwrite"
  done

  # Empty brief on action=add also passes through without overwrite
  local p_empty out_empty
  p_empty=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "swarm",
      args: {action: "add", name: "empty-worker", workspace: "share", brief: ""}
    }
  }')
  out_empty=$(printf '%s\n' "$p_empty" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_empty" ".decision" "allow" "swarm add with empty brief must allow"
  assert_json_field "$out_empty" "has(\"overwrite\")" "false" "swarm add with empty brief must not overwrite"

  # 2. action=add + workspace=share + tasks + multiline UTF-8 + trailing \n\n
  local p_share out_share
  p_share=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "swarm",
      args: {
        action: "add",
        name: "api-worker",
        workspace: "share",
        tasks: ["src/auth.py", "tests/test_auth.py"],
        model: "pro",
        fork: "coordinator",
        brief: "Görev: Türkçe UTF-8 (ğüşiöçİĞÜŞÖÇ) & `code()` & $HOME.\nSatır 2: Birim testlerini çalıştır.\n\n"
      }
    }
  }')
  out_share=$(printf '%s\n' "$p_share" | "$PRE_SUBAGENT_GUARD")
  jq -e \
    --arg eff "$EXPECTED_MEDIUM" \
    --arg ctr "$EXPECTED_SWARM_CONTRACT" \
    --arg grd "$EXPECTED_SWARM_BRANCH_GUARD" \
    --argjson req "$p_share" \
    '.decision == "allow"
     and (.overwrite | keys) == ["brief"]
     and .overwrite.brief == ($eff + "\n" + $ctr + "\n" + $grd + "\n\n" + $req.toolCall.args.brief)
     and (.overwrite.brief | endswith("Birim testlerini çalıştır.\n\n"))' \
    <<< "$out_share" >/dev/null || {
      echo "swarm add with share+tasks failed brief enrichment check: $out_share" >&2
      return 1
    }

  # 3. action=add + workspace=inherit omits SWARM_BRANCH_GUARD
  local p_inherit out_inherit
  p_inherit=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "swarm",
      args: {
        action: "add",
        name: "reader-1",
        workspace: "inherit",
        brief: "Inspect repository architecture."
      }
    }
  }')
  out_inherit=$(printf '%s\n' "$p_inherit" | "$PRE_SUBAGENT_GUARD")
  jq -e \
    --arg eff "$EXPECTED_MEDIUM" \
    --arg ctr "$EXPECTED_SWARM_CONTRACT" \
    '.decision == "allow"
     and .overwrite.brief == ($eff + "\n" + $ctr + "\n\nInspect repository architecture.")' \
    <<< "$out_inherit" >/dev/null || {
      echo "swarm add with inherit failed expected brief check: $out_inherit" >&2
      return 1
    }
  assert_not_contains "$(printf '%s\n' "$out_inherit" | jq -r '.overwrite.brief')" "[SWARM_BRANCH_GUARD" "inherit mode must not inject SWARM_BRANCH_GUARD"

  # 4. Idempotency: re-submitting already-enriched brief produces allow without overwrite
  local p_idem out_idem
  p_idem=$(jq -nc --arg ws "$repo" --argjson prev "$out_share" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "swarm",
      args: {
        action: "add",
        name: "api-worker",
        workspace: "share",
        brief: $prev.overwrite.brief
      }
    }
  }')
  out_idem=$(printf '%s\n' "$p_idem" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_idem" ".decision" "allow" "Idempotent swarm add must allow"
  assert_json_field "$out_idem" "has(\"overwrite\")" "false" "Idempotent swarm add must not re-overwrite brief"

  # 5. Optional swarm dispatch consumption (typeName == "swarm") uses registered effortProfile
  "$STAMP_GATE" dispatch --role "swarm-arch" --type "swarm" --tier "multi_module_integration" --workspace "$repo"
  local p_disp out_disp
  p_disp=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "swarm",
      args: {
        action: "add",
        name: "swarm-arch",
        workspace: "branch",
        brief: "Design module boundaries."
      }
    }
  }')
  out_disp=$(printf '%s\n' "$p_disp" | "$PRE_SUBAGENT_GUARD")
  jq -e \
    --arg eff "$EXPECTED_HIGH" \
    --arg ctr "$EXPECTED_SWARM_CONTRACT" \
    --arg grd "$EXPECTED_SWARM_BRANCH_GUARD" \
    '.decision == "allow"
     and .overwrite.brief == ($eff + "\n" + $ctr + "\n" + $grd + "\n\nDesign module boundaries.")' \
    <<< "$out_disp" >/dev/null || {
      echo "Optional swarm dispatch failed HIGH effort + branch guard check: $out_disp" >&2
      return 1
    }
  assert_json_field "$repo/.harness/state/main/subagent-dispatch.json" '.entries["swarm-arch"].consumed' "true" "Matching swarm dispatch entry must be marked consumed"

  # 6. A "self" or "research" dispatch entry with the same name must NOT be consumed by swarm
  "$STAMP_GATE" dispatch --role "shared-role" --type "self" --tier "critical_architecture_or_audit" --workspace "$repo"
  local p_self_guard out_self_guard
  p_self_guard=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "swarm",
      args: {
        action: "add",
        name: "shared-role",
        workspace: "inherit",
        brief: "Swarm task sharing a role name."
      }
    }
  }')
  out_self_guard=$(printf '%s\n' "$p_self_guard" | "$PRE_SUBAGENT_GUARD")
  jq -e \
    --arg eff "$EXPECTED_MEDIUM" \
    --arg ctr "$EXPECTED_SWARM_CONTRACT" \
    '.decision == "allow"
     and .overwrite.brief == ($eff + "\n" + $ctr + "\n\nSwarm task sharing a role name.")' \
    <<< "$out_self_guard" >/dev/null || {
      echo "swarm must ignore self dispatch entry and fall back to MEDIUM: $out_self_guard" >&2
      return 1
    }
  assert_json_field "$repo/.harness/state/main/subagent-dispatch.json" '.entries["shared-role"].consumed' "false" "swarm must NOT consume self dispatch entry"

  local p_sub_after out_sub_after
  p_sub_after=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "invoke_subagent",
      args: {
        TypeName: "self",
        Role: "shared-role",
        Prompt: "Run invoke_subagent after swarm."
      }
    }
  }')
  out_sub_after=$(printf '%s\n' "$p_sub_after" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_sub_after" ".decision" "allow" "Unconsumed self dispatch entry must remain valid for invoke_subagent"
  assert_json_field "$repo/.harness/state/main/subagent-dispatch.json" '.entries["shared-role"].consumed' "true" "invoke_subagent must consume self entry"

  # 7. "research" entry is NOT consumed, typeName == "" IS consumed, conversationId is respected, and partial header is idempotent
  "$STAMP_GATE" dispatch --role "shared-res" --type "research" --tier "trivial_lookup" --workspace "$repo"
  local p_res_guard out_res_guard
  p_res_guard=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {name: "swarm", args: {action: "add", name: "shared-res", workspace: "inherit", brief: "Check research guard."}}
  }')
  out_res_guard=$(printf '%s\n' "$p_res_guard" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$repo/.harness/state/main/subagent-dispatch.json" '.entries["shared-res"].consumed' "false" "swarm must NOT consume research dispatch entry"
  assert_contains "$(printf '%s\n' "$out_res_guard" | jq -r '.overwrite.brief')" "[EFFORT_PROFILE: MEDIUM" "swarm ignoring research entry must use MEDIUM"

  local dispatch_json="$repo/.harness/state/main/subagent-dispatch.json"
  local updated_disp
  updated_disp=$(jq '
    .entries["empty-type-worker"] = {typeName: "", tier: "trivial_lookup", model: "flash_lite", effortProfile: "LOW", consumed: false, timestamp: "2026-11-26T00:00:00Z"}
    | .entries["conv-worker"] = {typeName: "swarm", tier: "critical_architecture_or_audit", model: "pro", effortProfile: "MAX", consumed: false, conversationId: "conv-alpha", timestamp: "2026-11-26T00:00:00Z"}
  ' "$dispatch_json")
  printf '%s\n' "$updated_disp" > "$dispatch_json"

  local p_empty_type out_empty_type
  p_empty_type=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {name: "swarm", args: {action: "add", name: "empty-type-worker", workspace: "inherit", brief: "Quick check."}}
  }')
  out_empty_type=$(printf '%s\n' "$p_empty_type" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$dispatch_json" '.entries["empty-type-worker"].consumed' "true" "swarm must consume entry with empty typeName"
  assert_contains "$(printf '%s\n' "$out_empty_type" | jq -r '.overwrite.brief')" "[EFFORT_PROFILE: LOW" "empty typeName dispatch must apply registered LOW effort"

  local p_wrong_conv out_wrong_conv p_right_conv out_right_conv
  p_wrong_conv=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    conversationId: "conv-beta",
    toolCall: {name: "swarm", args: {action: "add", name: "conv-worker", workspace: "inherit", brief: "Cross-conv task."}}
  }')
  out_wrong_conv=$(printf '%s\n' "$p_wrong_conv" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$dispatch_json" '.entries["conv-worker"].consumed' "false" "swarm from different conversationId must NOT consume conv-alpha dispatch"
  assert_contains "$(printf '%s\n' "$out_wrong_conv" | jq -r '.overwrite.brief')" "[EFFORT_PROFILE: MEDIUM" "mismatched conversationId must fall back to MEDIUM"

  p_right_conv=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    conversationId: "conv-alpha",
    toolCall: {name: "swarm", args: {action: "add", name: "conv-worker", workspace: "inherit", brief: "Same-conv task."}}
  }')
  out_right_conv=$(printf '%s\n' "$p_right_conv" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$dispatch_json" '.entries["conv-worker"].consumed' "true" "swarm from matching conversationId must consume dispatch"
  assert_contains "$(printf '%s\n' "$out_right_conv" | jq -r '.overwrite.brief')" "[EFFORT_PROFILE: MAX" "matching conversationId must apply MAX effort"

  local p_partial out_partial
  p_partial=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "swarm",
      args: {
        action: "add",
        name: "partial-worker",
        workspace: "share",
        brief: "[EFFORT_PROFILE: XHIGH — custom]\n\nExisting effort header."
      }
    }
  }')
  out_partial=$(printf '%s\n' "$p_partial" | "$PRE_SUBAGENT_GUARD")
  jq -e \
    --arg ctr "$EXPECTED_SWARM_CONTRACT" \
    --arg grd "$EXPECTED_SWARM_BRANCH_GUARD" \
    '.decision == "allow"
     and .overwrite.brief == ($ctr + "\n" + $grd + "\n\n[EFFORT_PROFILE: XHIGH — custom]\n\nExisting effort header.")' \
    <<< "$out_partial" >/dev/null || {
      echo "Partial pre-existing EFFORT_PROFILE header was duplicated: $out_partial" >&2
      return 1
    }
}

test_parallel_same_role_dispatch_queue_and_conversation_affinity() {
  [ -x "$PRE_SUBAGENT_GUARD" ] || { echo "pre-subagent-guard.sh missing or not executable: $PRE_SUBAGENT_GUARD" >&2; return 1; }
  [ -x "$STAMP_GATE" ] || { echo "stamp-gate.sh missing or not executable: $STAMP_GATE" >&2; return 1; }
  export HARNESS_DISABLE_DAEMON=1

  local repo dispatch_file
  repo=$(make_temp_repo)
  dispatch_file="$repo/.harness/state/main/subagent-dispatch.json"

  # 1. Two dispatches for the SAME Role -> FIFO consumption + 3rd deny + .entries[role] sync
  "$STAMP_GATE" dispatch --role "Parallel Worker" --type "self" --tier "bounded_execution" --workspace "$repo"
  "$STAMP_GATE" dispatch --role "Parallel Worker" --type "self" --tier "multi_module_integration" --workspace "$repo"

  assert_json_field "$dispatch_file" '.pendingQueues["Parallel Worker"] | length' "2" "Two dispatches for same role must queue 2 items"
  assert_json_field "$dispatch_file" '.entries["Parallel Worker"].consumed' "false" "entries[role] must remain unconsumed"

  local p_pw out_pw1 out_pw2 out_pw3
  p_pw=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {
      name: "invoke_subagent",
      args: {TypeName: "self", Role: "Parallel Worker", Prompt: "Execute parallel task."}
    }
  }')
  out_pw1=$(printf '%s\n' "$p_pw" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_pw1" ".decision" "allow" "1st parallel same-role invocation must be allowed"
  assert_json_field "$out_pw1" ".overwrite.Model" "flash" "1st FIFO entry (bounded_execution) must use flash"
  assert_contains "$(printf '%s\n' "$out_pw1" | jq -r '.overwrite.Prompt')" "[EFFORT_PROFILE: MEDIUM" "1st FIFO entry must inject MEDIUM"
  assert_json_field "$dispatch_file" '.entries["Parallel Worker"].consumed' "false" "entries[role] must sync to remaining unconsumed entry"
  assert_json_field "$dispatch_file" '.entries["Parallel Worker"].effortProfile' "HIGH" "entries[role] must reflect next queued entry"

  out_pw2=$(printf '%s\n' "$p_pw" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_pw2" ".decision" "allow" "2nd parallel same-role invocation must be allowed"
  assert_json_field "$out_pw2" ".overwrite.Model" "inherit" "2nd FIFO entry (multi_module_integration) must use inherit"
  assert_contains "$(printf '%s\n' "$out_pw2" | jq -r '.overwrite.Prompt')" "[EFFORT_PROFILE: HIGH" "2nd FIFO entry must inject HIGH"
  assert_json_field "$dispatch_file" '.entries["Parallel Worker"].consumed' "true" "entries[role] must sync to consumed=true when queue empty"

  out_pw3=$(printf '%s\n' "$p_pw" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_pw3" ".decision" "deny" "3rd invocation after both queued entries consumed must deny"
  assert_contains "$(printf '%s\n' "$out_pw3" | jq -r '.reason')" "consumed == true" "Deny reason must preserve saw_consumed semantics"

  # 2. Legacy entries[role] seeding when pendingQueues[role] is absent
  local legacy_json
  legacy_json=$(jq 'del(.pendingQueues) | .entries["Legacy Role"] = {typeName: "self", tier: "trivial_lookup", model: "flash_lite", effortProfile: "LOW", consumed: false, timestamp: "2026-11-26T00:00:00Z"}' "$dispatch_file")
  printf '%s\n' "$legacy_json" > "$dispatch_file"
  "$STAMP_GATE" dispatch --role "Legacy Role" --type "self" --tier "critical_architecture_or_audit" --workspace "$repo"
  assert_json_field "$dispatch_file" '.pendingQueues["Legacy Role"] | length' "2" "Existing unconsumed legacy entry must seed pendingQueues before appending"

  local p_leg out_leg1 out_leg2 out_leg3
  p_leg=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {name: "invoke_subagent", args: {TypeName: "self", Role: "Legacy Role", Prompt: "Legacy task."}}
  }')
  out_leg1=$(printf '%s\n' "$p_leg" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_leg1" ".overwrite.Model" "flash_lite" "Seeded legacy entry must be consumed first (FIFO)"
  out_leg2=$(printf '%s\n' "$p_leg" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_leg2" ".overwrite.Model" "pro" "Newly appended entry must be consumed second"
  out_leg3=$(printf '%s\n' "$p_leg" | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_leg3" ".decision" "deny" "3rd legacy queue call must deny"

  # 3. conversationId affinity across parallel same-role dispatches (--conversation-id, --conversation-id=, HARNESS_CONVERSATION_ID)
  "$STAMP_GATE" dispatch --role "Conv Worker" --type "self" --tier "bounded_execution" --conversation-id "conv-1" --workspace "$repo"
  "$STAMP_GATE" dispatch --role "Conv Worker" --type "self" --tier "critical_architecture_or_audit" --conversation-id="conv-2" --workspace "$repo"
  HARNESS_CONVERSATION_ID="conv-3" "$STAMP_GATE" dispatch --role "Conv Worker" --type "self" --tier "trivial_lookup" --workspace "$repo"

  local out_c2 out_c3 out_c1 out_c_other
  out_c2=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    conversationId: "conv-2",
    toolCall: {name: "invoke_subagent", args: {TypeName: "self", Role: "Conv Worker", Prompt: "Run conv-2."}}
  }' | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_c2" ".decision" "allow" "conv-2 must match its queued entry"
  assert_json_field "$out_c2" ".overwrite.Model" "pro" "conv-2 must receive MAX/pro entry regardless of queue position"
  assert_contains "$(printf '%s\n' "$out_c2" | jq -r '.overwrite.Prompt')" "[EFFORT_PROFILE: MAX"
  assert_json_field "$dispatch_file" '.entries["Conv Worker"].consumed' "false" "Remaining conv-1 and conv-3 entries must keep entries[role] unconsumed"

  out_c_other=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    conversationId: "conv-unrelated",
    toolCall: {name: "invoke_subagent", args: {TypeName: "self", Role: "Conv Worker", Prompt: "Wrong conv."}}
  }' | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_c_other" ".decision" "deny" "Unrelated conversationId must not steal conv-1 or conv-3 entries"

  out_c3=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    conversationId: "conv-3",
    toolCall: {name: "invoke_subagent", args: {TypeName: "self", Role: "Conv Worker", Prompt: "Run conv-3."}}
  }' | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_c3" ".overwrite.Model" "flash_lite" "conv-3 must receive trivial_lookup entry"

  out_c1=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    conversationId: "conv-1",
    toolCall: {name: "invoke_subagent", args: {TypeName: "self", Role: "Conv Worker", Prompt: "Run conv-1."}}
  }' | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_c1" ".overwrite.Model" "flash" "conv-1 must receive bounded_execution entry"
  assert_json_field "$dispatch_file" '.entries["Conv Worker"].consumed' "true" "After all conv entries consumed, entries[role].consumed must be true"

  # 4. Exact conversationId beats generic (empty conversationId) entry even when generic is older in queue
  "$STAMP_GATE" dispatch --role "Affinity Order" --type "self" --tier "trivial_lookup" --workspace "$repo"
  "$STAMP_GATE" dispatch --role "Affinity Order" --type "self" --tier "critical_architecture_or_audit" --conversation-id "conv-vip" --workspace "$repo"
  local out_vip out_vip_fallback
  out_vip=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    conversationId: "conv-vip",
    toolCall: {name: "invoke_subagent", args: {TypeName: "self", Role: "Affinity Order", Prompt: "VIP first."}}
  }' | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_vip" ".overwrite.Model" "pro" "Exact conversationId entry must beat older generic entry"
  out_vip_fallback=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    conversationId: "conv-vip",
    toolCall: {name: "invoke_subagent", args: {TypeName: "self", Role: "Affinity Order", Prompt: "VIP fallback."}}
  }' | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_vip_fallback" ".overwrite.Model" "flash_lite" "Second call falls back to older generic entry"

  # 5. Error semantics (mismatch_type & invalid_entry) preserved on queued entries without consuming
  "$STAMP_GATE" dispatch --role "Type Guard" --type "research" --tier "trivial_lookup" --workspace "$repo"
  local out_mismatch
  out_mismatch=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {name: "invoke_subagent", args: {TypeName: "self", Role: "Type Guard", Prompt: "Mismatch."}}
  }' | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_mismatch" ".decision" "deny" "Type mismatch in queue must deny"
  assert_contains "$(printf '%s\n' "$out_mismatch" | jq -r '.reason')" "research" "Mismatch reason must cite registered typeName"
  assert_json_field "$dispatch_file" '.entries["Type Guard"].consumed' "false" "Type mismatch must not consume queued entry"

  local bad_queue_json
  bad_queue_json=$(jq '.pendingQueues["Invalid Role"] = [{typeName: "self", tier: "bounded_execution", model: "", effortProfile: "BAD", consumed: false}] | .entries["Invalid Role"] = {typeName: "self", tier: "bounded_execution", model: "", effortProfile: "BAD", consumed: false}' "$dispatch_file")
  printf '%s\n' "$bad_queue_json" > "$dispatch_file"
  local out_invalid
  out_invalid=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    toolCall: {name: "invoke_subagent", args: {TypeName: "self", Role: "Invalid Role", Prompt: "Invalid."}}
  }' | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_invalid" ".decision" "deny" "Invalid queued entry must deny"
  assert_contains "$(printf '%s\n' "$out_invalid" | jq -r '.reason')" "geçersiz model veya effortProfile" "Invalid queued entry must preserve invalid_entry reason"

  # 6. Queue pruning keeps at most 20 consumed items while retaining new unconsumed entry
  local prune_json
  prune_json=$(jq '
    .pendingQueues["Pruned Role"] = [range(0; 23) | {typeName: "self", tier: "trivial_lookup", model: "flash_lite", effortProfile: "LOW", consumed: true, timestamp: "2026-11-26T00:00:00Z"}]
    | .entries["Pruned Role"] = {typeName: "self", tier: "trivial_lookup", model: "flash_lite", effortProfile: "LOW", consumed: true, timestamp: "2026-11-26T00:00:00Z"}
  ' "$dispatch_file")
  printf '%s\n' "$prune_json" > "$dispatch_file"
  "$STAMP_GATE" dispatch --role "Pruned Role" --type "self" --tier "bounded_execution" --workspace "$repo"
  assert_json_field "$dispatch_file" '[.pendingQueues["Pruned Role"][] | select(.consumed == true)] | length' "20" "Pruning must retain at most 20 consumed items"
  assert_json_field "$dispatch_file" '[.pendingQueues["Pruned Role"][] | select(.consumed == false)] | length' "1" "Pruning must retain newly registered unconsumed item"

  # 7. Swarm add consumes matching pendingQueues entry with conversationId affinity
  "$STAMP_GATE" dispatch --role "swarm-shard" --type "swarm" --tier "trivial_lookup" --conversation-id "conv-s1" --workspace "$repo"
  "$STAMP_GATE" dispatch --role "swarm-shard" --type "swarm" --tier "bounded_execution" --effort "XHIGH" --conversation-id "conv-s2" --workspace "$repo"
  local out_sw2 out_sw1 out_sw3
  out_sw2=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    conversationId: "conv-s2",
    toolCall: {name: "swarm", args: {action: "add", name: "swarm-shard", workspace: "inherit", brief: "Shard 2."}}
  }' | "$PRE_SUBAGENT_GUARD")
  assert_contains "$(printf '%s\n' "$out_sw2" | jq -r '.overwrite.brief')" "[EFFORT_PROFILE: XHIGH" "Swarm add must consume conv-s2 queue entry"
  out_sw1=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    conversationId: "conv-s1",
    toolCall: {name: "swarm", args: {action: "add", name: "swarm-shard", workspace: "inherit", brief: "Shard 1."}}
  }' | "$PRE_SUBAGENT_GUARD")
  assert_contains "$(printf '%s\n' "$out_sw1" | jq -r '.overwrite.brief')" "[EFFORT_PROFILE: LOW" "Swarm add must consume conv-s1 queue entry"
  out_sw3=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    conversationId: "conv-s1",
    toolCall: {name: "swarm", args: {action: "add", name: "swarm-shard", workspace: "inherit", brief: "Shard 3."}}
  }' | "$PRE_SUBAGENT_GUARD")
  assert_contains "$(printf '%s\n' "$out_sw3" | jq -r '.overwrite.brief')" "[EFFORT_PROFILE: MEDIUM" "After queue exhausted, swarm add falls back to MEDIUM"
}

test_neon_gemini4_and_custom_parent_model_routing() {
  [ -x "$PRE_SUBAGENT_GUARD" ] || { echo "pre-subagent-guard.sh missing or not executable: $PRE_SUBAGENT_GUARD" >&2; return 1; }
  export HARNESS_DISABLE_DAEMON=1

  local repo
  repo=$(make_temp_repo)

  # 1. Neon High routes identically to Carbon frontier family
  local out_neon_sec out_neon_pr out_neon_self out_neon_canon_def out_neon_canon_inh
  out_neon_sec=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    modelName: "gemini-4-neon-high",
    toolCall: {name: "invoke_subagent", args: {TypeName: "security-reviewer", Role: "Neon Sec", Model: "pro", Prompt: "Audit Neon."}}
  }' | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_neon_sec" ".overwrite.Model" "inherit" "Neon parent keeps security-reviewer on inherit"

  out_neon_pr=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    modelName: "Gemini 4 Neon (Medium)",
    toolCall: {name: "invoke_subagent", args: {TypeName: "pr-auditor", Role: "Neon PR", Prompt: "Audit PR on Neon."}}
  }' | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_neon_pr" ".overwrite.Model" "inherit" "Neon parent keeps pr-auditor on inherit"

  "$STAMP_GATE" dispatch --role "Neon Worker" --type "self" --tier "bounded_execution" --workspace "$repo"
  out_neon_self=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    modelName: "gemini-4-neon-high",
    toolCall: {name: "invoke_subagent", args: {TypeName: "self", Role: "Neon Worker", Prompt: "Implement Neon module."}}
  }' | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_neon_self" ".overwrite.Model" "pro" "Neon bounded_execution steps down to pro (Argon)"

  "$STAMP_GATE" dispatch --role "Neon Canon Def" --type "canon-auditor" --tier "multi_module_integration" --workspace "$repo"
  out_neon_canon_def=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    modelName: "gemini-4-neon-high",
    toolCall: {name: "invoke_subagent", args: {TypeName: "canon-auditor", Role: "Neon Canon Def", Model: "pro", Prompt: "Canon Argon."}}
  }' | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_neon_canon_def" ".overwrite.Model" "pro" "Neon multi_module defaults to pro"

  "$STAMP_GATE" dispatch --role "Neon Canon Inh" --type "canon-auditor" --tier "multi_module_integration" --workspace "$repo"
  out_neon_canon_inh=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    modelName: "gemini-4-neon-high",
    toolCall: {name: "invoke_subagent", args: {TypeName: "canon-auditor", Role: "Neon Canon Inh", Model: "inherit", Prompt: "Canon Neon."}}
  }' | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_neon_canon_inh" ".overwrite.Model" "inherit" "Neon multi_module preserves explicit inherit"

  # 2. Neon Low -> argon_low
  local out_neon_low_sec out_neon_low_self
  out_neon_low_sec=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    modelName: "gemini-4-neon-low",
    toolCall: {name: "invoke_subagent", args: {TypeName: "security-reviewer", Role: "Neon Low Sec", Prompt: "Audit Neon Low."}}
  }' | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_neon_low_sec" ".overwrite.Model" "pro" "Neon Low (argon_low) escalates security-reviewer to pro"

  "$STAMP_GATE" dispatch --role "Neon Low Worker" --type "self" --tier "bounded_execution" --workspace "$repo"
  out_neon_low_self=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    modelName: "Gemini 4 Neon (Low)",
    toolCall: {name: "invoke_subagent", args: {TypeName: "self", Role: "Neon Low Worker", Prompt: "Bounded Neon Low."}}
  }' | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_neon_low_self" ".overwrite.Model" "inherit" "Neon Low bounded_execution keeps inherit"

  # 3. Custom parent model -> bounded_execution routes to pro, multi_module & critical stay inherit
  "$STAMP_GATE" dispatch --role "Custom Bounded" --type "self" --tier "bounded_execution" --workspace "$repo"
  local out_custom_bounded out_custom_multi out_custom_sec
  out_custom_bounded=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    modelName: "enterprise-tuned-v1",
    toolCall: {name: "invoke_subagent", args: {TypeName: "self", Role: "Custom Bounded", Prompt: "Custom bounded."}}
  }' | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_custom_bounded" ".overwrite.Model" "pro" "custom bounded_execution must route to pro instead of flash"

  "$STAMP_GATE" dispatch --role "Custom Multi" --type "self" --tier "multi_module_integration" --workspace "$repo"
  out_custom_multi=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    modelName: "enterprise-tuned-v1",
    toolCall: {name: "invoke_subagent", args: {TypeName: "self", Role: "Custom Multi", Prompt: "Custom multi."}}
  }' | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_custom_multi" ".overwrite.Model" "inherit" "custom multi_module_integration keeps inherit"

  out_custom_sec=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    modelName: "enterprise-tuned-v1",
    toolCall: {name: "invoke_subagent", args: {TypeName: "security-reviewer", Role: "Custom Sec", Prompt: "Custom audit."}}
  }' | "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_custom_sec" ".overwrite.Model" "inherit" "custom critical_architecture_or_audit keeps inherit"
}

run_tests
