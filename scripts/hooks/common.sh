#!/usr/bin/env bash
# Alps AGY Harness - Shared Hook Library (common.sh)
# Provides stdin parsing, branch slugging, git tree hashing, glossary checks, and PreToolUse JSON emitters.

# Read hook JSON payload from stdin into HOOK_INPUT and resolve WORKSPACE_ROOT.
harness_read_stdin() {
  if [ -t 0 ]; then
    HOOK_INPUT="{}"
  else
    HOOK_INPUT="$(cat)"
  fi

  if [ -z "${HOOK_INPUT//[[:space:]]/}" ]; then
    HOOK_INPUT="{}"
  fi

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

# Return filesystem-safe branch slug (<branch-with-hyphens> or detached-<7-char-sha>).
harness_branch_slug() {
  local workspace="${1:-${WORKSPACE_ROOT:-$PWD}}"
  local branch=""
  if branch="$(git -C "$workspace" symbolic-ref --quiet --short HEAD 2>/dev/null)" && [ -n "$branch" ]; then
    local slug
    slug="$(printf '%s' "$branch" | LC_ALL=C sed -E 's/[^A-Za-z0-9]+/-/g; s/^-+//; s/-+$//')"
    if [ -z "$slug" ]; then
      slug="default"
    fi
    printf '%s\n' "$slug"
  else
    local short_sha=""
    if short_sha="$(git -C "$workspace" rev-parse --short=7 HEAD 2>/dev/null)" && [ -n "$short_sha" ]; then
      printf 'detached-%s\n' "$short_sha"
    else
      printf 'detached-unknown\n'
    fi
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
    jq -nc --argjson overwrite "$overwrite_json" --arg reason "$reason" \
      '{decision: "allow", overwrite: $overwrite, reason: $reason}'
  else
    jq -nc --argjson overwrite "$overwrite_json" \
      '{decision: "allow", overwrite: $overwrite}'
  fi
}

# Parse a command line string into an array of argv token arrays, respecting quotes and stripping wrappers.
harness_parse_command_segments() {
  local cmd="${1:-}"
  if [ -z "$cmd" ]; then
    printf '[]\n'
    return 0
  fi
  python3 -c '
import sys, json, shlex

def parse_command_segments(cmd_line):
    segments = []
    current = []
    in_single = False
    in_double = False
    escape = False
    i = 0
    n = len(cmd_line)
    
    while i < n:
        c = cmd_line[i]
        if escape:
            current.append(c)
            escape = False
            i += 1
            continue
        if c == "\\" and not in_single:
            escape = True
            current.append(c)
            i += 1
            continue
        if c == "\x27" and not in_double:
            in_single = not in_single
            current.append(c)
            i += 1
            continue
        if c == "\x22" and not in_single:
            in_double = not in_double
            current.append(c)
            i += 1
            continue
            
        if not in_single and not in_double:
            if c in ("&", "|") and i + 1 < n and cmd_line[i+1] == c:
                seg = "".join(current).strip()
                if seg:
                    segments.append(seg)
                current = []
                i += 2
                continue
            elif c in (";", "\n", "|", "&", "(", ")"):
                seg = "".join(current).strip()
                if seg:
                    segments.append(seg)
                current = []
                i += 1
                continue
        current.append(c)
        i += 1
        
    seg = "".join(current).strip()
    if seg:
        segments.append(seg)
        
    result = []
    for s in segments:
        try:
            tokens = shlex.split(s)
        except Exception:
            tokens = s.split()
        if not tokens:
            continue
        idx = 0
        while idx < len(tokens):
            t = tokens[idx]
            if "=" in t and t.split("=", 1)[0].isidentifier():
                idx += 1
                continue
            if t == "sudo":
                idx += 1
                while idx < len(tokens) and tokens[idx].startswith("-"):
                    if tokens[idx] in ("-u", "-g", "-h", "-p", "-U"):
                        idx += 2
                    else:
                        idx += 1
                continue
            if t == "env":
                idx += 1
                while idx < len(tokens):
                    if tokens[idx].startswith("-"):
                        idx += 1
                    elif "=" in tokens[idx] and tokens[idx].split("=", 1)[0].isidentifier():
                        idx += 1
                    else:
                        break
                continue
            if t in ("nohup", "time", "builtin", "command"):
                idx += 1
                continue
            break
        cleaned = tokens[idx:]
        if cleaned:
            result.append(cleaned)
    return result

cmd = sys.argv[1] if len(sys.argv) > 1 else ""
print(json.dumps(parse_command_segments(cmd)))
' "$cmd"
}
