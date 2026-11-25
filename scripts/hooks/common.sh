#!/usr/bin/env bash
# Alps AGY Harness - Shared Hook Library (common.sh)
# Provides stdin parsing, branch slugging, git tree hashing, glossary checks, daemon IPC, and PreToolUse JSON emitters.

_COMMON_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
_HARNESS_PLUGIN_ROOT="$(cd "$_COMMON_SH_DIR/../.." && pwd -P)"

# Return absolute path to the shared Python deterministic core module.
harness_core_python() {
  printf '%s/scripts/lib/harness_core.py\n' "$_HARNESS_PLUGIN_ROOT"
}

# Return secure per-user AF_UNIX socket path (respecting HARNESS_DAEMON_SOCK).
harness_daemon_socket_path() {
  if [ -n "${HARNESS_DAEMON_SOCK:-}" ]; then
    printf '%s\n' "$HARNESS_DAEMON_SOCK"
  else
    printf '/tmp/agy-hd-%s/d.sock\n' "$(id -u)"
  fi
}

# Return 0 when socket path and parent dir pass UID, non-symlink, and strict 0700 checks.
harness_is_safe_daemon_socket() {
  local sock="${1:-}"
  [ -n "$sock" ] || return 1
  local sock_dir
  sock_dir="$(dirname "$sock")"
  [ -n "$sock_dir" ] || return 1
  [ ! -L "$sock_dir" ] && [ -d "$sock_dir" ] && [ -O "$sock_dir" ] || return 1
  local dir_mode
  dir_mode="$(stat -c '%a' "$sock_dir" 2>/dev/null || stat -f '%Lp' "$sock_dir" 2>/dev/null || true)"
  [[ "$dir_mode" =~ ^[0-7]+$ ]] || return 1
  [ "$(( 8#$dir_mode & 8#077 ))" -eq 0 ] || return 1
  [ ! -L "$sock" ] && [ -S "$sock" ] && [ -O "$sock" ] || return 1
  local sock_mode
  sock_mode="$(stat -c '%a' "$sock" 2>/dev/null || stat -f '%Lp' "$sock" 2>/dev/null || true)"
  [[ "$sock_mode" =~ ^[0-7]+$ ]] || return 1
  [ "$(( 8#$sock_mode & 8#077 ))" -eq 0 ] || return 1
  return 0
}

# Ensure the background harness-daemon is running when auto-start is enabled.
# Returns 0 if a safe, healthy socket is ready; 1 otherwise.
harness_ensure_daemon() {
  if [ "${HARNESS_DISABLE_DAEMON:-0}" = "1" ] || [ "${HARNESS_AUTO_START_DAEMON:-1}" != "1" ]; then
    return 1
  fi
  local sock="${1:-$(harness_daemon_socket_path)}"
  local mode="${2:-normal}"

  if [ "$mode" != "recover" ] && harness_is_safe_daemon_socket "$sock"; then
    return 0
  fi

  [ -n "$sock" ] && [ ! -L "$sock" ] || return 1
  if [ -e "$sock" ] && [ ! -O "$sock" ]; then
    return 1
  fi

  local sock_dir
  sock_dir="$(dirname "$sock")"
  [ -n "$sock_dir" ] && [ ! -L "$sock_dir" ] || return 1
  if [ -e "$sock_dir" ]; then
    [ -d "$sock_dir" ] && [ -O "$sock_dir" ] || return 1
    local dir_mode
    dir_mode="$(stat -c '%a' "$sock_dir" 2>/dev/null || stat -f '%Lp' "$sock_dir" 2>/dev/null || true)"
    [[ "$dir_mode" =~ ^[0-7]+$ ]] || return 1
    [ "$(( 8#$dir_mode & 8#077 ))" -eq 0 ] || return 1
  fi

  local daemon_py="$_HARNESS_PLUGIN_ROOT/sidecars/harness-daemon/daemon.py"
  [ -f "$daemon_py" ] || return 1

  HARNESS_DAEMON_SOCK="$sock" HARNESS_DAEMON_EXIT_ON_LOCK_BUSY=1 nohup python3 -B "$daemon_py" </dev/null >/dev/null 2>&1 &

  local max_ticks="${HARNESS_DAEMON_STARTUP_WAIT_TICKS:-8}"
  local tick=0
  while [ "$tick" -lt "$max_ticks" ]; do
    if harness_is_safe_daemon_socket "$sock" && \
       curl -fsS --max-time 0.05 --unix-socket "$sock" "http://localhost/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.025
    tick=$((tick + 1))
  done

  harness_is_safe_daemon_socket "$sock"
}

# Query the background harness-daemon over its Unix domain socket.
# Auto-starts the daemon when enabled and socket is missing; fails closed on unsafe/missing/error sockets.
harness_daemon_call() {
  local endpoint="${1:?endpoint required}"
  local payload="${2:?payload required}"
  if [ "${HARNESS_DISABLE_DAEMON:-0}" = "1" ]; then
    return 1
  fi
  local sock
  sock="$(harness_daemon_socket_path)"
  if ! harness_is_safe_daemon_socket "$sock"; then
    if [ ! -e "$sock" ] && [ ! -L "$sock" ]; then
      harness_ensure_daemon "$sock" || return 1
    else
      return 1
    fi
  fi
  local timeout_sec="${HARNESS_DAEMON_TIMEOUT_SEC:-0.35}"
  local resp=""
  local rc=0
  resp="$(printf '%s' "$payload" | curl -fsS --max-time "$timeout_sec" --unix-socket "$sock" \
    -H "Content-Type: application/json" \
    -X POST \
    --data-binary @- \
    "http://localhost${endpoint}" 2>/dev/null)" || rc=$?

  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$resp"
    return 0
  fi

  if [ "$rc" -eq 7 ] && harness_ensure_daemon "$sock" "recover"; then
    resp="$(printf '%s' "$payload" | curl -fsS --max-time "$timeout_sec" --unix-socket "$sock" \
      -H "Content-Type: application/json" \
      -X POST \
      --data-binary @- \
      "http://localhost${endpoint}" 2>/dev/null)" || return 1
    printf '%s\n' "$resp"
    return 0
  fi

  return 1
}

# Read hook JSON payload from stdin into HOOK_INPUT and resolve WORKSPACE_ROOT.
harness_read_stdin() {
  if [ -t 0 ]; then
    HOOK_INPUT="{}"
  else
    HOOK_INPUT="$(cat)"
  fi

  case "$HOOK_INPUT" in
    *[![:space:]]*) ;;
    *) HOOK_INPUT="{}" ;;
  esac

  local ws=""
  ws="$(printf '%s\n' "$HOOK_INPUT" | jq -r '.workspacePaths[0] // empty' 2>/dev/null || true)"
  if [ -n "$ws" ]; then
    WORKSPACE_ROOT="$ws"
  else
    WORKSPACE_ROOT="$PWD"
  fi

  export HOOK_INPUT WORKSPACE_ROOT
}

# Atomically write JSON string content to $state_dir/$filename via a hidden temp file.
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

# Return 0 if workspace opts out via .harness-ignore, 1 otherwise.
harness_is_ignored() {
  local workspace="${1:-${WORKSPACE_ROOT:-$PWD}}"
  [ -f "$workspace/.harness-ignore" ]
}

# Return active symbolic branch name (including unborn branches), or "HEAD" when detached.
harness_branch_name() {
  local workspace="${1:-${WORKSPACE_ROOT:-$PWD}}"
  local branch=""
  if branch="$(git -C "$workspace" symbolic-ref --quiet --short HEAD 2>/dev/null)" && [ -n "$branch" ]; then
    printf '%s\n' "$branch"
  else
    printf 'HEAD\n'
  fi
}

# Convert a branch or worktree name into the canonical filesystem-safe slug.
_harness_slugify() {
  local raw="${1:-}"
  local slug
  slug="$(printf '%s' "$raw" | LC_ALL=C sed -E 's/[^A-Za-z0-9]+/-/g; s/^-+//; s/-+$//')"
  if [ -z "$slug" ]; then
    slug="default"
  fi
  printf '%s\n' "$slug"
}

# Return filesystem-safe branch slug (<branch-with-hyphens>, detached-wt-<name>, or detached-<7-char-sha>).
harness_branch_slug() {
  local workspace="${1:-${WORKSPACE_ROOT:-$PWD}}"
  local branch=""
  if branch="$(git -C "$workspace" symbolic-ref --quiet --short HEAD 2>/dev/null)" && [ -n "$branch" ]; then
    _harness_slugify "$branch"
    return 0
  fi

  local git_dirs="" raw_gd="" raw_cd=""
  if git_dirs="$(git -C "$workspace" rev-parse --git-dir --git-common-dir 2>/dev/null)" && [ -n "$git_dirs" ]; then
    {
      IFS= read -r raw_gd || true
      IFS= read -r raw_cd || true
    } <<EOF
$git_dirs
EOF
    if [ -n "$raw_gd" ] && [ -n "$raw_cd" ]; then
      local gd_abs cd_abs real_gd="" real_cd=""
      case "$raw_gd" in
        /*) gd_abs="$raw_gd" ;;
        *) gd_abs="$workspace/$raw_gd" ;;
      esac
      case "$raw_cd" in
        /*) cd_abs="$raw_cd" ;;
        *) cd_abs="$workspace/$raw_cd" ;;
      esac
      real_gd="$(unset CDPATH && cd -- "$gd_abs" 2>/dev/null && pwd -P || true)"
      real_cd="$(unset CDPATH && cd -- "$cd_abs" 2>/dev/null && pwd -P || true)"
      if [ -n "$real_gd" ] && [ -n "$real_cd" ] && [ "$real_gd" != "$real_cd" ]; then
        local wt_parent wt_name
        wt_parent="$(basename "$(dirname "$real_gd")")"
        wt_name="$(basename "$real_gd")"
        if [ "$wt_parent" = "worktrees" ] && [ -n "$wt_name" ]; then
          printf 'detached-wt-%s\n' "$(_harness_slugify "$wt_name")"
          return 0
        fi
      fi
    fi
  fi

  local short_sha=""
  if short_sha="$(git -C "$workspace" rev-parse --short=7 HEAD 2>/dev/null)" && [ -n "$short_sha" ]; then
    printf 'detached-%s\n' "$short_sha"
  else
    printf 'detached-unknown\n'
  fi
}

# Ensure $workspace/.harness/state/<slug> exists, idempotently exclude .harness/ in git, and print state dir path.
harness_state_dir() {
  local workspace="${1:-${WORKSPACE_ROOT:-$PWD}}"
  local slug
  slug="$(harness_branch_slug "$workspace")"
  local state_dir="$workspace/.harness/state/$slug"

  mkdir -p "$state_dir"

  if git -C "$workspace" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local exclude_rel=""
    exclude_rel="$(git -C "$workspace" rev-parse --git-path info/exclude 2>/dev/null || true)"
    if [ -n "$exclude_rel" ]; then
      local exclude_file
      if [[ "$exclude_rel" == /* ]]; then
        exclude_file="$exclude_rel"
      else
        exclude_file="$workspace/$exclude_rel"
      fi
      mkdir -p "$(dirname "$exclude_file")"
      [ -f "$exclude_file" ] || : > "$exclude_file"
      if ! grep -Fqx '.harness/' "$exclude_file" 2>/dev/null; then
        if [ -s "$exclude_file" ] && [ -n "$(tail -c 1 "$exclude_file")" ]; then
          printf '\n' >> "$exclude_file"
        fi
        printf '.harness/\n' >> "$exclude_file"
      fi
    fi
  fi

  printf '%s\n' "$state_dir"
}

# Compute deterministic git tree SHA excluding docs/walkthroughs/* and docs/parking-lot.md ("UNBORN" if no HEAD).
harness_code_tree_sha() {
  local workspace="${1:-${WORKSPACE_ROOT:-$PWD}}"
  if ! git -C "$workspace" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
    printf 'UNBORN\n'
    return 0
  fi

  local tab=$'\t'
  git -C "$workspace" ls-tree -r HEAD \
    | { grep -Ev "${tab}docs/(walkthroughs/|parking-lot\\.md\$)" || true; } \
    | git -C "$workspace" hash-object --stdin
}

# Verify markdown content string ends with a non-empty Technical Glossary / Teknik Terimler Sözlüğü H2 section,
# ignoring headings and lines inside fenced code blocks.
harness_has_glossary_section() {
  local text="${1:-}"
  [ -n "$text" ] || return 1

  printf '%s\n' "$text" | jq -Rse '
    split("\n")
    | map(sub("\r$"; ""))
    | reduce .[] as $line (
        {
          in_fence: false,
          fence_len: 0,
          has_h2: false,
          last_h2_is_glossary: false,
          seen_sep: false,
          data_after_sep: false,
          has_bullet_or_row: false
        };
        if .in_fence then
          if ($line | test("^[ \t]*`{3,}[ \t]*$")) and (($line | match("^[ \t]*(`{3,})[ \t]*$").captures[0].length) >= .fence_len) then
            .in_fence = false | .fence_len = 0
          else
            .
          end
        elif ($line | test("^[ \t]*`{3,}")) then
          .in_fence = true | .fence_len = ($line | match("^[ \t]*(`{3,})").captures[0].length)
        elif ($line | test("^## ")) then
          .has_h2 = true
          | .seen_sep = false
          | .data_after_sep = false
          | .has_bullet_or_row = false
          | .last_h2_is_glossary = ($line | test("^## ([0-9]+\\. )?(Teknik Terimler Sözlüğü|Technical Glossary)[[:space:]]*$"))
        elif .last_h2_is_glossary then
          if ($line | test("^\\|[[:space:]:|-]+\\|[[:space:]]*$")) then
            .seen_sep = true
          elif .seen_sep then
            if ($line | test("^\\|")) and (($line | test("^\\|[[:space:]]*$")) | not) then
              .data_after_sep = true
            else
              .
            end
          else
            if ($line | test("^[[:space:]]*[-*][[:space:]]+\\*\\*[^*]+\\*\\*")) or ($line | test("^\\|[^-]")) then
              .has_bullet_or_row = true
            else
              .
            end
          end
        else
          .
        end
      )
    | .has_h2 and .last_h2_is_glossary and (if .seen_sep then .data_after_sep else .has_bullet_or_row end)
  ' >/dev/null 2>&1
}

# Validate a PR/merge walkthrough markdown string against:
#   1. >= 2 ```mermaid diagrams
#   2. No unedited template placeholders
#   3. Mandatory '## Dosya Bazlı Değişiklik Analizi' (or '## File-by-File Change Analysis') H2 section
#   4. 100% coverage of all changed/created/deleted files in $2 (excluding docs/walkthroughs/* and docs/parking-lot.md)
#   5. Non-shallow per-file 'Ne Değişti/Üretildi/Silindi' (What) and 'Neden Değişti/Üretildi/Silindi' (Why) explanations
# Prints an actionable English error reason on stdout and returns 1 on failure; returns 0 on success.
harness_validate_walkthrough() {
  local wt_text="${1:-}"
  local diff_files_raw="${2:-}"

  if [ -z "$wt_text" ]; then
    printf 'walkthrough file in docs/walkthroughs/*.md is empty.\n'
    return 1
  fi

  WT_TEXT="$wt_text" DIFF_FILES_RAW="$diff_files_raw" python3 -B "$(harness_core_python)" validate-walkthrough
}

# Return 0 when normalized model name indicates a low-effort tier variant.
_harness_is_low_model_variant() {
  local norm="${1:-}"
  [[ "$norm" == *-low ]] || [[ "$norm" == *"(low)"* ]] || [[ "$norm" == *" low"* ]]
}

# Classify a parent session modelName (slug or display label) into a canonical routing family:
#   unset | orchestrator | carbon | neon | argon_low | argon | hydrogen | claude | flash | custom
harness_classify_parent_model() {
  local raw="${1:-}"
  case "$raw" in
    *[![:space:]]*) ;;
    *)
      printf 'unset\n'
      return 0
      ;;
  esac

  local norm
  norm="$(printf '%s' "$raw" | LC_ALL=C tr '[:upper:]' '[:lower:]')"

  case "$norm" in
    *orchestrator*|auto)
      printf 'orchestrator\n'
      ;;
    *carbon*)
      printf 'carbon\n'
      ;;
    *neon*)
      if _harness_is_low_model_variant "$norm"; then
        printf 'argon_low\n'
      else
        printf 'neon\n'
      fi
      ;;
    *argon*)
      if _harness_is_low_model_variant "$norm"; then
        printf 'argon_low\n'
      else
        printf 'argon\n'
      fi
      ;;
    *hydrogen*)
      printf 'hydrogen\n'
      ;;
    *claude*|*opus*|*sonnet*)
      printf 'claude\n'
      ;;
    *flash*|*gpt-oss*)
      printf 'flash\n'
      ;;
    *gemini-4*|*"gemini 4"*)
      if _harness_is_low_model_variant "$norm"; then
        printf 'argon_low\n'
      else
        printf 'argon\n'
      fi
      ;;
    *)
      printf 'custom\n'
      ;;
  esac
}

# Return 0 when effort profile is one of LOW | MEDIUM | HIGH | XHIGH | MAX.
harness_is_valid_effort_profile() {
  case "${1:-}" in
    LOW|MEDIUM|HIGH|XHIGH|MAX) return 0 ;;
    *) return 1 ;;
  esac
}

# Default EFFORT_PROFILE for a dispatch complexity tier.
harness_default_effort_for_tier() {
  case "${1:-}" in
    trivial_lookup) printf 'LOW\n' ;;
    bounded_execution) printf 'MEDIUM\n' ;;
    multi_module_integration) printf 'HIGH\n' ;;
    critical_architecture_or_audit) printf 'MAX\n' ;;
    *) return 1 ;;
  esac
}

# Resolve parent-aware Antigravity invoke_subagent Model tier (inherit | flash_lite | flash | pro)
# from ($parent_model, $tier, $caller_model, $floor_upgraded).
harness_resolve_subagent_model() {
  local parent_model="${1:-}"
  local tier="${2:-}"
  local caller_model="${3:-}"
  local floor_upgraded="${4:-false}"
  local family
  family="$(harness_classify_parent_model "$parent_model")"

  case "$tier" in
    trivial_lookup)
      printf 'flash_lite\n'
      ;;
    bounded_execution)
      case "$family" in
        orchestrator|hydrogen|argon_low)
          printf 'inherit\n'
          ;;
        carbon|neon|argon|claude|custom)
          printf 'pro\n'
          ;;
        *)
          printf 'flash\n'
          ;;
      esac
      ;;
    multi_module_integration)
      case "$family" in
        orchestrator|argon|claude|custom)
          printf 'inherit\n'
          ;;
        carbon|neon)
          if [ "$caller_model" = "inherit" ]; then
            printf 'inherit\n'
          else
            printf 'pro\n'
          fi
          ;;
        argon_low|hydrogen|flash)
          printf 'pro\n'
          ;;
        unset)
          if [ "$floor_upgraded" = "true" ]; then
            printf 'pro\n'
          else
            printf 'inherit\n'
          fi
          ;;
      esac
      ;;
    critical_architecture_or_audit)
      case "$family" in
        orchestrator|carbon|neon|argon|claude|custom)
          printf 'inherit\n'
          ;;
        *)
          printf 'pro\n'
          ;;
      esac
      ;;
    *)
      return 1
      ;;
  esac
}

# Antigravity PreToolUse JSON emitters
emit_allow() {
  jq -nc '{decision: "allow"}'
}

emit_deny() {
  local reason="${1:-}"
  jq -nc --arg reason "$reason" '{decision: "deny", reason: $reason}'
}

emit_force_ask() {
  local reason="${1:-}"
  jq -nc --arg reason "$reason" '{decision: "force_ask", reason: $reason}'
}

emit_overwrite() {
  local overwrite_json="${1:?emit_overwrite requires a JSON object string}"
  local reason="${2:-}"
  if [ -n "$reason" ]; then
    printf '%s\n' "$overwrite_json" | jq -c --arg reason "$reason" \
      '{decision: "allow", overwrite: ., reason: $reason}'
  else
    printf '%s\n' "$overwrite_json" | jq -c \
      '{decision: "allow", overwrite: .}'
  fi
}

# Parse a command line string into an array of argv token arrays, respecting quotes and stripping wrappers.
harness_parse_command_segments() {
  local cmd="${1:-}"
  if [ -z "$cmd" ]; then
    printf '[]\n'
    return 0
  fi
  printf '%s' "$cmd" | python3 -B "$(harness_core_python)" parse-segments
}
