#!/usr/bin/env bash
# Alps AGY Harness - Deterministic Stamp & Subagent Dispatch CLI (stamp-gate.sh)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/hooks/common.sh"

utc_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

atomic_write_json() {
  local state_dir="$1"
  local filename="$2"
  local content="$3"
  local tmp_file
  tmp_file="$(mktemp "$state_dir/.${filename}.tmp.XXXXXX")"
  if ! printf '%s\n' "$content" > "$tmp_file"; then
    rm -f "$tmp_file"
    return 1
  fi
  mv -f "$tmp_file" "$state_dir/$filename"
}

usage() {
  cat >&2 <<'EOF'
Usage:
  stamp-gate.sh tree-sha [--workspace <dir>]
  stamp-gate.sh canon --verdict PASS|FAIL [--plan <path>] [--allow-file <relpath> ...] [--workspace <dir>]
  stamp-gate.sh security --verdict PASS|FAIL --critical <n> --important <n> [--workspace <dir>]
  stamp-gate.sh tdd --verdict PASS|FAIL --critical-gaps <n> --important-gaps <n> --provider claude-cli|agy-cli|subagent --model <id> [--effort <level>] [--file <relpath> ...] [--workspace <dir>]
  stamp-gate.sh review --kind spec-plan|tdd [--provider claude|agy] [--model <id>] [--effort <level>] [--target <relpath> ...] [--auto-stamp] [--workspace <dir>]
  stamp-gate.sh ui --verdict PASS|FAIL --p0 <n> --p1 <n> [--target <relpath> ...] [--workspace <dir>]
  stamp-gate.sh context7 --package <name> --version <ver> --source locked|greenfield-latest [--workspace <dir>]
  stamp-gate.sh dispatch --role <role> --type <typeName> --tier <tier> [--parent-model <modelName>] [--effort LOW|MEDIUM|HIGH|XHIGH|MAX] [--conversation-id <id>] [--workspace <dir>]
  stamp-gate.sh select-model --tier <tier> [--parent-model <modelName>] [--caller-model <tier>] [--effort LOW|MEDIUM|HIGH|XHIGH|MAX] [--workspace <dir>]
  stamp-gate.sh verify-pr-stamps [--workspace <dir>]
  stamp-gate.sh clear-pr-audit [--workspace <dir>]
EOF
}

# Extract --workspace from any argument position
WORKSPACE="$PWD"
REMAINING_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --workspace)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "Error: --workspace requires a directory path" >&2
        exit 1
      fi
      WORKSPACE="$2"
      shift 2
      ;;
    --workspace=*)
      WORKSPACE="${1#--workspace=}"
      if [ -z "$WORKSPACE" ]; then
        echo "Error: --workspace requires a directory path" >&2
        exit 1
      fi
      shift
      ;;
    *)
      REMAINING_ARGS+=("$1")
      shift
      ;;
  esac
done

if [ ! -d "$WORKSPACE" ]; then
  echo "Error: workspace directory does not exist: $WORKSPACE" >&2
  exit 1
fi

if [ ${#REMAINING_ARGS[@]} -eq 0 ]; then
  usage
  exit 1
fi

SUBCMD="${REMAINING_ARGS[0]}"
SUB_ARGS=()
if [ ${#REMAINING_ARGS[@]} -gt 1 ]; then
  SUB_ARGS=("${REMAINING_ARGS[@]:1}")
fi

cmd_tree_sha() {
  if [ $# -gt 0 ]; then
    echo "Error: unexpected arguments for tree-sha: $*" >&2
    exit 1
  fi
  harness_code_tree_sha "$WORKSPACE"
}

cmd_canon() {
  local verdict=""
  local plan_path=""
  local allow_files=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --verdict)
        [ $# -ge 2 ] || { echo "Error: --verdict requires PASS or FAIL" >&2; exit 1; }
        verdict="$2"
        shift 2
        ;;
      --verdict=*)
        verdict="${1#--verdict=}"
        shift
        ;;
      --plan)
        [ $# -ge 2 ] || { echo "Error: --plan requires a path" >&2; exit 1; }
        plan_path="$2"
        shift 2
        ;;
      --plan=*)
        plan_path="${1#--plan=}"
        shift
        ;;
      --allow-file)
        [ $# -ge 2 ] || { echo "Error: --allow-file requires a relative file path" >&2; exit 1; }
        local norm_af="$2"
        while [[ "$norm_af" == ./* ]]; do norm_af="${norm_af#./}"; done
        allow_files+=("$norm_af")
        shift 2
        ;;
      --allow-file=*)
        local norm_af="${1#--allow-file=}"
        while [[ "$norm_af" == ./* ]]; do norm_af="${norm_af#./}"; done
        allow_files+=("$norm_af")
        shift
        ;;
      *)
        echo "Error: unknown argument for canon: $1" >&2
        exit 1
        ;;
    esac
  done

  if [ "$verdict" != "PASS" ] && [ "$verdict" != "FAIL" ]; then
    echo "Error: canon --verdict must be PASS or FAIL (got '$verdict')" >&2
    exit 1
  fi

  local allowed_json="[]"
  if [ ${#allow_files[@]} -gt 0 ]; then
    allowed_json="$(printf '%s\n' "${allow_files[@]}" | jq -R . | jq -sc .)"
  fi

  local state_dir tree_sha ts json_payload
  state_dir="$(harness_state_dir "$WORKSPACE")"
  tree_sha="$(harness_code_tree_sha "$WORKSPACE")"
  ts="$(utc_now)"

  json_payload="$(jq -nc \
    --arg verdict "$verdict" \
    --arg sha "$tree_sha" \
    --arg plan "$plan_path" \
    --argjson allowed "$allowed_json" \
    --arg ts "$ts" \
    '{
      verdict: $verdict,
      codeTreeSha: $sha,
      planPath: $plan,
      allowedFiles: $allowed,
      timestamp: $ts
    }')"

  atomic_write_json "$state_dir" "canon-pass.json" "$json_payload"
}

cmd_security() {
  local verdict=""
  local critical=""
  local important=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --verdict)
        [ $# -ge 2 ] || { echo "Error: --verdict requires PASS or FAIL" >&2; exit 1; }
        verdict="$2"
        shift 2
        ;;
      --verdict=*)
        verdict="${1#--verdict=}"
        shift
        ;;
      --critical)
        [ $# -ge 2 ] || { echo "Error: --critical requires a non-negative integer" >&2; exit 1; }
        critical="$2"
        shift 2
        ;;
      --critical=*)
        critical="${1#--critical=}"
        shift
        ;;
      --important)
        [ $# -ge 2 ] || { echo "Error: --important requires a non-negative integer" >&2; exit 1; }
        important="$2"
        shift 2
        ;;
      --important=*)
        important="${1#--important=}"
        shift
        ;;
      *)
        echo "Error: unknown argument for security: $1" >&2
        exit 1
        ;;
    esac
  done

  if [ "$verdict" != "PASS" ] && [ "$verdict" != "FAIL" ]; then
    echo "Error: security --verdict must be PASS or FAIL (got '$verdict')" >&2
    exit 1
  fi

  if [[ ! "$critical" =~ ^[0-9]+$ ]]; then
    echo "Error: security --critical must be a non-negative integer (got '$critical')" >&2
    exit 1
  fi

  if [[ ! "$important" =~ ^[0-9]+$ ]]; then
    echo "Error: security --important must be a non-negative integer (got '$important')" >&2
    exit 1
  fi

  if [ "$verdict" = "PASS" ] && { [ "$critical" -ne 0 ] || [ "$important" -ne 0 ]; }; then
    echo "Error: security stamp cannot record PASS when criticalCount ($critical) or importantCount ($important) is non-zero" >&2
    exit 1
  fi

  local state_dir tree_sha ts json_payload
  state_dir="$(harness_state_dir "$WORKSPACE")"
  tree_sha="$(harness_code_tree_sha "$WORKSPACE")"
  ts="$(utc_now)"

  json_payload="$(jq -nc \
    --arg verdict "$verdict" \
    --arg sha "$tree_sha" \
    --argjson critical "$critical" \
    --argjson important "$important" \
    --arg ts "$ts" \
    '{
      verdict: $verdict,
      codeTreeSha: $sha,
      criticalCount: $critical,
      importantCount: $important,
      timestamp: $ts
    }')"

  atomic_write_json "$state_dir" "security-pass.json" "$json_payload"
}

cmd_context7() {
  local pkg=""
  local ver=""
  local src=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --package)
        [ $# -ge 2 ] || { echo "Error: --package requires a package name" >&2; exit 1; }
        pkg="$2"
        shift 2
        ;;
      --package=*)
        pkg="${1#--package=}"
        shift
        ;;
      --version)
        [ $# -ge 2 ] || { echo "Error: --version requires a version string" >&2; exit 1; }
        ver="$2"
        shift 2
        ;;
      --version=*)
        ver="${1#--version=}"
        shift
        ;;
      --source)
        [ $# -ge 2 ] || { echo "Error: --source requires locked or greenfield-latest" >&2; exit 1; }
        src="$2"
        shift 2
        ;;
      --source=*)
        src="${1#--source=}"
        shift
        ;;
      *)
        echo "Error: unknown argument for context7: $1" >&2
        exit 1
        ;;
    esac
  done

  if [ -z "$pkg" ] || [ -z "$ver" ]; then
    echo "Error: context7 requires non-empty --package and --version" >&2
    exit 1
  fi

  if [ "$src" != "locked" ] && [ "$src" != "greenfield-latest" ]; then
    echo "Error: context7 --source must be 'locked' or 'greenfield-latest' (got '$src')" >&2
    exit 1
  fi

  python3 -B "$(harness_core_python)" context7-register \
    --workspace "$WORKSPACE" \
    --package "$pkg" \
    --version "$ver" \
    --source "$src"
}

cmd_dispatch() {
  local role=""
  local type_name=""
  local tier=""
  local parent_model="${HARNESS_PARENT_MODEL:-}"
  local explicit_effort=""
  local conversation_id="${HARNESS_CONVERSATION_ID:-}"

  while [ $# -gt 0 ]; do
    case "$1" in
      --role)
        [ $# -ge 2 ] || { echo "Error: --role requires a role description" >&2; exit 1; }
        role="$2"
        shift 2
        ;;
      --role=*)
        role="${1#--role=}"
        shift
        ;;
      --type)
        [ $# -ge 2 ] || { echo "Error: --type requires a subagent typeName" >&2; exit 1; }
        type_name="$2"
        shift 2
        ;;
      --type=*)
        type_name="${1#--type=}"
        shift
        ;;
      --tier)
        [ $# -ge 2 ] || { echo "Error: --tier requires a tier name" >&2; exit 1; }
        tier="$2"
        shift 2
        ;;
      --tier=*)
        tier="${1#--tier=}"
        shift
        ;;
      --parent-model)
        [ $# -ge 2 ] || { echo "Error: --parent-model requires a model name" >&2; exit 1; }
        parent_model="$2"
        shift 2
        ;;
      --parent-model=*)
        parent_model="${1#--parent-model=}"
        shift
        ;;
      --effort)
        [ $# -ge 2 ] || { echo "Error: --effort requires LOW|MEDIUM|HIGH|XHIGH|MAX" >&2; exit 1; }
        explicit_effort="$2"
        shift 2
        ;;
      --effort=*)
        explicit_effort="${1#--effort=}"
        shift
        ;;
      --conversation-id)
        [ $# -ge 2 ] || { echo "Error: --conversation-id requires a conversation id" >&2; exit 1; }
        conversation_id="$2"
        shift 2
        ;;
      --conversation-id=*)
        conversation_id="${1#--conversation-id=}"
        shift
        ;;
      *)
        echo "Error: unknown argument for dispatch: $1" >&2
        exit 1
        ;;
    esac
  done

  if [ -z "$role" ] || [ -z "$type_name" ]; then
    echo "Error: dispatch requires non-empty --role and --type" >&2
    exit 1
  fi

  local model=""
  local effort=""
  if ! effort="$(harness_default_effort_for_tier "$tier")"; then
    echo "Error: unknown dispatch --tier '$tier' (expected trivial_lookup|bounded_execution|multi_module_integration|critical_architecture_or_audit)" >&2
    exit 1
  fi

  if [ -n "$explicit_effort" ]; then
    if ! harness_is_valid_effort_profile "$explicit_effort"; then
      echo "Error: invalid dispatch --effort '$explicit_effort' (expected LOW|MEDIUM|HIGH|XHIGH|MAX)" >&2
      exit 1
    fi
    effort="$explicit_effort"
  fi

  model="$(harness_resolve_subagent_model "$parent_model" "$tier" "" "false")"

  python3 -B "$(harness_core_python)" dispatch-register \
    --workspace "$WORKSPACE" \
    --role "$role" \
    --type "$type_name" \
    --tier "$tier" \
    --model "$model" \
    --effort "$effort" \
    --conversation-id="$conversation_id"
}

cmd_select_model() {
  local tier=""
  local parent_model="${HARNESS_PARENT_MODEL:-}"
  local caller_model=""
  local explicit_effort=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --tier)
        [ $# -ge 2 ] || { echo "Error: --tier requires a tier name" >&2; exit 1; }
        tier="$2"
        shift 2
        ;;
      --tier=*)
        tier="${1#--tier=}"
        shift
        ;;
      --parent-model)
        [ $# -ge 2 ] || { echo "Error: --parent-model requires a model name" >&2; exit 1; }
        parent_model="$2"
        shift 2
        ;;
      --parent-model=*)
        parent_model="${1#--parent-model=}"
        shift
        ;;
      --caller-model)
        [ $# -ge 2 ] || { echo "Error: --caller-model requires a model tier" >&2; exit 1; }
        caller_model="$2"
        shift 2
        ;;
      --caller-model=*)
        caller_model="${1#--caller-model=}"
        shift
        ;;
      --effort)
        [ $# -ge 2 ] || { echo "Error: --effort requires LOW|MEDIUM|HIGH|XHIGH|MAX" >&2; exit 1; }
        explicit_effort="$2"
        shift 2
        ;;
      --effort=*)
        explicit_effort="${1#--effort=}"
        shift
        ;;
      *)
        echo "Error: unknown argument for select-model: $1" >&2
        exit 1
        ;;
    esac
  done

  local effort=""
  if ! effort="$(harness_default_effort_for_tier "$tier")"; then
    echo "Error: unknown select-model --tier '$tier' (expected trivial_lookup|bounded_execution|multi_module_integration|critical_architecture_or_audit)" >&2
    exit 1
  fi

  if [ -n "$explicit_effort" ]; then
    if ! harness_is_valid_effort_profile "$explicit_effort"; then
      echo "Error: invalid select-model --effort '$explicit_effort' (expected LOW|MEDIUM|HIGH|XHIGH|MAX)" >&2
      exit 1
    fi
    effort="$explicit_effort"
  fi

  local family model effort_hint deprecated_flag="false"
  family="$(harness_classify_parent_model "$parent_model")"
  model="$(harness_resolve_subagent_model "$parent_model" "$tier" "$caller_model" "false")"
  effort_hint="$(harness_detect_parent_effort_hint "$parent_model")"
  if harness_is_deprecated_model "$parent_model"; then
    deprecated_flag="true"
  fi

  jq -nc \
    --arg tier "$tier" \
    --arg parentModel "$parent_model" \
    --arg parentFamily "$family" \
    --arg parentEffortHint "$effort_hint" \
    --argjson deprecated "$deprecated_flag" \
    --arg model "$model" \
    --arg effort "$effort" \
    '{tier: $tier, parentModel: $parentModel, parentFamily: $parentFamily, parentEffortHint: $parentEffortHint, deprecated: $deprecated, model: $model, effortProfile: $effort}'
}

cmd_verify_pr_stamps() {
  if [ $# -gt 0 ]; then
    echo "Error: unexpected arguments for verify-pr-stamps: $*" >&2
    exit 1
  fi

  python3 -B "$(harness_core_python)" verify-pr-stamps --workspace "$WORKSPACE"
}

cmd_ui() {
  local verdict=""
  local p0="0"
  local p1="0"
  local targets=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --verdict)
        [ $# -ge 2 ] || { echo "Error: --verdict requires PASS or FAIL" >&2; exit 1; }
        verdict="$2"
        shift 2
        ;;
      --verdict=*)
        verdict="${1#--verdict=}"
        shift
        ;;
      --p0)
        [ $# -ge 2 ] || { echo "Error: --p0 requires a non-negative integer" >&2; exit 1; }
        p0="$2"
        shift 2
        ;;
      --p0=*)
        p0="${1#--p0=}"
        shift
        ;;
      --p1)
        [ $# -ge 2 ] || { echo "Error: --p1 requires a non-negative integer" >&2; exit 1; }
        p1="$2"
        shift 2
        ;;
      --p1=*)
        p1="${1#--p1=}"
        shift
        ;;
      --target)
        [ $# -ge 2 ] || { echo "Error: --target requires a relative file path" >&2; exit 1; }
        local norm_t="$2"
        while [[ "$norm_t" == ./* ]]; do norm_t="${norm_t#./}"; done
        targets+=("$norm_t")
        shift 2
        ;;
      --target=*)
        local norm_t="${1#--target=}"
        while [[ "$norm_t" == ./* ]]; do norm_t="${norm_t#./}"; done
        targets+=("$norm_t")
        shift
        ;;
      *)
        echo "Error: unknown argument for ui: $1" >&2
        exit 1
        ;;
    esac
  done

  if [ "$verdict" != "PASS" ] && [ "$verdict" != "FAIL" ]; then
    echo "Error: ui --verdict must be PASS or FAIL (got '$verdict')" >&2
    exit 1
  fi
  if [[ ! "$p0" =~ ^[0-9]+$ ]]; then
    echo "Error: ui --p0 must be a non-negative integer (got '$p0')" >&2
    exit 1
  fi
  if [[ ! "$p1" =~ ^[0-9]+$ ]]; then
    echo "Error: ui --p1 must be a non-negative integer (got '$p1')" >&2
    exit 1
  fi

  local py_args=(ui-stamp --workspace "$WORKSPACE" --verdict "$verdict" --p0 "$p0" --p1 "$p1")
  local t
  for t in ${targets[@]+"${targets[@]}"}; do
    py_args+=(--target "$t")
  done

  python3 -B "$(harness_core_python)" "${py_args[@]}"
}

cmd_tdd() {
  local verdict=""
  local critical_gaps=""
  local important_gaps=""
  local provider=""
  local model=""
  local effort=""
  local files=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --verdict)
        [ $# -ge 2 ] || { echo "Error: --verdict requires PASS or FAIL" >&2; exit 1; }
        verdict="$2"
        shift 2
        ;;
      --verdict=*)
        verdict="${1#--verdict=}"
        shift
        ;;
      --critical-gaps)
        [ $# -ge 2 ] || { echo "Error: --critical-gaps requires a non-negative integer" >&2; exit 1; }
        critical_gaps="$2"
        shift 2
        ;;
      --critical-gaps=*)
        critical_gaps="${1#--critical-gaps=}"
        shift
        ;;
      --important-gaps)
        [ $# -ge 2 ] || { echo "Error: --important-gaps requires a non-negative integer" >&2; exit 1; }
        important_gaps="$2"
        shift 2
        ;;
      --important-gaps=*)
        important_gaps="${1#--important-gaps=}"
        shift
        ;;
      --provider)
        [ $# -ge 2 ] || { echo "Error: --provider requires claude-cli, agy-cli, or subagent" >&2; exit 1; }
        provider="$2"
        shift 2
        ;;
      --provider=*)
        provider="${1#--provider=}"
        shift
        ;;
      --model)
        [ $# -ge 2 ] || { echo "Error: --model requires a model identifier" >&2; exit 1; }
        model="$2"
        shift 2
        ;;
      --model=*)
        model="${1#--model=}"
        shift
        ;;
      --effort)
        [ $# -ge 2 ] || { echo "Error: --effort requires an effort level" >&2; exit 1; }
        effort="$2"
        shift 2
        ;;
      --effort=*)
        effort="${1#--effort=}"
        shift
        ;;
      --file)
        [ $# -ge 2 ] || { echo "Error: --file requires a relative file path" >&2; exit 1; }
        local norm_f="$2"
        while [[ "$norm_f" == ./* ]]; do norm_f="${norm_f#./}"; done
        files+=("$norm_f")
        shift 2
        ;;
      --file=*)
        local norm_f="${1#--file=}"
        while [[ "$norm_f" == ./* ]]; do norm_f="${norm_f#./}"; done
        files+=("$norm_f")
        shift
        ;;
      *)
        echo "Error: unknown argument for tdd: $1" >&2
        exit 1
        ;;
    esac
  done

  if [ "$verdict" != "PASS" ] && [ "$verdict" != "FAIL" ]; then
    echo "Error: tdd --verdict must be PASS or FAIL (got '$verdict')" >&2
    exit 1
  fi
  if [[ ! "$critical_gaps" =~ ^[0-9]+$ ]] || [[ ! "$important_gaps" =~ ^[0-9]+$ ]]; then
    echo "Error: tdd --critical-gaps and --important-gaps must be non-negative integers" >&2
    exit 1
  fi
  if [ -z "$provider" ] || [ -z "$model" ]; then
    echo "Error: tdd requires non-empty --provider and --model" >&2
    exit 1
  fi

  local py_args=(tdd-stamp --workspace="$WORKSPACE" --verdict="$verdict" --critical-gaps="$critical_gaps" --important-gaps="$important_gaps" --provider="$provider" --model="$model" --effort="$effort")
  local f
  for f in ${files[@]+"${files[@]}"}; do
    py_args+=(--file="$f")
  done

  python3 -B "$(harness_core_python)" "${py_args[@]}"
}

cmd_review() {
  local kind=""
  local provider="claude"
  local model=""
  local effort=""
  local auto_stamp="false"
  local targets=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --kind)
        [ $# -ge 2 ] || { echo "Error: --kind requires spec-plan or tdd" >&2; exit 1; }
        kind="$2"
        shift 2
        ;;
      --kind=*)
        kind="${1#--kind=}"
        shift
        ;;
      --provider)
        [ $# -ge 2 ] || { echo "Error: --provider requires claude or agy" >&2; exit 1; }
        provider="$2"
        shift 2
        ;;
      --provider=*)
        provider="${1#--provider=}"
        shift
        ;;
      --model)
        [ $# -ge 2 ] || { echo "Error: --model requires a model identifier" >&2; exit 1; }
        model="$2"
        shift 2
        ;;
      --model=*)
        model="${1#--model=}"
        shift
        ;;
      --effort)
        [ $# -ge 2 ] || { echo "Error: --effort requires an effort level" >&2; exit 1; }
        effort="$2"
        shift 2
        ;;
      --effort=*)
        effort="${1#--effort=}"
        shift
        ;;
      --target)
        [ $# -ge 2 ] || { echo "Error: --target requires a relative file path" >&2; exit 1; }
        local norm_t="$2"
        while [[ "$norm_t" == ./* ]]; do norm_t="${norm_t#./}"; done
        targets+=("$norm_t")
        shift 2
        ;;
      --target=*)
        local norm_t="${1#--target=}"
        while [[ "$norm_t" == ./* ]]; do norm_t="${norm_t#./}"; done
        targets+=("$norm_t")
        shift
        ;;
      --auto-stamp)
        auto_stamp="true"
        shift
        ;;
      *)
        echo "Error: unknown argument for review: $1" >&2
        exit 1
        ;;
    esac
  done

  if [ "$kind" != "spec-plan" ] && [ "$kind" != "tdd" ]; then
    echo "Error: review --kind must be spec-plan or tdd (got '$kind')" >&2
    exit 1
  fi

  local py_args=(external-review --workspace="$WORKSPACE" --kind="$kind" --provider="$provider" --model="$model" --effort="$effort")
  if [ "$auto_stamp" = "true" ]; then
    py_args+=(--auto-stamp)
  fi
  local t
  for t in ${targets[@]+"${targets[@]}"}; do
    py_args+=(--target="$t")
  done

  python3 -B "$(harness_core_python)" "${py_args[@]}"
}

cmd_clear_pr_audit() {
  if [ $# -gt 0 ]; then
    echo "Error: unexpected arguments for clear-pr-audit: $*" >&2
    exit 1
  fi
  python3 -B "$(harness_core_python)" clear-pr-audit --workspace "$WORKSPACE"
}

case "$SUBCMD" in
  tree-sha)
    cmd_tree_sha ${SUB_ARGS[@]+"${SUB_ARGS[@]}"}
    ;;
  canon)
    cmd_canon ${SUB_ARGS[@]+"${SUB_ARGS[@]}"}
    ;;
  security)
    cmd_security ${SUB_ARGS[@]+"${SUB_ARGS[@]}"}
    ;;
  tdd)
    cmd_tdd ${SUB_ARGS[@]+"${SUB_ARGS[@]}"}
    ;;
  review)
    cmd_review ${SUB_ARGS[@]+"${SUB_ARGS[@]}"}
    ;;
  ui)
    cmd_ui ${SUB_ARGS[@]+"${SUB_ARGS[@]}"}
    ;;
  context7)
    cmd_context7 ${SUB_ARGS[@]+"${SUB_ARGS[@]}"}
    ;;
  dispatch)
    cmd_dispatch ${SUB_ARGS[@]+"${SUB_ARGS[@]}"}
    ;;
  select-model)
    cmd_select_model ${SUB_ARGS[@]+"${SUB_ARGS[@]}"}
    ;;
  verify-pr-stamps)
    cmd_verify_pr_stamps ${SUB_ARGS[@]+"${SUB_ARGS[@]}"}
    ;;
  clear-pr-audit)
    cmd_clear_pr_audit ${SUB_ARGS[@]+"${SUB_ARGS[@]}"}
    ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    echo "Error: unknown subcommand '$SUBCMD'" >&2
    usage
    exit 1
    ;;
esac
