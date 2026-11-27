#!/usr/bin/env bash
# Alps AGY Harness - Background Daemon Sidecar Tests (test-sidecar-daemon.sh)
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-helpers.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/hooks/common.sh"

SIDECAR_DIR="$REPO_ROOT/sidecars/harness-daemon"
SIDECAR_JSON="$SIDECAR_DIR/sidecar.json"
DAEMON_PY="$SIDECAR_DIR/daemon.py"
CORE_PY="$REPO_ROOT/scripts/lib/harness_core.py"

SESSION_START="$REPO_ROOT/scripts/hooks/session-start.sh"
PRE_EDIT_GUARD="$REPO_ROOT/scripts/hooks/pre-edit-guard.sh"
PRE_COMMAND_GUARD="$REPO_ROOT/scripts/hooks/pre-command-guard.sh"
POST_COMMAND_HOOKS="$REPO_ROOT/scripts/hooks/post-command-hooks.sh"
DOCTOR_SH="$REPO_ROOT/scripts/harness-doctor.sh"

_TD_PIDS=()
_TD_DIRS=()

_td_cleanup() {
  local p d
  for p in ${_TD_PIDS[@]+"${_TD_PIDS[@]}"}; do
    if [ -n "$p" ]; then
      kill "$p" 2>/dev/null || true
      wait "$p" 2>/dev/null || true
    fi
  done
  for d in ${_TD_DIRS[@]+"${_TD_DIRS[@]}"}; do
    if [ -n "$d" ] && [ -d "$d" ]; then
      rm -rf "$d" 2>/dev/null || true
    fi
  done
  _cleanup_harness_temp_dirs
}

_wait_for_socket_health() {
  local sock="$1"
  local max_tries="${2:-40}"
  local i=0
  while [ "$i" -lt "$max_tries" ]; do
    if [ -S "$sock" ] && curl -fsS --max-time 0.2 --unix-socket "$sock" "http://localhost/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
    ((i++))
  done
  return 1
}

_wait_for_file_jq() {
  local file="$1"
  local expr="$2"
  local max_tries="${3:-50}"
  local i=0
  while [ "$i" -lt "$max_tries" ]; do
    if [ -f "$file" ] && jq -e "$expr" "$file" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
    ((i++))
  done
  return 1
}

test_sidecar_manifest_schema_and_files() {
  [ -f "$SIDECAR_JSON" ] || { echo "Missing sidecar.json: $SIDECAR_JSON" >&2; return 1; }
  [ -x "$DAEMON_PY" ] || { echo "daemon.py missing or not executable: $DAEMON_PY" >&2; return 1; }
  [ -x "$CORE_PY" ] || { echo "harness_core.py missing or not executable: $CORE_PY" >&2; return 1; }

  jq -e '
    .command == "python3" and
    (.args | type == "array") and
    (.args == ["daemon.py"]) and
    .restart_policy == "always" and
    (.display_name | type == "string" and length > 0) and
    (.description | type == "string" and length > 0) and
    (.has_web_ui // false) == false
  ' "$SIDECAR_JSON" >/dev/null
}

test_daemon_lifecycle_health_permissions_and_standby() {
  trap _td_cleanup EXIT INT TERM
  local sock_dir data_dir sock_path dpid1 dpid2
  sock_dir=$(mktemp -d "/tmp/hd-t1.XXXXXX")
  data_dir=$(mktemp -d "${TMPDIR:-/tmp}/hd-d1.XXXXXX")
  _TD_DIRS+=("$sock_dir" "$data_dir")
  sock_path="$sock_dir/d.sock"

  chmod 0755 "$sock_dir"
  touch "$sock_path"

  HARNESS_DAEMON_SOCK="$sock_path" \
  HARNESS_DAEMON_DATA_DIR="$data_dir" \
  HARNESS_SKIP_SHELL_PATH_SYNC="1" \
  HARNESS_DAEMON_POLL_INTERVAL_SEC="0.2" \
  python3 -B "$DAEMON_PY" >/dev/null 2>&1 &
  dpid1=$!
  _TD_PIDS+=("$dpid1")

  _wait_for_socket_health "$sock_path" 50 || { echo "Primary daemon failed to become healthy" >&2; return 1; }

  local dir_perm sock_perm
  dir_perm=$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$sock_dir")
  sock_perm=$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$sock_path")
  assert_eq "0o700" "$dir_perm" "Daemon must harden 0755 socket dir to 0700"
  assert_eq "0o600" "$sock_perm" "Socket file must have 0600 permissions"

  local health_json http_404 http_400
  health_json=$(curl -fsS --unix-socket "$sock_path" "http://localhost/health")
  assert_json_field "$health_json" ".status" "ok"
  assert_json_field "$health_json" ".pid" "$dpid1"
  http_404=$(curl -s -o /dev/null -w "%{http_code}" --unix-socket "$sock_path" "http://localhost/unknown")
  assert_eq "404" "$http_404" "Unknown GET route must return 404"
  http_400=$(curl -s -o /dev/null -w "%{http_code}" --unix-socket "$sock_path" -H "Content-Type: application/json" -X POST -d '{bad' "http://localhost/event/swarm-quota-wait")
  assert_eq "400" "$http_400" "Malformed JSON POST must return 400"

  # I4: HTTP 413 oversized request, 400 non-numeric Content-Length, 400 non-object JSON body, and 404 unknown POST route
  DAEMON_SOCK_CHECK="$sock_path" python3 - << 'PYEOF'
import os, socket

sock_path = os.environ["DAEMON_SOCK_CHECK"]

def send_raw(req_bytes: bytes) -> tuple[int, str]:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(5.0)
        s.connect(sock_path)
        s.sendall(req_bytes)
        chunks = []
        while True:
            data = s.recv(4096)
            if not data:
                break
            chunks.append(data)
    resp = b"".join(chunks).decode("utf-8", errors="replace")
    status = int(resp.split(" ", 2)[1])
    return status, resp

st_413, _ = send_raw(
    b"POST /hook/pre-command HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2097153\r\nConnection: close\r\n\r\n"
)
assert st_413 == 413, f"Expected 413 for > MAX_REQUEST_BYTES, got {st_413}"

st_nan, _ = send_raw(
    b"POST /hook/pre-command HTTP/1.1\r\nHost: localhost\r\nContent-Length: notanumber\r\nConnection: close\r\n\r\n"
)
assert st_nan == 400, f"Expected 400 for non-numeric Content-Length, got {st_nan}"

st_arr, _ = send_raw(
    b"POST /hook/pre-command HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 5\r\nConnection: close\r\n\r\n[1,2]"
)
assert st_arr == 400, f"Expected 400 for non-object JSON array, got {st_arr}"

st_404, resp_404 = send_raw(
    b'POST /unknown-post-route HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 20\r\nConnection: close\r\n\r\n{"workspace":"/tmp"}'
)
assert st_404 == 404 and "not_found" in resp_404, (st_404, resp_404)
PYEOF

  # I5: Already-served socket under separate data_dir must be refused cleanly
  local alt_data_dir
  alt_data_dir=$(mktemp -d "${TMPDIR:-/tmp}/hd-d1-alt.XXXXXX")
  _TD_DIRS+=("$alt_data_dir")
  if HARNESS_DAEMON_SOCK="$sock_path" HARNESS_DAEMON_DATA_DIR="$alt_data_dir" HARNESS_SKIP_SHELL_PATH_SYNC="1" \
    python3 -B "$DAEMON_PY" >/dev/null 2>&1; then
    echo "Daemon must refuse starting when socket is already served by a live instance" >&2
    return 1
  fi

  HARNESS_DAEMON_SOCK="$sock_path" \
  HARNESS_DAEMON_DATA_DIR="$data_dir" \
  HARNESS_SKIP_SHELL_PATH_SYNC="1" \
  HARNESS_DAEMON_STANDBY_INTERVAL_SEC="0.2" \
  python3 -B "$DAEMON_PY" >/dev/null 2>&1 &
  dpid2=$!
  _TD_PIDS+=("$dpid2")

  # I6: Wait until dpid2 enters passive standby, kill PRIMARY first, and assert real failover to dpid2
  local sb_tries=0
  while [ "$sb_tries" -lt 40 ]; do
    if grep -q "waiting in passive standby" "$data_dir/daemon.log" 2>/dev/null; then
      break
    fi
    sleep 0.1
    sb_tries=$((sb_tries + 1))
  done
  grep -q "waiting in passive standby" "$data_dir/daemon.log" 2>/dev/null \
    || { echo "Secondary daemon did not enter passive standby" >&2; return 1; }
  kill -0 "$dpid2" 2>/dev/null || { echo "Secondary daemon must stay alive in passive standby" >&2; return 1; }

  kill -TERM "$dpid1" 2>/dev/null || true
  wait "$dpid1" 2>/dev/null || true

  local fo_tries=0 fo_pid=""
  while [ "$fo_tries" -lt 40 ]; do
    fo_pid=$(curl -fsS --unix-socket "$sock_path" "http://localhost/health" 2>/dev/null | jq -r '.pid // empty' || true)
    if [ "$fo_pid" = "$dpid2" ]; then
      break
    fi
    sleep 0.1
    fo_tries=$((fo_tries + 1))
  done
  assert_eq "$dpid2" "$fo_pid" "Standby daemon dpid2 must take over /health after primary dpid1 terminates"

  kill -TERM "$dpid2" 2>/dev/null || true
  wait "$dpid2" 2>/dev/null || true

  [ ! -S "$sock_path" ] || { echo "Socket file should be unlinked on graceful SIGTERM" >&2; return 1; }
  [ ! -f "$sock_dir/d.pid" ] || { echo "PID file should be removed on graceful SIGTERM" >&2; return 1; }

  # I5: Startup security refusals (symlink dir, symlink socket, over-long sun_path, foreign UID owner)
  local sec_base sym_dir_target sym_dir sym_sock_dir sym_sock_target long_dir
  sec_base=$(mktemp -d "/tmp/hd-sec.XXXXXX")
  _TD_DIRS+=("$sec_base")
  sym_dir_target="$sec_base/real_dir"
  mkdir -p "$sym_dir_target"
  sym_dir="$sec_base/sym_dir"
  ln -s "$sym_dir_target" "$sym_dir"
  if HARNESS_DAEMON_SOCK="$sym_dir/d.sock" HARNESS_DAEMON_DATA_DIR="$data_dir" HARNESS_SKIP_SHELL_PATH_SYNC="1" \
    python3 -B "$DAEMON_PY" >/dev/null 2>&1; then
    echo "Daemon must refuse symlinked socket directory" >&2
    return 1
  fi

  sym_sock_dir="$sec_base/real_sock_dir"
  mkdir -p "$sym_sock_dir" && chmod 0700 "$sym_sock_dir"
  sym_sock_target="$sec_base/evil.target"
  touch "$sym_sock_target"
  ln -s "$sym_sock_target" "$sym_sock_dir/d.sock"
  if HARNESS_DAEMON_SOCK="$sym_sock_dir/d.sock" HARNESS_DAEMON_DATA_DIR="$data_dir" HARNESS_SKIP_SHELL_PATH_SYNC="1" \
    python3 -B "$DAEMON_PY" >/dev/null 2>&1; then
    echo "Daemon must refuse symlinked socket file" >&2
    return 1
  fi

  long_dir="/tmp/hd-long-$(python3 -c 'print("x"*105)')"
  local long_err
  long_err=$(HARNESS_DAEMON_SOCK="$long_dir/d.sock" HARNESS_DAEMON_DATA_DIR="$data_dir" HARNESS_SKIP_SHELL_PATH_SYNC="1" \
    python3 -B "$DAEMON_PY" 2>&1 || true)
  assert_contains "$long_err" "sun_path limit" "Over-long socket path must fail with explicit sun_path limit guard"
  if HARNESS_DAEMON_SOCK="$long_dir/d.sock" HARNESS_DAEMON_DATA_DIR="$data_dir" HARNESS_SKIP_SHELL_PATH_SYNC="1" \
    python3 -B "$DAEMON_PY" >/dev/null 2>&1; then
    echo "Daemon must refuse over-long Unix socket path on macOS" >&2
    return 1
  fi

  SEC_DIR="$sym_sock_dir" PYTHONPATH="$REPO_ROOT/sidecars/harness-daemon" python3 - << 'PYEOF'
import os, pathlib, types
import daemon

orig_lstat = pathlib.Path.lstat
def fake_lstat(self):
    res = orig_lstat(self)
    return types.SimpleNamespace(st_mode=res.st_mode, st_uid=os.getuid() + 1)

pathlib.Path.lstat = fake_lstat
try:
    try:
        daemon.validate_and_prepare_socket_dir(pathlib.Path(os.environ["SEC_DIR"]) / "d.sock")
        raise AssertionError("Expected PermissionError for foreign UID socket dir")
    except PermissionError:
        pass
finally:
    pathlib.Path.lstat = orig_lstat
PYEOF
}

test_daemon_on_vs_off_hook_parity() {
  trap _td_cleanup EXIT INT TERM
  local repo sock_dir data_dir sock_path dpid
  repo=$(make_temp_repo)
  sock_dir=$(mktemp -d "/tmp/hd-t2.XXXXXX")
  data_dir=$(mktemp -d "${TMPDIR:-/tmp}/hd-d2.XXXXXX")
  _TD_DIRS+=("$sock_dir" "$data_dir")
  sock_path="$sock_dir/d.sock"

  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: init" --quiet

  HARNESS_DAEMON_SOCK="$sock_path" \
  HARNESS_DAEMON_DATA_DIR="$data_dir" \
  HARNESS_SKIP_SHELL_PATH_SYNC="1" \
  HARNESS_DAEMON_POLL_INTERVAL_SEC="0.2" \
  python3 -B "$DAEMON_PY" >/dev/null 2>&1 &
  dpid=$!
  _TD_PIDS+=("$dpid")
  _wait_for_socket_health "$sock_path" 50 || { echo "Daemon did not start" >&2; return 1; }

  local p_start p_edit_main p_edit_angular p_pkg_deny
  p_start=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], modelName: "Orchestrator (Neon)"}')
  p_edit_main=$(jq -nc --arg ws "$repo" --arg path "$repo/src/App.ts" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: "export const x = 1;"}}}')
  p_pkg_deny=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: "npm install left-pad"}}}')

  local on_start off_start on_edit off_edit on_pkg off_pkg
  on_start=$(printf '%s' "$p_start" | HARNESS_DAEMON_SOCK="$sock_path" "$SESSION_START")
  off_start=$(printf '%s' "$p_start" | HARNESS_DISABLE_DAEMON=1 "$SESSION_START")
  assert_contains "$(printf '%s' "$on_start" | jq -r '.injectSteps[0].systemMessage.systemMessage')" "Active Git Branch: main"
  assert_contains "$(printf '%s' "$off_start" | jq -r '.injectSteps[0].systemMessage.systemMessage')" "Active Git Branch: main"

  on_edit=$(printf '%s' "$p_edit_main" | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_EDIT_GUARD")
  off_edit=$(printf '%s' "$p_edit_main" | HARNESS_DISABLE_DAEMON=1 "$PRE_EDIT_GUARD")
  assert_json_field "$on_edit" ".decision" "deny"
  assert_json_field "$off_edit" ".decision" "deny"

  git -C "$repo" checkout -b "feat/parity" --quiet
  p_edit_angular=$(jq -nc --arg ws "$repo" --arg path "$repo/src/App.ts" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: "this.sanitizer.bypassSecurityTrustHtml(x);"}}}')
  local on_ang off_ang
  on_ang=$(printf '%s' "$p_edit_angular" | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_EDIT_GUARD")
  off_ang=$(printf '%s' "$p_edit_angular" | HARNESS_DISABLE_DAEMON=1 "$PRE_EDIT_GUARD")
  assert_json_field "$on_ang" ".decision" "force_ask"
  assert_json_field "$off_ang" ".decision" "force_ask"

  on_pkg=$(printf '%s' "$p_pkg_deny" | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_COMMAND_GUARD")
  off_pkg=$(printf '%s' "$p_pkg_deny" | HARNESS_DISABLE_DAEMON=1 "$PRE_COMMAND_GUARD")
  assert_json_field "$on_pkg" ".decision" "deny"
  assert_json_field "$off_pkg" ".decision" "deny"
}

test_fail_closed_fallback_on_timeout_and_corrupt_socket() {
  trap _td_cleanup EXIT INT TERM
  local repo sock_dir sock_hang sock_bad pid_hang pid_bad
  repo=$(make_temp_repo)
  sock_dir=$(mktemp -d "/tmp/hd-t3.XXXXXX")
  _TD_DIRS+=("$sock_dir")
  sock_hang="$sock_dir/hang.sock"
  sock_bad="$sock_dir/bad.sock"

  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: init" --quiet

  python3 -B -c '
import os, socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
os.chmod(sys.argv[1], 0o600)
s.listen(8)
while True:
    conn, _ = s.accept()
    time.sleep(2.0)
    conn.close()
' "$sock_hang" >/dev/null 2>&1 &
  pid_hang=$!
  _TD_PIDS+=("$pid_hang")

  python3 -B -c '
import os, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
os.chmod(sys.argv[1], 0o600)
s.listen(8)
while True:
    conn, _ = s.accept()
    conn.recv(4096)
    conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 23\r\nConnection: close\r\n\r\n{\"decision\":\"allow_bad\"}")
    conn.close()
' "$sock_bad" >/dev/null 2>&1 &
  pid_bad=$!
  _TD_PIDS+=("$pid_bad")

  local i=0
  while [ "$i" -lt 30 ] && { [ ! -S "$sock_hang" ] || [ ! -S "$sock_bad" ]; }; do
    sleep 0.05
    ((i++))
  done

  local p_edit_main p_pkg p_start
  p_edit_main=$(jq -nc --arg ws "$repo" --arg path "$repo/src/Bad.ts" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: "export const a = 1;"}}}')
  p_pkg=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: "npm install lodash"}}}')
  p_start=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws]}')

  local out1 out2 out3 out4
  out1=$(printf '%s' "$p_edit_main" | HARNESS_DAEMON_SOCK="$sock_hang" HARNESS_DAEMON_TIMEOUT_SEC="0.15" "$PRE_EDIT_GUARD")
  assert_json_field "$out1" ".decision" "deny" "Hanging daemon must fail closed via local pre-edit fallback"

  out2=$(printf '%s' "$p_pkg" | HARNESS_DAEMON_SOCK="$sock_bad" HARNESS_DAEMON_TIMEOUT_SEC="0.15" "$PRE_COMMAND_GUARD")
  assert_json_field "$out2" ".decision" "deny" "Corrupt daemon response must fail closed via local pre-command fallback"

  out3=$(printf '%s' "$p_start" | HARNESS_DAEMON_SOCK="$sock_bad" HARNESS_DAEMON_TIMEOUT_SEC="0.15" "$SESSION_START")
  assert_contains "$(printf '%s' "$out3" | jq -r '.injectSteps[0].systemMessage.systemMessage')" "Active Git Branch: main"

  out4=$(printf '%s' "$p_pkg" | HARNESS_DAEMON_SOCK="$sock_dir/missing.sock" "$PRE_COMMAND_GUARD")
  assert_json_field "$out4" ".decision" "deny"
}

test_async_graphify_queue_and_coalescing() {
  trap _td_cleanup EXIT INT TERM
  local repo sock_dir data_dir sock_path dpid
  repo=$(make_temp_repo)
  sock_dir=$(mktemp -d "/tmp/hd-t4.XXXXXX")
  data_dir=$(mktemp -d "${TMPDIR:-/tmp}/hd-d4.XXXXXX")
  _TD_DIRS+=("$sock_dir" "$data_dir")
  sock_path="$sock_dir/d.sock"

  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: init" --quiet
  mkdir -p "$repo/graphify-out"

  local call_log started1 release1 active_flag count_file mock_graphify
  call_log="$repo/.mock-graphify-calls.log"
  started1="$repo/.mock-graphify.started1"
  release1="$repo/.mock-graphify.release1"
  active_flag="$repo/.mock-graphify.active"
  count_file="$repo/.mock-graphify.count"
  mock_graphify="$repo/mock-graphify.sh"
  cat << EOF > "$mock_graphify"
#!/usr/bin/env bash
if [ -f "$active_flag" ]; then
  echo "OVERLAP" >> "$call_log"
fi
touch "$active_flag"
n=0
if [ -f "$count_file" ]; then
  n=\$(cat "$count_file")
fi
n=\$((n + 1))
echo "\$n" > "$count_file"
echo "START:\$n" >> "$call_log"
if [ "\$n" -eq 1 ]; then
  touch "$started1"
  tries=0
  while [ ! -f "$release1" ] && [ "\$tries" -lt 80 ]; do
    sleep 0.05
    tries=\$((tries + 1))
  done
fi
rm -f "$active_flag"
echo "END:\$n" >> "$call_log"
EOF
  chmod +x "$mock_graphify"

  HARNESS_DAEMON_SOCK="$sock_path" \
  HARNESS_DAEMON_DATA_DIR="$data_dir" \
  HARNESS_SKIP_SHELL_PATH_SYNC="1" \
  HARNESS_DAEMON_POLL_INTERVAL_SEC="0.1" \
  HARNESS_GRAPHIFY_DEBOUNCE_SEC="0.15" \
  HARNESS_GRAPHIFY_BIN="$mock_graphify" \
  python3 -B "$DAEMON_PY" >/dev/null 2>&1 &
  dpid=$!
  _TD_PIDS+=("$dpid")
  _wait_for_socket_health "$sock_path" 50 || { echo "Daemon did not start" >&2; return 1; }

  local p_merge t_ms
  p_merge=$(jq -nc --arg ws "$repo" --arg cmd "gh pr merge --squash" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}, toolOutput: {output: "Merged"}}')

  t_ms=$(HARNESS_DAEMON_SOCK="$sock_path" python3 -B -c 'import time, subprocess, sys
t0 = time.monotonic()
proc = subprocess.run([sys.argv[1]], input=sys.argv[2], text=True, capture_output=True)
dt = int((time.monotonic() - t0) * 1000)
if proc.returncode != 0 or proc.stdout.strip() != "{}":
    sys.exit(1)
print(dt)
' "$POST_COMMAND_HOOKS" "$p_merge") || { echo "post-command-hooks failed" >&2; return 1; }

  if [ "$t_ms" -ge 500 ]; then
    echo "Expected post-command-hooks to return in < 500ms, took ${t_ms}ms" >&2
    return 1
  fi

  # Wait until run 1 is actively running behind release1
  local tries_s=0
  while [ ! -f "$started1" ] && [ "$tries_s" -lt 50 ]; do
    sleep 0.05
    tries_s=$((tries_s + 1))
  done
  [ -f "$started1" ] || { echo "Graphify run 1 did not start behind barrier" >&2; return 1; }

  # Send two bursts while run 1 is still executing
  curl -fsS --unix-socket "$sock_path" -H "Content-Type: application/json" -X POST \
    --data-binary "$(jq -nc --arg ws "$repo" '{workspace: $ws, reason: "burst1"}')" \
    "http://localhost/event/graphify" >/dev/null
  curl -fsS --unix-socket "$sock_path" -H "Content-Type: application/json" -X POST \
    --data-binary "$(jq -nc --arg ws "$repo" '{workspace: $ws, reason: "burst2"}')" \
    "http://localhost/event/graphify" >/dev/null

  # Wait for >= 3 watcherCycles while run 1 holds release1 -> single-flight must keep START == 1
  local c0 cur_cyc w_steps=0
  c0=$(curl -fsS --unix-socket "$sock_path" "http://localhost/health" | jq -r '.watcherCycles // 0')
  while [ "$w_steps" -lt 40 ]; do
    sleep 0.1
    w_steps=$((w_steps + 1))
    cur_cyc=$(curl -fsS --unix-socket "$sock_path" "http://localhost/health" | jq -r '.watcherCycles // 0')
    [ "$cur_cyc" -ge $((c0 + 3)) ] && break
  done
  [ "$cur_cyc" -ge $((c0 + 3)) ] || { echo "Expected >= 3 watcherCycles during graphify barrier" >&2; return 1; }
  assert_eq "1" "$(grep -c '^START:' "$call_log" || true)" "Single-flight must not start a concurrent graphify run while run 1 is active"

  # Release run 1 -> bursts must coalesce into exactly 1 rerun (total START == 2, END == 2, OVERLAP == 0)
  touch "$release1"
  _wait_for_file_jq "$repo/.harness/cache/graphify-status.json" '.state == "succeeded"' 60 || {
    echo "graphify-status.json did not reach succeeded" >&2
    return 1
  }
  local e_tries=0
  while [ "$(grep -c '^END:' "$call_log" || true)" -lt 2 ] && [ "$e_tries" -lt 40 ]; do
    sleep 0.05
    e_tries=$((e_tries + 1))
  done

  assert_eq "2" "$(grep -c '^START:' "$call_log" || true)" "Expected 1 initial run + 1 coalesced rerun"
  assert_eq "2" "$(grep -c '^END:' "$call_log" || true)" "Expected 2 completed runs"
  assert_eq "0" "$(grep -c '^OVERLAP' "$call_log" || true)" "Single-flight runs must never overlap"

  # I5: Non-zero exit and non-executable binary failure paths for graphify + exception cleanup of _quota_resume_inflight
  cat << 'EOF' > "$mock_graphify"
#!/usr/bin/env bash
echo "boom-42" >&2
exit 42
EOF
  chmod +x "$mock_graphify"
  curl -fsS --unix-socket "$sock_path" -H "Content-Type: application/json" -X POST \
    --data-binary "$(jq -nc --arg ws "$repo" '{workspace: $ws, reason: "fail-rc"}')" \
    "http://localhost/event/graphify" >/dev/null
  _wait_for_file_jq "$repo/.harness/cache/graphify-status.json" '.reason == "fail-rc" and .state == "failed" and .exitCode == 42' 60 || {
    echo "Expected failed state with exitCode 42 on non-zero graphify mock" >&2
    return 1
  }
  grep -q "boom-42" "$repo/.harness/logs/graphify-hook.log" || {
    echo "Expected boom-42 output in graphify-hook.log" >&2
    return 1
  }

  chmod 0644 "$mock_graphify"
  curl -fsS --unix-socket "$sock_path" -H "Content-Type: application/json" -X POST \
    --data-binary "$(jq -nc --arg ws "$repo" '{workspace: $ws, reason: "fail-exec"}')" \
    "http://localhost/event/graphify" >/dev/null
  _wait_for_file_jq "$repo/.harness/cache/graphify-status.json" '.reason == "fail-exec" and .state == "failed" and .exitCode == 1' 60 || {
    echo "Expected failed state with exitCode 1 on non-executable graphify mock" >&2
    return 1
  }
  grep -q "graphify invocation failed:" "$repo/.harness/logs/graphify-hook.log" || {
    echo "Expected graphify invocation failed error in graphify-hook.log" >&2
    return 1
  }

  PYTHONPATH="$REPO_ROOT/sidecars/harness-daemon:$REPO_ROOT/scripts/lib" DAEMON_DATA="$data_dir" python3 - << 'PYEOF'
import os, pathlib
import daemon, harness_core

ddir = pathlib.Path(os.environ["DAEMON_DATA"])
st = daemon.HarnessDaemonState(ddir, daemon.DaemonLogger(ddir / "exc-test.log"), False)
ws_key = "/tmp/exc-ws"
st._quota_resume_inflight.add(ws_key)
orig_attempt = harness_core.attempt_swarm_quota_resume
def boom(_ws):
    raise RuntimeError("injected resume boom")
harness_core.attempt_swarm_quota_resume = boom
try:
    st._run_swarm_quota_resume(ws_key)
finally:
    harness_core.attempt_swarm_quota_resume = orig_attempt
assert ws_key not in st._quota_resume_inflight, "Exception in _run_swarm_quota_resume must clear _quota_resume_inflight"
PYEOF
}

test_tree_state_and_stale_stamp_safety() {
  trap _td_cleanup EXIT INT TERM
  local repo sock_dir data_dir sock_path dpid
  repo=$(make_temp_repo)
  sock_dir=$(mktemp -d "/tmp/hd-t5.XXXXXX")
  data_dir=$(mktemp -d "${TMPDIR:-/tmp}/hd-d5.XXXXXX")
  _TD_DIRS+=("$sock_dir" "$data_dir")
  sock_path="$sock_dir/d.sock"

  cat << 'EOF' > "$repo/README.md"
# Repo

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| CI | Continuous Integration |
EOF
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: init" --quiet
  git -C "$repo" checkout -b "feat/stamps" --quiet

  echo "export const v = 1;" > "$repo/app.ts"
  git -C "$repo" add app.ts
  git -C "$repo" commit -m "feat: app v1" --quiet

  "$REPO_ROOT/scripts/stamp-gate.sh" canon --workspace "$repo" --verdict PASS >/dev/null
  "$REPO_ROOT/scripts/stamp-gate.sh" security --workspace "$repo" --verdict PASS --critical 0 --important 0 >/dev/null
  "$REPO_ROOT/scripts/stamp-gate.sh" tdd --workspace "$repo" --verdict PASS --critical-gaps 0 --important-gaps 0 --provider claude-cli --model sonnet --effort high >/dev/null

  HARNESS_DAEMON_SOCK="$sock_path" \
  HARNESS_DAEMON_DATA_DIR="$data_dir" \
  HARNESS_SKIP_SHELL_PATH_SYNC="1" \
  HARNESS_DAEMON_POLL_INTERVAL_SEC="0.1" \
  python3 -B "$DAEMON_PY" >/dev/null 2>&1 &
  dpid=$!
  _TD_PIDS+=("$dpid")
  _wait_for_socket_health "$sock_path" 50 || { echo "Daemon did not start" >&2; return 1; }

  curl -fsS --unix-socket "$sock_path" -H "Content-Type: application/json" -X POST \
    --data-binary "$(jq -nc --arg ws "$repo" '{workspace: $ws}')" \
    "http://localhost/event/workspace-touch" >/dev/null

  local tree_cache="$repo/.harness/cache/tree-state.json"
  _wait_for_file_jq "$tree_cache" '.canonStampValid == true and .securityStampValid == true and .tddStampValid == true and .tddStampStatus == "fresh"' 40 || {
    echo "tree-state.json should report fresh stamps" >&2
    return 1
  }

  echo "export const v = 2;" > "$repo/app.ts"
  git -C "$repo" add app.ts
  git -C "$repo" commit -m "feat: app v2" --quiet

  local new_head
  new_head=$(git -C "$repo" rev-parse HEAD)
  _wait_for_file_jq "$tree_cache" ".headOid == \"$new_head\" and .canonStampStatus == \"stale\" and .tddStampStatus == \"stale\"" 50 || {
    echo "tree-state.json did not invalidate stale stamps after new commit" >&2
    return 1
  }

  local start_out start_msg
  start_out=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws]}' | HARNESS_DAEMON_SOCK="$sock_path" "$SESSION_START")
  start_msg=$(printf '%s' "$start_out" | jq -r '.injectSteps[0].systemMessage.systemMessage')
  assert_contains "$start_msg" "[DAEMON STAMP NOTICE]" "SessionStart must warn when stamps are stale"
  assert_contains "$start_msg" "tdd-pass" "SessionStart stale stamp notice must include tdd-pass"

  mkdir -p "$repo/docs/walkthroughs"
  cat << 'EOF' > "$repo/docs/walkthroughs/2026-11-19-stamps.md"
# Stamps Feature Walkthrough

```mermaid
flowchart TD
  App --> Core
```

```mermaid
sequenceDiagram
  User->>App: Run
```

## Dosya Bazlı Değişiklik Analizi

### `app.ts` — [ÜRETİLDİ] (`Domain`)
- **Ne Değişti / Ne Üretildi:** Uygulama sürüm sabiti olan `v` değeri eklendi ve güncellendi.
- **Neden Değişti / Neden Üretildi:** Yeni sürüm doğrulama testi için kalıcı kod farkı oluşturmak amacıyla üretildi.

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| Stamp | Kriptografik denetim damgası |
EOF
  git -C "$repo" add docs/walkthroughs/2026-11-19-stamps.md
  git -C "$repo" commit -m "docs: add walkthrough" --quiet

  local latest_head old_sha
  latest_head=$(git -C "$repo" rev-parse HEAD)
  _wait_for_file_jq "$tree_cache" ".headOid == \"$latest_head\"" 50 || {
    echo "tree-state.json did not advance to walkthrough commit HEAD" >&2
    return 1
  }
  old_sha=$(jq -r '.canonStampSha' "$tree_cache")
  jq -c --arg head "$latest_head" --arg sha "$old_sha" \
    '.headOid = $head | .codeTreeSha = $sha | .canonStampValid = true | .securityStampValid = true' \
    "$tree_cache" > "$tree_cache.tmp"
  mv "$tree_cache.tmp" "$tree_cache"

  local pr_out pr_cold_out
  pr_out=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: "gh pr create --fill"}}}' \
    | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_COMMAND_GUARD")
  assert_json_field "$pr_out" ".decision" "deny" "Forged same-headOid tree-state cache must never allow gh pr create under daemon"
  assert_contains "$(printf '%s' "$pr_out" | jq -r '.reason')" "PR stamps verification failed" "PR deny reason must reach stamp verification (daemon)"

  pr_cold_out=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: "gh pr create --fill"}}}' \
    | HARNESS_DISABLE_DAEMON="1" "$PRE_COMMAND_GUARD")
  assert_json_field "$pr_cold_out" ".decision" "deny" "Forged same-headOid tree-state cache must never allow gh pr create under cold fallback"
  assert_contains "$(printf '%s' "$pr_cold_out" | jq -r '.reason')" "PR stamps verification failed" "PR deny reason must reach stamp verification (cold)"

  "$REPO_ROOT/scripts/stamp-gate.sh" canon --workspace "$repo" --verdict PASS >/dev/null
  "$REPO_ROOT/scripts/stamp-gate.sh" security --workspace "$repo" --verdict PASS --critical 0 --important 0 >/dev/null
  "$REPO_ROOT/scripts/stamp-gate.sh" tdd --workspace "$repo" --verdict PASS --critical-gaps 0 --important-gaps 0 --provider claude-cli --model sonnet --effort high >/dev/null

  _wait_for_file_jq "$repo/.harness/cache/tree-state.json" '.tddStampStatus == "fresh" and .tddStampValid == true' 50 \
    || { echo "tree-state.json did not record fresh tddStampStatus" >&2; return 1; }
  _wait_for_file_jq "$repo/.harness/cache/doc-validation.json" \
    '.docs["docs/walkthroughs/2026-11-19-stamps.md"].walkthroughValid == true' 50 || {
    echo "doc-validation.json did not cache walkthroughValid == true" >&2
    return 1
  }
  _wait_for_file_jq "$tree_cache" '.canonStampValid == true and .securityStampValid == true' 50 || {
    echo "tree-state.json did not refresh after re-stamping" >&2
    return 1
  }

  local pr_allow_out
  pr_allow_out=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: "gh pr create --fill"}}}' \
    | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_COMMAND_GUARD")
  assert_json_field "$pr_allow_out" ".decision" "allow" "Valid stamps + cached walkthroughValid must allow gh pr create"
}

test_spec_package_index_and_doc_validation_cache() {
  trap _td_cleanup EXIT INT TERM
  local repo sock_dir data_dir sock_path dpid
  repo=$(make_temp_repo)
  sock_dir=$(mktemp -d "/tmp/hd-t6.XXXXXX")
  data_dir=$(mktemp -d "${TMPDIR:-/tmp}/hd-d6.XXXXXX")
  _TD_DIRS+=("$sock_dir" "$data_dir")
  sock_path="$sock_dir/d.sock"

  mkdir -p "$repo/docs/superpowers/specs" "$repo/docs/walkthroughs"
  cat << 'EOF' > "$repo/docs/superpowers/specs/app-spec.md"
# Spec

## Global Constraints
- Allowed package: `zod@^3.23.0`

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| Spec | Tasarım dokümanı |
EOF
  git -C "$repo" add -A
  git -C "$repo" commit -m "docs: initial spec" --quiet

  HARNESS_DAEMON_SOCK="$sock_path" \
  HARNESS_DAEMON_DATA_DIR="$data_dir" \
  HARNESS_SKIP_SHELL_PATH_SYNC="1" \
  HARNESS_DAEMON_POLL_INTERVAL_SEC="0.1" \
  python3 -B "$DAEMON_PY" >/dev/null 2>&1 &
  dpid=$!
  _TD_PIDS+=("$dpid")
  _wait_for_socket_health "$sock_path" 50 || { echo "Daemon did not start" >&2; return 1; }

  curl -fsS --unix-socket "$sock_path" -H "Content-Type: application/json" -X POST \
    --data-binary "$(jq -nc --arg ws "$repo" '{workspace: $ws}')" \
    "http://localhost/event/workspace-touch" >/dev/null

  _wait_for_file_jq "$repo/.harness/cache/spec-packages.json" '.specs["docs/superpowers/specs/app-spec.md"] != null' 40 || {
    echo "spec-packages.json missing indexed spec" >&2
    return 1
  }
  _wait_for_file_jq "$repo/.harness/cache/doc-validation.json" '.docs["docs/superpowers/specs/app-spec.md"].hasGlossary == true' 40 || {
    echo "doc-validation.json missing glossary status" >&2
    return 1
  }

  local out_zod out_evil
  out_zod=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: "npm install zod"}}}' \
    | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_COMMAND_GUARD")
  assert_json_field "$out_zod" ".decision" "allow" "Indexed spec package zod must be allowed"

  out_evil=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: "npm install unverified-pkg"}}}' \
    | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_COMMAND_GUARD")
  assert_json_field "$out_evil" ".decision" "deny" "Unverified package must be denied"
}

test_harness_ignore_and_workspace_ttl_eviction() {
  trap _td_cleanup EXIT INT TERM
  local repo_ignored repo_active sock_dir data_dir sock_path dpid
  repo_ignored=$(make_temp_repo)
  repo_active=$(make_temp_repo)
  sock_dir=$(mktemp -d "/tmp/hd-t7.XXXXXX")
  data_dir=$(mktemp -d "${TMPDIR:-/tmp}/hd-d7.XXXXXX")
  _TD_DIRS+=("$sock_dir" "$data_dir")
  sock_path="$sock_dir/d.sock"

  touch "$repo_ignored/.harness-ignore"

  HARNESS_DAEMON_SOCK="$sock_path" \
  HARNESS_DAEMON_DATA_DIR="$data_dir" \
  HARNESS_SKIP_SHELL_PATH_SYNC="1" \
  HARNESS_DAEMON_POLL_INTERVAL_SEC="0.1" \
  HARNESS_DAEMON_WORKSPACE_TTL_SEC="0.5" \
  python3 -B "$DAEMON_PY" >/dev/null 2>&1 &
  dpid=$!
  _TD_PIDS+=("$dpid")
  _wait_for_socket_health "$sock_path" 50 || { echo "Daemon did not start" >&2; return 1; }

  local touch_ign
  touch_ign=$(curl -fsS --unix-socket "$sock_path" -H "Content-Type: application/json" -X POST \
    --data-binary "$(jq -nc --arg ws "$repo_ignored" '{workspace: $ws}')" \
    "http://localhost/event/workspace-touch")
  assert_json_field "$touch_ign" ".ignored" "true"
  [ ! -d "$repo_ignored/.harness/cache" ] || { echo "Ignored workspace must not get .harness/cache" >&2; return 1; }

  curl -fsS --unix-socket "$sock_path" -H "Content-Type: application/json" -X POST \
    --data-binary "$(jq -nc --arg ws "$repo_active" '{workspace: $ws}')" \
    "http://localhost/event/workspace-touch" >/dev/null
  assert_json_field "$(curl -fsS --unix-socket "$sock_path" "http://localhost/health")" ".activeWorkspaces" "1"

  local i=0
  while [ "$i" -lt 30 ]; do
    local cnt
    cnt=$(curl -fsS --unix-socket "$sock_path" "http://localhost/health" | jq -r '.activeWorkspaces')
    if [ "$cnt" = "0" ]; then
      return 0
    fi
    sleep 0.1
    ((i++))
  done
  echo "Workspace was not evicted after TTL" >&2
  return 1
}

test_conditional_ios_crash_watcher_and_non_mobile_skip() {
  trap _td_cleanup EXIT INT TERM
  local repo_plain repo_android repo_ios diag_dir sock_dir data_dir sock_path dpid
  repo_plain=$(make_temp_repo)
  repo_android=$(make_temp_repo)
  repo_ios=$(make_temp_repo)
  diag_dir=$(mktemp -d "${TMPDIR:-/tmp}/hd-diag.XXXXXX")
  sock_dir=$(mktemp -d "/tmp/hd-t8.XXXXXX")
  data_dir=$(mktemp -d "${TMPDIR:-/tmp}/hd-d8.XXXXXX")
  _TD_DIRS+=("$diag_dir" "$sock_dir" "$data_dir")
  sock_path="$sock_dir/d.sock"

  touch "$repo_android/build.gradle.kts"
  mkdir -p "$repo_ios/MyApp.xcodeproj"
  cat << 'EOF' > "$repo_ios/MyApp.xcodeproj/project.pbxproj"
PRODUCT_BUNDLE_IDENTIFIER = com.alps.MyApp;
EOF

  cat << 'EOF' > "$diag_dir/Slack-2026-11-19.ips"
{"app_name":"Slack","bundleID":"com.tinyspeck.slackmacgap"}
{"procName":"Slack","bundleID":"com.tinyspeck.slackmacgap","exception":{"type":"EXC_CRASH"}}
EOF
  cat << 'EOF' > "$diag_dir/MyApp-2026-11-19.ips"
{"app_name":"MyApp","bundleID":"com.alps.MyApp"}
{"procName":"MyApp","bundleID":"com.alps.MyApp","exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},"threads":[{"triggered":true,"frames":[{"symbol":"AppDelegate.crash"}]}]}
EOF

  HARNESS_DAEMON_SOCK="$sock_path" \
  HARNESS_DAEMON_DATA_DIR="$data_dir" \
  HARNESS_DIAG_REPORTS_DIR="$diag_dir" \
  HARNESS_SKIP_SHELL_PATH_SYNC="1" \
  HARNESS_DAEMON_POLL_INTERVAL_SEC="0.1" \
  python3 -B "$DAEMON_PY" >/dev/null 2>&1 &
  dpid=$!
  _TD_PIDS+=("$dpid")
  _wait_for_socket_health "$sock_path" 50 || { echo "Daemon did not start" >&2; return 1; }

  for ws in "$repo_plain" "$repo_android" "$repo_ios"; do
    curl -fsS --unix-socket "$sock_path" -H "Content-Type: application/json" -X POST \
      --data-binary "$(jq -nc --arg ws "$ws" '{workspace: $ws}')" \
      "http://localhost/event/workspace-touch" >/dev/null
  done

  _wait_for_file_jq "$repo_ios/.harness/cache/mobile-crashes.json" '.latestReportName == "MyApp-2026-11-19.ips"' 40 || {
    echo "iOS workspace did not write matching MyApp mobile-crashes.json" >&2
    return 1
  }
  [ ! -f "$repo_plain/.harness/cache/mobile-crashes.json" ] || { echo "Plain workspace must not have mobile-crashes.json" >&2; return 1; }
  [ ! -f "$repo_android/.harness/cache/mobile-crashes.json" ] || { echo "Android-only workspace must not have mobile-crashes.json" >&2; return 1; }

  local ios_start_out ios_msg
  ios_start_out=$(jq -nc --arg ws "$repo_ios" '{workspacePaths: [$ws]}' | HARNESS_DAEMON_SOCK="$sock_path" "$SESSION_START")
  ios_msg=$(printf '%s' "$ios_start_out" | jq -r '.injectSteps[0].systemMessage.systemMessage')
  assert_contains "$ios_msg" "[DAEMON MOBILE CRASH]" "SessionStart for iOS must surface recent crash"
  assert_contains "$ios_msg" "MyApp-2026-11-19.ips"
}

test_harness_doctor_daemon_check_and_zero_secret_leakage() {
  trap _td_cleanup EXIT INT TERM
  local repo cfg_dir bin_dir sock_dir data_dir sock_path dpid
  repo=$(make_temp_repo)
  cfg_dir="$repo/cfg"
  bin_dir="$repo/bin"
  sock_dir=$(mktemp -d "/tmp/hd-t9.XXXXXX")
  data_dir=$(mktemp -d "${TMPDIR:-/tmp}/hd-d9.XXXXXX")
  _TD_DIRS+=("$sock_dir" "$data_dir")
  sock_path="$sock_dir/d.sock"

  mkdir -p "$cfg_dir/plugins/superpowers" "$bin_dir"
  cat << 'EOF' > "$cfg_dir/plugins.json"
{"plugins":[{"name":"superpowers"},{"name":"firebase"},{"name":"postman"},{"name":"chrome-devtools-plugin"}]}
EOF
  cat << 'EOF' > "$cfg_dir/mcp_config.json"
{"mcpServers":{"jev":{},"context7":{},"csharp-lsp":{},"typescript-lsp":{},"playwright":{},"graphify":{},"revenuecat":{},"filesystem":{}}}
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin_dir/gh"
  chmod +x "$bin_dir/gh"

  local secret_val="ts_live_super_secret_daemon_999"

  local doc_off
  doc_off=$(TYPESAFE_API_KEY="$secret_val" HARNESS_CONFIG_DIR="$cfg_dir" HARNESS_GH_BIN="$bin_dir/gh" \
    HARNESS_DAEMON_SOCK="$sock_dir/none.sock" "$DOCTOR_SH" --workspace "$repo" --json)
  assert_json_field "$doc_off" ".healthy" "true"
  assert_json_field "$doc_off" '.checks[] | select(.name=="harness_daemon") | .status' "INFO"
  assert_not_contains "$doc_off" "$secret_val" "Doctor output must never leak TYPESAFE_API_KEY"

  TYPESAFE_API_KEY="$secret_val" \
  HARNESS_CONFIG_DIR="$cfg_dir" \
  HARNESS_GH_BIN="$bin_dir/gh" \
  HARNESS_DAEMON_SOCK="$sock_path" \
  HARNESS_DAEMON_DATA_DIR="$data_dir" \
  HARNESS_SKIP_SHELL_PATH_SYNC="1" \
  HARNESS_DAEMON_POLL_INTERVAL_SEC="0.1" \
  python3 -B "$DAEMON_PY" >/dev/null 2>&1 &
  dpid=$!
  _TD_PIDS+=("$dpid")
  _wait_for_socket_health "$sock_path" 50 || { echo "Daemon did not start" >&2; return 1; }

  local doc_on
  doc_on=$(TYPESAFE_API_KEY="$secret_val" HARNESS_CONFIG_DIR="$cfg_dir" HARNESS_GH_BIN="$bin_dir/gh" \
    HARNESS_DAEMON_SOCK="$sock_path" "$DOCTOR_SH" --workspace "$repo" --json)
  assert_json_field "$doc_on" ".healthy" "true"
  assert_json_field "$doc_on" '.checks[] | select(.name=="harness_daemon") | .status' "OK"
  assert_not_contains "$doc_on" "$secret_val" "Doctor output must never leak TYPESAFE_API_KEY"

  curl -fsS --unix-socket "$sock_path" -H "Content-Type: application/json" -X POST \
    --data-binary "$(jq -nc --arg ws "$repo" '{workspace: $ws}')" \
    "http://localhost/event/workspace-touch" >/dev/null
  _wait_for_file_jq "$repo/.harness/cache/health.json" '.keyStatus == "present"' 40 || {
    echo "health.json did not preserve keyStatus == present" >&2
    return 1
  }

  local health_raw daemon_log_raw
  health_raw=$(cat "$repo/.harness/cache/health.json")
  daemon_log_raw=$(cat "$data_dir/daemon.log" 2>/dev/null || true)
  assert_not_contains "$health_raw" "$secret_val" "health.json must never contain secret key"
  assert_not_contains "$daemon_log_raw" "$secret_val" "daemon.log must never contain secret key"
}

test_client_refuses_unsafe_socket_dir_and_symlink() {
  trap _td_cleanup EXIT INT TERM
  local repo sock_dir sym_dir rogue_sock link_sock rogue_pid
  repo=$(make_temp_repo)
  sock_dir=$(mktemp -d "/tmp/hd-t10.XXXXXX")
  sym_dir=$(mktemp -d "/tmp/hd-t10s.XXXXXX")
  _TD_DIRS+=("$sock_dir" "$sym_dir")
  rogue_sock="$sock_dir/d.sock"
  link_sock="$sym_dir/d.sock"

  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: init" --quiet

  # Rogue socket server returning forged allow on /hook/pre-edit and status ok on /health
  python3 -B -c '
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
s.listen(8)
while True:
    conn, _ = s.accept()
    req = conn.recv(4096)
    body = b"{\"status\":\"ok\",\"pid\":99999}" if b"GET /health" in req else b"{\"decision\":\"allow\"}"
    conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: " + str(len(body)).encode() + b"\r\nConnection: close\r\n\r\n" + body)
    conn.close()
' "$rogue_sock" >/dev/null 2>&1 &
  rogue_pid=$!
  _TD_PIDS+=("$rogue_pid")

  local i=0
  while [ "$i" -lt 30 ] && [ ! -S "$rogue_sock" ]; do
    sleep 0.05
    ((i++))
  done

  # 1. Unsafe 0755 permissions on socket dir -> client hook and probe_daemon_health must refuse
  chmod 0755 "$sock_dir"
  local p_edit_main out_perm
  p_edit_main=$(jq -nc --arg ws "$repo" --arg path "$repo/src/Evil.ts" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: "export const evil = 1;"}}}')
  out_perm=$(printf '%s' "$p_edit_main" | HARNESS_DAEMON_SOCK="$rogue_sock" "$PRE_EDIT_GUARD")
  assert_json_field "$out_perm" ".decision" "deny" "Hook must refuse 0755 socket dir and fail closed to local deny"

  local probe_perm
  probe_perm=$(HARNESS_DAEMON_SOCK="$rogue_sock" python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import harness_core; print(harness_core.probe_daemon_health()[0])' "$REPO_ROOT/scripts/lib")
  assert_eq "False" "$probe_perm" "probe_daemon_health must refuse 0755 socket dir"

  # 2. Symlink socket inside 0700 dir -> client hook and probe_daemon_health must refuse
  chmod 0700 "$sock_dir"
  chmod 0700 "$sym_dir"
  ln -s "$rogue_sock" "$link_sock"
  local out_sym probe_sym
  out_sym=$(printf '%s' "$p_edit_main" | HARNESS_DAEMON_SOCK="$link_sock" "$PRE_EDIT_GUARD")
  assert_json_field "$out_sym" ".decision" "deny" "Hook must refuse symlink socket and fail closed to local deny"

  probe_sym=$(HARNESS_DAEMON_SOCK="$link_sock" python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import harness_core; print(harness_core.probe_daemon_health()[0])' "$REPO_ROOT/scripts/lib")
  assert_eq "False" "$probe_sym" "probe_daemon_health must refuse symlink socket"
}

test_linked_git_worktree_tracking() {
  trap _td_cleanup EXIT INT TERM
  local repo wt_parent wt_dir sock_dir data_dir sock_path dpid
  repo=$(make_temp_repo)
  wt_parent=$(mktemp -d "${TMPDIR:-/tmp}/hd-wt12.XXXXXX")
  sock_dir=$(mktemp -d "/tmp/hd-t12.XXXXXX")
  data_dir=$(mktemp -d "${TMPDIR:-/tmp}/hd-d12.XXXXXX")
  _TD_DIRS+=("$wt_parent" "$sock_dir" "$data_dir")
  wt_dir="$wt_parent/wt"
  sock_path="$sock_dir/d.sock"

  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: init" --quiet
  git -C "$repo" worktree add "$wt_dir" -b "feat/wt-track" --quiet

  mkdir -p "$wt_dir/graphify-out"
  local call_log="$wt_dir/.mock-graphify-wt.log"
  local mock_graphify="$wt_parent/mock-graphify.sh"
  cat << EOF > "$mock_graphify"
#!/usr/bin/env bash
echo "RUN:\$*" >> "$call_log"
EOF
  chmod +x "$mock_graphify"

  HARNESS_DAEMON_SOCK="$sock_path" \
  HARNESS_DAEMON_DATA_DIR="$data_dir" \
  HARNESS_SKIP_SHELL_PATH_SYNC="1" \
  HARNESS_DAEMON_POLL_INTERVAL_SEC="0.1" \
  HARNESS_GRAPHIFY_DEBOUNCE_SEC="0.15" \
  HARNESS_GRAPHIFY_BIN="$mock_graphify" \
  python3 -B "$DAEMON_PY" >/dev/null 2>&1 &
  dpid=$!
  _TD_PIDS+=("$dpid")
  _wait_for_socket_health "$sock_path" 50 || { echo "Daemon did not start" >&2; return 1; }

  curl -fsS --unix-socket "$sock_path" -H "Content-Type: application/json" -X POST \
    --data-binary "$(jq -nc --arg ws "$wt_dir" '{workspace: $ws}')" \
    "http://localhost/event/workspace-touch" >/dev/null

  local wt_tree="$wt_dir/.harness/cache/tree-state.json"
  _wait_for_file_jq "$wt_tree" '.branch == "feat/wt-track"' 50 || {
    echo "Linked worktree tree-state.json missing branch feat/wt-track" >&2
    return 1
  }

  echo "export const wt = 1;" > "$wt_dir/wt.ts"
  git -C "$wt_dir" add wt.ts
  git -C "$wt_dir" commit -m "feat: commit in linked worktree" --quiet

  local new_wt_head
  new_wt_head=$(git -C "$wt_dir" rev-parse HEAD)
  _wait_for_file_jq "$wt_tree" ".headOid == \"$new_wt_head\"" 50 || {
    echo "Linked worktree tree-state.json did not refresh headOid after commit" >&2
    return 1
  }
  _wait_for_file_jq "$wt_dir/.harness/cache/graphify-status.json" '.state == "succeeded"' 60 || {
    echo "Linked worktree commit did not trigger async graphify run" >&2
    return 1
  }

  local run_count
  run_count=$(grep -c '^RUN:' "$call_log" 2>/dev/null || true)
  [ "$run_count" -ge 1 ] || { echo "Expected mock graphify to run in linked worktree" >&2; return 1; }
}

test_pre_edit_symlink_parent_traversal_blocked() {
  trap _td_cleanup EXIT INT TERM
  local repo sock_dir data_dir sock_path dpid
  repo=$(make_temp_repo)
  sock_dir=$(mktemp -d "/tmp/hd-t13.XXXXXX")
  data_dir=$(mktemp -d "${TMPDIR:-/tmp}/hd-d13.XXXXXX")
  _TD_DIRS+=("$sock_dir" "$data_dir")
  sock_path="$sock_dir/d.sock"

  mkdir -p "$repo/docs/superpowers/specs" "$repo/src"
  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: init" --quiet
  ln -s ../../../src "$repo/docs/superpowers/specs/sub"

  HARNESS_DAEMON_SOCK="$sock_path" \
  HARNESS_DAEMON_DATA_DIR="$data_dir" \
  HARNESS_SKIP_SHELL_PATH_SYNC="1" \
  HARNESS_DAEMON_POLL_INTERVAL_SEC="0.1" \
  python3 -B "$DAEMON_PY" >/dev/null 2>&1 &
  dpid=$!
  _TD_PIDS+=("$dpid")
  _wait_for_socket_health "$sock_path" 50 || { echo "Daemon did not start" >&2; return 1; }

  local rel_evil="docs/superpowers/specs/sub/../src/evil.ts"
  local abs_evil="$repo/docs/superpowers/specs/sub/../src/evil.ts"
  local evil_content=$'eval(x);\n-----BEGIN RSA PRIVATE KEY-----\n'
  local p_rel p_abs out_rel_on out_rel_off out_abs_on out_abs_off out_feat_on out_feat_off

  p_rel=$(jq -nc --arg ws "$repo" --arg path "$rel_evil" --arg content "$evil_content" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: $content}}}')
  p_abs=$(jq -nc --arg ws "$repo" --arg path "$abs_evil" --arg content "$evil_content" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: $content}}}')

  out_rel_on=$(printf '%s' "$p_rel" | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_EDIT_GUARD")
  assert_json_field "$out_rel_on" ".decision" "deny" "Relative symlink+.. traversal on main must be denied (daemon ON)"

  out_rel_off=$(printf '%s' "$p_rel" | HARNESS_DISABLE_DAEMON="1" "$PRE_EDIT_GUARD")
  assert_json_field "$out_rel_off" ".decision" "deny" "Relative symlink+.. traversal on main must be denied (cold fallback)"

  out_abs_on=$(printf '%s' "$p_abs" | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_EDIT_GUARD")
  assert_json_field "$out_abs_on" ".decision" "deny" "Absolute symlink+.. traversal on main must be denied (daemon ON)"

  out_abs_off=$(printf '%s' "$p_abs" | HARNESS_DISABLE_DAEMON="1" "$PRE_EDIT_GUARD")
  assert_json_field "$out_abs_off" ".decision" "deny" "Absolute symlink+.. traversal on main must be denied (cold fallback)"

  git -C "$repo" checkout -b "feat/symlink-check" --quiet
  out_feat_on=$(printf '%s' "$p_rel" | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_EDIT_GUARD")
  assert_json_field "$out_feat_on" ".decision" "deny" "Rule 3 dangerous pattern/key must not be bypassed via symlink+.. on feature branch (daemon ON)"

  out_feat_off=$(printf '%s' "$p_rel" | HARNESS_DISABLE_DAEMON="1" "$PRE_EDIT_GUARD")
  assert_json_field "$out_feat_off" ".decision" "deny" "Rule 3 dangerous pattern/key must not be bypassed via symlink+.. on feature branch (cold fallback)"
}

test_workspace_plugin_auto_start_daemon_and_fd_isolation() {
  trap _td_cleanup EXIT INT TERM
  local repo sock_dir data_dir sock_path dpid
  repo=$(make_temp_repo)
  sock_dir=$(mktemp -d "/tmp/hd-t14.XXXXXX")
  data_dir=$(mktemp -d "${TMPDIR:-/tmp}/hd-d14.XXXXXX")
  _TD_DIRS+=("$sock_dir" "$data_dir")
  sock_path="$sock_dir/d.sock"

  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: init" --quiet

  local p_start t_ms start_out
  p_start=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws]}')

  # Run session-start inside $() with HARNESS_AUTO_START_DAEMON=1; verify detached FDs don't hang pipe
  local res_file="$repo/.autostart-out.json"
  t_ms=$(HARNESS_AUTO_START_DAEMON=1 \
    HARNESS_DAEMON_SOCK="$sock_path" \
    HARNESS_DAEMON_DATA_DIR="$data_dir" \
    HARNESS_SKIP_SHELL_PATH_SYNC="1" \
    python3 -B -c 'import subprocess, sys, time
t0 = time.monotonic()
proc = subprocess.run([sys.argv[1]], input=sys.argv[2], text=True, capture_output=True, timeout=5)
dt = int((time.monotonic() - t0) * 1000)
if proc.returncode != 0:
    sys.stderr.write(proc.stderr)
    sys.exit(1)
open(sys.argv[3], "w", encoding="utf-8").write(proc.stdout)
print(dt)
' "$SESSION_START" "$p_start" "$res_file") || { echo "session-start auto-start failed" >&2; return 1; }

  start_out=$(cat "$res_file")
  assert_contains "$(printf '%s' "$start_out" | jq -r '.injectSteps[0].systemMessage.systemMessage')" "Active Git Branch: main"

  if [ "$t_ms" -ge 2000 ]; then
    echo "session-start with daemon auto-start took ${t_ms}ms (possible FD pipe block)" >&2
    return 1
  fi

  [ -S "$sock_path" ] || { echo "Auto-started daemon socket missing: $sock_path" >&2; return 1; }
  local health_json
  health_json=$(curl -fsS --unix-socket "$sock_path" "http://localhost/health")
  assert_json_field "$health_json" ".status" "ok"
  dpid=$(printf '%s' "$health_json" | jq -r '.pid')
  _TD_PIDS+=("$dpid")

  # Concurrent hook calls must preserve singleton PID without spawning standby duplicates
  local p_edit
  p_edit=$(jq -nc --arg ws "$repo" --arg path "$repo/src/Bad.ts" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: "export const x = 1;"}}}')
  local c_pids=()
  for _ in 1 2 3 4; do
    (printf '%s' "$p_edit" | HARNESS_AUTO_START_DAEMON=1 HARNESS_DAEMON_SOCK="$sock_path" HARNESS_DAEMON_DATA_DIR="$data_dir" HARNESS_SKIP_SHELL_PATH_SYNC="1" "$PRE_EDIT_GUARD" >/dev/null) &
    c_pids+=("$!")
  done
  for cp in "${c_pids[@]}"; do
    wait "$cp"
  done

  local health_after
  health_after=$(curl -fsS --unix-socket "$sock_path" "http://localhost/health")
  assert_json_field "$health_after" ".pid" "$dpid" "Singleton daemon PID must remain unchanged across concurrent calls"

  # I4: Starting daemon directly with HARNESS_DAEMON_EXIT_ON_LOCK_BUSY=1 while lock is held exits 0 and logs clean exit
  HARNESS_DAEMON_SOCK="$sock_path" HARNESS_DAEMON_DATA_DIR="$data_dir" HARNESS_DAEMON_EXIT_ON_LOCK_BUSY=1 \
    python3 -B "$DAEMON_PY" || { echo "Expected exit 0 when HARNESS_DAEMON_EXIT_ON_LOCK_BUSY=1 encounters busy lock" >&2; return 1; }
  grep -q "auto-start helper exiting cleanly" "$data_dir/daemon.log" || {
    echo "Expected busy-lock exit log line in $data_dir/daemon.log" >&2
    return 1
  }

  # HARNESS_DISABLE_DAEMON=1 must never auto-start even when HARNESS_AUTO_START_DAEMON=1
  local sock_disabled="$sock_dir/disabled.sock"
  local out_disabled
  out_disabled=$(printf '%s' "$p_start" | HARNESS_AUTO_START_DAEMON=1 HARNESS_DISABLE_DAEMON=1 HARNESS_DAEMON_SOCK="$sock_disabled" HARNESS_DAEMON_DATA_DIR="$data_dir" "$SESSION_START")
  assert_contains "$(printf '%s' "$out_disabled" | jq -r '.injectSteps[0].systemMessage.systemMessage')" "Active Git Branch: main"
  [ ! -S "$sock_disabled" ] || { echo "HARNESS_DISABLE_DAEMON=1 must never start daemon" >&2; return 1; }
}

test_parallel_worktrees_warm_daemon_vs_cold_parity() {
  trap _td_cleanup EXIT INT TERM
  local main_repo wt_parent wt_backend wt_admin sock_dir data_dir sock_path dpid
  main_repo=$(make_temp_repo)
  wt_parent=$(mktemp -d "${TMPDIR:-/tmp}/hd-wtp15.XXXXXX")
  sock_dir=$(mktemp -d "/tmp/hd-t15.XXXXXX")
  data_dir=$(mktemp -d "${TMPDIR:-/tmp}/hd-d15.XXXXXX")
  _TD_DIRS+=("$wt_parent" "$sock_dir" "$data_dir")
  sock_path="$sock_dir/d.sock"
  wt_backend="$wt_parent/kedo-backend"
  wt_admin="$wt_parent/kedo-admin"

  cat << 'EOF' > "$main_repo/.gitignore"
docs/walkthroughs/*
EOF
  cat << 'EOF' > "$main_repo/README.md"
# Kedo

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| Kedo | Çoklu worktree test projesi |
EOF
  git -C "$main_repo" add .gitignore README.md
  git -C "$main_repo" commit -m "chore: init with gitignored walkthroughs" --quiet

  git -C "$main_repo" worktree add "$wt_backend" -b "feat/backend" --quiet
  git -C "$main_repo" worktree add "$wt_admin" -b "feat/admin" --quiet

  mkdir -p "$wt_admin/src" "$wt_admin/docs/walkthroughs"
  echo "export const Admin = true;" > "$wt_admin/src/AdminPage.ts"
  git -C "$wt_admin" add src/AdminPage.ts
  git -C "$wt_admin" commit -m "feat: add admin page" --quiet

  cat << 'EOF' > "$wt_admin/docs/walkthroughs/2026-11-21-admin.md"
# Admin PR Rehberi

```mermaid
flowchart LR
  AdminPage --> AppRouter
```

```mermaid
sequenceDiagram
  User->>AdminPage: open()
  AdminPage-->>User: ready
```

## Dosya Bazlı Değişiklik Analizi

### `src/AdminPage.ts` — [ÜRETİLDİ] (`Presentation`)
- **Ne Değişti / Ne Üretildi?:** Yönetici paneli başlangıç bayrağını dışa aktaran `AdminPage.ts` modülü ve `Admin` sabiti eklendi.
- **Neden Değişti / Neden Üretildi?:** Çoklu worktree PR kapısında `.gitignore` kapsamındaki yerel walkthrough doğrulamasını kanıtlamak için üretildi.

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| AdminPage | Yönetici paneli kök modülü |
EOF

  "$REPO_ROOT/scripts/stamp-gate.sh" canon --workspace "$wt_admin" --verdict PASS --allow-file "src/AdminPage.ts" >/dev/null
  "$REPO_ROOT/scripts/stamp-gate.sh" security --workspace "$wt_admin" --verdict PASS --critical 0 --important 0 >/dev/null
  "$REPO_ROOT/scripts/stamp-gate.sh" tdd --workspace "$wt_admin" --verdict PASS --critical-gaps 0 --important-gaps 0 --provider claude-cli --model sonnet --effort high >/dev/null

  HARNESS_DAEMON_SOCK="$sock_path" \
  HARNESS_DAEMON_DATA_DIR="$data_dir" \
  HARNESS_SKIP_SHELL_PATH_SYNC="1" \
  HARNESS_DAEMON_POLL_INTERVAL_SEC="0.1" \
  python3 -B "$DAEMON_PY" >/dev/null 2>&1 &
  dpid=$!
  _TD_PIDS+=("$dpid")
  _wait_for_socket_health "$sock_path" 50 || { echo "Daemon did not start" >&2; return 1; }

  # 1. Sibling pre-edit parity + auto-registration in daemon
  local p_wt_clean p_wt_bad out_clean_on out_clean_off out_bad_on out_bad_off
  p_wt_clean=$(jq -nc --arg ws "$main_repo" --arg path "$wt_backend/src/Service.ts" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: "export const svc = 1;"}}}')
  p_wt_bad=$(jq -nc --arg ws "$main_repo" --arg path "$wt_backend/src/Bad.ts" \
    '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: $path, Content: "export const bad = eval(\"x\");"}}}')

  out_clean_on=$(printf '%s' "$p_wt_clean" | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_EDIT_GUARD")
  out_clean_off=$(printf '%s' "$p_wt_clean" | HARNESS_DISABLE_DAEMON="1" "$PRE_EDIT_GUARD")
  assert_json_field "$out_clean_on" ".decision" "allow"
  assert_json_field "$out_clean_off" ".decision" "allow"

  out_bad_on=$(printf '%s' "$p_wt_bad" | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_EDIT_GUARD")
  out_bad_off=$(printf '%s' "$p_wt_bad" | HARNESS_DISABLE_DAEMON="1" "$PRE_EDIT_GUARD")
  assert_json_field "$out_bad_on" ".decision" "deny"
  assert_json_field "$out_bad_off" ".decision" "deny"

  local active_cnt
  active_cnt=$(curl -fsS --unix-socket "$sock_path" "http://localhost/health" | jq -r '.activeWorkspaces')
  [ "$active_cnt" -ge 2 ] || { echo "Expected sibling worktree auto-registered in daemon (activeWorkspaces=$active_cnt)" >&2; return 1; }

  # 2. Cross-worktree cd && gh pr create with gitignored local walkthrough (daemon ON vs OFF)
  local p_admin_pr p_main_pr out_pr_on out_pr_off out_main_pr_on out_main_pr_off
  p_admin_pr=$(jq -nc --arg ws "$main_repo" --arg cmd "cd \"$wt_admin\" && gh pr create --fill" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  p_main_pr=$(jq -nc --arg ws "$main_repo" --arg cmd "cd \"$main_repo\" && gh pr create --fill" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')

  out_pr_on=$(printf '%s' "$p_admin_pr" | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_COMMAND_GUARD")
  out_pr_off=$(printf '%s' "$p_admin_pr" | HARNESS_DISABLE_DAEMON="1" "$PRE_COMMAND_GUARD")
  assert_json_field "$out_pr_on" ".decision" "allow" "Daemon must allow cd <wt_admin> && gh pr create with gitignored walkthrough"
  assert_json_field "$out_pr_off" ".decision" "allow" "Cold must allow cd <wt_admin> && gh pr create with gitignored walkthrough"

  out_main_pr_on=$(printf '%s' "$p_main_pr" | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_COMMAND_GUARD")
  out_main_pr_off=$(printf '%s' "$p_main_pr" | HARNESS_DISABLE_DAEMON="1" "$PRE_COMMAND_GUARD")
  assert_json_field "$out_main_pr_on" ".decision" "deny"
  assert_json_field "$out_main_pr_off" ".decision" "deny"

  # 3. post-command writes pr-audit-pending.json into wt_admin with conversationId
  local p_post_pr pending_admin
  p_post_pr=$(jq -nc --arg ws "$main_repo" --arg cmd "cd \"$wt_admin\" && gh pr create --fill" \
    '{workspacePaths: [$ws], conversationId: "conv-admin", toolCall: {name: "run_command", args: {CommandLine: $cmd}}, toolOutput: {output: "https://github.com/org/kedo/pull/101"}}')
  printf '%s' "$p_post_pr" | HARNESS_DAEMON_SOCK="$sock_path" "$POST_COMMAND_HOOKS" >/dev/null
  pending_admin="$wt_admin/.harness/state/feat-admin/pr-audit-pending.json"
  [ -f "$pending_admin" ] || { echo "Expected pr-audit-pending.json in $pending_admin" >&2; return 1; }
  [ ! -f "$main_repo/.harness/state/main/pr-audit-pending.json" ] || { echo "main_repo must not receive wt_admin pending flag" >&2; return 1; }
  assert_json_field "$pending_admin" ".conversationId" "conv-admin"

  # 4. stop-gate parity across daemon ON and cold OFF with conversationId isolation
  local STOP_GATE="$REPO_ROOT/scripts/hooks/stop-gate.sh"
  local stop_other_on stop_other_off stop_admin_on stop_admin_off
  stop_other_on=$(jq -nc --arg ws "$main_repo" '{workspacePaths: [$ws], conversationId: "conv-backend", terminationReason: "NO_TOOL_CALL"}' \
    | HARNESS_DAEMON_SOCK="$sock_path" "$STOP_GATE" | jq -c .)
  stop_other_off=$(jq -nc --arg ws "$main_repo" '{workspacePaths: [$ws], conversationId: "conv-ios", terminationReason: "NO_TOOL_CALL"}' \
    | HARNESS_DISABLE_DAEMON="1" "$STOP_GATE" | jq -c .)
  assert_eq "{}" "$stop_other_on" "Other conversation must not be blocked under daemon"
  assert_eq "{}" "$stop_other_off" "Other conversation must not be blocked under cold fallback"

  stop_admin_on=$(jq -nc --arg ws "$main_repo" '{workspacePaths: [$ws], conversationId: "conv-admin", terminationReason: "NO_TOOL_CALL"}' \
    | HARNESS_DAEMON_SOCK="$sock_path" "$STOP_GATE")
  assert_json_field "$stop_admin_on" ".decision" "continue" "Matching conversationId must block once under daemon"
  stop_admin_off=$(jq -nc --arg ws "$main_repo" '{workspacePaths: [$ws], conversationId: "conv-admin", terminationReason: "NO_TOOL_CALL"}' \
    | HARNESS_DISABLE_DAEMON="1" "$STOP_GATE")
  assert_json_field "$stop_admin_off" ".decision" "continue" "Matching conversationId must block second time under cold fallback"
}

test_swarm_cwd_detached_and_parallel_dispatch_daemon_vs_cold_parity() {
  trap _td_cleanup EXIT INT TERM
  local PRE_SUBAGENT_GUARD="$REPO_ROOT/scripts/hooks/pre-subagent-guard.sh"
  local STAMP_GATE="$REPO_ROOT/scripts/stamp-gate.sh"
  local main_repo wt_parent wt_feat wt_detached sock_dir data_dir sock_path dpid
  main_repo=$(make_temp_repo)
  wt_parent=$(mktemp -d "/tmp/hd-wtp16.XXXXXX")
  sock_dir=$(mktemp -d "/tmp/hd-t16.XXXXXX")
  data_dir=$(mktemp -d "${TMPDIR:-/tmp}/hd-d16.XXXXXX")
  _TD_DIRS+=("$wt_parent" "$sock_dir" "$data_dir")
  sock_path="$sock_dir/d.sock"
  wt_feat="$wt_parent/worker-feat"
  wt_detached="$wt_parent/worker-detached"

  echo "init" > "$main_repo/README.md"
  git -C "$main_repo" add README.md
  git -C "$main_repo" commit -m "chore: init" --quiet
  git -C "$main_repo" remote add origin "https://github.com/example/swarm-parity.git"
  git -C "$main_repo" worktree add "$wt_feat" -b "feat/parity-cwd" --quiet
  git -C "$main_repo" worktree add --detach "$wt_detached" --quiet

  HARNESS_DAEMON_SOCK="$sock_path" \
  HARNESS_DAEMON_DATA_DIR="$data_dir" \
  HARNESS_SKIP_SHELL_PATH_SYNC="1" \
  HARNESS_DAEMON_POLL_INTERVAL_SEC="0.1" \
  python3 -B "$DAEMON_PY" >/dev/null 2>&1 &
  dpid=$!
  _TD_PIDS+=("$dpid")
  _wait_for_socket_health "$sock_path" 50 || { echo "Daemon did not start" >&2; return 1; }

  # 1. swarm add brief enrichment parity (daemon ON vs cold OFF)
  local p_swarm out_sw_on out_sw_off
  p_swarm=$(jq -nc --arg ws "$main_repo" '{
    workspacePaths: [$ws],
    toolCall: {name: "swarm", args: {action: "add", name: "parity-worker", workspace: "share", brief: "Implement parity task."}}
  }')
  out_sw_on=$(printf '%s' "$p_swarm" | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_SUBAGENT_GUARD" | jq -c .)
  out_sw_off=$(printf '%s' "$p_swarm" | HARNESS_DISABLE_DAEMON="1" "$PRE_SUBAGENT_GUARD" | jq -c .)
  assert_eq "$out_sw_off" "$out_sw_on" "swarm add response must match identically between daemon ON and cold fallback"
  assert_contains "$(printf '%s' "$out_sw_on" | jq -r '.overwrite.brief')" "[SWARM_WORKER_CONTRACT"
  assert_contains "$(printf '%s' "$out_sw_on" | jq -r '.overwrite.brief')" "[SWARM_BRANCH_GUARD"

  # 2. HOOK_INPUT.cwd parity for pre-edit, pre-command, and post-command
  local p_edit_rel p_edit_bad p_push_cwd out_er_on out_er_off out_eb_on out_eb_off out_pc_on out_pc_off
  p_edit_rel=$(jq -nc --arg ws "$main_repo" --arg cwd "$wt_feat" \
    '{workspacePaths: [$ws], cwd: $cwd, toolCall: {name: "write_file", args: {Path: "src/Clean.ts", Content: "export const ok = 1;"}}}')
  p_edit_bad=$(jq -nc --arg ws "$main_repo" --arg cwd "$wt_feat" \
    '{workspacePaths: [$ws], cwd: $cwd, toolCall: {name: "write_file", args: {Path: "src/Bad.ts", Content: "export const x = eval(\"1\");"}}}')
  p_push_cwd=$(jq -nc --arg ws "$main_repo" --arg cwd "$wt_feat" \
    '{workspacePaths: [$ws], cwd: $cwd, toolCall: {name: "run_command", args: {CommandLine: "git push"}}}')

  out_er_on=$(printf '%s' "$p_edit_rel" | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_EDIT_GUARD")
  out_er_off=$(printf '%s' "$p_edit_rel" | HARNESS_DISABLE_DAEMON="1" "$PRE_EDIT_GUARD")
  assert_json_field "$out_er_on" ".decision" "allow" "Daemon ON must allow relative write_file in cwd sibling worktree"
  assert_json_field "$out_er_off" ".decision" "allow" "Cold OFF must allow relative write_file in cwd sibling worktree"

  out_eb_on=$(printf '%s' "$p_edit_bad" | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_EDIT_GUARD")
  out_eb_off=$(printf '%s' "$p_edit_bad" | HARNESS_DISABLE_DAEMON="1" "$PRE_EDIT_GUARD")
  assert_json_field "$out_eb_on" ".decision" "deny" "Daemon ON must deny eval() in cwd sibling worktree"
  assert_json_field "$out_eb_off" ".decision" "deny" "Cold OFF must deny eval() in cwd sibling worktree"

  out_pc_on=$(printf '%s' "$p_push_cwd" | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_COMMAND_GUARD")
  out_pc_off=$(printf '%s' "$p_push_cwd" | HARNESS_DISABLE_DAEMON="1" "$PRE_COMMAND_GUARD")
  assert_json_field "$out_pc_on" ".decision" "allow" "Daemon ON must allow git push in cwd sibling worktree"
  assert_json_field "$out_pc_off" ".decision" "allow" "Cold OFF must allow git push in cwd sibling worktree"

  local p_post_cwd pending_cwd
  p_post_cwd=$(jq -nc --arg ws "$main_repo" --arg cwd "$wt_feat" \
    '{workspacePaths: [$ws], cwd: $cwd, conversationId: "conv-parity", toolCall: {name: "run_command", args: {CommandLine: "gh pr create --fill"}}, toolOutput: {output: "https://github.com/example/swarm-parity/pull/12"}}')
  pending_cwd="$wt_feat/.harness/state/feat-parity-cwd/pr-audit-pending.json"
  printf '%s' "$p_post_cwd" | HARNESS_DAEMON_SOCK="$sock_path" "$POST_COMMAND_HOOKS" >/dev/null
  [ -f "$pending_cwd" ] || { echo "Daemon ON post-command with cwd must write $pending_cwd" >&2; return 1; }
  assert_json_field "$pending_cwd" ".conversationId" "conv-parity"
  rm -f "$pending_cwd"
  printf '%s' "$p_post_cwd" | HARNESS_DISABLE_DAEMON="1" "$POST_COMMAND_HOOKS" >/dev/null
  [ -f "$pending_cwd" ] || { echo "Cold OFF post-command with cwd must write $pending_cwd" >&2; return 1; }
  assert_json_field "$pending_cwd" ".conversationId" "conv-parity"
  rm -f "$pending_cwd"

  # 3. detached-wt-* parity across commits (daemon ON vs cold OFF)
  "$STAMP_GATE" context7 --workspace "$wt_detached" --package "zod" --version "3.24.0" --source "locked"
  echo "export const det = 1;" > "$wt_detached/det.ts"
  git -C "$wt_detached" add det.ts
  git -C "$wt_detached" commit -m "feat: detached commit" --quiet

  local p_det_pkg p_det_unstamped out_dp_on out_dp_off out_du_on out_du_off
  p_det_pkg=$(jq -nc --arg ws "$main_repo" --arg cwd "$wt_detached" \
    '{workspacePaths: [$ws], cwd: $cwd, toolCall: {name: "run_command", args: {CommandLine: "npm install zod"}}}')
  p_det_unstamped=$(jq -nc --arg ws "$main_repo" --arg cwd "$wt_detached" \
    '{workspacePaths: [$ws], cwd: $cwd, toolCall: {name: "run_command", args: {CommandLine: "npm install express"}}}')

  out_dp_on=$(printf '%s' "$p_det_pkg" | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_COMMAND_GUARD")
  out_dp_off=$(printf '%s' "$p_det_pkg" | HARNESS_DISABLE_DAEMON="1" "$PRE_COMMAND_GUARD")
  assert_json_field "$out_dp_on" ".decision" "allow" "Daemon ON must preserve detached-wt-* context7 stamp across commit"
  assert_json_field "$out_dp_off" ".decision" "allow" "Cold OFF must preserve detached-wt-* context7 stamp across commit"

  out_du_on=$(printf '%s' "$p_det_unstamped" | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_COMMAND_GUARD")
  out_du_off=$(printf '%s' "$p_det_unstamped" | HARNESS_DISABLE_DAEMON="1" "$PRE_COMMAND_GUARD")
  assert_json_field "$out_du_on" ".decision" "deny" "Daemon ON must deny unstamped pkg in detached-wt-*"
  assert_json_field "$out_du_off" ".decision" "deny" "Cold OFF must deny unstamped pkg in detached-wt-*"

  # 4. Parallel same-role dispatch parity (1st consumed via daemon ON, 2nd via cold OFF, 3rd denied on both)
  "$STAMP_GATE" dispatch --role "Daemon Queue Role" --type "self" --tier "bounded_execution" --conversation-id "conv-d1" --workspace "$main_repo"
  "$STAMP_GATE" dispatch --role "Daemon Queue Role" --type "self" --tier "multi_module_integration" --conversation-id "conv-d2" --workspace "$main_repo"

  local out_dq1 out_dq2 out_dq3_on out_dq3_off
  out_dq1=$(jq -nc --arg ws "$main_repo" '{
    workspacePaths: [$ws],
    conversationId: "conv-d1",
    toolCall: {name: "invoke_subagent", args: {TypeName: "self", Role: "Daemon Queue Role", Prompt: "Q1"}}
  }' | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_dq1" ".decision" "allow"
  assert_json_field "$out_dq1" ".overwrite.Model" "flash"

  out_dq2=$(jq -nc --arg ws "$main_repo" '{
    workspacePaths: [$ws],
    conversationId: "conv-d2",
    toolCall: {name: "invoke_subagent", args: {TypeName: "self", Role: "Daemon Queue Role", Prompt: "Q2"}}
  }' | HARNESS_DISABLE_DAEMON="1" "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_dq2" ".decision" "allow"
  assert_json_field "$out_dq2" ".overwrite.Model" "inherit"

  out_dq3_on=$(jq -nc --arg ws "$main_repo" '{
    workspacePaths: [$ws],
    conversationId: "conv-d1",
    toolCall: {name: "invoke_subagent", args: {TypeName: "self", Role: "Daemon Queue Role", Prompt: "Q3"}}
  }' | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_SUBAGENT_GUARD")
  out_dq3_off=$(jq -nc --arg ws "$main_repo" '{
    workspacePaths: [$ws],
    conversationId: "conv-d1",
    toolCall: {name: "invoke_subagent", args: {TypeName: "self", Role: "Daemon Queue Role", Prompt: "Q3"}}
  }' | HARNESS_DISABLE_DAEMON="1" "$PRE_SUBAGENT_GUARD")
  assert_json_field "$out_dq3_on" ".decision" "deny" "Daemon ON must deny after queue exhausted"
  assert_json_field "$out_dq3_off" ".decision" "deny" "Cold OFF must deny after queue exhausted"
}

test_daemon_impeccable_parity_and_ui_stamp_tree_state() {
  trap _td_cleanup EXIT INT TERM
  local repo sock_dir data_dir sock_path dpid mock_bin
  repo=$(make_temp_repo)
  sock_dir=$(mktemp -d "/tmp/hd-imp.XXXXXX")
  data_dir=$(mktemp -d "${TMPDIR:-/tmp}/hd-imp-d.XXXXXX")
  _TD_DIRS+=("$sock_dir" "$data_dir")
  sock_path="$sock_dir/d.sock"

  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: init" --quiet

  HARNESS_DAEMON_SOCK="$sock_path" \
  HARNESS_DAEMON_DATA_DIR="$data_dir" \
  HARNESS_SKIP_SHELL_PATH_SYNC="1" \
  HARNESS_DAEMON_POLL_INTERVAL_SEC="0.2" \
  python3 -B "$DAEMON_PY" >/dev/null 2>&1 &
  dpid=$!
  _TD_PIDS+=("$dpid")
  _wait_for_socket_health "$sock_path" 50 || { echo "Daemon did not start" >&2; return 1; }

  # 1. .impeccable/ edit parity (daemon ON vs cold OFF)
  local p_imp_edit on_edit off_edit
  p_imp_edit=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], toolCall: {name: "write_file", args: {Path: ".impeccable/hook.cache.json", Content: "{}"}}}')
  on_edit=$(printf '%s' "$p_imp_edit" | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_EDIT_GUARD")
  off_edit=$(printf '%s' "$p_imp_edit" | HARNESS_DISABLE_DAEMON="1" "$PRE_EDIT_GUARD")
  assert_json_field "$on_edit" ".decision" "allow" "Daemon ON must allow .impeccable/ cache writes"
  assert_json_field "$off_edit" ".decision" "allow" "Cold OFF must allow .impeccable/ cache writes"

  # 2. npx impeccable live guard parity (daemon ON vs cold OFF)
  local p_live on_live off_live
  p_live=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: "npx impeccable live"}}}')
  on_live=$(printf '%s' "$p_live" | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_COMMAND_GUARD")
  off_live=$(printf '%s' "$p_live" | HARNESS_DISABLE_DAEMON="1" "$PRE_COMMAND_GUARD")
  assert_json_field "$on_live" ".decision" "deny" "Daemon ON must deny unguarded npx impeccable live"
  assert_json_field "$off_live" ".decision" "deny" "Cold OFF must deny unguarded npx impeccable live"

  # 3. tree-state.json tracks uiStampStatus fresh -> stale across UI commit
  git -C "$repo" checkout -b "feat/daemon-ui" --quiet
  mkdir -p "$repo/src"
  echo "export const Hero = () => <section />;" > "$repo/src/Hero.tsx"
  git -C "$repo" add src/Hero.tsx
  git -C "$repo" commit -m "feat: add Hero.tsx" --quiet

  mock_bin="$repo/.mock-impeccable"
  cat << 'EOF' > "$mock_bin"
#!/usr/bin/env bash
echo '[]'
exit 0
EOF
  chmod +x "$mock_bin"
  HARNESS_IMPECCABLE_BIN="$mock_bin" "$REPO_ROOT/scripts/stamp-gate.sh" ui --workspace "$repo" --verdict PASS --p0 0 --p1 0

  # Register workspace with daemon and wait for fresh uiStampStatus in tree-state.json
  printf '%s' "$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws]}')" | HARNESS_DAEMON_SOCK="$sock_path" "$SESSION_START" >/dev/null
  _wait_for_file_jq "$repo/.harness/cache/tree-state.json" '.uiStampStatus == "fresh" and .uiStampValid == true' 50 \
    || { echo "tree-state.json did not record fresh uiStampStatus" >&2; return 1; }

  # Commit another UI edit -> daemon refreshes tree-state.json to stale
  echo "export const Hero = () => <section>v2</section>;" > "$repo/src/Hero.tsx"
  git -C "$repo" add src/Hero.tsx
  git -C "$repo" commit -m "feat: update Hero.tsx" --quiet
  _wait_for_file_jq "$repo/.harness/cache/tree-state.json" '.uiStampStatus == "stale" and .uiStampValid == false' 50 \
    || { echo "tree-state.json did not transition uiStampStatus to stale" >&2; return 1; }
}

test_daemon_run_workflow_and_deprecation_parity() {
  trap _td_cleanup EXIT INT TERM
  local repo sock_dir data_dir sock_path dpid
  repo=$(make_temp_repo)
  git -C "$repo" checkout -b "feat/daemon-5layer" --quiet
  sock_dir=$(mktemp -d "/tmp/hd-5l.XXXXXX")
  data_dir=$(mktemp -d "${TMPDIR:-/tmp}/hd-d5l.XXXXXX")
  _TD_DIRS+=("$sock_dir" "$data_dir")
  sock_path="$sock_dir/d.sock"

  HARNESS_DAEMON_SOCK="$sock_path" \
  HARNESS_DAEMON_DATA_DIR="$data_dir" \
  HARNESS_SKIP_SHELL_PATH_SYNC="1" \
  HARNESS_DAEMON_POLL_INTERVAL_SEC="0.2" \
  python3 -B "$DAEMON_PY" >/dev/null 2>&1 &
  dpid=$!
  _TD_PIDS+=("$dpid")
  _wait_for_socket_health "$sock_path" 50 || { echo "Daemon did not start" >&2; return 1; }

  # 1. SessionStart deprecation warning parity (Argon vs Neon)
  local p_dep on_dep off_dep p_act on_act off_act
  p_dep=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], modelName: "Orchestrator (Argon)"}')
  on_dep=$(printf '%s' "$p_dep" | HARNESS_DAEMON_SOCK="$sock_path" "$SESSION_START" | jq -r '.injectSteps[0].systemMessage.systemMessage')
  off_dep=$(printf '%s' "$p_dep" | HARNESS_DISABLE_DAEMON=1 "$SESSION_START" | jq -r '.injectSteps[0].systemMessage.systemMessage')
  assert_contains "$on_dep" "[MODEL DEPRECATION WARNING]" "Daemon SessionStart warns on Orchestrator (Argon)"
  assert_contains "$off_dep" "[MODEL DEPRECATION WARNING]" "Fallback SessionStart warns on Orchestrator (Argon)"

  p_act=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], modelName: "Gemini 4 Neon (Extra)"}')
  on_act=$(printf '%s' "$p_act" | HARNESS_DAEMON_SOCK="$sock_path" "$SESSION_START" | jq -r '.injectSteps[0].systemMessage.systemMessage')
  off_act=$(printf '%s' "$p_act" | HARNESS_DISABLE_DAEMON=1 "$SESSION_START" | jq -r '.injectSteps[0].systemMessage.systemMessage')
  assert_not_contains "$on_act" "[MODEL DEPRECATION WARNING]" "Daemon SessionStart silent on Neon Extra"
  assert_not_contains "$off_act" "[MODEL DEPRECATION WARNING]" "Fallback SessionStart silent on Neon Extra"

  # 2. run_workflow pre-subagent guard parity (allow vs deny)
  local pre_subagent_guard="$REPO_ROOT/scripts/hooks/pre-subagent-guard.sh"
  local p_wf_deny p_wf_allow on_wf_deny off_wf_deny on_wf_allow off_wf_allow
  p_wf_deny=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], toolCall: {name: "run_workflow", args: {Description: "Bad tier", Script: "agent(prompt=\"x\", model=\"sonnet\")"}}}')
  on_wf_deny=$(printf '%s' "$p_wf_deny" | HARNESS_DAEMON_SOCK="$sock_path" "$pre_subagent_guard")
  off_wf_deny=$(printf '%s' "$p_wf_deny" | HARNESS_DISABLE_DAEMON=1 "$pre_subagent_guard")
  assert_json_field "$on_wf_deny" ".decision" "deny" "Daemon denies invalid run_workflow model tier"
  assert_json_field "$off_wf_deny" ".decision" "deny" "Fallback denies invalid run_workflow model tier"

  p_wf_allow=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], toolCall: {name: "run_workflow", args: {Description: "Good workflow", Script: "agent(prompt=\"x\", model=\"pro\")"}}}')
  on_wf_allow=$(printf '%s' "$p_wf_allow" | HARNESS_DAEMON_SOCK="$sock_path" "$pre_subagent_guard")
  off_wf_allow=$(printf '%s' "$p_wf_allow" | HARNESS_DISABLE_DAEMON=1 "$pre_subagent_guard")
  assert_json_field "$on_wf_allow" ".decision" "allow" "Daemon allows valid run_workflow"
  assert_json_field "$off_wf_allow" ".decision" "allow" "Fallback allows valid run_workflow"
}

test_daemon_swarm_coordinator_parity_and_quota_auto_resume_watchdog() {
  trap _td_cleanup EXIT INT TERM
  local PRE_SUBAGENT_GUARD="$REPO_ROOT/scripts/hooks/pre-subagent-guard.sh"
  local STOP_GATE="$REPO_ROOT/scripts/hooks/stop-gate.sh"
  local STAMP_GATE="$REPO_ROOT/scripts/stamp-gate.sh"
  local repo sock_dir data_dir sock_path dpid mock_dir mock_agy calls_log attempt_file
  repo=$(make_temp_repo)
  sock_dir=$(mktemp -d "/tmp/hd-swq.XXXXXX")
  data_dir=$(mktemp -d "${TMPDIR:-/tmp}/hd-swq-d.XXXXXX")
  mock_dir=$(mktemp -d "${TMPDIR:-/tmp}/hd-swq-m.XXXXXX")
  _TD_DIRS+=("$sock_dir" "$data_dir" "$mock_dir")
  sock_path="$sock_dir/d.sock"
  mock_agy="$mock_dir/mock-agy"
  calls_log="$mock_dir/agy-calls.log"
  attempt_file="$mock_dir/attempt.count"

  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: init" --quiet
  git -C "$repo" checkout -b "feat/daemon-quota" --quiet

  local started_flag release_flag
  started_flag="$mock_dir/agy.started"
  release_flag="$mock_dir/agy.release"

  cat << EOF > "$mock_agy"
#!/usr/bin/env bash
count=0
if [ -f "$attempt_file" ]; then
  count=\$(cat "$attempt_file")
fi
count=\$((count + 1))
echo "\$count" > "$attempt_file"
printf 'ATTEMPT=%s TYPESAFE=%s ARGS=%s\n' "\$count" "\${TYPESAFE_API_KEY:-}" "\$*" >> "$calls_log"
if [ "\$count" -eq 1 ]; then
  touch "$started_flag"
  tries=0
  while [ ! -f "$release_flag" ] && [ "\$tries" -lt 80 ]; do
    sleep 0.05
    tries=\$((tries + 1))
  done
  echo "429 RESOURCE_EXHAUSTED: quota still exhausted" >&2
  exit 1
fi
echo "Resumed coordinator successfully."
exit 0
EOF
  chmod +x "$mock_agy"

  TYPESAFE_API_KEY="ts_live_must_be_scrubbed" \
  HARNESS_DAEMON_SOCK="$sock_path" \
  HARNESS_DAEMON_DATA_DIR="$data_dir" \
  HARNESS_SKIP_SHELL_PATH_SYNC="1" \
  HARNESS_DAEMON_POLL_INTERVAL_SEC="0.1" \
  HARNESS_DAEMON_WORKSPACE_TTL_SEC="0.4" \
  HARNESS_SWARM_QUOTA_DEFAULT_PROBE_SEC="0.2" \
  HARNESS_SWARM_QUOTA_MAX_BACKOFF_SEC="0.4" \
  HARNESS_SWARM_STALE_RESUMING_SEC="0.3" \
  python3 -B "$DAEMON_PY" >/dev/null 2>&1 &
  dpid=$!
  _TD_PIDS+=("$dpid")
  _wait_for_socket_health "$sock_path" 50 || { echo "Daemon did not start" >&2; return 1; }

  # Restart daemon with HARNESS_AGY_BIN exported cleanly for all child tests:
  kill -TERM "$dpid" 2>/dev/null || true
  wait "$dpid" 2>/dev/null || true
  TYPESAFE_API_KEY="ts_live_must_be_scrubbed" \
  HARNESS_DAEMON_SOCK="$sock_path" \
  HARNESS_DAEMON_DATA_DIR="$data_dir" \
  HARNESS_SKIP_SHELL_PATH_SYNC="1" \
  HARNESS_DAEMON_POLL_INTERVAL_SEC="0.1" \
  HARNESS_DAEMON_WORKSPACE_TTL_SEC="0.4" \
  HARNESS_SWARM_QUOTA_DEFAULT_PROBE_SEC="0.2" \
  HARNESS_SWARM_QUOTA_MAX_BACKOFF_SEC="0.4" \
  HARNESS_SWARM_STALE_RESUMING_SEC="0.3" \
  HARNESS_AGY_BIN="$mock_agy" \
  python3 -B "$DAEMON_PY" >/dev/null 2>&1 &
  dpid=$!
  _TD_PIDS+=("$dpid")
  _wait_for_socket_health "$sock_path" 50 || { echo "Daemon did not restart" >&2; return 1; }

  # 1. Parity: Coordinator-Only pre-edit, pre-command, and pre-subagent under daemon ON vs cold OFF (full JSON equality)
  printf '%s' "$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], conversationId: "conv-dq", toolCall: {name: "swarm", args: {action: "title", title: "Quota Swarm"}}}')" \
    | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_SUBAGENT_GUARD" >/dev/null

  local p_ed p_cmd p_sub on_ed off_ed on_cmd off_cmd on_sub off_sub
  p_ed=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], conversationId: "conv-dq", toolCall: {name: "write_file", args: {Path: "src/X.ts", Content: "export const x=1;"}}}')
  p_cmd=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], conversationId: "conv-dq", toolCall: {name: "run_command", args: {CommandLine: "npm test"}}}')
  p_sub=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], conversationId: "conv-dq", toolCall: {name: "invoke_subagent", args: {TypeName: "research", Role: "R", Prompt: "Scan"}}}')

  on_ed=$(printf '%s' "$p_ed" | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_EDIT_GUARD" | jq -c .)
  off_ed=$(printf '%s' "$p_ed" | HARNESS_DISABLE_DAEMON="1" "$PRE_EDIT_GUARD" | jq -c .)
  assert_json_field "$on_ed" ".decision" "deny"
  assert_eq "$off_ed" "$on_ed" "pre-edit Coordinator-Only parity"

  on_cmd=$(printf '%s' "$p_cmd" | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_COMMAND_GUARD" | jq -c .)
  off_cmd=$(printf '%s' "$p_cmd" | HARNESS_DISABLE_DAEMON="1" "$PRE_COMMAND_GUARD" | jq -c .)
  assert_json_field "$on_cmd" ".decision" "deny"
  assert_eq "$off_cmd" "$on_cmd" "pre-command Coordinator-Only parity"

  on_sub=$(printf '%s' "$p_sub" | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_SUBAGENT_GUARD" | jq -c .)
  off_sub=$(printf '%s' "$p_sub" | HARNESS_DISABLE_DAEMON="1" "$PRE_SUBAGENT_GUARD" | jq -c .)
  assert_json_field "$on_sub" ".decision" "deny"
  assert_eq "$off_sub" "$on_sub" "pre-subagent Coordinator-Only parity"

  # 2. stamp-gate.sh swarm-quota pause from relative --workspace . arms daemon automatically,
  #    in-flight deduplication holds attempt count at 1 behind barrier past stale threshold, and attempt 2 resumes.
  printf '%s' "$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], conversationId: "conv-dq", toolCall: {name: "swarm", args: {action: "add", name: "worker-1", workspace: "share", brief: "Work."}}}')" \
    | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_SUBAGENT_GUARD" >/dev/null

  (cd "$repo" && HARNESS_DAEMON_SOCK="$sock_path" "$STAMP_GATE" swarm-quota pause --workspace "." --conversation-id "conv-dq" --wait-seconds 0 --buffer-seconds 0 --window 5h --model "gemini-4-neon-high" --reason "5-hour quota" >/dev/null)

  local tries_b=0
  while [ ! -f "$started_flag" ] && [ "$tries_b" -lt 60 ]; do
    sleep 0.05
    tries_b=$((tries_b + 1))
  done
  [ -f "$started_flag" ] || { echo "stamp-gate.sh pause --workspace . did not trigger daemon auto-resume" >&2; return 1; }

  # I6: Wait deterministically for >=4 completed watcherCycles AND >=0.35s (past 0.3s stale threshold) behind barrier
  local c0 now_c cur_cyc waited_steps
  c0=$(curl -fsS --unix-socket "$sock_path" "http://localhost/health" | jq -r '.watcherCycles // 0')
  waited_steps=0
  while [ "$waited_steps" -lt 40 ]; do
    sleep 0.1
    waited_steps=$((waited_steps + 1))
    cur_cyc=$(curl -fsS --unix-socket "$sock_path" "http://localhost/health" | jq -r '.watcherCycles // 0')
    if [ "$cur_cyc" -ge $((c0 + 4)) ] && [ "$waited_steps" -ge 4 ]; then
      break
    fi
  done
  [ "$cur_cyc" -ge $((c0 + 4)) ] || { echo "Expected >= 4 watcherCycles past stale threshold (c0=$c0, cur=$cur_cyc)" >&2; return 1; }
  local health_json
  health_json=$(curl -fsS --unix-socket "$sock_path" "http://localhost/health")
  assert_json_field "$health_json" ".quotaWaits" "1"
  assert_eq "1" "$(cat "$attempt_file")" "In-flight deduplication must hold attempt count at 1 past stale threshold while barrier is held"

  # Release barrier -> attempt 1 fails with 429 -> backoff -> attempt 2 succeeds -> status == resumed
  touch "$release_flag"
  local quota_file="$repo/.harness/state/swarm/swarm-quota-wait.json"
  _wait_for_file_jq "$quota_file" '.status == "resumed" and .attemptCount == 2' 60 \
    || { echo "Daemon quota watchdog failed to auto-resume on attempt 2: $(cat "$quota_file" 2>/dev/null || true)" >&2; return 1; }

  local agy_log
  agy_log=$(cat "$calls_log")
  assert_contains "$agy_log" "--conversation conv-dq"
  assert_contains "$agy_log" "[SWARM_QUOTA_AUTO_RESUME]"
  assert_contains "$agy_log" "@worker-1"
  assert_not_contains "$agy_log" "ts_live_must_be_scrubbed" "Daemon must scrub TYPESAFE_API_KEY before invoking agy"

  # 3. Registry reload across daemon restart retains workspace past expired TTL when quota wait is active (I7 isolated)
  HARNESS_DISABLE_DAEMON=1 "$STAMP_GATE" swarm-quota pause --workspace "$repo" --conversation-id "conv-dq" --resume-at "2031-01-01T00:00:00Z" --buffer-seconds 0 --window weekly >/dev/null
  kill -TERM "$dpid" 2>/dev/null || true
  wait "$dpid" 2>/dev/null || true
  local real_repo
  real_repo=$(cd "$repo" && pwd -P)
  jq --arg ws "$real_repo" '.workspaces[$ws].lastSeenAt = 1' "$data_dir/workspaces.json" > "$data_dir/workspaces.json.tmp" && mv "$data_dir/workspaces.json.tmp" "$data_dir/workspaces.json"

  HARNESS_DAEMON_SOCK="$sock_path" \
  HARNESS_DAEMON_DATA_DIR="$data_dir" \
  HARNESS_SKIP_SHELL_PATH_SYNC="1" \
  HARNESS_DAEMON_POLL_INTERVAL_SEC="0.1" \
  HARNESS_DAEMON_WORKSPACE_TTL_SEC="2.0" \
  HARNESS_SWARM_QUOTA_DEFAULT_PROBE_SEC="0.2" \
  HARNESS_SWARM_STALE_RESUMING_SEC="0.3" \
  HARNESS_AGY_BIN="$mock_agy" \
  python3 -B "$DAEMON_PY" >/dev/null 2>&1 &
  dpid=$!
  _TD_PIDS+=("$dpid")
  _wait_for_socket_health "$sock_path" 50 || { echo "Daemon failed restart" >&2; return 1; }
  health_json=$(curl -fsS --unix-socket "$sock_path" "http://localhost/health")
  assert_json_field "$health_json" ".activeWorkspaces" "1" "Registry reload must keep workspace with active quota wait even when TTL expired"
  assert_json_field "$health_json" ".quotaWaits" "1"

  # 4. Stale 'resuming' state recovery & I5 lastSeenAt retention refresh + malformed nextProbeEpoch resilience
  jq '.status = "resuming" | .resumingStartedAtEpoch = 1 | .resumingToken = "stale-tok"' "$quota_file" > "$quota_file.tmp" && mv "$quota_file.tmp" "$quota_file"
  _wait_for_file_jq "$quota_file" '.status == "resumed"' 50 \
    || { echo "Daemon failed to recover stale resuming state: $(cat "$quota_file" 2>/dev/null || true)" >&2; return 1; }
  _wait_for_file_jq "$data_dir/workspaces.json" ".workspaces[\"$real_repo\"].lastSeenAt > 1000000000" 30 \
    || { echo "Daemon must refresh & persist lastSeenAt after resume: $(cat "$data_dir/workspaces.json" 2>/dev/null || true)" >&2; return 1; }

  jq '.status = "waiting" | .nextProbeEpoch = "not-a-number"' "$quota_file" > "$quota_file.tmp" && mv "$quota_file.tmp" "$quota_file"
  _wait_for_file_jq "$quota_file" '.status == "resumed"' 50 \
    || { echo "Malformed nextProbeEpoch broke watcher_loop" >&2; return 1; }
  health_json=$(curl -fsS --unix-socket "$sock_path" "http://localhost/health")
  assert_json_field "$health_json" ".status" "ok"

  # 5. /event/swarm-quota-wait edge responses: invalid workspace (400) & .harness-ignore (ignored: true)
  local bad_status ign_repo ign_resp
  bad_status=$(curl -s -o /dev/null -w "%{http_code}" --unix-socket "$sock_path" -H "Content-Type: application/json" -X POST -d '{"workspace":""}' "http://localhost/event/swarm-quota-wait")
  assert_eq "400" "$bad_status"
  ign_repo=$(make_temp_repo)
  touch "$ign_repo/.harness-ignore"
  ign_resp=$(jq -nc --arg ws "$ign_repo" '{workspace: $ws}' | curl -fsS --unix-socket "$sock_path" -H "Content-Type: application/json" -X POST --data-binary @- "http://localhost/event/swarm-quota-wait")
  assert_json_field "$ign_resp" ".ignored" "true"
  assert_json_field "$ign_resp" ".armed" "false"

  # 6. Verify Stop hook over daemon /hook/stop-gate also arms quota wait cleanly
  "$STAMP_GATE" swarm-quota clear --workspace "$repo" >/dev/null
  local stop_out
  stop_out=$(jq -nc --arg ws "$repo" '{
    workspacePaths: [$ws],
    conversationId: "conv-dq",
    modelName: "gemini-4-neon-high",
    terminationReason: "ERROR",
    error: "RESOURCE_EXHAUSTED: 5-hour quota exceeded"
  }' | HARNESS_DAEMON_SOCK="$sock_path" "$STOP_GATE" | jq -c .)
  assert_eq "{}" "$stop_out"
  assert_json_field "$quota_file" ".source" "stop-error"
  _wait_for_file_jq "$quota_file" '.status == "resumed"' 50 \
    || { echo "Daemon did not auto-resume Stop(ERROR) quota wait: $(cat "$quota_file" 2>/dev/null || true)" >&2; return 1; }

  # 7. I8: Isolated /event/swarm-quota-wait arming on unregistered workspaces under 30s poll interval
  local long_sock_dir long_data_dir long_sock long_dpid always_ok_agy
  long_sock_dir=$(mktemp -d "/tmp/hd-swq-ev.XXXXXX")
  long_data_dir=$(mktemp -d "${TMPDIR:-/tmp}/hd-swq-evd.XXXXXX")
  _TD_DIRS+=("$long_sock_dir" "$long_data_dir")
  long_sock="$long_sock_dir/d.sock"
  always_ok_agy="$mock_dir/always-ok-agy"
  cat << 'EOF' > "$always_ok_agy"
#!/usr/bin/env bash
echo "Quota restored."
exit 0
EOF
  chmod +x "$always_ok_agy"

  HARNESS_DAEMON_SOCK="$long_sock" \
  HARNESS_DAEMON_DATA_DIR="$long_data_dir" \
  HARNESS_SKIP_SHELL_PATH_SYNC="1" \
  HARNESS_DAEMON_POLL_INTERVAL_SEC="30" \
  HARNESS_SWARM_QUOTA_DEFAULT_PROBE_SEC="0.2" \
  HARNESS_AGY_BIN="$always_ok_agy" \
  python3 -B "$DAEMON_PY" >/dev/null 2>&1 &
  long_dpid=$!
  _TD_PIDS+=("$long_dpid")
  _wait_for_socket_health "$long_sock" 50 || { echo "Long-poll daemon failed to start" >&2; return 1; }

  local unreg_a unreg_b ev_raw ev_code ev_body
  unreg_a=$(make_temp_repo)
  HARNESS_DISABLE_DAEMON=1 "$STAMP_GATE" swarm-quota pause --workspace "$unreg_a" --conversation-id "conv-eva" --wait-seconds 600 --buffer-seconds 0 >/dev/null
  ev_raw=$(jq -nc --arg ws "$unreg_a" '{workspace: $ws}' | curl -s -w '\n%{http_code}' --unix-socket "$long_sock" -H "Content-Type: application/json" -X POST --data-binary @- "http://localhost/event/swarm-quota-wait")
  ev_code=$(printf '%s\n' "$ev_raw" | tail -n 1)
  ev_body=$(printf '%s\n' "$ev_raw" | sed '$d')
  assert_eq "202" "$ev_code" "POST /event/swarm-quota-wait must return 202 for valid active workspace"
  assert_json_field "$ev_body" ".armed" "true"

  unreg_b=$(make_temp_repo)
  (cd "$unreg_b" && HARNESS_DAEMON_SOCK="$long_sock" "$STAMP_GATE" swarm-quota pause --workspace "." --conversation-id "conv-evb" --wait-seconds 0 --buffer-seconds 0 >/dev/null)
  _wait_for_file_jq "$unreg_b/.harness/state/swarm/swarm-quota-wait.json" '.status == "resumed"' 40 \
    || { echo "stamp-gate pause must immediately wake daemon via /event/swarm-quota-wait even under 30s poll" >&2; return 1; }

  # I3: /hook/stop-gate on_swarm_quota_wait immediately wakes 30s-poll daemon and auto-resumes within 4s
  local unreg_c stop_c_out
  unreg_c=$(make_temp_repo)
  HARNESS_DISABLE_DAEMON=1 "$STAMP_GATE" swarm-coordinator on --workspace "$unreg_c" --conversation-id "conv-evc" --title "Stop Callback" >/dev/null
  stop_c_out=$(jq -nc --arg ws "$unreg_c" '{
    workspacePaths: [$ws],
    conversationId: "conv-evc",
    terminationReason: "ERROR",
    error: "RESOURCE_EXHAUSTED: 5-hour quota exceeded"
  }' | HARNESS_DAEMON_SOCK="$long_sock" "$STOP_GATE" | jq -c .)
  assert_eq "{}" "$stop_c_out"
  _wait_for_file_jq "$unreg_c/.harness/state/swarm/swarm-quota-wait.json" '.status == "resumed"' 40 \
    || { echo "/hook/stop-gate callback did not wake 30s-poll daemon to auto-resume within 4s: $(cat "$unreg_c/.harness/state/swarm/swarm-quota-wait.json" 2>/dev/null || true)" >&2; return 1; }
}

run_tests "$@"
