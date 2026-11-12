#!/usr/bin/env bash
# Alps AGY Harness - PreToolUse Hybrid jev Subagent Model & Effort Lock (pre-subagent-guard.sh)
# Enforces:
#   - security-reviewer -> auto overwrite Model="pro", EFFORT_PROFILE: MAX
#   - pr-auditor        -> auto overwrite Model="pro", EFFORT_PROFILE: HIGH (or MAX if dispatched as MAX)
#   - browser           -> overwrite Model="flash" when Model omitted; preserve explicit Model
#   - image-generator   -> allow directly
#   - self, research, canon-auditor, and custom subagents -> require unconsumed subagent-dispatch.json
#     entry for Role, enforce canon-auditor floor (pro / HIGH), mark consumed=true, and idempotently
#     prepend EFFORT_PROFILE directive byte-for-byte via jq.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

harness_read_stdin

if harness_is_ignored "$WORKSPACE_ROOT"; then
  emit_allow
  exit 0
fi

if ! printf '%s\n' "$HOOK_INPUT" | jq -e 'type == "object"' >/dev/null 2>&1; then
  emit_allow
  exit 0
fi

tool_name="$(printf '%s\n' "$HOOK_INPUT" | jq -r '.toolCall.name // empty' 2>/dev/null || true)"
if [ -n "$tool_name" ] && [ "$tool_name" != "invoke_subagent" ]; then
  emit_allow
  exit 0
fi

if ! printf '%s\n' "$HOOK_INPUT" | jq -e '(.toolCall.args | type) == "object"' >/dev/null 2>&1; then
  emit_allow
  exit 0
fi

type_name="$(printf '%s\n' "$HOOK_INPUT" | jq -r '.toolCall.args.TypeName // empty' 2>/dev/null || true)"
role="$(printf '%s\n' "$HOOK_INPUT" | jq -r '.toolCall.args.Role // empty' 2>/dev/null || true)"
caller_model="$(printf '%s\n' "$HOOK_INPUT" | jq -r '.toolCall.args.Model // empty' 2>/dev/null || true)"

effort_header_for_profile() {
  local level="$1"
  case "$level" in
    LOW)
      printf '%s' "[EFFORT_PROFILE: LOW — Hedef odaklı çalış; en fazla 3 okuma turu yap, spekülatif dallanma yapma, yanıtı kısa tut.]"
      ;;
    MEDIUM)
      printf '%s' "[EFFORT_PROFILE: MEDIUM — Standart TDD döngüsü uygula; yalnız görev kapsamındaki dosyaları ve doğrudan bağımlılıklarını incele.]"
      ;;
    HIGH)
      printf '%s' "[EFFORT_PROFILE: HIGH — Katman sınırlarını, LSP tanılamalarını ve kenar durumları çapraz doğrula; her iddiayı dosya/satır kanıtına bağla.]"
      ;;
    MAX)
      printf '%s' "[EFFORT_PROFILE: MAX — Sıfır varsayım; tüm bağımlılık zincirini, karşı-örnekleri ve güvenlik/kanon değişmezlerini satır satır kanıtla.]"
      ;;
    *)
      return 1
      ;;
  esac
}

emit_model_and_effort_overwrite() {
  local model="$1"
  local effort="$2"
  local header
  header="$(effort_header_for_profile "$effort")"

  local overwrite_json
  overwrite_json="$(jq -nc \
    --arg model "$model" \
    --arg header "$header" \
    --argjson input "$HOOK_INPUT" \
    '($input.toolCall.args.Prompt // "") as $orig
     | (if ($orig | startswith("[EFFORT_PROFILE:")) then $orig else ($header + "\n\n" + $orig) end) as $new_prompt
     | {Model: $model, Prompt: $new_prompt}')"

  emit_overwrite "$overwrite_json"
}

mark_role_consumed_if_present() {
  local target_role="$1"
  [ -n "$target_role" ] || return 0

  local slug state_dir dispatch_file
  slug="$(harness_branch_slug "$WORKSPACE_ROOT")"
  state_dir="$WORKSPACE_ROOT/.harness/state/$slug"
  dispatch_file="$state_dir/subagent-dispatch.json"

  [ -f "$dispatch_file" ] || return 0

  if jq -e --arg role "$target_role" 'type == "object" and (.entries | type == "object") and ((.entries[$role] | type) == "object") and ((.entries[$role].consumed // false) == false)' "$dispatch_file" >/dev/null 2>&1; then
    local updated_json
    updated_json="$(jq -c --arg role "$target_role" '.entries[$role].consumed = true' "$dispatch_file")"
    atomic_write_json "$state_dir" "subagent-dispatch.json" "$updated_json"
  fi
}

case "$type_name" in
  image-generator)
    emit_allow
    exit 0
    ;;

  browser)
    if [ -z "${caller_model//[[:space:]]/}" ]; then
      emit_overwrite "$(jq -nc '{Model: "flash"}')"
    else
      emit_allow
    fi
    exit 0
    ;;

  security-reviewer)
    mark_role_consumed_if_present "$role"
    emit_model_and_effort_overwrite "pro" "MAX"
    exit 0
    ;;

  pr-auditor)
    pr_effort="HIGH"
    if [ -n "$role" ]; then
      slug="$(harness_branch_slug "$WORKSPACE_ROOT")"
      state_dir="$WORKSPACE_ROOT/.harness/state/$slug"
      dispatch_file="$state_dir/subagent-dispatch.json"
      if [ -f "$dispatch_file" ] && jq -e --arg role "$role" 'type == "object" and (.entries | type == "object") and ((.entries[$role] | type) == "object") and ((.entries[$role].consumed // false) == false)' "$dispatch_file" >/dev/null 2>&1; then
        reg_effort="$(jq -r --arg role "$role" '.entries[$role].effortProfile // empty' "$dispatch_file" 2>/dev/null || true)"
        if [ "$reg_effort" = "MAX" ]; then
          pr_effort="MAX"
        fi
        updated_json="$(jq -c --arg role "$role" '.entries[$role].consumed = true' "$dispatch_file")"
        atomic_write_json "$state_dir" "subagent-dispatch.json" "$updated_json"
      fi
    fi
    emit_model_and_effort_overwrite "pro" "$pr_effort"
    exit 0
    ;;

  *)
    if [ -z "$role" ]; then
      emit_deny "Alt ajan çağrısı reddedildi ('$type_name'): Role alanı boş olamaz. Önce görev karmaşıklığını jev_classify / jev_score ile sınıflandırın ve 'scripts/stamp-gate.sh dispatch --role <Role> --type \"$type_name\" --tier <katman>' komutunu çalıştırın."
      exit 0
    fi

    slug="$(harness_branch_slug "$WORKSPACE_ROOT")"
    state_dir="$WORKSPACE_ROOT/.harness/state/$slug"
    dispatch_file="$state_dir/subagent-dispatch.json"

    if [ ! -f "$dispatch_file" ] || ! jq -e --arg role "$role" 'type == "object" and (.entries | type == "object") and ((.entries[$role] | type) == "object")' "$dispatch_file" >/dev/null 2>&1; then
      emit_deny "Alt ajan çağrısı reddedildi ('$type_name' / Role: '$role'): subagent-dispatch.json içinde kayıt bulunamadı. Önce görev karmaşıklığını jev_classify / jev_score ile sınıflandırın ve 'scripts/stamp-gate.sh dispatch --role \"$role\" --type \"$type_name\" --tier <katman>' komutunu çalıştırın."
      exit 0
    fi

    if ! jq -e --arg role "$role" '.entries[$role].consumed == false' "$dispatch_file" >/dev/null 2>&1; then
      emit_deny "Alt ajan çağrısı reddedildi ('$type_name' / Role: '$role'): subagent-dispatch.json içindeki '$role' kaydı zaten tüketildi (consumed == true). Yeni çağrı için jev_classify / jev_score sonrası 'scripts/stamp-gate.sh dispatch --role \"$role\" --type \"$type_name\" --tier <katman>' komutunu çalıştırın."
      exit 0
    fi

    entry_type="$(jq -r --arg role "$role" '.entries[$role].typeName // empty' "$dispatch_file" 2>/dev/null || true)"
    if [ -n "$entry_type" ] && [ "$entry_type" != "$type_name" ]; then
      emit_deny "Alt ajan çağrısı reddedildi: '$role' kaydı '$entry_type' tipi için oluşturulmuş, ancak '$type_name' çağrıldı. jev_classify / jev_score sonrası 'scripts/stamp-gate.sh dispatch --role \"$role\" --type \"$type_name\" --tier <katman>' komutunu çalıştırın."
      exit 0
    fi

    entry_tier="$(jq -r --arg role "$role" '.entries[$role].tier // empty' "$dispatch_file" 2>/dev/null || true)"
    model="$(jq -r --arg role "$role" '.entries[$role].model // empty' "$dispatch_file" 2>/dev/null || true)"
    effort="$(jq -r --arg role "$role" '.entries[$role].effortProfile // empty' "$dispatch_file" 2>/dev/null || true)"

    if [ -z "$model" ] || { [ "$effort" != "LOW" ] && [ "$effort" != "MEDIUM" ] && [ "$effort" != "HIGH" ] && [ "$effort" != "MAX" ]; }; then
      emit_deny "Alt ajan çağrısı reddedildi ('$type_name' / Role: '$role'): subagent-dispatch.json kaydı geçersiz model veya effortProfile içeriyor. 'scripts/stamp-gate.sh dispatch --role \"$role\" --type \"$type_name\" --tier <katman>' ile kaydı yenileyin."
      exit 0
    fi

    updated_json="$(jq -c --arg role "$role" '.entries[$role].consumed = true' "$dispatch_file")"
    atomic_write_json "$state_dir" "subagent-dispatch.json" "$updated_json"

    # Ruling #3: canon-auditor floor upgrade (trivial_lookup / bounded_execution -> pro / HIGH)
    if [ "$type_name" = "canon-auditor" ]; then
      if [ "$entry_tier" = "trivial_lookup" ] || [ "$entry_tier" = "bounded_execution" ] || [ "$effort" = "LOW" ] || [ "$effort" = "MEDIUM" ]; then
        model="pro"
        effort="HIGH"
      fi
    fi

    emit_model_and_effort_overwrite "$model" "$effort"
    exit 0
    ;;
esac
