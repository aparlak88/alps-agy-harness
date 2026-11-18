#!/usr/bin/env bash
# Alps AGY Harness - Mobile Simulator & Emulator Diagnostic Filter (mobile-logs.sh)
# Usage: mobile-logs.sh --platform ios|android [--bundle-id <id>] [--package <pkg>] [--last <dur>] [--screenshot <out.png>] [--workspace <dir>]
set -euo pipefail

platform=""
bundle_id=""
package=""
last_dur="2m"
screenshot=""
workspace=""

while [ $# -gt 0 ]; do
  case "$1" in
    --platform)
      platform="${2:-}"
      shift 2
      ;;
    --bundle-id)
      bundle_id="${2:-}"
      shift 2
      ;;
    --package)
      package="${2:-}"
      shift 2
      ;;
    --last)
      last_dur="${2:-2m}"
      shift 2
      ;;
    --screenshot)
      screenshot="${2:-}"
      shift 2
      ;;
    --workspace)
      workspace="${2:-}"
      shift 2
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

if [ "$platform" != "ios" ] && [ "$platform" != "android" ]; then
  echo "Error: --platform must be 'ios' or 'android'" >&2
  exit 1
fi

log_dir="$workspace/.harness/logs"
mkdir -p "$log_dir"

xcrun_bin="${HARNESS_XCRUN_BIN:-xcrun}"
adb_bin="${HARNESS_ADB_BIN:-adb}"
diag_dir="${HARNESS_DIAG_REPORTS_DIR:-$HOME/Library/Logs/DiagnosticReports}"

# ==========================================
# iOS Platform
# ==========================================
if [ "$platform" = "ios" ]; then
  raw_temp="$(mktemp "${TMPDIR:-/tmp}/harness-ios-raw.XXXXXX")"
  crash_temp="$(mktemp "${TMPDIR:-/tmp}/harness-ios-crash.XXXXXX")"
  trap 'rm -f "$raw_temp" "$crash_temp" 2>/dev/null || true' EXIT

  # 1. Fetch simctl logs
  if [ -n "$bundle_id" ]; then
    "$xcrun_bin" simctl spawn booted log show --style compact --last "$last_dur" \
      --predicate "subsystem CONTAINS '$bundle_id' OR processImagePath CONTAINS '$bundle_id' OR composedMessage CONTAINS '$bundle_id'" \
      > "$raw_temp" 2>&1 || true
  else
    "$xcrun_bin" simctl spawn booted log show --style compact --last "$last_dur" \
      > "$raw_temp" 2>&1 || true
  fi

  # 2. Inspect DiagnosticReports for newest .ips or .crash via shared harness_core.py
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  python3 -B "$SCRIPT_DIR/lib/harness_core.py" parse-ios-crash \
    --diag-dir "$diag_dir" \
    --bundle-id "$bundle_id" > "$crash_temp" 2>&1 || true

  # 3. Screenshot if requested
  if [ -n "$screenshot" ]; then
    mkdir -p "$(dirname "$screenshot")"
    "$xcrun_bin" simctl io booted screenshot "$screenshot" 2>&1 || true
  fi

  # 4. Save combined dump to mobile-ios-last.log
  ios_log="$log_dir/mobile-ios-last.log"
  {
    if [ -s "$crash_temp" ]; then
      cat "$crash_temp"
      printf '\n=== SYSTEM LOGS ===\n'
    fi
    cat "$raw_temp"
  } > "$ios_log"

  # 5. Filter for stdout: strip Apple daemon chatter unless bundle_id is on line
  python3 -c '
import os, sys, re

crash_file = sys.argv[1]
raw_file = sys.argv[2]
bundle_id = sys.argv[3]

noise_pat = re.compile(r"(runningboardd|SpringBoard|mDNSResponder|CoreAnalytics|symptomsd|analyticsd|distnoted|dasd|powerd)", re.IGNORECASE)

output_lines = []

# Include crash report lines first
if os.path.isfile(crash_file):
    with open(crash_file, "r", errors="replace") as f:
        for line in f:
            output_lines.append(line.rstrip("\n"))

# Filter raw system logs
if os.path.isfile(raw_file):
    with open(raw_file, "r", errors="replace") as f:
        for line in f:
            line_str = line.rstrip("\n")
            if not line_str.strip():
                continue
            if noise_pat.search(line_str):
                if bundle_id and bundle_id in line_str:
                    output_lines.append(line_str)
            else:
                output_lines.append(line_str)

# Cap at 100 lines
for l in output_lines[:100]:
    print(l)
' "$crash_temp" "$raw_temp" "$bundle_id"
  exit 0
fi

# ==========================================
# Android Platform
# ==========================================
if [ "$platform" = "android" ]; then
  raw_temp="$(mktemp "${TMPDIR:-/tmp}/harness-android-raw.XXXXXX")"
  crash_temp="$(mktemp "${TMPDIR:-/tmp}/harness-android-crash.XXXXXX")"
  trap 'rm -f "$raw_temp" "$crash_temp" 2>/dev/null || true' EXIT

  # 1. Resolve PID if package provided
  pid=""
  if [ -n "$package" ]; then
    pid="$("$adb_bin" shell pidof "$package" 2>/dev/null | tr -d '\r\n' | awk '{print $1}' || true)"
  fi

  if [ -n "$pid" ] && [[ "$pid" =~ ^[0-9]+$ ]]; then
    "$adb_bin" logcat -d --pid="$pid" > "$raw_temp" 2>&1 || true
  else
    "$adb_bin" logcat -d > "$raw_temp" 2>&1 || true
  fi

  # Always capture crash buffer
  "$adb_bin" logcat -b crash -d > "$crash_temp" 2>&1 || true

  # 2. Screenshot if requested
  if [ -n "$screenshot" ]; then
    mkdir -p "$(dirname "$screenshot")"
    "$adb_bin" exec-out screencap -p > "$screenshot" 2>/dev/null || true
  fi

  # 3. Save combined dump to mobile-android-last.log
  android_log="$log_dir/mobile-android-last.log"
  {
    if [ -s "$crash_temp" ]; then
      printf '=== CRASH BUFFER (logcat -b crash) ===\n'
      cat "$crash_temp"
      printf '\n=== MAIN LOGCAT ===\n'
    fi
    cat "$raw_temp"
  } > "$android_log"

  # 4. Filter for stdout: strip Android chatter (WindowManager, SurfaceFlinger, WifiService, etc.)
  python3 -c '
import os, sys, re

crash_file = sys.argv[1]
raw_file = sys.argv[2]
package = sys.argv[3]

noise_pat = re.compile(r"(WindowManager|SurfaceFlinger|WifiService|ActivityTaskManager|AudioFlinger|InputDispatcher|system_server)", re.IGNORECASE)
keep_pat = re.compile(r"(FATAL EXCEPTION|ANR|AndroidRuntime|NullPointerException|Crash|Exception|Error|E/|F/)", re.IGNORECASE)

output_lines = []

# Include crash logcat buffer first
if os.path.isfile(crash_file):
    with open(crash_file, "r", errors="replace") as f:
        for line in f:
            line_str = line.rstrip("\n")
            if line_str.strip():
                output_lines.append(line_str)

# Filter raw logcat
if os.path.isfile(raw_file):
    with open(raw_file, "r", errors="replace") as f:
        for line in f:
            line_str = line.rstrip("\n")
            if not line_str.strip():
                continue
            if noise_pat.search(line_str):
                continue
            if package and package in line_str:
                output_lines.append(line_str)
            elif keep_pat.search(line_str):
                output_lines.append(line_str)

# Cap at 100 lines
for l in output_lines[:100]:
    print(l)
' "$crash_temp" "$raw_temp" "$package"
  exit 0
fi
