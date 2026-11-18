#!/usr/bin/env bash
# Alps AGY Harness - Environment & Setup Diagnostics (harness-doctor.sh)
# Usage: harness-doctor.sh [--workspace <dir>] [--json]
set -euo pipefail

workspace=""
json_mode=false

while [ $# -gt 0 ]; do
  case "$1" in
    --workspace)
      workspace="${2:-}"
      shift 2
      ;;
    --json)
      json_mode=true
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$workspace" ]; then
  workspace="$PWD"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
args=(doctor --workspace "$workspace")
if [ "$json_mode" = "true" ]; then
  args+=(--json)
fi

exec python3 -B "$SCRIPT_DIR/lib/harness_core.py" "${args[@]}"
