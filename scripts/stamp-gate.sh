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
  stamp-gate.sh context7 --package <name> --version <ver> --source locked|greenfield-latest [--workspace <dir>]
  stamp-gate.sh dispatch --role <role> --type <typeName> --tier <tier> [--parent-model <modelName>] [--effort LOW|MEDIUM|HIGH|XHIGH|MAX] [--workspace <dir>]
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

  local state_dir ts existing json_payload
  state_dir="$(harness_state_dir "$WORKSPACE")"
  ts="$(utc_now)"
  existing='{"packages":{}}'
  if [ -f "$state_dir/context7-verified.json" ]; then
    if jq -e 'type == "object" and (.packages | type == "object")' "$state_dir/context7-verified.json" >/dev/null 2>&1; then
      existing="$(cat "$state_dir/context7-verified.json")"
    fi
  fi

  json_payload="$(jq -nc \
    --argjson base "$existing" \
    --arg pkg "$pkg" \
    --arg ver "$ver" \
    --arg src "$src" \
    --arg ts "$ts" \
    '$base | .packages = ((.packages // {}) + {($pkg): {version: $ver, source: $src, timestamp: $ts}})')"

  atomic_write_json "$state_dir" "context7-verified.json" "$json_payload"
}

cmd_dispatch() {
  local role=""
  local type_name=""
  local tier=""
  local parent_model="${HARNESS_PARENT_MODEL:-}"
  local explicit_effort=""

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

  local state_dir ts existing json_payload
  state_dir="$(harness_state_dir "$WORKSPACE")"
  ts="$(utc_now)"
  existing='{"entries":{}}'
  if [ -f "$state_dir/subagent-dispatch.json" ]; then
    if jq -e 'type == "object" and (.entries | type == "object")' "$state_dir/subagent-dispatch.json" >/dev/null 2>&1; then
      existing="$(cat "$state_dir/subagent-dispatch.json")"
    fi
  fi

  json_payload="$(jq -nc \
    --argjson base "$existing" \
    --arg role "$role" \
    --arg typeName "$type_name" \
    --arg tier "$tier" \
    --arg model "$model" \
    --arg effort "$effort" \
    --arg ts "$ts" \
    '$base | .entries = ((.entries // {}) + {
      ($role): {
        typeName: $typeName,
        tier: $tier,
        model: $model,
        effortProfile: $effort,
        consumed: false,
        timestamp: $ts
      }
    })')"

  atomic_write_json "$state_dir" "subagent-dispatch.json" "$json_payload"
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

  local family model
  family="$(harness_classify_parent_model "$parent_model")"
  model="$(harness_resolve_subagent_model "$parent_model" "$tier" "$caller_model" "false")"

  jq -nc \
    --arg tier "$tier" \
    --arg parentModel "$parent_model" \
    --arg parentFamily "$family" \
    --arg model "$model" \
    --arg effort "$effort" \
    '{tier: $tier, parentModel: $parentModel, parentFamily: $parentFamily, model: $model, effortProfile: $effort}'
}

cmd_verify_pr_stamps() {
  if [ $# -gt 0 ]; then
    echo "Error: unexpected arguments for verify-pr-stamps: $*" >&2
    exit 1
  fi

  local current_sha
  current_sha="$(harness_code_tree_sha "$WORKSPACE")"
  if [ "$current_sha" = "UNBORN" ]; then
    echo "Error: verify-pr-stamps failed: repository HEAD is UNBORN (no commits found)" >&2
    exit 1
  fi

  local state_dir canon_file security_file
  state_dir="$(harness_state_dir "$WORKSPACE")"
  canon_file="$state_dir/canon-pass.json"
  security_file="$state_dir/security-pass.json"

  if [ ! -f "$canon_file" ]; then
    echo "Error: verify-pr-stamps failed: missing canon stamp ($canon_file)" >&2
    exit 1
  fi

  if [ ! -f "$security_file" ]; then
    echo "Error: verify-pr-stamps failed: missing security stamp ($security_file)" >&2
    exit 1
  fi

  local canon_verdict canon_sha
  canon_verdict="$(jq -r '.verdict // empty' "$canon_file" 2>/dev/null || true)"
  canon_sha="$(jq -r '.codeTreeSha // empty' "$canon_file" 2>/dev/null || true)"

  if [ "$canon_verdict" != "PASS" ]; then
    echo "Error: verify-pr-stamps failed: canon-pass.json verdict is '$canon_verdict' (expected PASS)" >&2
    exit 1
  fi

  if [ "$canon_sha" != "$current_sha" ]; then
    echo "Error: verify-pr-stamps failed: canon-pass.json codeTreeSha ($canon_sha) does not match current HEAD codeTreeSha ($current_sha)" >&2
    exit 1
  fi

  local sec_verdict sec_sha
  sec_verdict="$(jq -r '.verdict // empty' "$security_file" 2>/dev/null || true)"
  sec_sha="$(jq -r '.codeTreeSha // empty' "$security_file" 2>/dev/null || true)"

  if [ "$sec_verdict" != "PASS" ]; then
    echo "Error: verify-pr-stamps failed: security-pass.json verdict is '$sec_verdict' (expected PASS)" >&2
    exit 1
  fi

  if ! jq -e '(.criticalCount == 0) and (.importantCount == 0)' "$security_file" >/dev/null 2>&1; then
    echo "Error: verify-pr-stamps failed: security-pass.json has non-zero criticalCount or importantCount" >&2
    exit 1
  fi

  if [ "$sec_sha" != "$current_sha" ]; then
    echo "Error: verify-pr-stamps failed: security-pass.json codeTreeSha ($sec_sha) does not match current HEAD codeTreeSha ($current_sha)" >&2
    exit 1
  fi

  return 0
}

cmd_clear_pr_audit() {
  if [ $# -gt 0 ]; then
    echo "Error: unexpected arguments for clear-pr-audit: $*" >&2
    exit 1
  fi
  local state_dir
  state_dir="$(harness_state_dir "$WORKSPACE")"
  rm -f "$state_dir/pr-audit-pending.json"
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
