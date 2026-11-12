#!/usr/bin/env bash
# Alps AGY Harness - PreToolUse Command Gate (pre-command-guard.sh)
# Enforces:
#   1. Infinite mobile log stream block (adb logcat without -d, simctl log stream without --timeout/--last)
#   2. PR-only main/master guard (blocks direct push and merge to main/master when remote exists; validates local merge)
#   3. Package install gate (requires context7 stamp or ## Global Constraints in Spec for npm, pnpm, yarn, dotnet, uv, cargo)
#   4. 5-point hard PR opening gate (gh pr create)
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
if [ "$tool_name" != "run_command" ]; then
  emit_allow
  exit 0
fi

cmd_line="$(printf '%s' "$HOOK_INPUT" | jq -r '.toolCall.args.CommandLine // empty' 2>/dev/null || true)"
if [ -z "$cmd_line" ]; then
  emit_allow
  exit 0
fi

segments_json="$(harness_parse_command_segments "$cmd_line")"
if [ -z "$segments_json" ] || [ "$segments_json" = "[]" ]; then
  emit_allow
  exit 0
fi

active_branch="$(harness_branch_name "$WORKSPACE_ROOT")"
remotes="$(git -C "$WORKSPACE_ROOT" remote 2>/dev/null || true)"
state_dir="$(harness_state_dir "$WORKSPACE_ROOT")"

# Iterate over each parsed command segment
num_segments="$(jq -r 'length' <<< "$segments_json" 2>/dev/null || echo 0)"

for ((s_idx = 0; s_idx < num_segments; s_idx++)); do
  seg_json="$(jq -c ".[$s_idx]" <<< "$segments_json")"
  exe="$(jq -r '.[0] // empty' <<< "$seg_json")"
  [ -n "$exe" ] || continue
  exe_base="$(basename "$exe")"

  # ---------------------------------------------------------------------------
  # Gate 1: Infinite Mobile Log Stream Block
  # ---------------------------------------------------------------------------
  if [ "$exe_base" = "adb" ]; then
    if jq -e 'index("logcat") != null' <<< "$seg_json" >/dev/null 2>&1; then
      has_d="$(jq -r '[.[] | select(. == "-d" or test("^-[a-zA-Z]*d[a-zA-Z]*$"))] | length' <<< "$seg_json" 2>/dev/null || echo 0)"
      if [ "$has_d" -eq 0 ]; then
        emit_deny "Infinite mobile log stream blocked: 'adb logcat' without '-d' runs indefinitely. Use 'adb logcat -d' for snapshots or use scripts/mobile-logs.sh."
        exit 0
      fi
    fi
  elif [ "$exe_base" = "simctl" ] || { [ "$exe_base" = "xcrun" ] && jq -e 'index("simctl") != null' <<< "$seg_json" >/dev/null 2>&1; }; then
    has_log_stream="$(jq -r '
      (to_entries | map(select(.value == "log")) | .[0].key) as $log_i
      | (to_entries | map(select(.value == "stream")) | .[0].key) as $stream_i
      | if $log_i != null and $stream_i != null and $log_i < $stream_i then "true" else "false" end
    ' <<< "$seg_json" 2>/dev/null || echo "false")"
    if [ "$has_log_stream" = "true" ]; then
      has_bound="$(jq -r '[.[] | select(test("^--(timeout|last)(=.*)?$"))] | length' <<< "$seg_json" 2>/dev/null || echo 0)"
      if [ "$has_bound" -eq 0 ]; then
        emit_deny "Infinite mobile log stream blocked: 'simctl log stream' without '--timeout' or '--last' runs indefinitely. Bound the stream or use scripts/mobile-logs.sh."
        exit 0
      fi
    fi
  fi

  # ---------------------------------------------------------------------------
  # Gate 2: PR-Only main/master Guard
  # ---------------------------------------------------------------------------
  if [ "$exe_base" = "git" ]; then
    git_subcmd="$(jq -r '
      . as $arr
      | if ($arr | length) <= 1 then ""
      else
        reduce range(1; $arr | length) as $i (
          {found: "", skip_next: false};
          if .found != "" then .
          elif .skip_next then .skip_next = false
          elif $arr[$i] == "-C" or $arr[$i] == "-c" or $arr[$i] == "--git-dir" or $arr[$i] == "--work-tree" then .skip_next = true
          elif ($arr[$i] | startswith("-")) then .
          else .found = $arr[$i]
          end
        ) | .found
      end
    ' <<< "$seg_json" 2>/dev/null || true)"

    if [ "$git_subcmd" = "push" ]; then
      targets_main="$(jq -r '
        (to_entries | map(select(.value == "push")) | .[0].key) as $push_idx
        | if $push_idx == null then "ok"
          else
            .[$push_idx + 1:] | map(select(startswith("-") | not)) as $pos
            | if ($pos | length) == 0 then "bare"
              elif ($pos | length) == 1 then "remote_only"
              else
                $pos[1:] | map(
                  (if contains(":") then split(":")[1] else . end)
                  | sub("^refs/heads/"; "")
                ) | if any(. == "main" or . == "master") then "targets_main" else "ok" end
              end
          end
      ' <<< "$seg_json" 2>/dev/null || echo "ok")"

      if [ -n "$remotes" ]; then
        if [ "$targets_main" = "targets_main" ]; then
          emit_deny "Direct push to main/master is blocked. Pull requests are required for main/master."
          exit 0
        elif [ "$targets_main" = "bare" ] || [ "$targets_main" = "remote_only" ]; then
          if [ "$active_branch" = "main" ] || [ "$active_branch" = "master" ]; then
            emit_deny "Direct push to main/master is blocked. Pull requests are required for main/master."
            exit 0
          fi
        fi
      fi

    elif [ "$git_subcmd" = "merge" ]; then
      if [ "$active_branch" = "main" ] || [ "$active_branch" = "master" ]; then
        has_ff="$(jq -r '[.[] | select(. == "--ff-only")] | length' <<< "$seg_json" 2>/dev/null || echo 0)"
        if [ "$has_ff" -eq 0 ]; then
          if [ -n "$remotes" ]; then
            emit_deny "Direct git merge into main/master is blocked when a remote is configured. Pull requests are required."
            exit 0
          else
            # Remote is empty: validate local merge against walkthrough + glossary + stamps
            target_branch="$(jq -r '
              (to_entries | map(select(.value == "merge")) | .[0].key) as $merge_idx
              | if $merge_idx == null then ""
                else .[$merge_idx + 1:] | map(select(startswith("-") | not)) | .[0] // ""
                end
            ' <<< "$seg_json" 2>/dev/null || true)"

            if [ -n "$target_branch" ]; then
              merge_base="$(git -C "$WORKSPACE_ROOT" merge-base HEAD "$target_branch" 2>/dev/null || printf 'HEAD')"
              diff_files="$(git -C "$WORKSPACE_ROOT" diff --name-only --diff-filter=ACMR "$merge_base..$target_branch" 2>/dev/null || true)"
              all_merge_diff="$(git -C "$WORKSPACE_ROOT" diff --name-only "$merge_base..$target_branch" 2>/dev/null || true)"
              walkthrough_found=false
              has_any_wt=false
              wt_err=""
              while IFS= read -r f; do
                [ -n "$f" ] || continue
                if [[ "$f" == docs/walkthroughs/*.md ]]; then
                  has_any_wt=true
                  wt_content="$(git -C "$WORKSPACE_ROOT" show "$target_branch:$f" 2>/dev/null || true)"
                  if wt_err="$(harness_validate_walkthrough "$wt_content" "$all_merge_diff")"; then
                    walkthrough_found=true
                    break
                  fi
                fi
              done <<< "$diff_files"

              if ! $walkthrough_found; then
                if ! $has_any_wt; then
                  emit_deny "Local merge into main requires a walkthrough in docs/walkthroughs/*.md covering every changed file."
                else
                  emit_deny "Local merge into main blocked: $wt_err"
                fi
                exit 0
              fi

              while IFS= read -r f; do
                [ -n "$f" ] || continue
                if [ "$f" = "docs/canon/glossary.md" ] || [ "$f" = "docs/parking-lot.md" ]; then
                  continue
                fi
                if [ "$f" = "README.md" ] || [[ "$f" == docs/*.md ]] || [[ "$f" == docs/**/*.md ]]; then
                  doc_content="$(git -C "$WORKSPACE_ROOT" show "$target_branch:$f" 2>/dev/null || true)"
                  if ! harness_has_glossary_section "$doc_content"; then
                    emit_deny "Local merge documentation file '$f' is missing a valid Technical Glossary section"
                    exit 0
                  fi
                fi
              done <<< "$diff_files"

              target_slug="$(printf '%s' "$target_branch" | LC_ALL=C sed -E 's/[^A-Za-z0-9]+/-/g; s/^-+//; s/-+$//')"
              target_state_dir="$WORKSPACE_ROOT/.harness/state/$target_slug"
              tab=$'\t'
              target_tree_sha="$(git -C "$WORKSPACE_ROOT" ls-tree -r "$target_branch" 2>/dev/null | { grep -Ev "${tab}docs/(walkthroughs/|parking-lot\.md\$)" || true; } | git -C "$WORKSPACE_ROOT" hash-object --stdin)"

              if [ ! -f "$target_state_dir/canon-pass.json" ] || [ ! -f "$target_state_dir/security-pass.json" ]; then
                emit_deny "Local merge requires valid canon-pass.json and security-pass.json under .harness/state/$target_slug"
                exit 0
              fi

              canon_verdict="$(jq -r '.verdict // empty' "$target_state_dir/canon-pass.json" 2>/dev/null || true)"
              canon_sha="$(jq -r '.codeTreeSha // empty' "$target_state_dir/canon-pass.json" 2>/dev/null || true)"
              sec_verdict="$(jq -r '.verdict // empty' "$target_state_dir/security-pass.json" 2>/dev/null || true)"
              sec_sha="$(jq -r '.codeTreeSha // empty' "$target_state_dir/security-pass.json" 2>/dev/null || true)"

              if [ "$canon_verdict" != "PASS" ] || [ "$canon_sha" != "$target_tree_sha" ] || \
                 [ "$sec_verdict" != "PASS" ] || [ "$sec_sha" != "$target_tree_sha" ]; then
                emit_deny "Local merge stamps for '$target_branch' do not match target branch codeTreeSha ($target_tree_sha) or verdict is not PASS"
                exit 0
              fi
            fi
          fi
        fi
      fi
    fi
  fi

  # ---------------------------------------------------------------------------
  # Gate 3: Package Install Gate
  # ---------------------------------------------------------------------------
  pkgs_json="$(python3 -c '
import sys, json

tokens = json.loads(sys.argv[1])
if not tokens:
    print("[]")
    sys.exit(0)

exe = tokens[0].split("/")[-1]
pkgs = []
if exe == "npm":
    if len(tokens) > 1 and tokens[1] in ("install", "i", "add"):
        i = 2
        while i < len(tokens):
            t = tokens[i]
            if t in ("--prefix", "-w", "--workspace", "--registry", "--cache", "--tag"):
                i += 2
            elif t.startswith("-"):
                i += 1
            else:
                pkgs.append(t)
                i += 1
elif exe == "pnpm":
    if len(tokens) > 1 and tokens[1] in ("add", "install", "i"):
        i = 2
        while i < len(tokens):
            t = tokens[i]
            if t in ("--dir", "-C", "-w", "--filter"):
                i += 2
            elif t.startswith("-"):
                i += 1
            else:
                pkgs.append(t)
                i += 1
elif exe == "yarn":
    if len(tokens) > 1 and tokens[1] == "add":
        i = 2
        while i < len(tokens):
            t = tokens[i]
            if t.startswith("-"):
                i += 1
            else:
                pkgs.append(t)
                i += 1
elif exe == "dotnet":
    dotnet_val_flags = ("--version", "-v", "--framework", "-f", "--source", "-s", "--package-directory", "--project", "--file")
    start_idx = None
    if len(tokens) > 2 and tokens[1] == "add" and "package" in tokens[2:]:
        start_idx = tokens.index("package", 2) + 1
    elif len(tokens) > 2 and tokens[1] == "package" and tokens[2] == "add":
        start_idx = 3
    if start_idx is not None:
        i = start_idx
        while i < len(tokens):
            t = tokens[i]
            if t in dotnet_val_flags:
                i += 2
            elif t.startswith("-"):
                i += 1
            else:
                pkgs.append(t)
                break
elif exe in ("uv", "cargo"):
    if len(tokens) > 1 and tokens[1] == "add":
        i = 2
        while i < len(tokens):
            t = tokens[i]
            if t in ("--features", "-F", "-p", "--package", "--target", "--optional", "--python"):
                i += 2
            elif t.startswith("-"):
                i += 1
            else:
                pkgs.append(t)
                i += 1

cleaned = []
for p in pkgs:
    p = p.strip().strip("\x27\x22")
    if not p or p.startswith((".", "/", "~", "http:", "https:", "git:", "git+")):
        continue
    if p.startswith("@"):
        cleaned.append("@" + p[1:].split("@", 1)[0])
    else:
        cleaned.append(p.split("@", 1)[0])

print(json.dumps(cleaned))
' "$seg_json" 2>/dev/null || echo "[]")"

  if [ -n "$pkgs_json" ] && [ "$pkgs_json" != "[]" ]; then
    unverified_pkgs=()
    verified_file="$state_dir/context7-verified.json"

    while IFS= read -r pkg; do
      [ -n "$pkg" ] || continue

      # 1. Check context7-verified.json
      if [ -f "$verified_file" ] && jq -e --arg p "$pkg" '.packages[$p] != null' "$verified_file" >/dev/null 2>&1; then
        continue
      fi

      # 2. Check ## Global Constraints in docs/superpowers/specs/*.md (token-boundary match)
      found_in_spec=false
      for spec in "$WORKSPACE_ROOT"/docs/superpowers/specs/*.md; do
        [ -f "$spec" ] || continue
        if python3 -c '
import sys, re
pkg, path = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8", errors="ignore") as f:
    lines = f.readlines()
in_sec = False
sec_lines = []
for line in lines:
    if re.match(r"^## Global Constraints(?:\s|$)", line):
        in_sec = True
        continue
    if in_sec and line.startswith("## "):
        in_sec = False
    if in_sec:
        sec_lines.append(line)
section = "".join(sec_lines)
pat = r"(?:^|[^A-Za-z0-9_./@-])" + re.escape(pkg) + r"(?:$|@[0-9^~>=<]|[^A-Za-z0-9_./@-])"
sys.exit(0 if re.search(pat, section) else 1)
' "$pkg" "$spec" 2>/dev/null; then
          found_in_spec=true
          break
        fi
      done

      if ! $found_in_spec; then
        unverified_pkgs+=("$pkg")
      fi
    done < <(jq -r '.[]' <<< "$pkgs_json")

    if [ ${#unverified_pkgs[@]} -gt 0 ]; then
      emit_deny "Package install blocked: unverified package(s): ${unverified_pkgs[*]}. Verify versions using dependency-versions / context7 before installing. Run: stamp-gate.sh context7 --package <pkg> --version <ver> --source <locked|greenfield-latest>"
      exit 0
    fi
  fi

  # ---------------------------------------------------------------------------
  # Gate 4: 5-Point Hard PR Gate (gh pr create)
  # ---------------------------------------------------------------------------
  if [ "$exe_base" = "gh" ]; then
    is_pr_create="$(jq -r '
      (to_entries | map(select(.value == "pr")) | .[0].key) as $pr_i
      | (to_entries | map(select(.value == "create")) | .[0].key) as $create_i
      | if $pr_i != null and $create_i != null and $create_i == ($pr_i + 1) then "true" else "false" end
    ' <<< "$seg_json" 2>/dev/null || echo "false")"

    if [ "$is_pr_create" = "true" ]; then
      base=""
      if git -C "$WORKSPACE_ROOT" rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
        base="origin/main"
      elif git -C "$WORKSPACE_ROOT" rev-parse --verify --quiet origin/master >/dev/null 2>&1; then
        base="origin/master"
      elif git -C "$WORKSPACE_ROOT" rev-parse --verify --quiet refs/heads/main >/dev/null 2>&1; then
        base="main"
      elif git -C "$WORKSPACE_ROOT" rev-parse --verify --quiet refs/heads/master >/dev/null 2>&1; then
        base="master"
      fi

      if [ -z "$base" ]; then
        emit_deny "PR creation blocked: cannot resolve base branch (origin/main, origin/master, main, master)"
        exit 0
      fi

      # (a) Active branch is not main/master AND working tree is completely clean
      if [ "$active_branch" = "main" ] || [ "$active_branch" = "master" ]; then
        emit_deny "PR creation blocked: pull requests cannot be opened from main/master branch"
        exit 0
      fi

      status_out="$(git -C "$WORKSPACE_ROOT" status --porcelain 2>/dev/null || true)"
      if [ -n "$status_out" ]; then
        emit_deny "PR creation blocked: working tree is dirty. Commit or stash all changes before creating PR."
        exit 0
      fi

      # (b) Walkthrough in docs/walkthroughs/*.md with >= 2 Mermaid blocks + 100% per-file Ne/Neden coverage
      merge_base="$(git -C "$WORKSPACE_ROOT" merge-base "$base" HEAD 2>/dev/null || printf '%s' "$base")"
      diff_files="$(git -C "$WORKSPACE_ROOT" diff --name-only --diff-filter=ACMR "$merge_base..HEAD" 2>/dev/null || true)"
      all_diff="$(git -C "$WORKSPACE_ROOT" diff --name-only "$merge_base..HEAD" 2>/dev/null || true)"
      walkthrough_found=false
      has_any_wt=false
      wt_err=""

      while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [[ "$f" == docs/walkthroughs/*.md ]]; then
          has_any_wt=true
          if [ -f "$WORKSPACE_ROOT/$f" ]; then
            wt_content="$(cat "$WORKSPACE_ROOT/$f")"
            if wt_err="$(harness_validate_walkthrough "$wt_content" "$all_diff")"; then
              walkthrough_found=true
              break
            fi
          fi
        fi
      done <<< "$diff_files"

      if ! $walkthrough_found; then
        if ! $has_any_wt; then
          emit_deny "PR creation blocked: missing walkthrough. PR diff must include at least one docs/walkthroughs/*.md file."
        else
          emit_deny "PR creation blocked: $wt_err"
        fi
        exit 0
      fi

      # (c) Every technical .md file in diff (except glossary.md and parking-lot.md) has glossary section
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ "$f" = "docs/canon/glossary.md" ] || [ "$f" = "docs/parking-lot.md" ]; then
          continue
        fi
        if [ "$f" = "README.md" ] || [[ "$f" == docs/*.md ]] || [[ "$f" == docs/**/*.md ]]; then
          if [ -f "$WORKSPACE_ROOT/$f" ]; then
            content="$(cat "$WORKSPACE_ROOT/$f")"
            if ! harness_has_glossary_section "$content"; then
              emit_deny "PR creation blocked: documentation file '$f' is missing a valid Technical Glossary / Teknik Terimler Sözlüğü section."
              exit 0
            fi
          fi
        fi
      done <<< "$diff_files"

      # (d) stamp-gate.sh verify-pr-stamps exits 0
      verify_err=""
      if ! verify_err="$("$SCRIPT_DIR/../stamp-gate.sh" verify-pr-stamps --workspace "$WORKSPACE_ROOT" 2>&1)"; then
        emit_deny "PR creation blocked: PR stamps verification failed: $verify_err"
        exit 0
      fi

      # (e) allowedFiles check if non-empty in canon-pass.json
      canon_file="$state_dir/canon-pass.json"
      if [ -f "$canon_file" ]; then
        allowed_len="$(jq -r '(.allowedFiles // []) | length' "$canon_file" 2>/dev/null || echo 0)"
        if [ "$allowed_len" -gt 0 ]; then
          all_diff="$(git -C "$WORKSPACE_ROOT" diff --name-only "$base..HEAD" 2>/dev/null || true)"
          while IFS= read -r f; do
            [ -n "$f" ] || continue
            if [[ "$f" == docs/superpowers/* ]] || [[ "$f" == docs/canon/* ]] || [[ "$f" == docs/walkthroughs/* ]] || [ "$f" = "docs/parking-lot.md" ]; then
              continue
            fi
            if ! jq -e --arg file "$f" '.allowedFiles | index($file) != null' "$canon_file" >/dev/null 2>&1; then
              emit_deny "PR creation blocked: file '$f' is not in allowedFiles list in canon-pass.json and not an allowed documentation path."
              exit 0
            fi
          done <<< "$all_diff"
        fi
      fi
    fi
  fi
done

emit_allow
exit 0
