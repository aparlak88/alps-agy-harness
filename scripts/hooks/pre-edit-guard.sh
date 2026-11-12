#!/usr/bin/env bash
# Alps AGY Harness - PreToolUse Guard for write_file & edit_file (pre-edit-guard.sh)
# Enforces:
#   1. main/master lock (only docs/superpowers/specs/* and docs/canon/* allowed)
#   2. Technical Glossary gate on documentation creation (README.md, docs/**/*.md)
#   3. Dangerous pattern & secret prevention in production code
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

harness_read_stdin

if harness_is_ignored "$WORKSPACE_ROOT"; then
  emit_allow
  exit 0
fi

tool_name="$(printf '%s' "$HOOK_INPUT" | jq -r '.toolCall.name // empty' 2>/dev/null || true)"
file_path="$(printf '%s' "$HOOK_INPUT" | jq -r '.toolCall.args.Path // empty' 2>/dev/null || true)"
append="$(printf '%s' "$HOOK_INPUT" | jq -r '(.toolCall.args.Append // false) | tostring' 2>/dev/null || true)"
content="$(printf '%s' "$HOOK_INPUT" | jq -r '.toolCall.args.Content // empty' 2>/dev/null || true)"
replacement="$(printf '%s' "$HOOK_INPUT" | jq -r '.toolCall.args.Replacement // empty' 2>/dev/null || true)"

# If not a guarded tool call or no path provided, allow immediately
if [ "$tool_name" != "write_file" ] && [ "$tool_name" != "edit_file" ]; then
  emit_allow
  exit 0
fi

if [ -z "$file_path" ]; then
  emit_allow
  exit 0
fi

# Expand leading tilde
target_path="$file_path"
if [[ "$target_path" == "~"* ]]; then
  target_path="${target_path/#\~/$HOME}"
fi

ws_root="${WORKSPACE_ROOT%/}"
real_ws=""
if [ -d "$ws_root" ]; then
  real_ws="$(cd "$ws_root" 2>/dev/null && pwd -P || echo "$ws_root")"
fi

rel_path=""
if [[ "$target_path" == /* ]]; then
  if [ -n "$real_ws" ] && [[ "$target_path" == "$real_ws"/* ]]; then
    rel_path="${target_path#"$real_ws"/}"
  elif [[ "$target_path" == "$ws_root"/* ]]; then
    rel_path="${target_path#"$ws_root"/}"
  elif [ "$target_path" = "$ws_root" ] || [ "$target_path" = "$real_ws" ]; then
    rel_path=""
  else
    # External path (outside WORKSPACE_ROOT e.g. brain artifacts, system tmp)
    emit_allow
    exit 0
  fi
else
  rel_path="$target_path"
fi

# Strip leading ./
rel_path="${rel_path#./}"

# External ledger and harness internal bypass
if [[ "$rel_path" == ".superpowers"* ]] || [[ "$rel_path" == ".harness"* ]]; then
  emit_allow
  exit 0
fi

# Rule 1: main/master lock
# When git repo has at least 1 commit (HEAD exists) and branch is main/master,
# allow ONLY docs/superpowers/specs/* and docs/canon/*; deny all other workspace files.
branch="$(harness_branch_name "$WORKSPACE_ROOT")"
if [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
  if git -C "$WORKSPACE_ROOT" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
    if [[ "$rel_path" == docs/superpowers/specs/* ]] || [[ "$rel_path" == docs/canon/* ]]; then
      : # Allowed on main/master draft, proceed to next rules
    else
      emit_deny "Direct writes to workspace file '$rel_path' are locked on branch '$branch'. Feature development must occur in a feature branch or worktree (only docs/superpowers/specs/* and docs/canon/* may be drafted on main/master)."
      exit 0
    fi
  fi
fi

# Rule 2: Technical Glossary gate on documentation creation
# When toolCall.name == write_file and Append != true,
# if rel_path is README.md or docs/*.md or docs/**/*.md (excluding docs/canon/glossary.md and docs/parking-lot.md),
# require non-empty Technical Glossary / Teknik Terimler Sözlüğü section.
if [ "$tool_name" = "write_file" ] && [ "$append" != "true" ]; then
  is_doc=0
  if [ "$rel_path" = "README.md" ]; then
    is_doc=1
  elif [[ "$rel_path" == docs/* ]] && [[ "$rel_path" == *.md ]]; then
    is_doc=1
  fi

  if [ "$rel_path" = "docs/canon/glossary.md" ] || [ "$rel_path" = "docs/parking-lot.md" ]; then
    is_doc=0
  fi

  if [ "$is_doc" -eq 1 ]; then
    if ! harness_has_glossary_section "$content"; then
      emit_deny "Documentation file '$rel_path' must end with a non-empty '## Teknik Terimler Sözlüğü' or '## Technical Glossary' table or section."
      exit 0
    fi
  fi
fi

# Rule 3: Dangerous patterns in production code
# Skip docs/*, tests/*, and README.md
if [[ "$rel_path" == docs/* ]] || [[ "$rel_path" == tests/* ]] || [ "$rel_path" = "README.md" ]; then
  emit_allow
  exit 0
fi

text_to_check=""
if [ "$tool_name" = "write_file" ]; then
  text_to_check="$content"
elif [ "$tool_name" = "edit_file" ]; then
  text_to_check="$replacement"
fi

# (a) Plain private key
if printf '%s\n' "$text_to_check" | grep -Eq -- '-----BEGIN [A-Z ]*PRIVATE KEY-----'; then
  emit_deny "Plain private key detected in code; secrets must never be committed."
  exit 0
fi

# (b) eval(
if printf '%s\n' "$text_to_check" | grep -Eq '((^|[^a-zA-Z0-9_])|\b)eval[[:space:]]*\('; then
  emit_deny "Dangerous eval() function call detected in production code."
  exit 0
fi

# (c) dangerouslySetInnerHTML
if printf '%s\n' "$text_to_check" | grep -Fq "dangerouslySetInnerHTML"; then
  emit_deny "dangerouslySetInnerHTML detected; potential XSS vulnerability."
  exit 0
fi

# (d) Raw SQL string concatenation
sql_concat_re='(SELECT|INSERT[[:space:]]+INTO|UPDATE|DELETE[[:space:]]+FROM)[[:space:]].*(['\''"][[:space:]]*\+[[:space:]]*[A-Za-z0-9_$(]|\+[[:space:]]*['\''"])'
if printf '%s\n' "$text_to_check" | grep -Eiq "$sql_concat_re"; then
  emit_deny "Raw SQL string concatenation detected; use parameterized queries."
  exit 0
fi

# (e) Angular bypassSecurityTrust pattern -> force_ask
if printf '%s\n' "$text_to_check" | grep -Fq "bypassSecurityTrust"; then
  emit_force_ask "Angular bypassSecurityTrust pattern detected; requires explicit confirmation."
  exit 0
fi

emit_allow
