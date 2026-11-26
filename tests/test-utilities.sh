#!/usr/bin/env bash
# Alps AGY Harness - Context Shield, Mobile Logs & Doctor Tests (test-utilities.sh)
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"

test_run_quiet_swallows_3000_lines_on_pass_and_counts_warnings() {
  local tmp_repo
  tmp_repo="$(make_temp_repo)"

  # Run quiet on a passing command producing 3000 normal lines and 2 compiler warnings
  local output
  output=$("$REPO_ROOT/scripts/run-quiet.sh" --workspace "$tmp_repo" test-pass -- bash -c '
    for i in $(seq 1 1500); do echo "Building alps core module line $i"; done
    echo "warning CS0168: The variable varName is declared but never used"
    for i in $(seq 1 1500); do echo "Compiling test fixtures line $i"; done
    echo "warning CS0219: The variable is assigned but never used"
  ')
  local rc=$?
  assert_eq "0" "$rc" "run-quiet must return exit 0 on success"

  # Stdout must be EXACTLY 1 line
  local line_count
  line_count=$(printf '%s\n' "$output" | sed '/^$/d' | wc -l | tr -d ' ')
  assert_eq "1" "$line_count" "run-quiet stdout must be exactly 1 line on success"

  # Verify single-line format: ✅ PASS [<label>] (süre: <N>s, warnings: <W> — log: .harness/logs/last.log)
  assert_contains "$output" "✅ PASS [test-pass]"
  assert_contains "$output" "warnings: 2"
  assert_contains "$output" "log: .harness/logs/last.log"

  # Verify last.log contains all 3002 lines
  local log_file="$tmp_repo/.harness/logs/last.log"
  [ -f "$log_file" ] || { echo "last.log was not created in $tmp_repo/.harness/logs" >&2; return 1; }
  local total_log_lines
  total_log_lines=$(wc -l < "$log_file" | tr -d ' ')
  assert_eq "3002" "$total_log_lines" "last.log must preserve all 3002 stdout/stderr lines"

  # Verify timestamped log file also exists
  local ts_logs
  ts_logs=$(find "$tmp_repo/.harness/logs" -maxdepth 1 -name "*-test-pass.log" | wc -l | tr -d ' ')
  assert_eq "1" "$ts_logs" "Timestamped log file matching *-test-pass.log must exist"
}

test_run_quiet_preserves_nonzero_exit_code_and_caps_failure_output() {
  local tmp_repo
  tmp_repo="$(make_temp_repo)"

  set +e
  local output
  output=$("$REPO_ROOT/scripts/run-quiet.sh" --workspace "$tmp_repo" test-fail -- bash -c '
    for i in $(seq 1 300); do
      echo "System.InvalidOperationException: Failure at step $i in AlpsPipeline"
    done
    exit 7
  ')
  local rc=$?
  set -e

  assert_eq "7" "$rc" "run-quiet must preserve exact non-zero exit code (7)"

  # Stdout line count must be strictly <= 85 lines
  local line_count
  line_count=$(printf '%s\n' "$output" | wc -l | tr -d ' ')
  if [ "$line_count" -gt 85 ]; then
    echo "Failure output too verbose: expected <= 85 lines, got $line_count" >&2
    return 1
  fi

  # Header must contain FAIL, label, exit code, and log path
  assert_contains "$output" "❌ FAIL [test-fail]"
  assert_contains "$output" "exit: 7"
  assert_contains "$output" "log: .harness/logs/last.log"

  # Verify last.log contains all 300 lines
  local log_file="$tmp_repo/.harness/logs/last.log"
  [ -f "$log_file" ] || { echo "last.log missing on failure" >&2; return 1; }
  local total_log_lines
  total_log_lines=$(wc -l < "$log_file" | tr -d ' ')
  assert_eq "300" "$total_log_lines" "last.log must preserve all 300 error lines"
}

test_run_quiet_workspace_flag_positions() {
  local tmp_repo
  tmp_repo="$(make_temp_repo)"

  # Test --workspace passed after label before --
  local output
  output=$("$REPO_ROOT/scripts/run-quiet.sh" post-flag --workspace "$tmp_repo" -- echo "ok post flag")
  local rc=$?
  assert_eq "0" "$rc"
  assert_contains "$output" "✅ PASS [post-flag]"
  [ -f "$tmp_repo/.harness/logs/last.log" ] || { echo "last.log missing" >&2; return 1; }
}

test_run_quiet_nested_summary_and_hyphenated_codes_zero_warnings() {
  local tmp_repo
  tmp_repo="$(make_temp_repo)"

  # 1. Outer run-quiet wrapping inner run-quiet plus hyphenated codes and warning-like identifiers -> warnings: 0
  local output_zero
  output_zero=$("$REPO_ROOT/scripts/run-quiet.sh" --workspace "$tmp_repo" outer-nested -- bash -c "
    \"$REPO_ROOT/scripts/run-quiet.sh\" --workspace \"$tmp_repo\" inner-step -- echo 'inner build ok'
    echo '❌ FAIL [simulated-summary] (exit: 1 — log: .harness/logs/last.log)'
    echo 'Ticket TS-1050 and CS-2040 processed'
    echo 'warnings_disabled=true MY_WARNING_VAR=1'
  ")
  local rc_zero=$?
  assert_eq "0" "$rc_zero" "Nested run-quiet must exit 0"
  assert_contains "$output_zero" "✅ PASS [outer-nested]"
  assert_contains "$output_zero" "warnings: 0" "Nested summary lines and hyphenated codes must yield warnings: 0"

  # 2. Outer run-quiet wrapping inner run-quiet plus 2 genuine compiler/runtime warnings -> warnings: 2
  local output_two
  output_two=$("$REPO_ROOT/scripts/run-quiet.sh" --workspace "$tmp_repo" outer-real-warns -- bash -c "
    \"$REPO_ROOT/scripts/run-quiet.sh\" --workspace \"$tmp_repo\" inner-step -- echo 'inner build ok'
    echo 'src/Service.cs(10,3): warning CS0168: Variable unused'
    echo 'WARN: slow query detected'
  ")
  local rc_two=$?
  assert_eq "0" "$rc_two" "Nested run-quiet with real warnings must exit 0"
  assert_contains "$output_two" "✅ PASS [outer-real-warns]"
  assert_contains "$output_two" "warnings: 2" "Real warnings alongside nested summary must count exactly 2"
}

test_mobile_logs_ios_and_android_mocked_binaries() {
  local tmp_repo
  tmp_repo="$(make_temp_repo)"

  local mock_bin_dir="$tmp_repo/mock-bin"
  local mock_diag_dir="$tmp_repo/mock-diag"
  mkdir -p "$mock_bin_dir" "$mock_diag_dir"

  # 1. Mock xcrun
  cat <<'EOF' > "$mock_bin_dir/xcrun"
#!/usr/bin/env bash
if [ "$1" = "simctl" ] && [ "$2" = "spawn" ] && [ "$3" = "booted" ] && [ "$4" = "log" ]; then
  # Emit noisy system logs and app logs
  echo "2026-11-12 12:00:01 runningboardd: [com.apple.runningboard] monitor check"
  echo "2026-11-12 12:00:02 SpringBoard: [com.apple.springboard] scene layout active"
  echo "2026-11-12 12:00:03 mDNSResponder: [com.apple.mdns] cache response"
  echo "2026-11-12 12:00:04 CoreAnalytics: [com.apple.analytics] event batch queued"
  echo "2026-11-12 12:00:05 symptomsd: [com.apple.symptoms] network condition good"
  echo "2026-11-12 12:00:06 MyApp[9876]: [com.alps.app] Database initialized"
  echo "2026-11-12 12:00:07 MyApp[9876]: [com.alps.app] Critical: Network timeout during auth"
  exit 0
elif [ "$1" = "simctl" ] && [ "$2" = "io" ] && [ "$3" = "booted" ] && [ "$4" = "screenshot" ]; then
  printf "FAKE_SCREENSHOT_DATA" > "$5"
  exit 0
fi
echo "Unexpected xcrun invocation: $*" >&2
exit 1
EOF
  chmod +x "$mock_bin_dir/xcrun"

  # 2. Mock Apple .ips crash file in mock_diag_dir
  cat <<'EOF' > "$mock_diag_dir/MyApp-2026-11-12-120000.ips"
{"app_name":"MyApp","timestamp":"2026-11-12 12:00:07 +0300","bundleID":"com.alps.app","slice_uuid":"1234-5678"}
{
  "exception": {"type": "EXC_CRASH", "signal": "SIGABRT"},
  "termination": {"namespace": "SIGNAL", "code": 6, "indicator": "Abort trap: 6"},
  "threads": [
    {
      "id": 1,
      "triggered": true,
      "name": "Crashing Thread",
      "frames": [
        {"imageIndex": 0, "symbol": "fatalError(_:file:line:)", "symbolLocation": 48},
        {"imageIndex": 0, "symbol": "AuthService.login()", "symbolLocation": 210}
      ]
    }
  ]
}
EOF

  # Execute iOS mobile logs
  local ios_out
  ios_out=$(HARNESS_XCRUN_BIN="$mock_bin_dir/xcrun" \
            HARNESS_DIAG_REPORTS_DIR="$mock_diag_dir" \
            "$REPO_ROOT/scripts/mobile-logs.sh" \
              --platform ios \
              --bundle-id "com.alps.app" \
              --screenshot "$tmp_repo/ios-screen.png" \
              --workspace "$tmp_repo")

  # Assert system daemon noise filtered out
  assert_not_contains "$ios_out" "runningboardd" "iOS daemon noise runningboardd must be filtered"
  assert_not_contains "$ios_out" "SpringBoard" "iOS daemon noise SpringBoard must be filtered"
  assert_not_contains "$ios_out" "mDNSResponder" "iOS daemon noise mDNSResponder must be filtered"

  # Assert app logs and crash info preserved
  assert_contains "$ios_out" "Critical: Network timeout during auth"
  assert_contains "$ios_out" "SIGABRT"
  assert_contains "$ios_out" "AuthService.login"

  # Assert stdout <= 100 lines
  local ios_line_count
  ios_line_count=$(printf '%s\n' "$ios_out" | wc -l | tr -d ' ')
  if [ "$ios_line_count" -gt 100 ]; then
    echo "iOS stdout exceeds 100 lines: $ios_line_count" >&2
    return 1
  fi

  # Assert log file and screenshot created
  [ -s "$tmp_repo/.harness/logs/mobile-ios-last.log" ] || { echo "mobile-ios-last.log missing" >&2; return 1; }
  [ -s "$tmp_repo/ios-screen.png" ] || { echo "ios-screen.png missing" >&2; return 1; }

  # 3. Mock adb
  cat <<'EOF' > "$mock_bin_dir/adb"
#!/usr/bin/env bash
if [ "$1" = "shell" ] && [ "$2" = "pidof" ]; then
  # Return PID with \r\n
  printf "3456\r\n"
  exit 0
elif [ "$1" = "logcat" ] && [ "$2" = "-d" ]; then
  # 500 lines of logcat noise + fatal crash
  for i in $(seq 1 200); do
    echo "D/WindowManager: animateWindowToken line $i"
    echo "V/SurfaceFlinger: swapBuffers display $i"
  done
  echo "E/com.alps.app: AlpsWorker encountered network exception"
  for i in $(seq 1 100); do
    echo "D/WifiService: scan results updated $i"
  done
  exit 0
elif [ "$1" = "logcat" ] && [ "$2" = "-b" ] && [ "$3" = "crash" ] && [ "$4" = "-d" ]; then
  echo "FATAL EXCEPTION: main"
  echo "Process: com.alps.app, PID: 3456"
  echo "java.lang.NullPointerException: Attempt to invoke virtual method on null object"
  echo "    at com.alps.app.AuthManager.authenticate(AuthManager.kt:42)"
  exit 0
elif [ "$1" = "exec-out" ] && [ "$2" = "screencap" ] && [ "$3" = "-p" ]; then
  printf "FAKE_ANDROID_PNG_DATA"
  exit 0
fi
echo "Unexpected adb invocation: $*" >&2
exit 1
EOF
  chmod +x "$mock_bin_dir/adb"

  # Execute Android mobile logs
  local android_out
  android_out=$(HARNESS_ADB_BIN="$mock_bin_dir/adb" \
                "$REPO_ROOT/scripts/mobile-logs.sh" \
                  --platform android \
                  --package "com.alps.app" \
                  --screenshot "$tmp_repo/android-screen.png" \
                  --workspace "$tmp_repo")

  # Assert system daemon noise filtered out
  assert_not_contains "$android_out" "SurfaceFlinger" "Android system chatter SurfaceFlinger must be filtered"
  assert_not_contains "$android_out" "WifiService" "Android system chatter WifiService must be filtered"

  # Assert crash trace preserved
  assert_contains "$android_out" "FATAL EXCEPTION: main"
  assert_contains "$android_out" "NullPointerException"
  assert_contains "$android_out" "AuthManager.authenticate"

  # Assert stdout <= 100 lines
  local android_line_count
  android_line_count=$(printf '%s\n' "$android_out" | wc -l | tr -d ' ')
  if [ "$android_line_count" -gt 100 ]; then
    echo "Android stdout exceeds 100 lines: $android_line_count" >&2
    return 1
  fi

  # Assert log file and screenshot created
  [ -s "$tmp_repo/.harness/logs/mobile-android-last.log" ] || { echo "mobile-android-last.log missing" >&2; return 1; }
  [ -s "$tmp_repo/android-screen.png" ] || { echo "android-screen.png missing" >&2; return 1; }
}

test_harness_doctor_json_and_zero_secret_leakage() {
  local tmp_repo
  tmp_repo="$(make_temp_repo)"

  local mock_config_dir="$tmp_repo/gemini-config"
  local mock_bin_dir="$tmp_repo/doctor-bin"
  mkdir -p "$mock_config_dir/plugins/superpowers" "$mock_bin_dir"

  # Setup mock plugins
  cat <<'EOF' > "$mock_config_dir/plugins.json"
{
  "plugins": [
    {"name": "superpowers"},
    {"name": "firebase"},
    {"name": "postman"},
    {"name": "chrome-devtools-plugin"}
  ]
}
EOF

  # Setup mock 8 mandatory MCP servers in mcp_config.json
  cat <<'EOF' > "$mock_config_dir/mcp_config.json"
{
  "mcpServers": {
    "jev": {"command": "jev-mcp-keychain"},
    "context7": {"command": "npx", "args": ["-y", "@upstash/context7-mcp"]},
    "csharp-lsp": {"command": "csharp-lsp-mcp"},
    "typescript-lsp": {"command": "typescript-language-server", "args": ["--stdio"]},
    "playwright": {"command": "npx", "args": ["-y", "@playwright/mcp"]},
    "graphify": {"command": "graphify"},
    "revenuecat": {"command": "npx", "args": ["-y", "@revenuecat/mcp"]},
    "filesystem": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem"]}
  }
}
EOF

  # Setup mock gh binary that reports authenticated
  cat <<'EOF' > "$mock_bin_dir/gh"
#!/usr/bin/env bash
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  echo "Logged in to github.com account alps-user"
  exit 0
fi
exit 0
EOF
  chmod +x "$mock_bin_dir/gh"

  local secret_key="ts_live_secret_98765"

  # Run doctor in text mode with secret key
  local text_out
  text_out=$(TYPESAFE_API_KEY="$secret_key" \
             HARNESS_CONFIG_DIR="$mock_config_dir" \
             HARNESS_GH_BIN="$mock_bin_dir/gh" \
             "$REPO_ROOT/scripts/harness-doctor.sh" --workspace "$tmp_repo")
  local rc_text=$?
  assert_eq "0" "$rc_text" "Doctor should exit 0 on fully healthy environment"

  # ZERO-SECRET-LEAKAGE: Check secret is NEVER printed in text output
  assert_not_contains "$text_out" "$secret_key" "TYPESAFE_API_KEY secret string must never be printed"
  assert_not_contains "$text_out" "ts_live" "Prefix of secret must not be leaked"
  assert_not_contains "$text_out" "98765" "Suffix of secret must not be leaked"
  assert_contains "$text_out" "present" "TYPESAFE_API_KEY status must be reported as present"

  # Run doctor in --json mode
  local json_out
  json_out=$(TYPESAFE_API_KEY="$secret_key" \
             HARNESS_CONFIG_DIR="$mock_config_dir" \
             HARNESS_GH_BIN="$mock_bin_dir/gh" \
             "$REPO_ROOT/scripts/harness-doctor.sh" --workspace "$tmp_repo" --json)
  local rc_json=$?
  assert_eq "0" "$rc_json" "Doctor --json should exit 0 on healthy environment"

  # ZERO-SECRET-LEAKAGE: Check secret is NEVER printed in JSON output
  assert_not_contains "$json_out" "$secret_key" "TYPESAFE_API_KEY secret string must never be in JSON output"
  assert_not_contains "$json_out" "ts_live" "Prefix must not be leaked in JSON"

  # Validate JSON structure
  assert_json_field "$json_out" ".healthy" "true"
  assert_json_field "$json_out" '.checks[] | select(.name=="typesafe_api_key") | .key_status' "present"
  assert_json_field "$json_out" '.checks[] | select(.name=="jev") | .status' "OK"

  # Test failure when mandatory MCP is missing
  local broken_config_dir="$tmp_repo/broken-config"
  mkdir -p "$broken_config_dir/plugins/superpowers"
  cp "$mock_config_dir/plugins.json" "$broken_config_dir/plugins.json"
  # Omit playwright from mcpServers
  cat <<'EOF' > "$broken_config_dir/mcp_config.json"
{
  "mcpServers": {
    "jev": {"command": "jev-mcp-keychain"},
    "context7": {"command": "npx"},
    "csharp-lsp": {"command": "csharp-lsp"},
    "typescript-lsp": {"command": "ts"},
    "graphify": {"command": "graphify"},
    "revenuecat": {"command": "rc"},
    "filesystem": {"command": "fs"}
  }
}
EOF

  set +e
  local fail_out
  fail_out=$(TYPESAFE_API_KEY="$secret_key" \
             HARNESS_CONFIG_DIR="$broken_config_dir" \
             HARNESS_GH_BIN="$mock_bin_dir/gh" \
             "$REPO_ROOT/scripts/harness-doctor.sh" --workspace "$tmp_repo")
  local rc_fail=$?
  set -e

  assert_eq "1" "$rc_fail" "Doctor must exit 1 when a mandatory MCP server is missing"
  assert_contains "$fail_out" "FAIL" "Doctor output must contain FAIL status"
  assert_contains "$fail_out" "playwright" "Missing MCP name must be identified"
  assert_contains "$fail_out" "Fix:" "Remediation command Fix: must be provided"

  # Test failure when TYPESAFE_API_KEY is missing (unset in env, non-existent key file, jev MCP has no keychain/wrapper)
  local missing_key_config_dir="$tmp_repo/missing-key-config"
  mkdir -p "$missing_key_config_dir/plugins/superpowers"
  cp "$mock_config_dir/plugins.json" "$missing_key_config_dir/plugins.json"
  cat <<'EOF' > "$missing_key_config_dir/mcp_config.json"
{
  "mcpServers": {
    "jev": {"command": "npx", "args": ["-y", "jev-mcp"]},
    "context7": {"command": "npx"},
    "csharp-lsp": {"command": "csharp-lsp"},
    "typescript-lsp": {"command": "ts"},
    "playwright": {"command": "pw"},
    "graphify": {"command": "graphify"},
    "revenuecat": {"command": "rc"},
    "filesystem": {"command": "fs"}
  }
}
EOF

  set +e
  local missing_key_json
  missing_key_json=$(env -u TYPESAFE_API_KEY \
                     HARNESS_CONFIG_DIR="$missing_key_config_dir" \
                     HARNESS_TYPESAFE_KEY_FILE="$tmp_repo/nonexistent-key" \
                     HARNESS_GH_BIN="$mock_bin_dir/gh" \
                     "$REPO_ROOT/scripts/harness-doctor.sh" --workspace "$tmp_repo" --json)
  local rc_missing_json=$?
  set -e

  assert_eq "1" "$rc_missing_json" "Doctor --json must exit 1 when TYPESAFE_API_KEY is missing"
  assert_json_field "$missing_key_json" ".healthy" "false"
  assert_json_field "$missing_key_json" '.checks[] | select(.name=="typesafe_api_key") | .status' "FAIL"
  assert_json_field "$missing_key_json" '.checks[] | select(.name=="typesafe_api_key") | .key_status' "missing"

  # Test missing key in text mode and verify Fix: prefix on remediation
  set +e
  local missing_key_text
  missing_key_text=$(env -u TYPESAFE_API_KEY \
                     HARNESS_CONFIG_DIR="$missing_key_config_dir" \
                     HARNESS_TYPESAFE_KEY_FILE="$tmp_repo/nonexistent-key" \
                     HARNESS_GH_BIN="$mock_bin_dir/gh" \
                     "$REPO_ROOT/scripts/harness-doctor.sh" --workspace "$tmp_repo")
  local rc_missing_text=$?
  set -e

  assert_eq "1" "$rc_missing_text" "Doctor text mode must exit 1 when TYPESAFE_API_KEY is missing"
  assert_contains "$missing_key_text" "[FAIL] typesafe_api_key: TYPESAFE_API_KEY is missing"
  assert_contains "$missing_key_text" "Fix: export TYPESAFE_API_KEY="

  # Test that whitespace-only key file is also rejected as missing
  local whitespace_key_file="$tmp_repo/whitespace-key"
  printf "   \n\t  \n" > "$whitespace_key_file"

  set +e
  local whitespace_out
  whitespace_out=$(env -u TYPESAFE_API_KEY \
                   HARNESS_CONFIG_DIR="$missing_key_config_dir" \
                   HARNESS_TYPESAFE_KEY_FILE="$whitespace_key_file" \
                   HARNESS_GH_BIN="$mock_bin_dir/gh" \
                   "$REPO_ROOT/scripts/harness-doctor.sh" --workspace "$tmp_repo" --json)
  local rc_whitespace=$?
  set -e

  assert_eq "1" "$rc_whitespace" "Whitespace-only key file must result in exit 1"
  assert_json_field "$whitespace_out" '.checks[] | select(.name=="typesafe_api_key") | .status' "FAIL"
  assert_json_field "$whitespace_out" '.checks[] | select(.name=="typesafe_api_key") | .key_status' "missing"

  # Test Group 1 remediation strings consistently start with 'Fix: '
  set +e
  local missing_gh_out
  missing_gh_out=$(TYPESAFE_API_KEY="$secret_key" \
                   HARNESS_CONFIG_DIR="$mock_config_dir" \
                   HARNESS_GH_BIN="/nonexistent/gh" \
                   "$REPO_ROOT/scripts/harness-doctor.sh" --workspace "$tmp_repo")
  set -e
  assert_contains "$missing_gh_out" "Fix: brew install gh" "Group 1 CLI remediation must start with Fix:"
}

test_harness_doctor_mobile_workspace_detection() {
  local tmp_repo
  tmp_repo="$(make_temp_repo)"

  local mock_config_dir="$tmp_repo/gemini-config"
  mkdir -p "$mock_config_dir/plugins/superpowers"
  cat <<'EOF' > "$mock_config_dir/plugins.json"
{
  "plugins": [{"name": "superpowers"}, {"name": "firebase"}, {"name": "postman"}, {"name": "chrome-devtools-plugin"}]
}
EOF
  cat <<'EOF' > "$mock_config_dir/mcp_config.json"
{
  "mcpServers": {
    "jev": {}, "context7": {}, "csharp-lsp": {}, "typescript-lsp": {},
    "playwright": {}, "graphify": {}, "revenuecat": {}, "filesystem": {}
  }
}
EOF

  local mock_bin_dir="$tmp_repo/doctor-bin"
  mkdir -p "$mock_bin_dir"
  cat <<'EOF' > "$mock_bin_dir/gh"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$mock_bin_dir/gh"

  # Create an iOS project file in workspace: xcrun missing must become FAIL
  mkdir -p "$tmp_repo/ios-app/App.xcodeproj"

  set +e
  local ios_fail_out
  ios_fail_out=$(TYPESAFE_API_KEY="test_key" \
                 HARNESS_CONFIG_DIR="$mock_config_dir" \
                 HARNESS_GH_BIN="$mock_bin_dir/gh" \
                 HARNESS_XCRUN_BIN="/nonexistent/xcrun" \
                 "$REPO_ROOT/scripts/harness-doctor.sh" --workspace "$tmp_repo")
  local rc_ios=$?
  set -e

  assert_eq "1" "$rc_ios" "Missing xcrun in iOS workspace must fail doctor"
  assert_contains "$ios_fail_out" "xcrun"
  assert_contains "$ios_fail_out" "Fix:"
}

test_harness_doctor_validates_subagent_frontmatter_and_forbids_call_mcp_tool() {
  local tmp_repo
  tmp_repo="$(make_temp_repo)"

  local mock_config_dir="$tmp_repo/gemini-config"
  local mock_bin_dir="$tmp_repo/doctor-bin"
  mkdir -p "$mock_config_dir/plugins/superpowers" "$mock_bin_dir"
  cat <<'EOF' > "$mock_config_dir/plugins.json"
{
  "plugins": [{"name": "superpowers"}, {"name": "firebase"}, {"name": "postman"}, {"name": "chrome-devtools-plugin"}]
}
EOF
  cat <<'EOF' > "$mock_config_dir/mcp_config.json"
{
  "mcpServers": {
    "jev": {}, "context7": {}, "csharp-lsp": {}, "typescript-lsp": {},
    "playwright": {}, "graphify": {}, "revenuecat": {}, "filesystem": {}
  }
}
EOF
  cat <<'EOF' > "$mock_bin_dir/gh"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$mock_bin_dir/gh"

  # 1. Healthy baseline workspace includes subagent_frontmatter = OK
  local ok_json
  ok_json=$(TYPESAFE_API_KEY="test_key" \
            HARNESS_CONFIG_DIR="$mock_config_dir" \
            HARNESS_GH_BIN="$mock_bin_dir/gh" \
            "$REPO_ROOT/scripts/harness-doctor.sh" --workspace "$tmp_repo" --json)
  assert_json_field "$ok_json" ".healthy" "true"
  assert_json_field "$ok_json" '.checks[] | select(.name=="subagent_frontmatter") | .status' "OK"

  # 2. Invalid call_mcp_tool in workspace plugin agent frontmatter -> FAIL naming call_mcp_tool
  local bad_ws="$tmp_repo/bad-ws-call-mcp"
  mkdir -p "$bad_ws/.agents/plugins/alps-agy-harness/agents"
  cat <<'EOF' > "$bad_ws/.agents/plugins/alps-agy-harness/agents/canon-auditor.md"
---
name: canon-auditor
description: "Bad agent"
subagent: true
mainAgent: false
inheritMcp: true
tools: [read_file, run_command, call_mcp_tool, send_message]
---
# Bad Agent
EOF

  set +e
  local bad_call_mcp_json
  bad_call_mcp_json=$(TYPESAFE_API_KEY="test_key" \
                      HARNESS_CONFIG_DIR="$mock_config_dir" \
                      HARNESS_GH_BIN="$mock_bin_dir/gh" \
                      "$REPO_ROOT/scripts/harness-doctor.sh" --workspace "$bad_ws" --json)
  local rc_bad1=$?
  set -e
  assert_eq "1" "$rc_bad1" "Doctor must fail when agent frontmatter lists call_mcp_tool"
  assert_json_field "$bad_call_mcp_json" ".healthy" "false"
  assert_json_field "$bad_call_mcp_json" '.checks[] | select(.name=="subagent_frontmatter") | .status' "FAIL"
  local msg_bad1
  msg_bad1=$(printf '%s\n' "$bad_call_mcp_json" | jq -r '.checks[] | select(.name=="subagent_frontmatter") | .message')
  assert_contains "$msg_bad1" "call_mcp_tool" "subagent_frontmatter failure must mention call_mcp_tool"

  # 3. Missing inheritMcp: true on canon-auditor.md -> FAIL naming inheritMcp
  cat <<'EOF' > "$bad_ws/.agents/plugins/alps-agy-harness/agents/canon-auditor.md"
---
name: canon-auditor
description: "Missing inheritMcp"
subagent: true
mainAgent: false
tools: [read_file, run_command, manage_task, send_message]
---
# Missing inheritMcp
EOF

  set +e
  local bad_inherit_json
  bad_inherit_json=$(TYPESAFE_API_KEY="test_key" \
                     HARNESS_CONFIG_DIR="$mock_config_dir" \
                     HARNESS_GH_BIN="$mock_bin_dir/gh" \
                     "$REPO_ROOT/scripts/harness-doctor.sh" --workspace "$bad_ws" --json)
  local rc_bad2=$?
  set -e
  assert_eq "1" "$rc_bad2" "Doctor must fail when auditor frontmatter omits inheritMcp: true"
  assert_json_field "$bad_inherit_json" ".healthy" "false"
  assert_json_field "$bad_inherit_json" '.checks[] | select(.name=="subagent_frontmatter") | .status' "FAIL"
  local msg_bad2
  msg_bad2=$(printf '%s\n' "$bad_inherit_json" | jq -r '.checks[] | select(.name=="subagent_frontmatter") | .message')
  assert_contains "$msg_bad2" "inheritMcp" "subagent_frontmatter failure must mention inheritMcp"
}

test_harness_doctor_project_install_emits_swarm_advisory_info() {
  local tmp_repo
  tmp_repo="$(make_temp_repo)"

  local mock_config_dir="$tmp_repo/gemini-config"
  local mock_bin_dir="$tmp_repo/doctor-bin"
  mkdir -p "$mock_config_dir/plugins/superpowers" "$mock_bin_dir"
  cat <<'EOF' > "$mock_config_dir/plugins.json"
{
  "plugins": [{"name": "superpowers"}, {"name": "firebase"}, {"name": "postman"}, {"name": "chrome-devtools-plugin"}]
}
EOF
  cat <<'EOF' > "$mock_config_dir/mcp_config.json"
{
  "mcpServers": {
    "jev": {}, "context7": {}, "csharp-lsp": {}, "typescript-lsp": {},
    "playwright": {}, "graphify": {}, "revenuecat": {}, "filesystem": {}
  }
}
EOF
  cat <<'EOF' > "$mock_bin_dir/gh"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$mock_bin_dir/gh"

  # 1. Global/standalone workspace without .agents/plugins or .agents/plugins.json must NOT emit swarm_install_advisory
  local standalone_json
  standalone_json=$(TYPESAFE_API_KEY="test_key" \
                    HARNESS_CONFIG_DIR="$mock_config_dir" \
                    HARNESS_GH_BIN="$mock_bin_dir/gh" \
                    "$REPO_ROOT/scripts/harness-doctor.sh" --workspace "$tmp_repo" --json)
  assert_json_field "$standalone_json" ".healthy" "true"
  local advisory_absent
  advisory_absent=$(printf '%s\n' "$standalone_json" | jq -r '.checks[] | select(.name=="swarm_install_advisory") | .name')
  assert_eq "" "$advisory_absent" "swarm_install_advisory must not be emitted without project-level plugin install"

  # 2. Workspace with .agents/plugins directory emits INFO swarm_install_advisory while staying healthy=true
  local proj_ws
  proj_ws="$(make_temp_repo)"
  mkdir -p "$proj_ws/.agents/plugins/alps-agy-harness"

  local proj_json rc_proj=0
  proj_json=$(TYPESAFE_API_KEY="test_key" \
              HARNESS_CONFIG_DIR="$mock_config_dir" \
              HARNESS_GH_BIN="$mock_bin_dir/gh" \
              "$REPO_ROOT/scripts/harness-doctor.sh" --workspace "$proj_ws" --json) || rc_proj=$?
  assert_eq "0" "$rc_proj" "Doctor must exit 0 when swarm_install_advisory INFO is emitted"
  assert_json_field "$proj_json" ".healthy" "true"
  assert_json_field "$proj_json" '.checks[] | select(.name=="install_mode") | .status' "OK"
  assert_json_field "$proj_json" '.checks[] | select(.name=="swarm_install_advisory") | .status' "INFO"
  local advisory_msg
  advisory_msg=$(printf '%s\n' "$proj_json" | jq -r '.checks[] | select(.name=="swarm_install_advisory") | "\(.message) \(.fix // "")"')
  assert_contains "$advisory_msg" "Swarm" "swarm_install_advisory must mention Swarm"
  assert_contains "$advisory_msg" "--recurse-submodules" "swarm_install_advisory must mention --recurse-submodules"
  assert_contains "$advisory_msg" "~/.gemini/config/plugins" "swarm_install_advisory must recommend global install path"

  local proj_text
  proj_text=$(TYPESAFE_API_KEY="test_key" \
              HARNESS_CONFIG_DIR="$mock_config_dir" \
              HARNESS_GH_BIN="$mock_bin_dir/gh" \
              "$REPO_ROOT/scripts/harness-doctor.sh" --workspace "$proj_ws")
  assert_contains "$proj_text" "[INFO] swarm_install_advisory:" "Doctor text output must display [INFO] swarm_install_advisory"

  # 3. Workspace with .agents/plugins.json file also emits INFO swarm_install_advisory
  local proj_json_ws
  proj_json_ws="$(make_temp_repo)"
  mkdir -p "$proj_json_ws/.agents"
  cat <<'EOF' > "$proj_json_ws/.agents/plugins.json"
{
  "plugins": [{"name": "alps-agy-harness", "path": "./.agents/plugins/alps-agy-harness"}]
}
EOF
  local pjson_out
  pjson_out=$(TYPESAFE_API_KEY="test_key" \
              HARNESS_CONFIG_DIR="$mock_config_dir" \
              HARNESS_GH_BIN="$mock_bin_dir/gh" \
              "$REPO_ROOT/scripts/harness-doctor.sh" --workspace "$proj_json_ws" --json)
  assert_json_field "$pjson_out" ".healthy" "true"
  assert_json_field "$pjson_out" '.checks[] | select(.name=="swarm_install_advisory") | .status' "INFO"

  # 4. .harness-ignore takes precedence and suppresses swarm_install_advisory
  touch "$proj_json_ws/.harness-ignore"
  local ignored_out
  ignored_out=$(TYPESAFE_API_KEY="test_key" \
                HARNESS_CONFIG_DIR="$mock_config_dir" \
                HARNESS_GH_BIN="$mock_bin_dir/gh" \
                "$REPO_ROOT/scripts/harness-doctor.sh" --workspace "$proj_json_ws" --json)
  assert_json_field "$ignored_out" ".healthy" "true"
  assert_json_field "$ignored_out" '.checks[] | select(.name=="install_mode") | .status' "INFO"
  local ignored_advisory
  ignored_advisory=$(printf '%s\n' "$ignored_out" | jq -r '.checks[] | select(.name=="swarm_install_advisory") | .name')
  assert_eq "" "$ignored_advisory" ".harness-ignore must suppress swarm_install_advisory"
}

test_harness_doctor_impeccable_ui_states() {
  local tmp_repo mock_cfg mock_bin_dir
  tmp_repo="$(make_temp_repo)"
  mock_cfg="$tmp_repo/gemini-config"
  mock_bin_dir="$tmp_repo/doctor-bin"
  mkdir -p "$mock_cfg/plugins/superpowers" "$mock_bin_dir"
  cat <<'EOF' > "$mock_cfg/plugins.json"
{
  "plugins": [{"name": "superpowers"}, {"name": "firebase"}, {"name": "postman"}, {"name": "chrome-devtools-plugin"}]
}
EOF
  cat <<'EOF' > "$mock_cfg/mcp_config.json"
{
  "mcpServers": {
    "jev": {}, "context7": {}, "csharp-lsp": {}, "typescript-lsp": {},
    "playwright": {}, "graphify": {}, "revenuecat": {}, "filesystem": {}
  }
}
EOF
  cat <<'EOF' > "$mock_bin_dir/gh"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$mock_bin_dir/gh"

  # 1. Backend workspace without Impeccable -> impeccable_ui = INFO, healthy = true
  local backend_json
  backend_json=$(TYPESAFE_API_KEY="test_key" \
                 HARNESS_CONFIG_DIR="$mock_cfg" \
                 HARNESS_GH_BIN="$mock_bin_dir/gh" \
                 env -u HARNESS_IMPECCABLE_BIN -u HARNESS_IMPECCABLE_SKILL_DIR \
                 "$REPO_ROOT/scripts/harness-doctor.sh" --workspace "$tmp_repo" --json)
  assert_json_field "$backend_json" ".healthy" "true"
  assert_json_field "$backend_json" '.checks[] | select(.name=="impeccable_ui") | .status' "INFO"

  # 2. UI workspace (src/App.tsx) without Impeccable -> impeccable_ui = WARN with Fix, healthy = true
  mkdir -p "$tmp_repo/src"
  echo "export const App = () => <main />;" > "$tmp_repo/src/App.tsx"
  local warn_json rc_warn=0
  warn_json=$(TYPESAFE_API_KEY="test_key" \
              HARNESS_CONFIG_DIR="$mock_cfg" \
              HARNESS_GH_BIN="$mock_bin_dir/gh" \
              env -u HARNESS_IMPECCABLE_BIN -u HARNESS_IMPECCABLE_SKILL_DIR \
              "$REPO_ROOT/scripts/harness-doctor.sh" --workspace "$tmp_repo" --json) || rc_warn=$?
  assert_eq "0" "$rc_warn" "Missing Impeccable on UI workspace must warn without failing doctor"
  assert_json_field "$warn_json" ".healthy" "true"
  assert_json_field "$warn_json" '.checks[] | select(.name=="impeccable_ui") | .status' "WARN"
  assert_contains "$(printf '%s\n' "$warn_json" | jq -r '.checks[] | select(.name=="impeccable_ui") | .fix')" "npx impeccable install --scope=global"

  # 3. UI workspace with global skill installed -> impeccable_ui = OK, healthy = true
  mkdir -p "$mock_cfg/skills/impeccable"
  echo "# Impeccable" > "$mock_cfg/skills/impeccable/SKILL.md"
  local ok_json
  ok_json=$(TYPESAFE_API_KEY="test_key" \
            HARNESS_CONFIG_DIR="$mock_cfg" \
            HARNESS_GH_BIN="$mock_bin_dir/gh" \
            env -u HARNESS_IMPECCABLE_BIN -u HARNESS_IMPECCABLE_SKILL_DIR \
            "$REPO_ROOT/scripts/harness-doctor.sh" --workspace "$tmp_repo" --json)
  assert_json_field "$ok_json" ".healthy" "true"
  assert_json_field "$ok_json" '.checks[] | select(.name=="impeccable_ui") | .status' "OK"
}

test_harness_doctor_plugins_json_entries_schema_and_autodiscovery() {
  local tmp_repo mock_cfg mock_bin_dir shared_plugins_dir
  tmp_repo="$(make_temp_repo)"
  mock_cfg="$tmp_repo/gemini-config"
  mock_bin_dir="$tmp_repo/doctor-bin"
  shared_plugins_dir="$tmp_repo/vendor/team-plugins"
  mkdir -p "$mock_cfg" "$mock_bin_dir" \
    "$shared_plugins_dir/superpowers" \
    "$shared_plugins_dir/firebase" \
    "$shared_plugins_dir/postman" \
    "$tmp_repo/.agents/plugins/chrome-devtools-plugin"

  cat <<'EOF' > "$mock_cfg/mcp_config.json"
{
  "mcpServers": {
    "jev": {}, "context7": {}, "csharp-lsp": {}, "typescript-lsp": {},
    "playwright": {}, "graphify": {}, "revenuecat": {}, "filesystem": {}
  }
}
EOF
  cat <<'EOF' > "$mock_bin_dir/gh"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$mock_bin_dir/gh"

  # 1. Antigravity plugins.json {"entries": [{"path": "..."}]} + .agents/plugins/ auto-discovery -> all 4 plugins OK
  mkdir -p "$tmp_repo/.agents"
  cat <<'EOF' > "$tmp_repo/.agents/plugins.json"
{
  "entries": [
    { "path": "vendor/team-plugins" }
  ]
}
EOF

  local ok_json rc_ok=0
  ok_json=$(TYPESAFE_API_KEY="test_key" \
            HARNESS_CONFIG_DIR="$mock_cfg" \
            HARNESS_GH_BIN="$mock_bin_dir/gh" \
            "$REPO_ROOT/scripts/harness-doctor.sh" --workspace "$tmp_repo" --json) || rc_ok=$?
  assert_eq "0" "$rc_ok" "Doctor must accept Antigravity plugins.json entries schema + .agents/plugins auto-discovery"
  assert_json_field "$ok_json" ".healthy" "true"
  assert_json_field "$ok_json" '.checks[] | select(.name=="superpowers") | .status' "OK"
  assert_json_field "$ok_json" '.checks[] | select(.name=="firebase") | .status' "OK"
  assert_json_field "$ok_json" '.checks[] | select(.name=="postman") | .status' "OK"
  assert_json_field "$ok_json" '.checks[] | select(.name=="chrome-devtools-plugin") | .status' "OK"

  # 2. exclude pattern in entries hides excluded plugin -> firebase FAIL
  cat <<'EOF' > "$tmp_repo/.agents/plugins.json"
{
  "entries": [
    { "path": "vendor/team-plugins", "exclude": ["firebase"] }
  ]
}
EOF
  set +e
  local excl_json
  excl_json=$(TYPESAFE_API_KEY="test_key" \
              HARNESS_CONFIG_DIR="$mock_cfg" \
              HARNESS_GH_BIN="$mock_bin_dir/gh" \
              "$REPO_ROOT/scripts/harness-doctor.sh" --workspace "$tmp_repo" --json)
  local rc_excl=$?
  set -e
  assert_eq "1" "$rc_excl" "Excluded plugin in entries must fail doctor check"
  assert_json_field "$excl_json" '.checks[] | select(.name=="firebase") | .status' "FAIL"
  assert_json_field "$excl_json" '.checks[] | select(.name=="postman") | .status' "OK"
}

run_tests "test_"
