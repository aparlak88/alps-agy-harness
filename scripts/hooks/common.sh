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

  WT_TEXT="$wt_text" DIFF_FILES_RAW="$diff_files_raw" python3 -c '
import os, re, sys

text = os.environ.get("WT_TEXT", "")
diff_raw = os.environ.get("DIFF_FILES_RAW", "")

lines = [l.rstrip("\r") for l in text.split("\n")]

# 1. Parse code fences, count ```mermaid blocks, and locate per-file H2 section
in_fence = False
fence_len = 0
mermaid_count = 0
has_file_h2 = False
in_file_h2 = False
file_sec_lines = []
non_fence_lines = []

h2_file_re = re.compile(
    r"^##\s+(?:\d+\.\s+)?(?:Dosya Bazlı(?: Tam)? Değişiklik Analizi|File-by-File Change Analysis)\s*$",
    re.IGNORECASE,
)

for line in lines:
    stripped = line.lstrip(" \t")
    if in_fence:
        m_close = re.match(r"^(`{3,})[ \t]*$", stripped)
        if m_close and len(m_close.group(1)) >= fence_len:
            in_fence = False
            fence_len = 0
        if in_file_h2:
            file_sec_lines.append((True, line))
        continue

    m_open = re.match(r"^(`{3,})(.*)$", stripped)
    if m_open:
        in_fence = True
        fence_len = len(m_open.group(1))
        info = m_open.group(2).strip().lower()
        if info == "mermaid" or info.startswith("mermaid "):
            mermaid_count += 1
        if in_file_h2:
            file_sec_lines.append((True, line))
        continue

    non_fence_lines.append(line)

    if line.startswith("## "):
        if h2_file_re.match(line):
            has_file_h2 = True
            in_file_h2 = True
            continue
        elif in_file_h2:
            in_file_h2 = False

    if in_file_h2:
        file_sec_lines.append((False, line))

if mermaid_count < 2:
    print(
        f"walkthrough in docs/walkthroughs/*.md must contain at least 2 Mermaid diagrams (```mermaid); found {mermaid_count}."
    )
    sys.exit(1)

# 2. Reject unedited template placeholders outside inline backticks / code fences
def strip_inline_code(s: str) -> str:
    return re.sub(r"`[^`]*`", "", s)

for line in non_fence_lines:
    if line.startswith("#") and "[Özellik / Düzeltme Başlığı]" in strip_inline_code(line):
        print("walkthrough contains unedited template placeholder \"[Özellik / Düzeltme Başlığı]\".")
        sys.exit(1)
    if line.startswith("###") and (
        "[ÜRETİLDİ | GÜNCELLENDİ | SİLİNDİ]" in strip_inline_code(line)
        or "`<dosya/tam/yolu>`" in line
        or "<dosya-yolu>" in strip_inline_code(line)
    ):
        print("walkthrough contains unedited per-file template placeholder (e.g. \"[ÜRETİLDİ | GÜNCELLENDİ | SİLİNDİ]\" or \"<dosya/tam/yolu>\").")
        sys.exit(1)
    plain = strip_inline_code(line)
    for marker in (
        "[Gerçek problemi ve kök bağlamı açıklayın",
        "[Eklenen veya değiştirilen sınıfları, metod imzalarını",
        "[Bu dosyadaki değişikliği zorunlu kılan iş kuralını",
    ):
        if marker in plain:
            print(f"walkthrough contains unedited template placeholder: {marker}...")
            sys.exit(1)

# 3. Require mandatory per-file analysis H2 heading
if not has_file_h2:
    print(
        "walkthrough in docs/walkthroughs/*.md is missing mandatory \"## Dosya Bazlı Değişiklik Analizi\" (or \"## File-by-File Change Analysis\") section."
    )
    sys.exit(1)

# 4. Collect required diff files (excluding docs/walkthroughs/* and docs/parking-lot.md)
required_files = []
seen = set()
for raw in diff_raw.splitlines():
    f = raw.strip()
    if not f or f.startswith("docs/walkthroughs/") or f == "docs/parking-lot.md":
        continue
    if f not in seen:
        seen.add(f)
        required_files.append(f)

section_non_fence_text = "\n".join(l for is_f, l in file_sec_lines if not is_f)

if not required_files:
    if len(re.sub(r"\s+", "", section_non_fence_text)) < 15:
        print("walkthrough \"## Dosya Bazlı Değişiklik Analizi\" section cannot be empty.")
        sys.exit(1)
    sys.exit(0)

# 5. Split "## Dosya Bazlı Değişiklik Analizi" into H3 per-file blocks (outside code fences)
h3_blocks = []
cur_header = None
cur_lines = []
for is_f, l in file_sec_lines:
    if not is_f and re.match(r"^###[ \t]+", l):
        if cur_header is not None:
            h3_blocks.append((cur_header, cur_lines))
        cur_header = l
        cur_lines = []
    else:
        if cur_header is not None:
            cur_lines.append((is_f, l))
if cur_header is not None:
    h3_blocks.append((cur_header, cur_lines))

# Check first if any required file is completely missing from the section or lacks its own H3 block
section_full_text = "\n".join(l for _, l in file_sec_lines)
missing_files = []
missing_h3_files = []
file_to_block = {}

for rf in required_files:
    pat = re.compile(r"(?<![A-Za-z0-9_./-])" + re.escape(rf) + r"(?![A-Za-z0-9_./-])")
    matched_blocks = [(hdr, blines) for hdr, blines in h3_blocks if pat.search(hdr)]
    if matched_blocks:
        file_to_block[rf] = matched_blocks[0]
    elif not pat.search(section_full_text):
        missing_files.append(rf)
    else:
        missing_h3_files.append(rf)

if missing_files:
    print(
        "walkthrough \"## Dosya Bazlı Değişiklik Analizi\" is missing per-file analysis for: "
        + ", ".join(missing_files)
        + ". Every created, modified, or deleted file in git diff must be documented."
    )
    sys.exit(1)

if missing_h3_files:
    print(
        "walkthrough \"## Dosya Bazlı Değişiklik Analizi\" is too shallow for: "
        + ", ".join(missing_h3_files)
        + ". Each file must have its own dedicated \"### `<path>` — [ÜRETİLDİ|GÜNCELLENDİ|SİLİNDİ]\" subsection instead of one-line summary bullets."
    )
    sys.exit(1)

# 6. Verify every file H3 block contains substantive What ("Ne ...") and Why ("Neden ...") prose (>= 25 chars each)
what_label = (
    r"(?:Ne\s+(?:Değişti|Üretildi|Silindi|Eklendi)"
    r"(?:\s*/\s*(?:Ne\s+)?(?:Değişti|Üretildi|Silindi|Eklendi))*"
    r"|What\s+(?:Changed|Was\s+(?:Added|Created|Updated|Removed|Deleted)))"
)
why_label = (
    r"(?:Neden\s+(?:Değişti|Üretildi|Silindi|Eklendi)"
    r"(?:\s*/\s*(?:Neden\s+)?(?:Değişti|Üretildi|Silindi|Eklendi))*"
    r"|Why\s+(?:It\s+)?(?:Changed|Was\s+(?:Added|Created|Updated|Removed|Deleted)|Added|Created|Removed|Deleted)|Why)"
)

what_re = re.compile(
    r"^[ \t]*(?:[-*+]|\d+\.|#{4,6})?[ \t]*\*{0,2}" + what_label + r"[ \t]*\??[ \t]*\*{0,2}[ \t]*:?[ \t]*\*{0,2}",
    re.IGNORECASE | re.MULTILINE,
)
why_re = re.compile(
    r"^[ \t]*(?:[-*+]|\d+\.|#{4,6})?[ \t]*\*{0,2}" + why_label + r"[ \t]*\??[ \t]*\*{0,2}[ \t]*:?[ \t]*\*{0,2}",
    re.IGNORECASE | re.MULTILINE,
)

shallow_files = []
for rf in required_files:
    _, blines = file_to_block[rf]
    masked_block = "\n".join((" " * len(l) if is_f else l) for is_f, l in blines)
    w_matches = list(what_re.finditer(masked_block))
    y_matches = list(why_re.finditer(masked_block))
    if not w_matches or not y_matches:
        shallow_files.append(f"{rf} (missing Ne/What or Neden/Why label)")
        continue

    bounds = sorted(
        set([len(masked_block)] + [m.start() for m in w_matches] + [m.start() for m in y_matches])
    )

    def next_bound(pos: int) -> int:
        for b in bounds:
            if b > pos:
                return b
        return len(masked_block)

    w_body = masked_block[w_matches[0].end():next_bound(w_matches[0].start())]
    y_body = masked_block[y_matches[0].end():next_bound(y_matches[0].start())]
    w_clean = re.sub(r"[`*_>#\-\s]+", " ", w_body).strip()
    y_clean = re.sub(r"[`*_>#\-\s]+", " ", y_body).strip()
    if len(w_clean) < 25 or len(y_clean) < 25:
        shallow_files.append(f"{rf} (stub/one-word prose < 25 chars)")

if shallow_files:
    print(
        "walkthrough \"## Dosya Bazlı Değişiklik Analizi\" has shallow per-file documentation for: "
        + ", ".join(shallow_files)
        + ". Provide concrete multi-sentence \"Ne Değişti / Ne Üretildi\" and \"Neden Değişti / Neden Üretildi\" explanations."
    )
    sys.exit(1)

sys.exit(0)
'
}

# Classify a parent session modelName (slug or display label) into a canonical routing family:
#   unset | orchestrator | carbon | argon_low | argon | hydrogen | claude | flash | custom
harness_classify_parent_model() {
  local raw="${1:-}"
  local trimmed="${raw//[[:space:]]/}"
  if [ -z "$trimmed" ]; then
    printf 'unset\n'
    return 0
  fi

  local norm
  norm="$(printf '%s' "$raw" | LC_ALL=C tr '[:upper:]' '[:lower:]')"

  case "$norm" in
    *orchestrator*|auto)
      printf 'orchestrator\n'
      ;;
    *carbon*)
      printf 'carbon\n'
      ;;
    *argon*)
      if [[ "$norm" == *-low ]] || [[ "$norm" == *"(low)"* ]] || [[ "$norm" == *" low"* ]]; then
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
        carbon|argon|claude)
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
        carbon)
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
        orchestrator|carbon|argon|claude|custom)
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
