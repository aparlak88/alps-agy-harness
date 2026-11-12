#!/usr/bin/env bash
# Alps AGY Harness - Master Test Suite Runner
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

failed=0
total=0
passed=0

test_files=()
for f in "$SCRIPT_DIR"/test-*.sh; do
  [ -f "$f" ] || continue
  [ "$(basename "$f")" = "test-helpers.sh" ] && continue
  test_files+=("$f")
done

if [ ${#test_files[@]} -eq 0 ]; then
  echo "No test suites found matching $SCRIPT_DIR/test-*.sh" >&2
  exit 1
fi

# Sort test files alphabetically
IFS=$'\n' sorted_files=($(sort <<<"${test_files[*]}"))
unset IFS

echo "=================================================="
echo " Alps AGY Harness - Test Suite Runner"
echo " Found ${#sorted_files[@]} suite(s)"
echo "=================================================="

for tf in "${sorted_files[@]}"; do
  rel_path="${tf#$REPO_ROOT/}"
  echo ""
  echo ">>> [SUITE] $rel_path"
  ((total++))
  if bash "$tf"; then
    ((passed++))
    echo ">>> [PASS] $rel_path"
  else
    ((failed++))
    echo ">>> [FAIL] $rel_path" >&2
  fi
done

echo ""
echo "=================================================="
echo " Overall Result: $passed passed, $failed failed, $total total"
echo "=================================================="

if [ "$failed" -gt 0 ]; then
  exit 1
fi
exit 0
