#!/usr/bin/env bash
# Alps AGY Harness - PreToolUse & PostToolUse Command Hook Tests (test-command-hooks.sh)
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-helpers.sh"

PRE_COMMAND_GUARD="$REPO_ROOT/scripts/hooks/pre-command-guard.sh"
POST_COMMAND_HOOKS="$REPO_ROOT/scripts/hooks/post-command-hooks.sh"
STAMP_GATE="$REPO_ROOT/scripts/stamp-gate.sh"

test_infinite_mobile_log_streams_blocked_but_snapshot_allowed() {
  [ -x "$PRE_COMMAND_GUARD" ] || { echo "pre-command-guard.sh missing or not executable: $PRE_COMMAND_GUARD" >&2; return 1; }

  local repo
  repo=$(make_temp_repo)

  # 1. adb logcat without -d -> deny
  local p_adb_deny
  p_adb_deny=$(jq -nc --arg ws "$repo" --arg cmd "adb logcat" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_adb_deny
  out_adb_deny=$(printf '%s' "$p_adb_deny" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_adb_deny" ".decision" "deny" "adb logcat must be denied"
  local reason_adb
  reason_adb=$(printf '%s' "$out_adb_deny" | jq -r '.reason // empty')
  assert_contains "$reason_adb" "scripts/mobile-logs.sh" "Reason must suggest scripts/mobile-logs.sh"

  # 2. adb with target device flag without -d -> deny
  local p_adb_dev
  p_adb_dev=$(jq -nc --arg ws "$repo" --arg cmd "adb -s emulator-5554 logcat" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_adb_dev
  out_adb_dev=$(printf '%s' "$p_adb_dev" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_adb_dev" ".decision" "deny" "adb -s emulator-5554 logcat must be denied"

  # 3. xcrun simctl spawn booted log stream without --timeout / --last -> deny
  local p_simctl_deny
  p_simctl_deny=$(jq -nc --arg ws "$repo" --arg cmd "xcrun simctl spawn booted log stream" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_simctl_deny
  out_simctl_deny=$(printf '%s' "$p_simctl_deny" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_simctl_deny" ".decision" "deny" "xcrun simctl log stream must be denied"
  local reason_simctl
  reason_simctl=$(printf '%s' "$out_simctl_deny" | jq -r '.reason // empty')
  assert_contains "$reason_simctl" "scripts/mobile-logs.sh" "Reason must suggest scripts/mobile-logs.sh"

  # 4. simctl log stream without xcrun -> deny
  local p_bare_simctl
  p_bare_simctl=$(jq -nc --arg ws "$repo" --arg cmd "simctl log stream" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_bare_simctl
  out_bare_simctl=$(printf '%s' "$p_bare_simctl" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_bare_simctl" ".decision" "deny" "simctl log stream must be denied"

  # 5. adb logcat with -d and --pid -> allow
  local p_adb_allow
  p_adb_allow=$(jq -nc --arg ws "$repo" --arg cmd "adb logcat -d --pid=123" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_adb_allow
  out_adb_allow=$(printf '%s' "$p_adb_allow" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_adb_allow" ".decision" "allow" "adb logcat -d must be allowed"

  # 6. xcrun simctl with --timeout -> allow
  local p_simctl_allow
  p_simctl_allow=$(jq -nc --arg ws "$repo" --arg cmd "xcrun simctl spawn booted log stream --timeout 5" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_simctl_allow
  out_simctl_allow=$(printf '%s' "$p_simctl_allow" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_simctl_allow" ".decision" "allow" "simctl log stream with --timeout must be allowed"

  # 7. simctl with --last -> allow
  local p_simctl_last
  p_simctl_last=$(jq -nc --arg ws "$repo" --arg cmd "simctl log stream --last 2m" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_simctl_last
  out_simctl_last=$(printf '%s' "$p_simctl_last" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_simctl_last" ".decision" "allow" "simctl log stream with --last must be allowed"
}

test_quoted_commit_message_does_not_trigger_gates() {
  [ -x "$PRE_COMMAND_GUARD" ] || { echo "pre-command-guard.sh missing or not executable: $PRE_COMMAND_GUARD" >&2; return 1; }

  local repo
  repo=$(make_temp_repo)

  # 1. Commit message mentioning dangerous commands in quotes
  local p_commit
  p_commit=$(jq -nc --arg ws "$repo" --arg cmd 'git commit -m "chore: ready for gh pr create and adb logcat"' \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_commit
  out_commit=$(printf '%s' "$p_commit" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_commit" ".decision" "allow" "Quoted commit message mentioning gates must be allowed"

  # 2. Echo with npm install
  local p_echo
  p_echo=$(jq -nc --arg ws "$repo" --arg cmd 'echo "npm install foo"' \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_echo
  out_echo=$(printf '%s' "$p_echo" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_echo" ".decision" "allow" "Echoing package install command must be allowed"

  # 3. Commit message mentioning push to main
  local p_commit2
  p_commit2=$(jq -nc --arg ws "$repo" --arg cmd 'git commit -m "git push origin main fixed"' \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_commit2
  out_commit2=$(printf '%s' "$p_commit2" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_commit2" ".decision" "allow" "Quoted commit message mentioning push to main must be allowed"
}

test_chained_package_install_requires_context7_stamp() {
  [ -x "$PRE_COMMAND_GUARD" ] || { echo "pre-command-guard.sh missing or not executable: $PRE_COMMAND_GUARD" >&2; return 1; }

  local repo
  repo=$(make_temp_repo)
  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: init" --quiet
  git -C "$repo" checkout -b "feature/pkg-test" --quiet

  # 1. Bare npm ci and npm install are always allowed
  local p_bare_ci
  p_bare_ci=$(jq -nc --arg ws "$repo" --arg cmd "npm ci" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_bare_ci
  out_bare_ci=$(printf '%s' "$p_bare_ci" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_bare_ci" ".decision" "allow" "Bare npm ci must be allowed"

  local p_bare_install
  p_bare_install=$(jq -nc --arg ws "$repo" --arg cmd "npm install" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_bare_install
  out_bare_install=$(printf '%s' "$p_bare_install" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_bare_install" ".decision" "allow" "Bare npm install must be allowed"

  # 2. Chained npm install with version and flags without stamp -> deny
  local p_pkg_deny
  p_pkg_deny=$(jq -nc --arg ws "$repo" --arg cmd "cd app && npm install zod@^3.23.0 --save-dev" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_pkg_deny
  out_pkg_deny=$(printf '%s' "$p_pkg_deny" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_pkg_deny" ".decision" "deny" "Unverified package install must be denied"
  local reason_pkg
  reason_pkg=$(printf '%s' "$out_pkg_deny" | jq -r '.reason // empty')
  assert_contains "$reason_pkg" "zod" "Reason must name unverified package 'zod'"
  assert_contains "$reason_pkg" "context7" "Reason must mention context7"

  # 3. Stamp context7 for zod
  "$STAMP_GATE" context7 --package zod --version 3.23.8 --source greenfield-latest --workspace "$repo"

  # 4. Same chained npm install now allowed
  local out_pkg_allow
  out_pkg_allow=$(printf '%s' "$p_pkg_deny" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_pkg_allow" ".decision" "allow" "Verified package install must be allowed"

  # 5. Scoped package @angular/core@19.0.0
  local p_scoped_deny
  p_scoped_deny=$(jq -nc --arg ws "$repo" --arg cmd "pnpm add @angular/core@19.0.0" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_scoped_deny
  out_scoped_deny=$(printf '%s' "$p_scoped_deny" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_scoped_deny" ".decision" "deny" "Unverified scoped package must be denied"
  local reason_scoped
  reason_scoped=$(printf '%s' "$out_scoped_deny" | jq -r '.reason // empty')
  assert_contains "$reason_scoped" "@angular/core" "Reason must name unverified scoped package"

  # 6. Verify package via ## Global Constraints in docs/superpowers/specs/*.md
  mkdir -p "$repo/docs/superpowers/specs"
  cat << 'EOF' > "$repo/docs/superpowers/specs/01-auth-spec.md"
# Spec: Auth

## Global Constraints

- **Packages:**
  - `@angular/core`: Angular framework version 19
  - `express`: Minimalist web framework
- **Limits:** Query results return at most 100 rows per page.
EOF

  local out_scoped_allow
  out_scoped_allow=$(printf '%s' "$p_scoped_deny" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_scoped_allow" ".decision" "allow" "Package declared in Global Constraints must be allowed"

  # 6b. Short package name 'ws' must NOT false-match 'rows' in Global Constraints
  local p_ws_deny
  p_ws_deny=$(jq -nc --arg ws "$repo" --arg cmd "npm install ws" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_ws_deny
  out_ws_deny=$(printf '%s' "$p_ws_deny" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_ws_deny" ".decision" "deny" "Short package 'ws' must not substring-match 'rows' in Global Constraints"
  assert_contains "$(printf '%s' "$out_ws_deny" | jq -r '.reason')" "ws"

  # 7. dotnet add package Foo -> deny, dotnet package add Foo -> deny, dotnet package search Foo -> allow
  local p_dotnet_search
  p_dotnet_search=$(jq -nc --arg ws "$repo" --arg cmd "dotnet package search Serilog" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_dotnet_search
  out_dotnet_search=$(printf '%s' "$p_dotnet_search" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_dotnet_search" ".decision" "allow" "dotnet package search Serilog must be allowed without context7 stamp"

  local p_dotnet_pkg_add
  p_dotnet_pkg_add=$(jq -nc --arg ws "$repo" --arg cmd "dotnet package add Serilog" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_dotnet_pkg_add
  out_dotnet_pkg_add=$(printf '%s' "$p_dotnet_pkg_add" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_dotnet_pkg_add" ".decision" "deny" "dotnet package add Serilog must be denied before Context7 stamp"
  assert_contains "$(printf '%s' "$out_dotnet_pkg_add" | jq -r '.reason')" "Serilog"

  local p_dotnet_deny
  p_dotnet_deny=$(jq -nc --arg ws "$repo" --arg cmd "dotnet add app.csproj package Serilog.AspNetCore --version 8.0.0" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_dotnet_deny
  out_dotnet_deny=$(printf '%s' "$p_dotnet_deny" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_dotnet_deny" ".decision" "deny" "Unverified dotnet package must be denied"
  assert_contains "$(printf '%s' "$out_dotnet_deny" | jq -r '.reason')" "Serilog.AspNetCore"
}

test_pr_only_main_blocks_direct_push_and_local_merge_when_remote_exists() {
  [ -x "$PRE_COMMAND_GUARD" ] || { echo "pre-command-guard.sh missing or not executable: $PRE_COMMAND_GUARD" >&2; return 1; }

  local repo
  repo=$(make_temp_repo)
  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: init" --quiet

  # Add dummy origin remote
  git -C "$repo" remote add origin "https://github.com/example/alps-repo.git"

  # 1. git push origin main -> deny
  local p_push_main
  p_push_main=$(jq -nc --arg ws "$repo" --arg cmd "git push origin main" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_push_main
  out_push_main=$(printf '%s' "$p_push_main" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_push_main" ".decision" "deny" "git push origin main must be denied"

  # 2. git push origin HEAD:main -> deny
  local p_push_refspec
  p_push_refspec=$(jq -nc --arg ws "$repo" --arg cmd "git push origin HEAD:main" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_push_refspec
  out_push_refspec=$(printf '%s' "$p_push_refspec" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_push_refspec" ".decision" "deny" "git push origin HEAD:main must be denied"

  # 3. Active branch is main, bare git push -> deny
  local p_push_bare
  p_push_bare=$(jq -nc --arg ws "$repo" --arg cmd "git push" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_push_bare
  out_push_bare=$(printf '%s' "$p_push_bare" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_push_bare" ".decision" "deny" "Bare git push while on main must be denied"

  # 4. Active branch is main, git merge feat-x -> deny
  local p_merge_feat
  p_merge_feat=$(jq -nc --arg ws "$repo" --arg cmd "git merge feat-x" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_merge_feat
  out_merge_feat=$(printf '%s' "$p_merge_feat" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_merge_feat" ".decision" "deny" "git merge into main must be denied when remote exists"

  # 5. Active branch is main, git merge --ff-only origin/main -> allow
  local p_merge_ff
  p_merge_ff=$(jq -nc --arg ws "$repo" --arg cmd "git merge --ff-only origin/main" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_merge_ff
  out_merge_ff=$(printf '%s' "$p_merge_ff" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_merge_ff" ".decision" "allow" "git merge --ff-only must be allowed"

  # 6. On feature branch, git push origin feature-x -> allow
  git -C "$repo" checkout -b "feature-x" --quiet
  local p_push_feat
  p_push_feat=$(jq -nc --arg ws "$repo" --arg cmd "git push origin feature-x" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_push_feat
  out_push_feat=$(printf '%s' "$p_push_feat" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_push_feat" ".decision" "allow" "git push feature branch must be allowed"
}

test_hard_pr_gate_all_five_checks() {
  [ -x "$PRE_COMMAND_GUARD" ] || { echo "pre-command-guard.sh missing or not executable: $PRE_COMMAND_GUARD" >&2; return 1; }

  local repo
  repo=$(make_temp_repo)
  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: init" --quiet

  git -C "$repo" checkout -b "feature/hard-gate" --quiet

  local p_pr_create
  p_pr_create=$(jq -nc --arg ws "$repo" --arg cmd "gh pr create --fill" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')

  # Check 1: Dirty working tree -> deny
  echo "uncommitted change" > "$repo/dirty.txt"
  local out_dirty
  out_dirty=$(printf '%s' "$p_pr_create" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_dirty" ".decision" "deny" "Dirty tree must deny gh pr create"
  assert_contains "$(printf '%s' "$out_dirty" | jq -r '.reason')" "dirty" "Reason must mention dirty tree"
  rm -f "$repo/dirty.txt"

  # Check 2: Missing walkthrough or < 2 Mermaid diagrams -> deny
  echo "console.log('work');" > "$repo/src.js"
  git -C "$repo" add src.js
  git -C "$repo" commit -m "feat: add src" --quiet

  local out_no_walkthrough
  out_no_walkthrough=$(printf '%s' "$p_pr_create" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_no_walkthrough" ".decision" "deny" "Missing walkthrough must deny gh pr create"
  assert_contains "$(printf '%s' "$out_no_walkthrough" | jq -r '.reason')" "walkthrough"

  # Add walkthrough with only 1 mermaid block -> deny
  mkdir -p "$repo/docs/walkthroughs"
  cat << 'EOF' > "$repo/docs/walkthroughs/01-feature.md"
# Feature Walkthrough

```mermaid
graph TD;
  A-->B;
```
EOF
  git -C "$repo" add docs/walkthroughs/01-feature.md
  git -C "$repo" commit -m "docs: 1 mermaid" --quiet

  local out_1_mermaid
  out_1_mermaid=$(printf '%s' "$p_pr_create" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_1_mermaid" ".decision" "deny" "Walkthrough with < 2 Mermaid blocks must deny"
  assert_contains "$(printf '%s' "$out_1_mermaid" | jq -r '.reason')" "Mermaid"

  # Fix walkthrough with 2 mermaid blocks, deep per-file analysis, and glossary
  cat << 'EOF' > "$repo/docs/walkthroughs/01-feature.md"
# Pull Request Mühendislik Rehberi: Çekirdek Başlangıç ve Mimari Kanon

## 1. Problem Bağlamı ve Mimari Kararlar
Uygulama giriş noktasını ve kanon mimari dokümantasyonunu standartlaştırmak için temel modül ve mimari referans dosyası oluşturuldu.

## 2. Mimari ve Veri Akışı Diyagramları
```mermaid
flowchart LR
  Entry["src.js (Bootstrap)"] --> ArchDoc["docs/canon/arch.md"]
```

```mermaid
sequenceDiagram
  Developer->>Entry: node src.js
  Entry-->>Developer: stdout ("work")
```

## 3. Dosya Bazlı Değişiklik Analizi

### `src.js` — [ÜRETİLDİ] (`Presentation / Entry`)
- **Ne Değişti / Ne Üretildi?:** Uygulamanın çalışma zamanı başlangıç çıktısını üreten `src.js` giriş betiği eklendi ve standart çıktı akışı yapılandırıldı.
- **Neden Değişti / Neden Üretildi?:** PR kapısı doğrulama hattında çalıştırılabilir minimal bir kaynak dosya giriş noktası sağlamak için üretildi.

### `docs/canon/arch.md` — [ÜRETİLDİ] (`Domain Canon`)
- **Ne Değişti / Ne Üretildi?:** Sistemin katman sınırlarını ve temel mimari sözleşmelerini tanımlayan `docs/canon/arch.md` referans dokümanı eklendi.
- **Neden Değişti / Neden Üretildi?:** Geliştiricilerin ve denetçi ajanların katman kurallarını tek bir kanonik kaynaktan doğrulayabilmesi için üretildi.

## 4. Kritik İş Mantığı, Kenar Durumlar (Edge Cases) ve Hata Yönetimi
Başlangıç betiği yan etkisiz çalışır; eksik argüman durumunda sıfır çıkış kodu korunur.

## 5. Somut Doğrulama Kanıtları
`test-command-hooks.sh` altındaki 5 aşamalı PR kapısı senaryosu ile tüm kontroller doğrulandı.

## 6. Kapsam Dışı (`docs/parking-lot.md`) ve Operasyonel Notlar
Ek CLI bayrakları kapsam dışı bırakıldı.

## Technical Glossary

| Term | Definition |
| :--- | :--- |
| Flow | Sequential process |
EOF
  git -C "$repo" add docs/walkthroughs/01-feature.md
  git -C "$repo" commit -m "docs: 2 mermaids and deep analysis" --quiet

  # Check 3: Modified technical doc missing Technical Glossary -> deny
  mkdir -p "$repo/docs/canon"
  cat << 'EOF' > "$repo/docs/canon/arch.md"
# Architecture

Some architecture description without glossary.
EOF
  git -C "$repo" add docs/canon/arch.md
  git -C "$repo" commit -m "docs: add arch without glossary" --quiet

  local out_no_glossary
  out_no_glossary=$(printf '%s' "$p_pr_create" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_no_glossary" ".decision" "deny" "Doc without glossary must deny gh pr create"
  assert_contains "$(printf '%s' "$out_no_glossary" | jq -r '.reason')" "Glossary"

  # Fix doc with Technical Glossary
  cat << 'EOF' >> "$repo/docs/canon/arch.md"

## Technical Glossary

| Term | Definition |
| :--- | :--- |
| API | Application Programming Interface |
EOF
  git -C "$repo" add docs/canon/arch.md
  git -C "$repo" commit -m "docs: fix glossary" --quiet

  # Check 4: Missing or stale stamps -> deny
  local out_no_stamps
  out_no_stamps=$(printf '%s' "$p_pr_create" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_no_stamps" ".decision" "deny" "Missing stamps must deny gh pr create"

  # Create valid stamps for current codeTreeSha
  "$STAMP_GATE" canon --verdict PASS --workspace "$repo"
  "$STAMP_GATE" security --verdict PASS --critical 0 --important 0 --workspace "$repo"

  # Check 5: Drive-by modified file outside allowedFiles -> deny (even if documented in walkthrough)
  mkdir -p "$repo/src"
  echo "drive by" > "$repo/src/unrelated.ts"
  python3 -c '
p = "'"$repo"'/docs/walkthroughs/01-feature.md"
s = open(p, encoding="utf-8").read()
entry = """
### `src/unrelated.ts` — [ÜRETİLDİ] (`Infrastructure`)
- **Ne Değişti / Ne Üretildi?:** Kapsam dışı eklenen `unrelated.ts` yardımcı dosyası oluşturuldu.
- **Neden Değişti / Neden Üretildi?:** `allowedFiles` kapsam kilidi kontrolünü izole olarak test etmek için eklendi.
"""
open(p, "w", encoding="utf-8").write(s.replace("## 4. Kritik İş Mantığı", entry + "\n## 4. Kritik İş Mantığı"))
'
  git -C "$repo" add src/unrelated.ts docs/walkthroughs/01-feature.md
  git -C "$repo" commit -m "drive by edit" --quiet
  # Restamp canon with allowedFiles restricting to src.js (current sha, but unrelated.ts not in allowedFiles)
  "$STAMP_GATE" canon --verdict PASS --allow-file "src.js" --workspace "$repo"
  # Re-stamp security for current sha so stamp is fresh, but allowedFiles violation remains
  "$STAMP_GATE" security --verdict PASS --critical 0 --important 0 --workspace "$repo"

  local out_driveby
  out_driveby=$(printf '%s' "$p_pr_create" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_driveby" ".decision" "deny" "Drive-by file outside allowedFiles must deny"
  assert_contains "$(printf '%s' "$out_driveby" | jq -r '.reason')" "allowedFiles"

  # Now fix: revert drive-by commit, update stamps to match HEAD
  git -C "$repo" reset --hard HEAD~1 --quiet

  "$STAMP_GATE" canon --verdict PASS --allow-file "src.js" --workspace "$repo"
  "$STAMP_GATE" security --verdict PASS --critical 0 --important 0 --workspace "$repo"

  # All 5 checks satisfied -> allow!
  local out_all_pass
  out_all_pass=$(printf '%s' "$p_pr_create" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_all_pass" ".decision" "allow" "When all 5 checks pass, gh pr create must be allowed"
}

test_walkthrough_deep_file_coverage_and_local_merge_gate() {
  [ -x "$PRE_COMMAND_GUARD" ] || { echo "pre-command-guard.sh missing or not executable: $PRE_COMMAND_GUARD" >&2; return 1; }

  local repo
  repo=$(make_temp_repo)
  mkdir -p "$repo/src"
  echo "export const legacy = true;" > "$repo/src/LegacyHelper.ts"
  cat << 'EOF' > "$repo/README.md"
# Repo

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| Repo | Kod deposu |
EOF
  git -C "$repo" add README.md src/LegacyHelper.ts
  git -C "$repo" commit -m "chore: init with legacy helper" --quiet

  git -C "$repo" checkout -b "feat/order-processing" --quiet

  # Touch 1 new file, 1 another new file, 1 deleted file, plus exempt docs/parking-lot.md
  mkdir -p "$repo/docs/walkthroughs"
  echo "export class OrderService { submit() { return true; } }" > "$repo/src/OrderService.ts"
  echo "export class OrderRepository { save() { return true; } }" > "$repo/src/OrderRepository.ts"
  git -C "$repo" rm -f src/LegacyHelper.ts --quiet
  echo "- [ ] V2 batch order retry queue" > "$repo/docs/parking-lot.md"
  git -C "$repo" add src/OrderService.ts src/OrderRepository.ts docs/parking-lot.md
  git -C "$repo" commit -m "feat(orders): add order service/repo and remove legacy helper" --quiet

  local p_pr_create
  p_pr_create=$(jq -nc --arg ws "$repo" --arg cmd "gh pr create --fill" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')

  # Stamp canon & security upfront so walkthrough gate is isolated
  "$STAMP_GATE" canon --verdict PASS \
    --allow-file "src/OrderService.ts" \
    --allow-file "src/OrderRepository.ts" \
    --allow-file "src/LegacyHelper.ts" \
    --workspace "$repo"
  "$STAMP_GATE" security --verdict PASS --critical 0 --important 0 --workspace "$repo"

  # Case 1: Walkthrough has 2 Mermaids + Glossary, but NO '## Dosya Bazlı Değişiklik Analizi' heading -> deny
  cat << 'EOF' > "$repo/docs/walkthroughs/2026-11-12-orders.md"
# Sipariş İşleme Rehberi

```mermaid
flowchart LR
  OrderService --> OrderRepository
```

```mermaid
sequenceDiagram
  Client->>OrderService: submit()
  OrderService->>OrderRepository: save()
```

src/OrderService.ts, src/OrderRepository.ts ve src/LegacyHelper.ts güncellendi.

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| OrderService | Sipariş uygulama servisi |
EOF
  git -C "$repo" add docs/walkthroughs/2026-11-12-orders.md
  git -C "$repo" commit -m "docs: walkthrough without file analysis heading" --quiet

  local out_no_heading
  out_no_heading=$(printf '%s' "$p_pr_create" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_no_heading" ".decision" "deny" "Walkthrough missing Dosya Bazlı Değişiklik Analizi heading must be denied"
  assert_contains "$(printf '%s' "$out_no_heading" | jq -r '.reason')" "Dosya Bazlı Değişiklik Analizi"

  # Case 2: Walkthrough omits src/OrderRepository.ts and deleted src/LegacyHelper.ts -> deny naming missing files
  cat << 'EOF' > "$repo/docs/walkthroughs/2026-11-12-orders.md"
# Sipariş İşleme Rehberi

```mermaid
flowchart LR
  OrderService --> OrderRepository
```

```mermaid
sequenceDiagram
  Client->>OrderService: submit()
  OrderService->>OrderRepository: save()
```

## Dosya Bazlı Değişiklik Analizi

### `src/OrderService.ts` — [ÜRETİLDİ] (`Application`)
- **Ne Değişti / Ne Üretildi?:** Sipariş oluşturma iş akışını koordine eden `OrderService` sınıfı ve `submit()` metodu eklendi.
- **Neden Değişti / Ne Üretildi?:** Sunum katmanı ile veri erişim katmanı arasındaki sipariş doğrulama mantığını tek merkezde toplamak için üretildi.

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| OrderService | Sipariş uygulama servisi |
EOF
  git -C "$repo" add docs/walkthroughs/2026-11-12-orders.md
  git -C "$repo" commit -m "docs: walkthrough missing repository and deleted legacy file" --quiet

  local out_missing_files
  out_missing_files=$(printf '%s' "$p_pr_create" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_missing_files" ".decision" "deny" "Walkthrough omitting changed/deleted files must be denied"
  local reason_missing
  reason_missing=$(printf '%s' "$out_missing_files" | jq -r '.reason')
  assert_contains "$reason_missing" "src/OrderRepository.ts" "Deny reason must explicitly name missing src/OrderRepository.ts"
  assert_contains "$reason_missing" "src/LegacyHelper.ts" "Deny reason must explicitly name missing deleted file src/LegacyHelper.ts"

  # Case 3: Walkthrough mentions all files under heading, but only with shallow 1-line bullets (no Ne/Neden depth) -> deny
  cat << 'EOF' > "$repo/docs/walkthroughs/2026-11-12-orders.md"
# Sipariş İşleme Rehberi

```mermaid
flowchart LR
  OrderService --> OrderRepository
```

```mermaid
sequenceDiagram
  Client->>OrderService: submit()
  OrderService->>OrderRepository: save()
```

## Dosya Bazlı Değişiklik Analizi
- `src/OrderService.ts`: Sipariş servisi eklendi.
- `src/OrderRepository.ts`: Sipariş deposu eklendi.
- `src/LegacyHelper.ts`: Eski yardımcı dosya silindi.

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| OrderService | Sipariş uygulama servisi |
EOF
  git -C "$repo" add docs/walkthroughs/2026-11-12-orders.md
  git -C "$repo" commit -m "docs: shallow 1-liner walkthrough" --quiet

  local out_shallow
  out_shallow=$(printf '%s' "$p_pr_create" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_shallow" ".decision" "deny" "Shallow 1-line summary walkthrough without Ne/Neden explanations must be denied"

  # Case 3b: Partial laziness — 2 files have full H3 Ne/Neden, 3rd file has H3 heading with 1-word stub -> deny naming 3rd file
  cat << 'EOF' > "$repo/docs/walkthroughs/2026-11-12-orders.md"
# Sipariş İşleme Rehberi

```mermaid
flowchart LR
  OrderService --> OrderRepository
```

```mermaid
sequenceDiagram
  Client->>OrderService: submit()
```

## Dosya Bazlı Değişiklik Analizi

### `src/OrderService.ts` — [ÜRETİLDİ] (`Application`)
- **Ne Değişti / Ne Üretildi?:** Sipariş oluşturma iş akışını koordine eden `OrderService` sınıfı ve `submit()` metodu eklendi.
- **Neden Değişti / Ne Üretildi?:** Sunum katmanı ile veri erişim katmanı arasındaki sipariş doğrulama mantığını izole etmek için üretildi.

### `src/OrderRepository.ts` — [ÜRETİLDİ] (`Infrastructure`)
- **Ne Değişti / Ne Üretildi?:** Kalıcı sipariş kaydını yöneten `OrderRepository` sınıfı ve `save()` metodu eklendi.
- **Neden Değişti / Ne Üretildi?:** Domain/Application katmanını veritabanı altyapısından soyutlamak için üretildi.

### `src/LegacyHelper.ts` — [SİLİNDİ] (`Legacy`)
- **Ne Silindi?:** Silindi.
- **Neden Silindi?:** Eskiydi.

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| OrderService | Sipariş uygulama servisi |
EOF
  git -C "$repo" add docs/walkthroughs/2026-11-12-orders.md
  git -C "$repo" commit -m "docs: partial stub on LegacyHelper" --quiet

  local out_partial_stub
  out_partial_stub=$(printf '%s' "$p_pr_create" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_partial_stub" ".decision" "deny" "Per-file block with 1-word stub must be denied"
  assert_contains "$(printf '%s' "$out_partial_stub" | jq -r '.reason')" "src/LegacyHelper.ts" "Deny reason must identify shallow file src/LegacyHelper.ts"

  # Case 4: Walkthrough contains unedited template placeholder -> deny
  cat << 'EOF' > "$repo/docs/walkthroughs/2026-11-12-orders.md"
# Pull Request Mühendislik Rehberi: [Özellik / Düzeltme Başlığı]

```mermaid
flowchart LR
  OrderService --> OrderRepository
```

```mermaid
sequenceDiagram
  Client->>OrderService: submit()
```

## Dosya Bazlı Değişiklik Analizi

### `src/OrderService.ts` — [ÜRETİLDİ | GÜNCELLENDİ | SİLİNDİ] (`Application`)
- **Ne Değişti / Ne Üretildi?:** Sipariş oluşturma iş akışını koordine eden `OrderService` sınıfı ve `submit()` metodu eklendi.
- **Neden Değişti / Ne Üretildi?:** Sunum katmanı ile veri erişim katmanı arasındaki sipariş doğrulama mantığını izole etmek için üretildi.

### `src/OrderRepository.ts` — [ÜRETİLDİ] (`Infrastructure`)
- **Ne Değişti / Ne Üretildi?:** Kalıcı sipariş kaydını yöneten `OrderRepository` sınıfı ve `save()` metodu eklendi.
- **Neden Değişti / Ne Üretildi?:** Domain/Application katmanını veritabanı altyapısından soyutlamak için üretildi.

### `src/LegacyHelper.ts` — [SİLİNDİ] (`Legacy`)
- **Ne Silindi?:** Artık kullanılmayan `legacy` bayrağını taşıyan `LegacyHelper.ts` modülü tamamen kaldırıldı.
- **Neden Silindi?:** Yeni `OrderService` akışı devreye alındığından ölü kod (dead code) birikimini önlemek için silindi.

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| OrderService | Sipariş uygulama servisi |
EOF
  git -C "$repo" add docs/walkthroughs/2026-11-12-orders.md
  git -C "$repo" commit -m "docs: walkthrough with leftover template placeholder" --quiet

  local out_placeholder
  out_placeholder=$(printf '%s' "$p_pr_create" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_placeholder" ".decision" "deny" "Walkthrough with leftover template placeholders must be denied"

  # Also verify local git merge into main (no remote) denies before fixing walkthrough
  git -C "$repo" checkout main --quiet
  local p_local_merge
  p_local_merge=$(jq -nc --arg ws "$repo" --arg cmd "git merge feat/order-processing" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  local out_merge_deny
  out_merge_deny=$(printf '%s' "$p_local_merge" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_merge_deny" ".decision" "deny" "Local merge into main must also deny invalid/placeholder walkthrough"
  git -C "$repo" checkout feat/order-processing --quiet

  # Case 5: Complete, deep engineering walkthrough covering 100% of non-exempt files -> allow!
  cat << 'EOF' > "$repo/docs/walkthroughs/2026-11-12-orders.md"
# Pull Request Mühendislik Rehberi: Sipariş İşleme Akışı ve Legacy Temizliği

## 1. Problem Bağlamı ve Mimari Kararlar
Dağınık yardımcı fonksiyonlarla yürütülen sipariş kaydı, katman sınırlarını koruyan `OrderService` ve `OrderRepository` bileşenlerine taşındı; eski `LegacyHelper` kaldırıldı.

## 2. Mimari ve Veri Akışı Diyagramları
```mermaid
flowchart LR
  OrderService["Application: OrderService"] --> OrderRepository["Infrastructure: OrderRepository"]
```

```mermaid
sequenceDiagram
  Client->>OrderService: submit()
  OrderService->>OrderRepository: save()
  OrderRepository-->>OrderService: true
```

## 3. Dosya Bazlı Değişiklik Analizi

### `src/OrderService.ts` — [ÜRETİLDİ] (`Application`)
- **Ne Değişti / Ne Üretildi?:** Sipariş gönderim adımlarını yöneten `OrderService` sınıfı ve `submit(): boolean` metodu oluşturuldu.
- **Neden Değişti / Ne Üretildi?:** İstemci çağrılarının doğrudan veri katmanına erişmesini engelleyip uygulama kurallarını merkezi katmanda yürütmek için üretildi.

### `src/OrderRepository.ts` — [ÜRETİLDİ] (`Infrastructure`)
- **Ne Değişti / Ne Üretildi?:** Sipariş varlıklarının kalıcı depoya yazılmasını sağlayan `OrderRepository` sınıfı ve `save(): boolean` metodu eklendi.
- **Neden Değişti / Ne Üretildi?:** Kalıcılık detaylarını uygulama mantığından ayırarak Clean Architecture bağımlılık yönünü korumak için üretildi.

### `src/LegacyHelper.ts` — [SİLİNDİ] (`Legacy`)
- **Ne Silindi?:** Eski statik `legacy = true` sabiti ve kullanılmayan yardımcı modül kod tabanından tamamen kaldırıldı.
- **Neden Silindi?:** Sipariş akışı `OrderService` üzerine taşındıktan sonra hiçbir çağrıcısı kalmayan ölü kodu temizlemek için silindi.

## 4. Kritik İş Mantığı, Kenar Durumlar (Edge Cases) ve Hata Yönetimi
Kayıt başarısız olduğunda `save()` hatası yutulmadan üst katmana iletilir.

## 5. Somut Doğrulama Kanıtları
Birim testleri `./scripts/run-quiet.sh unit -- npm test` komutuyla sıfır hata ile doğrulandı; `canon-pass.json` ve `security-pass.json` damgalandı.

## 6. Kapsam Dışı (`docs/parking-lot.md`) ve Operasyonel Notlar
Toplu sipariş tekrar deneme kuyruğu `docs/parking-lot.md` dosyasına aktarıldı.

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| **OrderService** | Sipariş oluşturma iş akışını koordine eden uygulama katmanı servisi. |
| **OrderRepository** | Sipariş verisinin kalıcı depoya yazılmasından sorumlu altyapı bileşeni. |
EOF
  git -C "$repo" add docs/walkthroughs/2026-11-12-orders.md
  git -C "$repo" commit -m "docs: complete deep walkthrough" --quiet

  # Check gh pr create -> allow!
  local out_pr_allow
  out_pr_allow=$(printf '%s' "$p_pr_create" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_pr_allow" ".decision" "allow" "Comprehensive walkthrough covering all diff files must allow gh pr create"

  # Check local merge into main (no remote) -> allow!
  git -C "$repo" checkout main --quiet
  local out_merge_allow
  out_merge_allow=$(printf '%s' "$p_local_merge" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_merge_allow" ".decision" "allow" "Comprehensive walkthrough covering all diff files must allow local merge when no remote exists"
}

test_post_command_sets_pr_audit_flag_and_triggers_graphify_on_merge() {
  [ -x "$POST_COMMAND_HOOKS" ] || { echo "post-command-hooks.sh missing or not executable: $POST_COMMAND_HOOKS" >&2; return 1; }

  local repo
  repo=$(make_temp_repo)
  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: init" --quiet
  git -C "$repo" checkout -b "feature/post-test" --quiet

  # 1. Successful gh pr create triggers pr-audit-pending.json
  local p_pr_create
  p_pr_create=$(jq -nc --arg ws "$repo" --arg cmd "gh pr create --fill" --arg url "https://github.com/example/repo/pull/42" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}, toolOutput: {output: $url}}')
  local out_pr_create
  out_pr_create=$(printf '%s' "$p_pr_create" | "$POST_COMMAND_HOOKS")
  assert_eq "{}" "$out_pr_create" "PostToolUse must output {} on stdout"

  local state_dir
  state_dir="$(cd "$REPO_ROOT" && ./scripts/stamp-gate.sh tree-sha --workspace "$repo" >/dev/null && source "$REPO_ROOT/scripts/hooks/common.sh" && harness_state_dir "$repo")"
  [ -f "$state_dir/pr-audit-pending.json" ] || { echo "Expected pr-audit-pending.json to be created" >&2; return 1; }
  assert_json_field "$state_dir/pr-audit-pending.json" ".stopRetries" "0"
  assert_json_field "$state_dir/pr-audit-pending.json" ".auditDispatched" "false"
  assert_json_field "$state_dir/pr-audit-pending.json" ".prUrl" "https://github.com/example/repo/pull/42"

  # 2. Failed gh pr create (error present) does NOT write flag
  rm -f "$state_dir/pr-audit-pending.json"
  local p_pr_err
  p_pr_err=$(jq -nc --arg ws "$repo" --arg cmd "gh pr create --fill" --arg err "GraphQL error: pull request already exists" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}, error: $err}')
  local out_pr_err
  out_pr_err=$(printf '%s' "$p_pr_err" | "$POST_COMMAND_HOOKS")
  assert_eq "{}" "$out_pr_err" "PostToolUse must output {} on error"
  [ ! -f "$state_dir/pr-audit-pending.json" ] || { echo "pr-audit-pending.json should not exist on command error" >&2; return 1; }

  # 3. Quoted command string does NOT trigger pr-audit-pending.json
  local p_commit
  p_commit=$(jq -nc --arg ws "$repo" --arg cmd 'git commit -m "gh pr create"' \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}, toolOutput: {output: "commit created"}}')
  local out_commit
  out_commit=$(printf '%s' "$p_commit" | "$POST_COMMAND_HOOKS")
  assert_eq "{}" "$out_commit" "PostToolUse must output {}"
  [ ! -f "$state_dir/pr-audit-pending.json" ] || { echo "Quoted command must not trigger pr-audit-pending.json" >&2; return 1; }

  # 4. Trigger graphify on gh pr merge
  local mock_log="$repo/.mock_graphify.log"
  local mock_graphify="$repo/mock-graphify.sh"
  cat << EOF > "$mock_graphify"
#!/usr/bin/env bash
echo "GRAPHIFY_CALLED: \$*" >> "$mock_log"
EOF
  chmod +x "$mock_graphify"

  mkdir -p "$repo/graphify-out"
  local p_merge
  p_merge=$(jq -nc --arg ws "$repo" --arg cmd "gh pr merge --auto --squash" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}, toolOutput: {output: "Merged"}}')

  local out_merge
  out_merge=$(printf '%s' "$p_merge" | HARNESS_GRAPHIFY_BIN="$mock_graphify" "$POST_COMMAND_HOOKS")
  assert_eq "{}" "$out_merge" "PostToolUse must output {}"
  [ -f "$mock_log" ] || { echo "Expected mock graphify to have been called" >&2; return 1; }
  local log_content
  log_content=$(cat "$mock_log")
  assert_contains "$log_content" "--update --no-viz" "Graphify must be invoked with --update --no-viz"
  [ -f "$repo/.harness/logs/graphify-hook.log" ] || { echo "Expected graphify-hook.log to exist" >&2; return 1; }

  # 5. Respect .harness-ignore
  touch "$repo/.harness-ignore"
  rm -f "$mock_log"
  local out_ignored
  out_ignored=$(printf '%s' "$p_merge" | HARNESS_GRAPHIFY_BIN="$mock_graphify" "$POST_COMMAND_HOOKS")
  assert_eq "{}" "$out_ignored"
  [ ! -f "$mock_log" ] || { echo "Ignored workspace must not invoke graphify" >&2; return 1; }
}

test_cross_worktree_cd_and_git_C_resolution() {
  local main_repo wt_parent wt_admin
  main_repo=$(make_temp_repo)
  echo "init" > "$main_repo/README.md"
  git -C "$main_repo" add README.md
  git -C "$main_repo" commit -m "chore: init" --quiet
  git -C "$main_repo" remote add origin "https://github.com/example/kedo.git"

  wt_parent=$(mktemp -d "${TMPDIR:-/tmp}/harness-wt-cmd.XXXXXX")
  echo "$wt_parent" >> "$_HARNESS_TEMP_TRACKER"
  wt_admin="$wt_parent/kedo-admin"
  git -C "$main_repo" worktree add "$wt_admin" -b "feat/admin" --quiet

  # 1. cd <wt_admin> && npm install uses wt_admin context7 state, not main_repo
  local p_pkg_wt p_pkg_main out_pkg_deny out_pkg_allow out_pkg_main
  p_pkg_wt=$(jq -nc --arg ws "$main_repo" --arg cmd "cd \"$wt_admin\" && npm install left-pad" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  p_pkg_main=$(jq -nc --arg ws "$main_repo" --arg cmd "cd \"$main_repo\" && npm install left-pad" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')

  out_pkg_deny=$(printf '%s' "$p_pkg_wt" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_pkg_deny" ".decision" "deny" "Unverified package install in sibling worktree must be denied"

  "$STAMP_GATE" context7 --workspace "$wt_admin" --package "left-pad" --version "1.3.0" --source "locked"
  out_pkg_allow=$(printf '%s' "$p_pkg_wt" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_pkg_allow" ".decision" "allow" "Package verified in wt_admin must allow cd <wt_admin> && npm install"

  out_pkg_main=$(printf '%s' "$p_pkg_main" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_pkg_main" ".decision" "deny" "main_repo without context7 stamp must still deny npm install"

  # 2. git -C <wt_admin> push & cd <wt_admin> && git push vs git -C <main_repo> push & subshell CWD isolation
  local out_push_wt out_cd_push_wt out_push_main out_subshell_push
  out_push_wt=$(jq -nc --arg ws "$main_repo" --arg cmd "git -C \"$wt_admin\" push" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}' | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_push_wt" ".decision" "allow" "git -C <wt_admin> push on feat/admin must be allowed"

  out_cd_push_wt=$(jq -nc --arg ws "$main_repo" --arg cmd "cd \"$wt_admin\" && git push" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}' | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_cd_push_wt" ".decision" "allow" "cd <wt_admin> && git push on feat/admin must be allowed"

  out_push_main=$(jq -nc --arg ws "$main_repo" --arg cmd "git -C \"$main_repo\" push" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}' | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_push_main" ".decision" "deny" "git -C <main_repo> push on main must be denied"

  out_subshell_push=$(jq -nc --arg ws "$main_repo" --arg cmd "(cd \"$wt_admin\" && echo ok) && git push" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}' | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_subshell_push" ".decision" "deny" "Subshell cd must not leak CWD to subsequent git push on main"
}

test_gitignored_local_walkthrough_pr_and_local_merge_gates() {
  local repo
  repo=$(make_temp_repo)
  cat << 'EOF' > "$repo/.gitignore"
docs/walkthroughs/*
EOF
  cat << 'EOF' > "$repo/README.md"
# Kedo

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| Walkthrough | PR mühendislik rehberi |
EOF
  git -C "$repo" add .gitignore README.md
  git -C "$repo" commit -m "chore: init with gitignored walkthroughs" --quiet

  git -C "$repo" checkout -b "feat/gitignore-wt" --quiet
  mkdir -p "$repo/src"
  echo "export const feature = true;" > "$repo/src/Feature.ts"
  git -C "$repo" add src/Feature.ts
  git -C "$repo" commit -m "feat: add Feature.ts" --quiet

  "$STAMP_GATE" canon --workspace "$repo" --verdict PASS --allow-file "src/Feature.ts"
  "$STAMP_GATE" security --workspace "$repo" --verdict PASS --critical 0 --important 0

  local p_pr_create
  p_pr_create=$(jq -nc --arg ws "$repo" --arg cmd "gh pr create --fill" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')

  # 1. No local walkthrough yet -> deny
  local out_missing
  out_missing=$(printf '%s' "$p_pr_create" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_missing" ".decision" "deny" "Missing gitignored local walkthrough must deny"
  assert_contains "$(printf '%s' "$out_missing" | jq -r '.reason')" "walkthrough"

  # 2. Older invalid walkthrough (only 1 mermaid) -> deny with mermaid error
  mkdir -p "$repo/docs/walkthroughs"
  cat << 'EOF' > "$repo/docs/walkthroughs/01-old.md"
# Old Walkthrough

```mermaid
flowchart LR
  A --> B
```
EOF
  local out_old_bad
  out_old_bad=$(printf '%s' "$p_pr_create" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_old_bad" ".decision" "deny" "Invalid local gitignored walkthrough must deny"
  assert_contains "$(printf '%s' "$out_old_bad" | jq -r '.reason')" "Mermaid"

  # 3. Newer walkthrough (mtime strictly newer) with 2 mermaids + full Ne/Neden BUT missing glossary -> deny mentioning glossary
  cat << 'EOF' > "$repo/docs/walkthroughs/02-new.md"
# Yeni Walkthrough

```mermaid
flowchart LR
  Feature["src/Feature.ts"] --> Core
```

```mermaid
sequenceDiagram
  App->>Feature: read()
```

## Dosya Bazlı Değişiklik Analizi

### `src/Feature.ts` — [ÜRETİLDİ] (`Domain`)
- **Ne Değişti / Ne Üretildi?:** Özellik bayrağını sunan `Feature.ts` modülü ve `feature` sabiti üretildi.
- **Neden Değişti / Neden Üretildi?:** `.gitignore` kapsamındaki yerel walkthrough doğrulama testini çalıştırmak için üretildi.
EOF
  python3 -c '
import os, time, sys
old_p, new_p = sys.argv[1], sys.argv[2]
now = time.time()
os.utime(old_p, (now - 20, now - 20))
os.utime(new_p, (now, now))
' "$repo/docs/walkthroughs/01-old.md" "$repo/docs/walkthroughs/02-new.md"

  local out_no_glossary
  out_no_glossary=$(printf '%s' "$p_pr_create" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_no_glossary" ".decision" "deny" "Gitignored walkthrough without glossary must deny"
  assert_contains "$(printf '%s' "$out_no_glossary" | jq -r '.reason')" "Glossary"

  # 4. Add glossary to newer walkthrough (keep 01-old.md invalid!) -> gh pr create AND local git merge must allow!
  cat << 'EOF' >> "$repo/docs/walkthroughs/02-new.md"

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| Feature | Özellik bayrağı modülü |
EOF
  python3 -c 'import os, time, sys; now=time.time(); os.utime(sys.argv[1], (now-20, now-20)); os.utime(sys.argv[2], (now+2, now+2))' \
    "$repo/docs/walkthroughs/01-old.md" "$repo/docs/walkthroughs/02-new.md"

  local out_pr_ok
  out_pr_ok=$(printf '%s' "$p_pr_create" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_pr_ok" ".decision" "allow" "Newest valid gitignored walkthrough must allow gh pr create"

  git -C "$repo" checkout main --quiet
  local out_merge_ok
  out_merge_ok=$(jq -nc --arg ws "$repo" --arg cmd "git merge feat/gitignore-wt" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}' | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_merge_ok" ".decision" "allow" "Valid gitignored walkthrough must also allow local git merge"
}

test_detached_linked_worktree_context7_survives_commit() {
  [ -x "$PRE_COMMAND_GUARD" ] || { echo "pre-command-guard.sh missing or not executable: $PRE_COMMAND_GUARD" >&2; return 1; }
  [ -x "$STAMP_GATE" ] || { echo "stamp-gate.sh missing or not executable: $STAMP_GATE" >&2; return 1; }
  export HARNESS_DISABLE_DAEMON=1

  local main_repo wt_parent wt_detached
  main_repo=$(make_temp_repo)
  echo "init" > "$main_repo/README.md"
  git -C "$main_repo" add README.md
  git -C "$main_repo" commit -m "chore: init" --quiet

  wt_parent=$(mktemp -d "/tmp/harness-wt-detached-cmd.XXXXXX")
  echo "$wt_parent" >> "$_HARNESS_TEMP_TRACKER"
  wt_detached="$wt_parent/swarm-detached"
  git -C "$main_repo" worktree add --detach "$wt_detached" --quiet

  local p_pkg p_pkg_cross p_unstamped
  p_pkg=$(jq -nc --arg ws "$wt_detached" --arg cmd "npm install zod@^3.24.0" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  p_pkg_cross=$(jq -nc --arg ws "$main_repo" --arg cmd "cd \"$wt_detached\" && npm install zod@^3.24.0" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')
  p_unstamped=$(jq -nc --arg ws "$wt_detached" --arg cmd "npm install express" \
    '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: $cmd}}}')

  # 1. Before stamp -> deny
  local out_deny
  out_deny=$(printf '%s' "$p_pkg" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_deny" ".decision" "deny" "Unverified npm install in detached linked worktree must deny"

  # 2. Stamp context7 -> allow before commit
  "$STAMP_GATE" context7 --workspace "$wt_detached" --package "zod" --version "3.24.0" --source "greenfield-latest"
  local out_allow_before
  out_allow_before=$(printf '%s' "$p_pkg" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_allow_before" ".decision" "allow" "Stamped npm install must allow before commit"

  # 3. Make a commit on detached HEAD in the linked worktree -> context7 stamp must remain active
  echo "export const worker = true;" > "$wt_detached/worker.ts"
  git -C "$wt_detached" add worker.ts
  git -C "$wt_detached" commit -m "feat: worker commit on detached worktree" --quiet

  local out_allow_after out_allow_cross out_unstamped
  out_allow_after=$(printf '%s' "$p_pkg" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_allow_after" ".decision" "allow" "Stamped npm install in detached linked worktree must stay allowed after commit"

  out_allow_cross=$(printf '%s' "$p_pkg_cross" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_allow_cross" ".decision" "allow" "Cross-worktree cd into detached linked worktree must see preserved context7 stamp after commit"

  out_unstamped=$(printf '%s' "$p_unstamped" | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_unstamped" ".decision" "deny" "Unstamped package must still be denied after commit"
}

test_hook_input_cwd_resolves_sibling_worktree_without_cd() {
  [ -x "$PRE_COMMAND_GUARD" ] || { echo "pre-command-guard.sh missing or not executable: $PRE_COMMAND_GUARD" >&2; return 1; }
  [ -x "$POST_COMMAND_HOOKS" ] || { echo "post-command-hooks.sh missing or not executable: $POST_COMMAND_HOOKS" >&2; return 1; }
  [ -x "$STAMP_GATE" ] || { echo "stamp-gate.sh missing or not executable: $STAMP_GATE" >&2; return 1; }
  export HARNESS_DISABLE_DAEMON=1

  local main_repo wt_parent wt_feat wt_detached
  main_repo=$(make_temp_repo)
  cat << 'EOF' > "$main_repo/README.md"
# Repo

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| Repo | Kod deposu |
EOF
  git -C "$main_repo" add README.md
  git -C "$main_repo" commit -m "chore: init" --quiet
  git -C "$main_repo" remote add origin "https://github.com/example/swarm-cwd.git"

  wt_parent=$(mktemp -d "${TMPDIR:-/tmp}/harness-wt-cwd-cmd.XXXXXX")
  echo "$wt_parent" >> "$_HARNESS_TEMP_TRACKER"
  wt_feat="$wt_parent/worker-feat"
  wt_detached="$wt_parent/worker-detached"
  git -C "$main_repo" worktree add "$wt_feat" -b "feat/cwd-worker" --quiet
  git -C "$main_repo" worktree add --detach "$wt_detached" --quiet

  # 1. git push without cd when HOOK_INPUT.cwd is wt_feat -> allow (while cwd=main_repo denies)
  local out_push_wt out_push_main out_push_explicit_c out_push_bad_cwd
  out_push_wt=$(jq -nc --arg ws "$main_repo" --arg cwd "$wt_feat" \
    '{workspacePaths: [$ws], cwd: $cwd, toolCall: {name: "run_command", args: {CommandLine: "git push"}}}' \
    | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_push_wt" ".decision" "allow" "git push with HOOK_INPUT.cwd in sibling worktree must allow"

  out_push_main=$(jq -nc --arg ws "$main_repo" --arg cwd "$main_repo" \
    '{workspacePaths: [$ws], cwd: $cwd, toolCall: {name: "run_command", args: {CommandLine: "git push"}}}' \
    | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_push_main" ".decision" "deny" "git push with HOOK_INPUT.cwd in main_repo must deny"

  out_push_explicit_c=$(jq -nc --arg ws "$main_repo" --arg cwd "$wt_feat" --arg cmd "git -C \"$main_repo\" push" \
    '{workspacePaths: [$ws], cwd: $cwd, toolCall: {name: "run_command", args: {CommandLine: $cmd}}}' \
    | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_push_explicit_c" ".decision" "deny" "Explicit git -C main_repo must override HOOK_INPUT.cwd"

  out_push_bad_cwd=$(jq -nc --arg ws "$main_repo" --arg cwd "$wt_parent/does-not-exist" \
    '{workspacePaths: [$ws], cwd: $cwd, toolCall: {name: "run_command", args: {CommandLine: "git push"}}}' \
    | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_push_bad_cwd" ".decision" "deny" "Invalid HOOK_INPUT.cwd must fall back safely to workspace"

  # 2. npm install without cd resolves context7 state in HOOK_INPUT.cwd worktree (including detached-wt-*)
  local out_npm_deny out_npm_allow out_npm_main out_det_deny out_det_allow
  out_npm_deny=$(jq -nc --arg ws "$main_repo" --arg cwd "$wt_feat" \
    '{workspacePaths: [$ws], cwd: $cwd, toolCall: {name: "run_command", args: {CommandLine: "npm install zod@^3.24.0"}}}' \
    | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_npm_deny" ".decision" "deny" "Unstamped npm install in cwd sibling worktree must deny"

  "$STAMP_GATE" context7 --workspace "$wt_feat" --package "zod" --version "3.24.0" --source "locked"
  out_npm_allow=$(jq -nc --arg ws "$main_repo" --arg cwd "$wt_feat" \
    '{workspacePaths: [$ws], cwd: $cwd, toolCall: {name: "run_command", args: {CommandLine: "npm install zod@^3.24.0"}}}' \
    | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_npm_allow" ".decision" "allow" "Stamped npm install in cwd sibling worktree must allow without cd"

  out_npm_main=$(jq -nc --arg ws "$main_repo" --arg cwd "$main_repo" \
    '{workspacePaths: [$ws], cwd: $cwd, toolCall: {name: "run_command", args: {CommandLine: "npm install zod@^3.24.0"}}}' \
    | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_npm_main" ".decision" "deny" "main_repo remains unstamped when HOOK_INPUT.cwd is main_repo"

  out_det_deny=$(jq -nc --arg ws "$main_repo" --arg cwd "$wt_detached" \
    '{workspacePaths: [$ws], cwd: $cwd, toolCall: {name: "run_command", args: {CommandLine: "npm install zod@^3.24.0"}}}' \
    | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_det_deny" ".decision" "deny" "Detached sibling worktree via cwd must deny before stamp"
  "$STAMP_GATE" context7 --workspace "$wt_detached" --package "zod" --version "3.24.0" --source "locked"
  out_det_allow=$(jq -nc --arg ws "$main_repo" --arg cwd "$wt_detached" \
    '{workspacePaths: [$ws], cwd: $cwd, toolCall: {name: "run_command", args: {CommandLine: "npm install zod@^3.24.0"}}}' \
    | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_det_allow" ".decision" "allow" "Detached sibling worktree via cwd must allow after stamp"

  # 3. gh pr create without cd resolves wt_feat PR checks + post-command writes pr-audit-pending.json into wt_feat
  mkdir -p "$wt_feat/src" "$wt_feat/docs/walkthroughs"
  echo "export const c = 1;" > "$wt_feat/src/Feature.ts"
  cat << 'EOF' > "$wt_feat/docs/walkthroughs/2026-11-26-cwd.md"
# Pull Request Mühendislik Rehberi: CWD Testi

```mermaid
flowchart LR
  Cwd["HOOK_INPUT.cwd"] --> Feature["src/Feature.ts"]
```

```mermaid
sequenceDiagram
  Hook->>Worker: resolve cwd
```

## Dosya Bazlı Değişiklik Analizi

### `src/Feature.ts` — [ÜRETİLDİ] (`Domain`)
- **Ne Değişti / Ne Üretildi?:** `HOOK_INPUT.cwd` testi için `Feature.ts` modülü ve `c` sabiti oluşturuldu.
- **Neden Değişti / Neden Üretildi?:** Kardeş worktree içinde `cd` olmadan `gh pr create` kapısını doğrulamak için üretildi.

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| HOOK_INPUT.cwd | Kanca çalışma dizini alanı |
EOF
  git -C "$wt_feat" add src/Feature.ts docs/walkthroughs/2026-11-26-cwd.md
  git -C "$wt_feat" commit -m "feat: add feature and walkthrough" --quiet
  "$STAMP_GATE" canon --workspace "$wt_feat" --verdict PASS --allow-file "src/Feature.ts"
  "$STAMP_GATE" security --workspace "$wt_feat" --verdict PASS --critical 0 --important 0

  local out_pr_wt out_post_pr pending_wt
  out_pr_wt=$(jq -nc --arg ws "$main_repo" --arg cwd "$wt_feat" \
    '{workspacePaths: [$ws], cwd: $cwd, toolCall: {name: "run_command", args: {CommandLine: "gh pr create --fill"}}}' \
    | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_pr_wt" ".decision" "allow" "gh pr create with HOOK_INPUT.cwd in wt_feat must allow without cd"

  out_post_pr=$(jq -nc --arg ws "$main_repo" --arg cwd "$wt_feat" \
    '{workspacePaths: [$ws], cwd: $cwd, conversationId: "conv-cwd", toolCall: {name: "run_command", args: {CommandLine: "gh pr create --fill"}}, toolOutput: {output: "https://github.com/example/swarm-cwd/pull/7"}}' \
    | "$POST_COMMAND_HOOKS")
  assert_eq "{}" "$out_post_pr" "post-command-hooks.sh must output {}"
  pending_wt="$wt_feat/.harness/state/feat-cwd-worker/pr-audit-pending.json"
  [ -f "$pending_wt" ] || { echo "Expected pr-audit-pending.json in $pending_wt" >&2; return 1; }
  [ ! -f "$main_repo/.harness/state/main/pr-audit-pending.json" ] || { echo "main_repo must not receive wt_feat pr-audit-pending.json" >&2; return 1; }
  assert_json_field "$pending_wt" ".conversationId" "conv-cwd"
}

test_conditional_ui_pr_and_local_merge_gates_and_live_mode_guard() {
  export HARNESS_DISABLE_DAEMON=1
  local repo mock_dir mock_cfg mock_bin
  repo=$(make_temp_repo)
  mock_dir=$(mktemp -d "${TMPDIR:-/tmp}/harness-ui-gate.XXXXXX")
  echo "$mock_dir" >> "$_HARNESS_TEMP_TRACKER"
  mock_cfg="$mock_dir/mock-cfg"
  mock_bin="$mock_dir/mock-impeccable"
  mkdir -p "$mock_cfg"

  cat << 'EOF' > "$mock_bin"
#!/usr/bin/env bash
echo '[]'
exit 0
EOF
  chmod +x "$mock_bin"

  cat << 'EOF' > "$repo/README.md"
# UI Gate Demo

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| UI Gate | Koşullu arayüz kalite kapısı |
EOF
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: init" --quiet

  git -C "$repo" checkout -b "feat/ui-card" --quiet
  mkdir -p "$repo/src/ui" "$repo/docs/walkthroughs"
  echo "export const Card = () => '<div />'; " > "$repo/src/ui/Card.tsx"
  cat << 'EOF' > "$repo/docs/walkthroughs/2026-11-26-ui-card.md"
# Pull Request Mühendislik Rehberi: UI Card Bileşeni

## 1. Problem Bağlamı ve Mimari Kararlar
Kullanıcı arayüzünde kart bileşeni sadeleştirildi ve deterministik UI doğrulama kapısına bağlandı.

## 2. Mimari ve Veri Akışı Diyagramları
```mermaid
flowchart LR
  Card["src/ui/Card.tsx"] --> Detector["impeccable detect"]
```

```mermaid
sequenceDiagram
  Dev->>StampGate: ui --verdict PASS
  StampGate-->>Dev: ui-pass.json
```

## 3. Dosya Bazlı Değişiklik Analizi

### `src/ui/Card.tsx` — [ÜRETİLDİ] (`Presentation`)
- **Ne Değişti / Ne Üretildi?:** `Card` sunum bileşeni ve temel JSX işaretlemesi eklendi.
- **Neden Değişti / Ne Üretildi?:** Koşullu `ui-pass.json` PR ve yerel merge kapısını gerçek Web UI dosyası üzerinde doğrulamak için üretildi.

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| Presentation | Arayüz sunum katmanı |
EOF
  git -C "$repo" add src/ui/Card.tsx docs/walkthroughs/2026-11-26-ui-card.md
  git -C "$repo" commit -m "feat: add Card.tsx and walkthrough" --quiet

  "$STAMP_GATE" canon --workspace "$repo" --verdict PASS --allow-file "src/ui/Card.tsx"
  "$STAMP_GATE" security --workspace "$repo" --verdict PASS --critical 0 --important 0

  local p_pr p_merge out_pr_no_imp out_pr_deny out_merge_deny out_pr_allow out_merge_allow
  p_pr=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: "gh pr create --fill"}}}')
  p_merge=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: "git merge feat/ui-card"}}}')

  # 1. Without Impeccable installed -> gh pr create is allowed even without ui-pass.json
  out_pr_no_imp=$(printf '%s' "$p_pr" | HARNESS_CONFIG_DIR="$mock_cfg" env -u HARNESS_IMPECCABLE_BIN -u HARNESS_IMPECCABLE_SKILL_DIR "$PRE_COMMAND_GUARD")
  assert_json_field "$out_pr_no_imp" ".decision" "allow" "gh pr create must allow without ui-pass.json when Impeccable is not installed"

  # 2. With Impeccable installed & missing ui-pass.json -> both gh pr create and local git merge are denied
  out_pr_deny=$(printf '%s' "$p_pr" | HARNESS_CONFIG_DIR="$mock_cfg" HARNESS_IMPECCABLE_BIN="$mock_bin" "$PRE_COMMAND_GUARD")
  assert_json_field "$out_pr_deny" ".decision" "deny" "gh pr create must deny without ui-pass.json when Impeccable is installed"
  assert_contains "$(printf '%s' "$out_pr_deny" | jq -r '.reason')" "ui stamp"

  git -C "$repo" checkout main --quiet
  out_merge_deny=$(printf '%s' "$p_merge" | HARNESS_CONFIG_DIR="$mock_cfg" HARNESS_IMPECCABLE_BIN="$mock_bin" "$PRE_COMMAND_GUARD")
  assert_json_field "$out_merge_deny" ".decision" "deny" "Local merge into main must deny without ui-pass.json when Impeccable is installed"
  assert_contains "$(printf '%s' "$out_merge_deny" | jq -r '.reason')" "ui-pass.json"

  # 3. Stamp ui-pass.json on feat/ui-card -> both gh pr create and local git merge allow
  git -C "$repo" checkout feat/ui-card --quiet
  HARNESS_CONFIG_DIR="$mock_cfg" HARNESS_IMPECCABLE_BIN="$mock_bin" \
    "$STAMP_GATE" ui --workspace "$repo" --verdict PASS --p0 0 --p1 0

  out_pr_allow=$(printf '%s' "$p_pr" | HARNESS_CONFIG_DIR="$mock_cfg" HARNESS_IMPECCABLE_BIN="$mock_bin" "$PRE_COMMAND_GUARD")
  assert_json_field "$out_pr_allow" ".decision" "allow" "gh pr create must allow after ui-pass.json stamp"

  git -C "$repo" checkout main --quiet
  out_merge_allow=$(printf '%s' "$p_merge" | HARNESS_CONFIG_DIR="$mock_cfg" HARNESS_IMPECCABLE_BIN="$mock_bin" "$PRE_COMMAND_GUARD")
  assert_json_field "$out_merge_allow" ".decision" "allow" "Local merge into main must allow after ui-pass.json stamp"

  # 4. Gate 5: impeccable live unsandboxed fallback guard
  local out_live_npx out_live_bin out_live_chat out_live_off
  out_live_npx=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: "npx impeccable live"}}}' | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_live_npx" ".decision" "deny" "npx impeccable live without IMPECCABLE_LIVE_COPY_AGENT must be denied"
  assert_contains "$(printf '%s' "$out_live_npx" | jq -r '.reason')" "IMPECCABLE_LIVE_COPY_AGENT"

  out_live_bin=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: ".agent/skills/impeccable/scripts/impeccable live"}}}' | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_live_bin" ".decision" "deny" "Direct impeccable live without IMPECCABLE_LIVE_COPY_AGENT must be denied"

  out_live_chat=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: "DO_NOT_TRACK=1 IMPECCABLE_LIVE_COPY_AGENT=chat npx impeccable live"}}}' | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_live_chat" ".decision" "allow" "impeccable live with IMPECCABLE_LIVE_COPY_AGENT=chat must be allowed"

  out_live_off=$(jq -nc --arg ws "$repo" '{workspacePaths: [$ws], toolCall: {name: "run_command", args: {CommandLine: "export IMPECCABLE_LIVE_COPY_AGENT=off && impeccable live"}}}' | "$PRE_COMMAND_GUARD")
  assert_json_field "$out_live_off" ".decision" "allow" "impeccable live after export IMPECCABLE_LIVE_COPY_AGENT=off must be allowed"
}

run_tests
