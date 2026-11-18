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
  assert_eq "0o700" "$dir_perm" "Socket dir must have 0700 permissions"
  assert_eq "0o600" "$sock_perm" "Socket file must have 0600 permissions"

  local health_json
  health_json=$(curl -fsS --unix-socket "$sock_path" "http://localhost/health")
  assert_json_field "$health_json" ".status" "ok"
  assert_json_field "$health_json" ".pid" "$dpid1"

  HARNESS_DAEMON_SOCK="$sock_path" \
  HARNESS_DAEMON_DATA_DIR="$data_dir" \
  HARNESS_SKIP_SHELL_PATH_SYNC="1" \
  HARNESS_DAEMON_STANDBY_INTERVAL_SEC="0.2" \
  python3 -B "$DAEMON_PY" >/dev/null 2>&1 &
  dpid2=$!
  _TD_PIDS+=("$dpid2")

  sleep 0.5
  kill -0 "$dpid2" 2>/dev/null || { echo "Secondary daemon must stay alive in passive standby" >&2; return 1; }

  health_json=$(curl -fsS --unix-socket "$sock_path" "http://localhost/health")
  assert_json_field "$health_json" ".pid" "$dpid1"

  kill -TERM "$dpid2" 2>/dev/null || true
  wait "$dpid2" 2>/dev/null || true

  kill -TERM "$dpid1" 2>/dev/null || true
  wait "$dpid1" 2>/dev/null || true

  [ ! -S "$sock_path" ] || { echo "Socket file should be unlinked on graceful SIGTERM" >&2; return 1; }
  [ ! -f "$sock_dir/d.pid" ] || { echo "PID file should be removed on graceful SIGTERM" >&2; return 1; }
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
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
s.listen(8)
while True:
    conn, _ = s.accept()
    time.sleep(2.0)
    conn.close()
' "$sock_hang" >/dev/null 2>&1 &
  pid_hang=$!
  _TD_PIDS+=("$pid_hang")

  python3 -B -c '
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
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

  local call_log="$repo/.mock-graphify-calls.log"
  local mock_graphify="$repo/mock-graphify.sh"
  cat << EOF > "$mock_graphify"
#!/usr/bin/env bash
echo "START:\$(date +%s)" >> "$call_log"
sleep 0.6
echo "END:\$*" >> "$call_log"
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

  curl -fsS --unix-socket "$sock_path" -H "Content-Type: application/json" -X POST \
    --data-binary "$(jq -nc --arg ws "$repo" '{workspace: $ws, reason: "burst1"}')" \
    "http://localhost/event/graphify" >/dev/null
  curl -fsS --unix-socket "$sock_path" -H "Content-Type: application/json" -X POST \
    --data-binary "$(jq -nc --arg ws "$repo" '{workspace: $ws, reason: "burst2"}')" \
    "http://localhost/event/graphify" >/dev/null

  _wait_for_file_jq "$repo/.harness/cache/graphify-status.json" '.state == "succeeded"' 60 || {
    echo "graphify-status.json did not reach succeeded" >&2
    return 1
  }

  local start_count
  start_count=$(grep -c '^START:' "$call_log" || true)
  if [ "$start_count" -lt 1 ] || [ "$start_count" -gt 2 ]; then
    echo "Expected 1 or 2 coalesced graphify runs, got $start_count" >&2
    return 1
  fi
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
  _wait_for_file_jq "$tree_cache" '.canonStampValid == true and .securityStampValid == true' 40 || {
    echo "tree-state.json should report fresh stamps" >&2
    return 1
  }

  echo "export const v = 2;" > "$repo/app.ts"
  git -C "$repo" add app.ts
  git -C "$repo" commit -m "feat: app v2" --quiet

  local new_head
  new_head=$(git -C "$repo" rev-parse HEAD)
  _wait_for_file_jq "$tree_cache" ".headOid == \"$new_head\" and .canonStampStatus == \"stale\"" 50 || {
    echo "tree-state.json did not invalidate stale stamps after new commit" >&2
    return 1
  }

  local start_out start_msg
  start_out=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws]}' | HARNESS_DAEMON_SOCK="$sock_path" "$SESSION_START")
  start_msg=$(printf '%s' "$start_out" | jq -r '.injectSteps[0].systemMessage.systemMessage')
  assert_contains "$start_msg" "[DAEMON STAMP NOTICE]" "SessionStart must warn when stamps are stale"

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

  local old_sha
  old_sha=$(jq -r '.canonStampSha' "$tree_cache")
  jq -c --arg sha "$old_sha" '.codeTreeSha = $sha | .canonStampValid = true | .securityStampValid = true' "$tree_cache" > "$tree_cache.tmp"
  mv "$tree_cache.tmp" "$tree_cache"

  local pr_out
  pr_out=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: "gh pr create --fill"}}}' \
    | HARNESS_DAEMON_SOCK="$sock_path" "$PRE_COMMAND_GUARD")
  assert_json_field "$pr_out" ".decision" "deny" "Stale tree-state cache must never allow gh pr create"
  assert_contains "$(printf '%s' "$pr_out" | jq -r '.reason')" "PR stamps verification failed" "PR deny reason must reach stamp verification"
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

run_tests "$@"
