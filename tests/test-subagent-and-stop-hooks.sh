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
EXPECTED_MAX="[EFFORT_PROFILE: MAX — Sıfır varsayım; tüm bağımlılık zincirini, karşı-örnekleri ve güvenlik/kanon değişmezlerini satır satır kanıtla.]"
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

  # 3. Non-NO_TOOL_CALL terminationReason returns {} without incrementing stopRetries
  local stop_other
  stop_other=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], terminationReason: "USER_ABORT"}')
  local out_other
  out_other=$(printf '%s\n' "$stop_other" | "$STOP_GATE" | jq -c .)
  assert_eq "{}" "$out_other" "Non-NO_TOOL_CALL terminationReason must return {}"
  assert_json_field "$repo/.harness/state/main/pr-audit-pending.json" ".stopRetries" "0" "stopRetries must stay 0 on USER_ABORT"

  # 4. 1st NO_TOOL_CALL -> continue (stopRetries becomes 1)
  local out_try1
  out_try1=$(printf '%s\n' "$stop_no_tool" | "$STOP_GATE")
  assert_json_field "$out_try1" ".decision" "continue" "1st NO_TOOL_CALL must return continue"
  assert_json_field "$out_try1" ".reason" "$EXPECTED_STOP_REASON" "1st NO_TOOL_CALL reason must match contract"
  assert_json_field "$repo/.harness/state/main/pr-audit-pending.json" ".stopRetries" "1" "stopRetries must increment to 1"
  assert_json_field "$repo/.harness/state/main/pr-audit-pending.json" ".prUrl" "https://github.com/alps/harness/pull/15" "prUrl must be preserved"

  # 5. 2nd NO_TOOL_CALL -> continue (stopRetries becomes 2)
  local out_try2
  out_try2=$(printf '%s\n' "$stop_no_tool" | "$STOP_GATE")
  assert_json_field "$out_try2" ".decision" "continue" "2nd NO_TOOL_CALL must return continue"
  assert_json_field "$out_try2" ".reason" "$EXPECTED_STOP_REASON" "2nd NO_TOOL_CALL reason must match contract"
  assert_json_field "$repo/.harness/state/main/pr-audit-pending.json" ".stopRetries" "2" "stopRetries must increment to 2"

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

run_tests
