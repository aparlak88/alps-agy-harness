#!/usr/bin/env bash
# Alps AGY Harness - Context Rot Shield (run-quiet.sh)
# Usage: run-quiet.sh [--workspace <dir>] <label> -- <command...>
set -euo pipefail

workspace=""
label=""
cmd_args=()

while [ $# -gt 0 ]; do
  case "$1" in
    --workspace)
      workspace="${2:-}"
      shift 2
      ;;
    --)
      shift
      cmd_args=("$@")
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      if [ -z "$label" ]; then
        label="$1"
        shift
      else
        echo "Unexpected argument before '--': $1" >&2
        exit 1
      fi
      ;;
  esac
done

if [ -z "$workspace" ]; then
  workspace="$PWD"
fi

if [ -z "$label" ]; then
  label="command"
fi

if [ ${#cmd_args[@]} -eq 0 ]; then
  echo "Error: No command specified after '--'" >&2
  exit 1
fi

log_dir="$workspace/.harness/logs"
mkdir -p "$log_dir"

# Idempotently exclude .harness/ in git info/exclude if in a git worktree
if git -C "$workspace" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  exclude_rel="$(git -C "$workspace" rev-parse --git-path info/exclude 2>/dev/null || true)"
  if [ -n "$exclude_rel" ]; then
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

# UTC timestamp & sanitized label
utc_ts="$(date -u +"%Y%m%dT%H%M%SZ")"
sanitized_label="$(printf '%s' "$label" | LC_ALL=C sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//')"
[ -n "$sanitized_label" ] || sanitized_label="task"
log_file="$log_dir/${utc_ts}-${sanitized_label}.log"

start_time="$(python3 -c 'import time; print(time.time())' 2>/dev/null || date +%s)"

set +e
"${cmd_args[@]}" > "$log_file" 2>&1
rc=$?
set -e

end_time="$(python3 -c 'import time; print(time.time())' 2>/dev/null || date +%s)"
elapsed="$(python3 -c "print(f'{$end_time - $start_time:.1f}')" 2>/dev/null || echo "0.0")"

# Atomically update last.log
cp -f "$log_file" "$log_dir/.last.log.tmp"
mv -f "$log_dir/.last.log.tmp" "$log_dir/last.log"

if [ "$rc" -eq 0 ]; then
  warning_count="$(grep -Ec 'warning|WARN|CS[0-9]{4}|TS[0-9]{4}' "$log_file" 2>/dev/null || true)"
  printf '✅ PASS [%s] (süre: %ss, warnings: %s — log: .harness/logs/last.log)\n' \
    "$label" "$elapsed" "$warning_count"
  exit 0
else
  printf '❌ FAIL [%s] (exit: %d — log: .harness/logs/last.log)\n' "$label" "$rc"
  
  # Output up to 80 meaningful error/stack-trace lines (total stdout <= 85 lines)
  python3 -c '
import sys, re

log_path = sys.argv[1]
try:
    with open(log_path, "r", errors="replace") as f:
        lines = f.readlines()
except Exception:
    sys.exit(0)

if len(lines) <= 80:
    for line in lines:
        sys.stdout.write(line)
else:
    pat = re.compile(r"(error|exception|fail|fatal|panic|traceback|assert|syntax)", re.IGNORECASE)
    err_indices = [i for i, l in enumerate(lines) if pat.search(l)]
    
    selected = set()
    # Take error lines with 1 line context before/after
    for idx in err_indices[:35]:
        selected.add(idx)
        if idx > 0:
            selected.add(idx - 1)
        if idx + 1 < len(lines):
            selected.add(idx + 1)
            
    # Fill remaining quota up to 80 from the end of the log
    remaining = 80 - len(selected)
    if remaining > 0:
        tail_start = max(0, len(lines) - remaining)
        for i in range(tail_start, len(lines)):
            selected.add(i)
            
    final_indices = sorted(list(selected))
    if len(final_indices) > 80:
        final_indices = final_indices[-80:]
        
    for i in final_indices:
        sys.stdout.write(lines[i])
' "$log_file"

  exit "$rc"
fi
