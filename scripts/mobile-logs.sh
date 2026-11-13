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

  # 2. Inspect DiagnosticReports for newest .ips or .crash
  python3 -c '
import os, sys, glob, json

diag_dir = sys.argv[1]
bundle_id = sys.argv[2] if len(sys.argv) > 2 else ""

if not os.path.isdir(diag_dir):
    sys.exit(0)

files = glob.glob(os.path.join(diag_dir, "*.ips")) + glob.glob(os.path.join(diag_dir, "*.crash"))
if not files:
    sys.exit(0)

files.sort(key=lambda f: os.path.getmtime(f), reverse=True)

target_file = None
for f in files:
    base = os.path.basename(f)
    if bundle_id:
        app_name = bundle_id.split(".")[-1]
        if bundle_id.lower() in base.lower() or app_name.lower() in base.lower():
            target_file = f
            break
        try:
            with open(f, "r", errors="replace") as fp:
                head = fp.read(2048)
                if bundle_id in head or app_name in head:
                    target_file = f
                    break
        except Exception:
            pass
    else:
        target_file = f
        break

if not target_file and files:
    target_file = files[0]

if not target_file:
    sys.exit(0)

try:
    with open(target_file, "r", errors="replace") as fp:
        raw_content = fp.read()
except Exception:
    sys.exit(0)

print(f"=== CRASH REPORT ({os.path.basename(target_file)}) ===")

lines = raw_content.splitlines()
body = None
header = {}

if lines and lines[0].strip().startswith("{"):
    try:
        header = json.loads(lines[0])
    except Exception:
        pass

if len(lines) > 1 and lines[1].strip().startswith("{"):
    try:
        body = json.loads("\n".join(lines[1:]))
    except Exception:
        pass

if body is None:
    try:
        body = json.loads(raw_content)
    except Exception:
        pass

if body and isinstance(body, dict):
    proc = header.get("app_name") or body.get("procName") or body.get("process")
    bid = header.get("bundleID") or body.get("bundleID")
    if proc: print(f"Process: {proc}")
    if bid: print(f"Bundle ID: {bid}")
    
    exc = body.get("exception", {})
    if isinstance(exc, dict):
        exc_type = exc.get("type", "")
        exc_signal = exc.get("signal", "")
        if exc_type or exc_signal:
            print(f"Exception: {exc_type} ({exc_signal})")
            
    term = body.get("termination", {})
    if isinstance(term, dict):
        ns = term.get("namespace", "")
        code = term.get("code", "")
        ind = term.get("indicator", "")
        term_line = f"Termination: {ns} code={code} {ind}".strip()
        print(term_line)

    threads = body.get("threads", [])
    crashed_thread = None
    for t in threads:
        if isinstance(t, dict) and t.get("triggered", False):
            crashed_thread = t
            break
    if not crashed_thread and threads:
        crashed_thread = threads[0]
        
    if crashed_thread:
        t_id = crashed_thread.get("id") or crashed_thread.get("name") or "0"
        print(f"Crashed Thread: {t_id}")
        frames = crashed_thread.get("frames", [])
        for i, fr in enumerate(frames[:25]):
            offset = fr.get("imageOffset", 0)
            sym = fr.get("symbol") or fr.get("binary") or f"0x{offset:x}"
            loc = fr.get("symbolLocation")
            loc_str = f" + {loc}" if loc is not None else ""
            print(f"  #{i:02d} {sym}{loc_str}")
else:
    for line in lines[:80]:
        if any(line.startswith(k) for k in ("Process:", "Identifier:", "Exception", "Termination", "Thread ")) or "Crashed:" in line:
            print(line)
' "$diag_dir" "$bundle_id" > "$crash_temp" 2>&1 || true

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
