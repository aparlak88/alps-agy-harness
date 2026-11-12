#!/usr/bin/env bash
# Alps AGY Harness - Shared POSIX Bash Test Helpers
set -euo pipefail

# Dynamic REPO_ROOT resolution (tests/ -> repo root)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
export REPO_ROOT

_cleanup_harness_temp_dirs() {
  if [ -n "${_HARNESS_TEMP_TRACKER:-}" ] && [ -f "$_HARNESS_TEMP_TRACKER" ]; then
    while IFS= read -r d; do
      if [ -n "$d" ] && [ -d "$d" ]; then
        rm -rf "$d" 2>/dev/null || true
      fi
    done < "$_HARNESS_TEMP_TRACKER"
    rm -f "$_HARNESS_TEMP_TRACKER" 2>/dev/null || true
  fi
}

# Tracker file for temporary directories to clean up on exit across subshells (unexported)
if [ "${_HARNESS_TRACKER_PID:-}" != "$$" ]; then
  _HARNESS_TRACKER_PID="$$"
  _HARNESS_TEMP_TRACKER=$(mktemp "${TMPDIR:-/tmp}/harness-temp-tracker.XXXXXX")
  trap _cleanup_harness_temp_dirs EXIT INT TERM
fi

# Assert equality of two strings/values
assert_eq() {
  local expected="$1"
  local actual="$2"
  local msg="${3:-Values should be equal}"
  if [ "$expected" != "$actual" ]; then
    echo "  [FAIL] $msg" >&2
    echo "    Expected: '$expected'" >&2
    echo "    Actual:   '$actual'" >&2
    return 1
  fi
}

# Assert haystack contains needle
assert_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="${3:-Expected string to contain needle}"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "  [FAIL] $msg" >&2
    echo "    Haystack: '$haystack'" >&2
    echo "    Needle:   '$needle'" >&2
    return 1
  fi
}

# Assert haystack does NOT contain needle
assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="${3:-Expected string to not contain needle}"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  [FAIL] $msg" >&2
    echo "    Haystack:   '$haystack'" >&2
    echo "    Not-Needle: '$needle'" >&2
    return 1
  fi
}

# Assert JSON field matches expected value using jq
assert_json_field() {
  local json_input="$1"
  local expr="$2"
  local expected="$3"
  local msg="${4:-JSON field assertion failed for expression: $expr}"
  local actual

  if [ -f "$json_input" ]; then
    actual=$(jq -r "$expr" "$json_input" 2>/dev/null || true)
  else
    actual=$(echo "$json_input" | jq -r "$expr" 2>/dev/null || true)
  fi

  if [ "$expected" != "$actual" ]; then
    echo "  [FAIL] $msg" >&2
    echo "    Expected: '$expected'" >&2
    echo "    Actual:   '$actual'" >&2
    return 1
  fi
}

# Create an isolated temporary git repo with git config preset and auto cleanup
make_temp_repo() {
  local tmp_dir
  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/harness-repo.XXXXXX")
  if [ -n "${_HARNESS_TEMP_TRACKER:-}" ] && [ -f "$_HARNESS_TEMP_TRACKER" ]; then
    echo "$tmp_dir" >> "$_HARNESS_TEMP_TRACKER"
  fi
  (
    cd "$tmp_dir"
    git init --quiet -b main 2>/dev/null || (git init --quiet && git checkout -b main --quiet)
    git config user.name "Harness Test"
    git config user.email "harness@test.local"
  )
  echo "$tmp_dir"
}

# Standard test runner: discovers and executes all test_* functions in caller script
run_tests() {
  local pattern="${1:-test_}"
  local funcs=()
  while IFS= read -r fn; do
    [ -n "$fn" ] && funcs+=("$fn")
  done < <(compgen -A function "$pattern" || true)

  if [ ${#funcs[@]} -eq 0 ]; then
    echo "No tests found matching pattern '$pattern'" >&2
    return 1
  fi

  # Sort function names
  IFS=$'\n' funcs=($(sort <<<"${funcs[*]}"))
  unset IFS

  local caller_name
  caller_name="$(basename "${BASH_SOURCE[1]:-$0}")"

  echo "=== Running ${#funcs[@]} tests in $caller_name ==="

  local passed=0
  local failed=0
  local total=${#funcs[@]}

  for fn in "${funcs[@]}"; do
    printf "  %-55s " "$fn"
    local output
    local status
    set +e
    output=$( (set -euo pipefail; "$fn") 2>&1 )
    status=$?
    set -e

    if [ "$status" -eq 0 ]; then
      echo "PASS"
      ((passed++))
    else
      echo "FAIL"
      ((failed++))
      if [ -n "$output" ]; then
        echo "$output" | sed 's/^/    /' >&2
      fi
    fi
  done

  echo "Summary ($caller_name): $passed passed, $failed failed, $total total"
  if [ "$failed" -gt 0 ]; then
    return 1
  fi
  return 0
}
