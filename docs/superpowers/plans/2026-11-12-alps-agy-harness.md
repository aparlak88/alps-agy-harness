# `alps-agy-harness` Uygulama Planı (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `superpowers` (`v7.0.0`+) etrafına deterministik yaşam döngüsü hook kapıları, zorunlu `jev` karar/kalibrasyon katmanı, `context7` sürüm kilidi, üç parçalı proje kanonu, dört platformlu Clean Architecture/DDD kuralları ve Web/Mobil çalışma zamanı teşhisi ekleyen dağıtılabilir Antigravity eklentisini (`alps-agy-harness`) oluşturmak.

**Architecture:** Depo kökünde yer alan native `plugin.json` ve `hooks.json`, POSIX kabuk betikleri (`scripts/hooks/*.sh`) ve paylaşımlı `.harness/` durum/log yöneticisi (`common.sh`, `stamp-gate.sh`) üzerinden fiziksel kapıları uygular. Evrensel orkestrasyon sözleşmesi `rules/AGENTS.md` (`< 8 KB`, frontmatter'sız) içinde, platform kuralları `trigger: glob` dosyalarında (`< 24 KB`), denetçiler `agents/*.md` alt ajanlarında ve iş akışları 11 adet `skills/*/SKILL.md` paketinde modüler olarak sunulur.

**Tech Stack:** Google Antigravity Native Plugin (`plugin.json`, `hooks.json`), POSIX `bash` + `jq` + `git` + `python3`, `jev-mcp` (`TYPESAFE_API_KEY`), `context7`, `@playwright/mcp`, `Chrome DevTools`, `xcrun simctl` / `adb`.

**Spec:** `docs/superpowers/specs/2026-11-12-alps-agy-harness-design.md`

## Global Constraints

- **Antigravity Kök Şeması:** `plugin.json` ve `hooks.json` doğrudan depo kökünde bulunmalıdır; `plugin.json` yalnızca izin verilen üst düzey alanları (`name`, `displayName`, `version`, `description`, `logo`, `suggestedPrompts`, `author`, `homepage`, `repository`) içerebilir.
- **Hook JSON Kontratı:** Tüm hook girdileri ve çıktıları **camelCase** JSON (`conversationId`, `workspacePaths`, `toolCall`, `injectSteps`, `systemMessage`, `permissionOverrides`, `overwrite`, `terminationReason`) kullanmalıdır; göreli betik yolları `$PLUGIN_ROOT` veya eklenti kök çalışma dizininden çözülmelidir.
- **Global ve Proje Bazlı Çalışma + `.harness-ignore`:** Betikler `~/.gemini/config/plugins/` sabit yolunu varsayamaz; `workspacePaths[0]/.harness-ignore` dosyası mevcutsa tüm hook'lar anında pasif (`{}` veya `{"decision":"allow"}`) dönmelidir.
- **Sıfır Gizli Anahtar Sızıntısı:** Depoda `mcp_config.json` yer almaz (şablonlar `README.md` içindedir); `harness-doctor.sh` dahil hiçbir betik `TYPESAFE_API_KEY` değerini veya alt dizgesini ekrana/loglara basamaz.
- **Kural ve Alt Ajan Kısıtları:** `rules/AGENTS.md` frontmatter içermez ve `< 8 KB` boyutundadır; platform kuralları (`rules/*.md`) `trigger: glob` ve virgülle ayrılmış genişletilmiş `globs` (`**/...`, süslü parantezsiz) kullanır ve her biri `< 24 KB` sınırındadır; `agents/*.md` dosyaları `name`, `description`, `subagent: true`, `mainAgent: false`, `tools: [...]` içerir (`model` ve `color` alanları bulunmaz).
- **Dil Standardı:** Kaynak kod, kod içi dokümantasyon kuralları (`XMLDoc`, `TSDoc`, `Swift DocC`, `KDoc`) ve mimari/E2E `REMEDIATION:` mesaj şablonları **İngilizce**; repo içi dokümanlar (`README.md`, şablonlar, Spec/Plan/Walkthrough açıklamaları) varsayılan **Türkçe** yazılır.
- **Doküman Sonu Sözlük Kuralı:** Üretilen tüm teknik Markdown dokümanları (`README.md`, `flows-template.md`, `lessons-template.md`, `walkthrough-template.md` dahil; `glossary-template.md` ve `parking-lot.md` hariç) `^## ([0-9]+\. )?(Teknik Terimler Sözlüğü|Technical Glossary)` bölümü ve en az 1 terim satırıyla bitmelidir.

## Karmaşıklık Bütçesi ve Kapsam Sınırları (Complexity Budget & Out-of-Scope)

- **Dosya Sayısı Bütçesi:** Toplam **49 dosya** (`5` kök manifesto/doküman/görsel: `.gitignore`, `plugin.json`, `hooks.json`, `assets/logo.svg`, `README.md`; `11` kabuk betiği: `7` `scripts/hooks/*.sh` + `4` `scripts/*.sh`; `5` kural dosyası; `3` alt ajan tanımı; `15` skill dosyası: `11` `SKILL.md` + `4` şablon; `10` otomatik kabuk test dosyası).
- **Soyutlama Gerekçesi:** Yalnızca `scripts/hooks/common.sh` (tüm 6 hook betiğinin paylaştığı JSON/git yardımcıları) ve `tests/test-helpers.sh` (tüm 8 `test-*.sh` betiğinin paylaştığı geçici git/fixture kurucuları) ortak modül olarak ayrılmıştır (`Rule of Three` tam uyumlu; tek kullanımlık sarmalayıcı katman yoktur).
- **Açıkça Kapsam Dışı (Out-of-Scope):**
  - `superpowers` kaynak dosyalarını kopyalamak veya alt modül olarak gömmek.
  - Harici bir Node/Python paketi veya derleme adımı gerektiren ikili (binary) kod eklemek (saf POSIX `bash` + `jq` + standart sistem araçları kullanılır).
  - CodeRabbit entegrasyonu.
  - Hedef projelerdeki mevcut (brownfield) kodları otomatik dönüştüren codemod betikleri yazmak.

## Review Focus

1. **Eğik Çizgili Dal Adları (`feature/auth/jwt`) ve Detached `HEAD`:** Ham dal adı dizin yoluna birleştirilirse `.harness/state/feature/auth/jwt` altında iç içe kırık klasörler oluşur; `branch_slug()` tüm `/` ve özel karakterleri `-` karakterine dönüştürmeli, detached `HEAD` durumunda `detached-<short-sha>` üretmelidir (**Task 2** testlerinde sabitlenir).
2. **Zincirlenmiş Kabuk Komutları (`cd web && npm i zod@^3.23.0 -D`) ve Tırnak İçi PR Metinleri (`git commit -m "prep gh pr create"`):** `pre-command-guard.sh`, `&&` / `;` ile bağlanmış komutlarda sürüm sonekli paket adını (`zod`) doğru ayıklamalı, buna karşılık `git commit -m` veya `echo` tırnakları içinde geçen `gh pr create` / `adb logcat` metinlerini yanlış pozitif olarak engellememelidir (**Task 4** testlerinde sabitlenir).
3. **İçi Boş Sözlük Başlığı (`## Teknik Terimler Sözlüğü` Altında Tanım Olmaması):** Yalnızca başlık satırı yazılıp altına hiçbir terim satırı (`| ... |` veya `- **...**`) eklenmemiş dokümanlar hem `pre-edit-guard.sh` (`write_file`) hem de `pre-command-guard.sh` (`gh pr create`) kapılarından `"decision": "deny"` almalıdır (**Task 3** ve **Task 4** testlerinde sabitlenir).
4. **Çok Satırlı, Tırnak ve `$degisken` İçeren Alt Ajan `Prompt` Metinlerinin `overwrite` Sırasında Bozulması:** `pre-subagent-guard.sh` içinde kabuk dizge birleştirmesi kullanılırsa ters tırnaklar ve `$FOO` ifadeleri bozulur; `overwrite` JSON çıktısı yalnızca `jq --arg` üzerinden üretilerek orijinal `Prompt` bayt-bayt korunmalıdır (**Task 5** testlerinde sabitlenir).
5. **`harness-doctor.sh` Çalışırken Gizli `TYPESAFE_API_KEY` Değerinin Sızması:** Ortamda veya `~/.config/typesafe/key` dosyasında `ts_live_secret_98765` tanımlı olduğunda `harness-doctor.sh` (normal ve `--json` çıktılarında, `stdout` ve `stderr` dahil) anahtar değerinin hiçbir parçasını basmamalı, yalnız varlık durumunu raporlamalıdır (**Task 6** testlerinde sabitlenir).

---

### Task 1: Eklenti Manifestosu (`plugin.json`), Kök `hooks.json`, Logo ve Test Çerçevesi

**Files:**
- Create: `.gitignore`
- Create: `plugin.json`
- Create: `hooks.json`
- Create: `assets/logo.svg`
- Create: `tests/test-helpers.sh`
- Create: `tests/run-all.sh`
- Create: `tests/test-manifest.sh`

**Interfaces:**
- Consumes: Yok (temel görev).
- Produces:
  - `plugin.json`: `{"name": "alps-agy-harness", "displayName": "Alps AGY Engineering Harness", "version": "1.0.0", "logo": "assets/logo.svg", "suggestedPrompts": [3 öğe], ...}`
  - `hooks.json`: `SessionStart` (`./scripts/hooks/session-start.sh`), `PreToolUse` (`write_file|edit_file` -> `./scripts/hooks/pre-edit-guard.sh`, `run_command` -> `./scripts/hooks/pre-command-guard.sh`, `invoke_subagent` -> `./scripts/hooks/pre-subagent-guard.sh`), `PostToolUse` (`run_command` -> `./scripts/hooks/post-command-hooks.sh`), `Stop` (`./scripts/hooks/stop-gate.sh`)
  - `tests/test-helpers.sh`: `assert_eq(expected, actual, msg)`, `assert_contains(haystack, needle, msg)`, `assert_not_contains(haystack, needle, msg)`, `assert_json_field(json, jq_expr, expected, msg)`, `make_temp_repo()`

- [ ] **Step 1: `tests/test-helpers.sh`, `tests/run-all.sh` ve başarısız olacak `tests/test-manifest.sh` testini yaz**

`tests/test-manifest.sh` içinde şu doğrulamaları kodla:
```bash
test_plugin_json_valid_and_strict_keys() {
  jq -e '.name == "alps-agy-harness" and .logo == "assets/logo.svg" and (.suggestedPrompts | length == 3)' "$REPO_ROOT/plugin.json" >/dev/null
  extra_keys=$(jq -r 'keys - ["name","displayName","version","description","logo","suggestedPrompts","author","homepage","repository","disabled"] | length' "$REPO_ROOT/plugin.json")
  assert_eq "0" "$extra_keys" "plugin.json must not contain unknown top-level keys"
}

test_hooks_json_root_wiring() {
  jq -e '
    .["alps-agy-harness"].SessionStart[0].command == "./scripts/hooks/session-start.sh" and
    (.["alps-agy-harness"].PreToolUse | map(.matcher) == ["write_file|edit_file","run_command","invoke_subagent"]) and
    .["alps-agy-harness"].PostToolUse[0].matcher == "run_command" and
    .["alps-agy-harness"].Stop[0].command == "./scripts/hooks/stop-gate.sh"
  ' "$REPO_ROOT/hooks.json" >/dev/null
}

test_logo_svg_square_and_present() {
  [ -s "$REPO_ROOT/assets/logo.svg" ]
  grep -Eq 'viewBox="0 0 256 256"' "$REPO_ROOT/assets/logo.svg"
}
```

- [ ] **Step 2: Testi çalıştır ve henüz dosyalar olmadığı için başarısız olduğunu doğrula**

Run: `bash tests/run-all.sh`
Expected: FAIL (`plugin.json` / `hooks.json` bulunamadı hatası, çıkış kodu `!= 0`)

- [ ] **Step 3: `.gitignore`, `plugin.json`, `hooks.json` ve `assets/logo.svg` dosyalarını oluştur**

- `.gitignore`: `.harness/`, `*.tmp`, `.DS_Store` kayıtlarını ekle.
- `plugin.json`: Antigravity şemasına tam uyumlu JSON oluştur (`3` Türkçe başlangıç istemi: yeni özellik planlama, `harness-doctor` kontrolü, PR inceleme).
- `hooks.json`: Tüm kancaları `"alps-agy-harness"` üst anahtarı altında `./scripts/hooks/...` göreli komutları ve `timeout: 15` (`post-command-hooks.sh` için `timeout: 30`) ile tanımla.
- `assets/logo.svg`: `viewBox="0 0 256 256"` şeffaf arka planlı, `%12` iç boşluklu, açık ve koyu temada yüksek kontrastlı kalkan/koşum (`harness`) vektör ikonu çiz.

- [ ] **Step 4: Test paketini çalıştır ve geçtiğini doğrula**

Run: `bash tests/run-all.sh`
Expected: PASS (`test-manifest.sh` tüm kontroller `0` çıkış koduyla geçer)

- [ ] **Step 5: Commit**

```bash
git add .gitignore plugin.json hooks.json assets/logo.svg tests/test-helpers.sh tests/run-all.sh tests/test-manifest.sh
git commit -m "feat(core): add plugin manifest, root hooks.json, logo, and shell test runner"
```

---

### Task 2: Ortak Hook Altyapısı (`common.sh`) ve Deterministik Damga/Yönlendirme Aracı (`stamp-gate.sh`)

**Files:**
- Create: `scripts/hooks/common.sh`
- Create: `scripts/stamp-gate.sh`
- Create: `tests/test-stamp-and-common.sh`

**Interfaces:**
- Consumes: `jq`, `git`
- Produces:
  - `scripts/hooks/common.sh` fonksiyonları:
    - `harness_read_stdin()` -> `HOOK_INPUT` değişkenine stdin JSON'u okur, `WORKSPACE_ROOT` değerini `.workspacePaths[0]` üzerinden çözer.
    - `harness_is_ignored "$workspace"` -> `$workspace/.harness-ignore` varsa `0` döner.
    - `harness_branch_name "$workspace"` -> aktif dal adını veya `HEAD` (detached) bilgisini döner.
    - `harness_branch_slug "$workspace"` -> `/` ve alfasayısal dışı karakterleri `-` yapan güvenli slug (`feature/auth/jwt` -> `feature-auth-jwt`; detached ise `detached-<short-sha>`).
    - `harness_state_dir "$workspace"` -> `$workspace/.harness/state/<slug>` dizinini oluşturur, `.git/info/exclude` içine `.harness/` satırını idempotent ekler ve yolu basar.
    - `harness_code_tree_sha "$workspace"` -> `git ls-tree -r HEAD | grep -Ev $'\tdocs/(walkthroughs/|parking-lot\\.md$)' | git hash-object --stdin` çıktısını basar (henüz commit yoksa `"UNBORN"`).
    - `harness_has_glossary_section "$text_or_file_content"` -> `^## ([0-9]+\. )?(Teknik Terimler Sözlüğü|Technical Glossary)` başlığından sonra en az 1 tablo satırı (`^\|[^-]`) veya madde (`^[-*] \*\*`) bulunduğunu doğrular.
    - `emit_allow()`, `emit_deny(reason)`, `emit_force_ask(reason)`, `emit_overwrite(json_obj)`
  - `scripts/stamp-gate.sh` alt komutları (`--workspace <dir>` opsiyonel, varsayılan `$PWD`):
    - `stamp-gate.sh tree-sha [--workspace <dir>]`
    - `stamp-gate.sh canon --verdict PASS|FAIL [--plan <path>] [--allow-file <relpath> ...] [--workspace <dir>]` -> `canon-pass.json` yazar.
    - `stamp-gate.sh security --verdict PASS|FAIL --critical <n> --important <n> [--workspace <dir>]` -> (`critical==0 && important==0` değilse `PASS` yazmayı reddeder) `security-pass.json` yazar.
    - `stamp-gate.sh context7 --package <name> --version <ver> --source locked|greenfield-latest [--workspace <dir>]` -> `context7-verified.json` günceller.
    - `stamp-gate.sh dispatch --role <role> --type <typeName> --tier trivial_lookup|bounded_execution|multi_module_integration|critical_architecture_or_audit [--workspace <dir>]` -> katmanı deterministik olarak `model` (`flash_lite|flash|inherit|pro`) ve `effortProfile` (`LOW|MEDIUM|HIGH|MAX`) alanlarına eşleyip `subagent-dispatch.json` içine `consumed: false` olarak yazar.
    - `stamp-gate.sh verify-pr-stamps [--workspace <dir>]` -> hem `canon-pass.json` hem `security-pass.json` `PASS` ve güncel `codeTreeSha` ile eşleşiyorsa `0`, değilse açıklayıcı hata mesajıyla `1` döner.
    - `stamp-gate.sh clear-pr-audit [--workspace <dir>]` -> `pr-audit-pending.json` dosyasını siler.

- [ ] **Step 1: `tests/test-stamp-and-common.sh` içinde başarısız olacak testleri yaz**

Aşağıdaki senaryoları kapsayan test fonksiyonlarını yaz:
- `test_branch_slug_slashes_and_detached_head`: `feature/auth/jwt-refresh` dalında slug `feature-auth-jwt-refresh`, `git checkout --detach` durumunda `detached-<7char>` üretir (*Review Focus #1*).
- `test_code_tree_sha_ignores_walkthrough_and_parking_lot_but_changes_on_src_and_lessons`: `src/app.ts` veya `docs/canon/lessons.md` değişip commit edildiğinde `tree-sha` değişir; `docs/walkthroughs/2026-11-12-demo.md` veya `docs/parking-lot.md` commit edildiğinde `tree-sha` **aynı kalır** ve `verify-pr-stamps` bozulmaz.
- `test_security_stamp_rejects_pass_when_important_nonzero`: `--verdict PASS --critical 0 --important 1` çağrısı `!= 0` ile reddedilir.
- `test_dispatch_tier_mapping`: `trivial_lookup` -> `flash_lite`/`LOW`, `bounded_execution` -> `flash`/`MEDIUM`, `multi_module_integration` -> `inherit`/`HIGH`, `critical_architecture_or_audit` -> `pro`/`MAX`.
- `test_harness_ignore_detection`: `.harness-ignore` varken `harness_is_ignored` `0` döner.

- [ ] **Step 2: Testi çalıştır ve başarısız olduğunu doğrula**

Run: `bash tests/test-stamp-and-common.sh`
Expected: FAIL (`scripts/hooks/common.sh` ve `scripts/stamp-gate.sh` mevcut değil)

- [ ] **Step 3: `scripts/hooks/common.sh` ve `scripts/stamp-gate.sh` betiklerini uygula (`chmod +x`)**

Yukarıdaki `Interfaces` imzalarını POSIX `bash` + `jq` ile uygula; JSON yazımlarında geçici dosya + `mv` ile atomik güncelleme kullan.

- [ ] **Step 4: Testi çalıştır ve geçtiğini doğrula**

Run: `bash tests/run-all.sh`
Expected: PASS (`test-manifest.sh` ve `test-stamp-and-common.sh` geçer)

- [ ] **Step 5: Commit**

```bash
git add scripts/hooks/common.sh scripts/stamp-gate.sh tests/test-stamp-and-common.sh
git commit -m "feat(state): implement common hook library and stamp-gate CLI"
```

---

### Task 3: `SessionStart` Yönlendiricisi ve `PreToolUse` Dosya Yazım Kapısı (`session-start.sh`, `pre-edit-guard.sh`)

**Files:**
- Create: `scripts/hooks/session-start.sh`
- Create: `scripts/hooks/pre-edit-guard.sh`
- Create: `tests/test-edit-and-session-hooks.sh`

**Interfaces:**
- Consumes: `scripts/hooks/common.sh` (`harness_read_stdin`, `harness_is_ignored`, `harness_branch_name`, `harness_has_glossary_section`, `emit_allow`, `emit_deny`, `emit_force_ask`)
- Produces:
  - `scripts/hooks/session-start.sh`: `stdin` ortak alanlarını alır; `{"injectSteps":[{"systemMessage":"..."}]}` JSON'u döner (aktif dal, `glossary.md`/`flows.md`/`lessons.md` durumu, `graphify-out/graph.json` durumu, eksik `gh`/`jq` varsa `harness-doctor.sh` uyarısı ve `jev` + `run-quiet.sh` protokol özeti).
  - `scripts/hooks/pre-edit-guard.sh`: `stdin` `toolCall` (`name`: `write_file|edit_file`, `args.Path`, `args.Content`, `args.Replacement`, `args.Append`) alır ve şu 3 kuralı sırayla uygular:
    1. **`main`/`master` Kilidi:** Depoda en az 1 commit varsa ve dal `main`/`master` ise çalışma alanı içindeki dosyalarda `docs/superpowers/specs/*` ve `docs/canon/*` **dışındaki** tüm yazımları `deny` eder.
    2. **Doküman Sonu Sözlük Kapısı:** `toolCall.name == "write_file"` ve `args.Append != true` iken hedef yol `README.md`, `docs/superpowers/specs/*.md`, `docs/superpowers/plans/*.md`, `docs/walkthroughs/*.md` veya `docs/**/*.md` (`docs/canon/glossary.md` ve `docs/parking-lot.md` hariç) ise `harness_has_glossary_section "$content"` yanlışsa `deny` eder.
    3. **Anlık Güvenlik Kapısı:** Yazılan metinde (`Content` veya `Replacement`) açık özel anahtar (`-----BEGIN [A-Z ]*PRIVATE KEY-----`), `eval(`, `dangerouslySetInnerHTML` veya ham SQL dizge birleştirmesi (`SELECT .* \+ |INSERT INTO .* \+ `) yakalanırsa (`docs/` ve `tests/` altındaki doküman/test dosyaları hariç üretim kodunda) `emit_deny` döner; Angular `bypassSecurityTrust` kalıbında meşru kullanıcı onayı gerekebileceği için `emit_force_ask` döner; aksi halde `emit_allow` döner.

- [ ] **Step 1: `tests/test-edit-and-session-hooks.sh` içinde başarısız olacak testleri yaz**

Test senaryoları:
- `test_session_start_injects_status_and_respects_harness_ignore`: Normal depoda `injectSteps[0].systemMessage` dal ve kanon durumunu içerir; `.harness-ignore` varken `{}` döner.
- `test_main_branch_blocks_src_edit_but_allows_spec_and_canon_draft`: `main` dalında `src/Order.cs` yazımı `deny`, `docs/superpowers/specs/2026-11-12-x.md` (sözlüklü) yazımı `allow` alır.
- `test_write_file_requires_non_empty_technical_glossary`: Sözlüksüz veya **yalnızca boş `## Teknik Terimler Sözlüğü` başlığı taşıyan** Plan/Walkthrough `deny` alır (*Review Focus #3*); `| Terim | Açıklama |` satırı içeren doküman `docs/canon/glossary.md` ve `docs/parking-lot.md` ile birlikte `allow` alır.
- `test_dangerous_patterns_blocked_in_production_files`: Feature dalında `src/auth.ts` içine `-----BEGIN RSA PRIVATE KEY-----` ve `eval(` yazımı `deny`, `bypassSecurityTrustHtml(` yazımı `force_ask` alır.

- [ ] **Step 2: Testi çalıştır ve başarısız olduğunu doğrula**

Run: `bash tests/test-edit-and-session-hooks.sh`
Expected: FAIL (`session-start.sh` ve `pre-edit-guard.sh` mevcut değil)

- [ ] **Step 3: `scripts/hooks/session-start.sh` ve `scripts/hooks/pre-edit-guard.sh` betiklerini uygula (`chmod +x`)**

`common.sh` yardımcıları ve `jq` ile tüm JSON girdi/çıktılarını güvenli biçimde işle.

- [ ] **Step 4: Testi çalıştır ve geçtiğini doğrula**

Run: `bash tests/run-all.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/hooks/session-start.sh scripts/hooks/pre-edit-guard.sh tests/test-edit-and-session-hooks.sh
git commit -m "feat(hooks): add SessionStart router and PreToolUse file-edit guard"
```

---

### Task 4: `PreToolUse` Komut Kapısı ve `PostToolUse` PR/Graphify Otomasyonu (`pre-command-guard.sh`, `post-command-hooks.sh`)

**Files:**
- Create: `scripts/hooks/pre-command-guard.sh`
- Create: `scripts/hooks/post-command-hooks.sh`
- Create: `tests/test-command-hooks.sh`

**Interfaces:**
- Consumes: `scripts/hooks/common.sh`, `scripts/stamp-gate.sh` (`verify-pr-stamps`, `tree-sha`)
- Produces:
  - `scripts/hooks/pre-command-guard.sh`: `toolCall.args.CommandLine` dizgesinden önce tek/çift tırnak içi sabit argümanları maskeleyip (`git commit -m "..."` yanlış pozitifini önlemek için) `&&`, `||`, `;`, `\n` segmentlerini ayrıştırır ve şu 4 kapıyı uygular:
    1. **Sonsuz Mobil Log Akışı Kilidi:** `-d` bayrağı içermeyen `adb logcat` veya `--last`/süre sınırı olmayan `simctl ... log stream` segmentini `deny` eder (`scripts/mobile-logs.sh` önerir).
    2. **PR-Only `main`/`master` Koruma Kapısı:** `git remote` boş değilse `git push ... main|master` komutunu ve aktif dal `main`/`master` iken `git merge` (`--ff-only` pull hariç) komutunu `deny` eder; `git remote` boşsa yerel `git merge` için aşağıdaki PR damga + walkthrough koşullarını arar.
    3. **Paket Kurulum Kapısı:** `npm install|i|add <pkg>`, `pnpm add <pkg>`, `yarn add <pkg>`, `dotnet add ... package <pkg>`, `uv add <pkg>`, `cargo add <pkg>` (çıplak `npm install`, `npm ci`, `dotnet restore` ve `-D`/`--save-dev` bayrakları ayıklanarak, `zod@^3.23.0` -> `zod`, `@angular/core@19.0.0` -> `@angular/core`) paket adını `.harness/state/<slug>/context7-verified.json` veya güncel Spec `Global Constraints` içinde arar; yoksa `deny` eder.
    4. **5 Maddeli Sert PR Açma Kapısı (`gh pr create`):** (a) Dal `main`/`master` değil ve `git status --porcelain` boş, (b) taban dal (`origin/main` varsa `origin/main..HEAD`, yoksa `main..HEAD`) farkında `docs/walkthroughs/*.md` eklenmiş/güncellenmiş ve içinde `>= 2` adet ```` ```mermaid ```` bloğu var, (c) farktaki tüm teknik `.md` dosyaları (`glossary.md` ve `parking-lot.md` hariç) dolu `## Teknik Terimler Sözlüğü` / `## Technical Glossary` içeriyor, (d) `stamp-gate.sh verify-pr-stamps` `0` dönüyor, (e) `canon-pass.json` içinde boş olmayan `allowedFiles` varsa farktaki her dosya ya `allowedFiles` içinde ya da `docs/{superpowers,canon,walkthroughs}/` veya `docs/parking-lot.md` altındadır.
  - `scripts/hooks/post-command-hooks.sh`:
    1. `gh pr create` başarılıysa (`error` boşsa) `pr-audit-pending.json` (`{"prUrl":"...","stopRetries":0}`) yazar.
    2. `gh pr merge` başarılıysa veya `main`/`master` dalında `git merge`/`git pull` başarılıysa ve `graphify-out/` mevcutsa artımlı güncelleme (`graphify-out/.graphify_python -m graphify --update --no-viz` veya `${HARNESS_GRAPHIFY_BIN:-graphify} --update --no-viz`) çalıştırır; hata olursa `.harness/logs/graphify-hook.log` dosyasına yazıp `{}` döner.

- [ ] **Step 1: `tests/test-command-hooks.sh` içinde başarısız olacak testleri yaz**

Test senaryoları:
- `test_infinite_mobile_log_streams_blocked_but_snapshot_allowed`: `adb logcat` ve `xcrun simctl spawn booted log stream` `deny`; `adb logcat -d --pid=123` `allow`.
- `test_quoted_commit_message_does_not_trigger_gates`: `git commit -m "chore: ready for gh pr create and adb logcat"` komutu `allow` alır (*Review Focus #2*).
- `test_chained_package_install_requires_context7_stamp`: `cd app && npm install zod@^3.23.0 --save-dev` damgasız `deny`, `stamp-gate.sh context7 --package zod --version 3.23.8 --source greenfield-latest` sonrası `allow`; çıplak `npm ci` ve `npm install` her zaman `allow` (*Review Focus #2*).
- `test_pr_only_main_blocks_direct_push_and_local_merge_when_remote_exists`: `origin` tanımlıyken `git push origin main` ve `main` üzerinde `git merge feat-x` `deny`.
- `test_hard_pr_gate_all_five_checks`: Kirli çalışma ağacı, `< 2` Mermaid içeren walkthrough, sözlüğü silinmiş doküman (*Review Focus #3*), bayat `codeTreeSha` damgası ve `allowedFiles` dışı *drive-by* değiştirilmiş `src/unrelated.ts` ayrı ayrı `deny` alır; hepsi tamamsa `gh pr create` `allow` alır.
- `test_post_command_sets_pr_audit_flag_and_triggers_graphify_on_merge`: `gh pr create` sonrası `pr-audit-pending.json` oluşur; sahte `HARNESS_GRAPHIFY_BIN` ile `gh pr merge` sonrası `--update --no-viz` çağrıldığı doğrulanır.

- [ ] **Step 2: Testi çalıştır ve başarısız olduğunu doğrula**

Run: `bash tests/test-command-hooks.sh`
Expected: FAIL (`pre-command-guard.sh` ve `post-command-hooks.sh` mevcut değil)

- [ ] **Step 3: `scripts/hooks/pre-command-guard.sh` ve `scripts/hooks/post-command-hooks.sh` betiklerini uygula (`chmod +x`)**

Tırnak maskeleme ve paket adı ayrıştırma mantığını `python3 -c` veya saf `jq`/POSIX yardımcısıyla net ve deterministik olarak kodla.

- [ ] **Step 4: Testi çalıştır ve geçtiğini doğrula**

Run: `bash tests/run-all.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/hooks/pre-command-guard.sh scripts/hooks/post-command-hooks.sh tests/test-command-hooks.sh
git commit -m "feat(hooks): add PreToolUse command gates and PostToolUse PR/Graphify hooks"
```

---

### Task 5: Hibrit `jev` Alt Ajan `overwrite` Kancası ve PR Sonrası `Stop` Kapısı (`pre-subagent-guard.sh`, `stop-gate.sh`)

**Files:**
- Create: `scripts/hooks/pre-subagent-guard.sh`
- Create: `scripts/hooks/stop-gate.sh`
- Create: `tests/test-subagent-and-stop-hooks.sh`

**Interfaces:**
- Consumes: `scripts/hooks/common.sh`, `.harness/state/<slug>/subagent-dispatch.json`, `.harness/state/<slug>/pr-audit-pending.json`
- Produces:
  - `scripts/hooks/pre-subagent-guard.sh`: `toolCall.args` (`TypeName`, `Role`, `Prompt`, `Model`) okur:
    - `security-reviewer` -> ön kayıt aramadan `Model: "pro"`, `EFFORT_PROFILE: MAX` ile `overwrite`.
    - `pr-auditor` -> ön kayıt aramadan `Model: "pro"`, `EFFORT_PROFILE: HIGH` (kayıtta `MAX` varsa `MAX`) ile `overwrite`.
    - `browser` -> `Model` boşsa `"flash"` olarak `overwrite`, kullanıcı açıkça başka model vermişse korur; `image-generator` -> doğrudan `allow`.
    - `self`, `research`, `canon-auditor` ve diğer özel alt ajanlar -> `subagent-dispatch.json` içinde `.entries[$Role]` (`consumed == false`) kaydı yoksa `deny`; varsa `consumed = true` günceller, `canon-auditor` için katman `trivial_lookup|bounded_execution` ise `Model: "pro"` + `HIGH` tabanına yükseltir ve `jq --arg` ile `[EFFORT_PROFILE: <SEVİYE> — <direktif>]\n\n<Prompt>` başlığını idempotent olarak `overwrite` eder.
  - `scripts/hooks/stop-gate.sh`: `terminationReason == "NO_TOOL_CALL"` ve `pr-audit-pending.json` mevcutken `stopRetries < 2` ise `stopRetries` değerini `+1` artırıp `{"decision":"continue","reason":"..."}` döner; `stopRetries >= 2` olduğunda sonsuz döngüyü önlemek için `{}` döner.

- [ ] **Step 1: `tests/test-subagent-and-stop-hooks.sh` içinde başarısız olacak testleri yaz**

Test senaryoları:
- `test_security_and_pr_auditor_auto_overwrite_to_pro`: `Model: "flash_lite"` ile çağrılan `security-reviewer` otomatik `overwrite.Model == "pro"` ve `EFFORT_PROFILE: MAX` alır.
- `test_self_and_research_denied_without_jev_dispatch_and_consumed_once`: Kayıtsız `self` çağrısı `deny` alır; `stamp-gate.sh dispatch --role "Task 1 Implementer" --type self --tier bounded_execution` sonrası ilk çağrı `overwrite.Model == "flash"` + `MEDIUM` alır, aynı rolle ikinci kayıtsız çağrı `consumed == true` olduğu için `deny` alır.
- `test_canon_auditor_floor_upgrade`: `trivial_lookup` ile kaydedilen `canon-auditor` çağrısı `flash_lite` yerine taban koruma ile `pro` / `HIGH` seviyesine yükseltilir.
- `test_multiline_prompt_with_quotes_backticks_and_dollar_preserved_idempotently`: İçinde `` `code` ``, `"quotes"`, `$HOME` ve çoklu satır bulunan `Prompt` bayt-bayt korunur ve zaten `[EFFORT_PROFILE:` içeriyorsa ikinci kez öneklenmez (*Review Focus #4*).
- `test_stop_gate_blocks_twice_then_releases_and_clears`: `pr-audit-pending.json` varken 1. ve 2. `NO_TOOL_CALL` `continue` döner, 3. deneme `{}` döner; `stamp-gate.sh clear-pr-audit` sonrası ilk denemede `{}` döner.

- [ ] **Step 2: Testi çalıştır ve başarısız olduğunu doğrula**

Run: `bash tests/test-subagent-and-stop-hooks.sh`
Expected: FAIL

- [ ] **Step 3: `scripts/hooks/pre-subagent-guard.sh` ve `scripts/hooks/stop-gate.sh` betiklerini uygula (`chmod +x`)**

Tüm `overwrite` nesnelerini yalnızca `jq -n --arg model ... --arg prompt ...` ile oluştur.

- [ ] **Step 4: Testi çalıştır ve geçtiğini doğrula**

Run: `bash tests/run-all.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/hooks/pre-subagent-guard.sh scripts/hooks/stop-gate.sh tests/test-subagent-and-stop-hooks.sh
git commit -m "feat(hooks): add hybrid jev subagent overwrite guard and post-PR Stop gate"
```

---

### Task 6: Context Kalkanı (`run-quiet.sh`), Mobil Simülatör Süzgeci (`mobile-logs.sh`) ve Ortam Teşhisi (`harness-doctor.sh`)

**Files:**
- Create: `scripts/run-quiet.sh`
- Create: `scripts/mobile-logs.sh`
- Create: `scripts/harness-doctor.sh`
- Create: `tests/test-utilities.sh`

**Interfaces:**
- Consumes: `scripts/hooks/common.sh` (veya ortak `.harness/` dizin kuralı), `jq`, `python3`
- Produces:
  - `scripts/run-quiet.sh [--workspace <dir>] <etiket> -- <komut...>`:
    - Çıktıyı `.harness/logs/<UTC-timestamp>-<etiket>.log` ve `.harness/logs/last.log` dosyasına yazar.
    - `exit 0` -> tek satır `✅ PASS [<etiket>] (süre: <N>s, warnings: <W> — log: .harness/logs/last.log)` basar (`warning|WARN|CS[0-9]{4}|TS[0-9]{4}` satır sayısıyla).
    - `exit != 0` -> orijinal çıkış kodunu korur (`exit $rc`), `❌ FAIL [<etiket>] (exit: <rc> — log: .harness/logs/last.log)` başlığıyla en fazla `80` anlamlı hata/stack-trace satırı basar.
  - `scripts/mobile-logs.sh --platform ios|android [--bundle-id <id>] [--package <pkg>] [--last <dur>] [--screenshot <out.png>] [--workspace <dir>]`:
    - Test edilebilirlik için `HARNESS_XCRUN_BIN` (varsayılan `xcrun`), `HARNESS_ADB_BIN` (varsayılan `adb`), `HARNESS_DIAG_REPORTS_DIR` (varsayılan `$HOME/Library/Logs/DiagnosticReports`) ortam değişkenlerini destekler.
    - `ios`: `simctl spawn booted log show --style compact --last "${last:-2m}" --predicate ...` çıktısını ve `HARNESS_DIAG_REPORTS_DIR` altındaki en yeni eşleşen `.ips`/`.crash` dosyasının çökme yığınını birleştirip `.harness/logs/mobile-ios-last.log` dosyasına yazar; ekrana `<= 100` satır süzülmüş özet basar.
    - `android`: `adb shell pidof <pkg>` ile PID bulup `adb logcat -d --pid=<PID>` (uygulama kapalıysa paket adına göre filtre) + `adb logcat -b crash -d` çıktısını `.harness/logs/mobile-android-last.log` dosyasına yazar; ekrana `<= 100` satır basar.
  - `scripts/harness-doctor.sh [--workspace <dir>] [--json]`:
    - Test izolasyonu için `HARNESS_CONFIG_DIR` (varsayılan `$HOME/.gemini/config`) ve `HARNESS_TYPESAFE_KEY_FILE` (varsayılan `$HOME/.config/typesafe/key`) ortam değişkenlerini destekler.
    - 6 kontrol grubunu (CLI/`gh auth`, `superpowers` + `firebase`/`postman`/`chrome-devtools-plugin`, 8 MCP sunucusu, gizlilik korumalı `TYPESAFE_API_KEY`, LSP/Graphify/platforma duyarlı mobil araçlar, aktif proje kanon/`.harness` durumu) denetler; zorunlu eksikte `exit 1`, tam hazırlıkta `exit 0` döner.

- [ ] **Step 1: `tests/test-utilities.sh` içinde başarısız olacak testleri yaz**

Test senaryoları:
- `test_run_quiet_swallows_3000_lines_on_pass_and_counts_warnings`: 3.000 satır + `2` adet `warning CS0168` basan başarılı komutta stdout tam **1 satır** (`warnings: 2`) döner ve `.harness/logs/last.log` 3.002 satırı korur.
- `test_run_quiet_preserves_nonzero_exit_code_and_caps_failure_output`: `exit 7` ile 300 satır hata basan komutta çıkış kodu `7` kalır ve stdout `<= 85` satırla sınırlandırılır.
- `test_mobile_logs_ios_and_android_mocked_binaries`: Sahte `xcrun` + örnek `.ips` crash dosyası ve sahte `adb` (`pidof` + 500 satır gürültülü logcat + `FATAL EXCEPTION`) ile her iki platformda sistem gürültüsünün elendiği, crash stack trace'in yakalandığı ve çıktının `<= 100` satır olduğu doğrulanır.
- `test_harness_doctor_json_and_zero_secret_leakage`: `TYPESAFE_API_KEY="ts_live_secret_98765"` ile hem metin hem `--json` modunda çalıştırıldığında `present` raporlanır ve çıktının hiçbir yerinde `ts_live_secret_98765` veya parçası geçmez (*Review Focus #5*); eksik MCP olduğunda `exit 1` ve `Fix:` komutu üretilir.

- [ ] **Step 2: Testi çalıştır ve başarısız olduğunu doğrula**

Run: `bash tests/test-utilities.sh`
Expected: FAIL

- [ ] **Step 3: `scripts/run-quiet.sh`, `scripts/mobile-logs.sh` ve `scripts/harness-doctor.sh` betiklerini uygula (`chmod +x`)**

Tüm betikleri POSIX uyumlu, hızlı ve gizli anahtar sızdırmaz biçimde kodla.

- [ ] **Step 4: Testi çalıştır ve geçtiğini doğrula**

Run: `bash tests/run-all.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/run-quiet.sh scripts/mobile-logs.sh scripts/harness-doctor.sh tests/test-utilities.sh
git commit -m "feat(tools): add run-quiet context shield, mobile-logs filter, and harness-doctor CLI"
```

---

### Task 7: Evrensel Orkestrasyon Kuralı (`rules/AGENTS.md`) ve 4 Platform Glob Kuralı (`rules/*.md`)

**Files:**
- Create: `rules/AGENTS.md`
- Create: `rules/dotnet-clean-arch.md`
- Create: `rules/angular-typescript.md`
- Create: `rules/ios-swift.md`
- Create: `rules/android-kotlin.md`
- Create: `tests/test-rules-and-agents.sh`

**Interfaces:**
- Consumes: Spec Bölüm 5, 5.1, 6.3–6.8, 6.10, 6.11
- Produces:
  - `rules/AGENTS.md` (`< 8,192` bayt, YAML frontmatter **yok**): `superpowers` aşamalarını saran zorunlu kapılar (`harness-orchestrator` `jev_classify`, `dependency-versions` + `context7`, `architecture-tradeoffs` ADR, `domain-canon` `glossary`/`flows`/`lessons`, anti-overengineering & `Rule of Three` & `docs/parking-lot.md`, hibrit `jev` alt ajan `dispatch` kuralı, `run-quiet.sh`, doküman sonu `## Teknik Terimler Sözlüğü`, `pre-pr-readiness` ve `review-pr`).
  - `rules/dotnet-clean-arch.md` (`trigger: glob`, `globs: **/*.cs, **/*.xaml, **/*.csproj, **/*.sln, **/*.slnx, **/Directory.Packages.props`): Saf C# Domain, CQRS Application, EF/Polly Infrastructure, RFC 7807 Presentation, `NetArchTest.Rules`/`ArchUnitNET` İngilizce `REMEDIATION:` fitness testi, `csharp-lsp` araçları, üretim kodunda İngilizce `XMLDoc` (papağan yorum yasağı).
  - `rules/angular-typescript.md` (`trigger: glob`, `globs: **/*.ts, **/*.tsx, **/*.html, **/angular.json, **/tsconfig*.json`): Bounded Context `model/`-`application/` (Signals)-`infrastructure/`-`presentation/` (Standalone, `@if/@for/@defer`), `@softarc/sheriff` veya `eslint-plugin-boundaries` `REMEDIATION:` kuralı, `typescript-lsp`, `@playwright/mcp` konsol/ağ kapısı + `Chrome DevTools`, üretim kodunda İngilizce `TSDoc`.
  - `rules/ios-swift.md` (`trigger: glob`, `globs: **/*.swift, **/Package.swift, **/*.xcodeproj/**`): SPM `Domain`/`Data`/`Features` (`@Observable`)/`App`, `Package.swift` + yasaklı `import` `REMEDIATION:` fitness testi, `mobile-logs.sh --platform ios`, üretim kodunda İngilizce `Swift DocC`.
  - `rules/android-kotlin.md` (`trigger: glob`, `globs: **/*.kt, **/*.kts, **/libs.versions.toml`): Gradle `:domain` (`kotlin("jvm")`)/`:data`/`:features:*` (UDF `StateFlow`, Compose), Konsist/JUnit `REMEDIATION:` fitness testi, `mobile-logs.sh --platform android`, üretim kodunda İngilizce `KDoc`.

- [ ] **Step 1: `tests/test-rules-and-agents.sh` içinde kural doğrulama testlerini yaz**

Test senaryoları:
- `test_agents_md_no_frontmatter_and_under_8kb`: `rules/AGENTS.md` ilk satırı `---` değildir, boyutu `< 8192` bayttır ve `jev_classify`, `stamp-gate.sh`, `run-quiet.sh`, `Teknik Terimler Sözlüğü`, `parking-lot.md` anahtar sözleşmelerini içerir.
- `test_platform_rules_valid_glob_frontmatter_and_under_24kb`: 4 platform kuralının her biri `trigger: glob` içerir, `globs:` satırında süslü parantez (`{}`) bulunmaz, boyutu `< 24576` bayttır, İngilizce `REMEDIATION:` örneği ve ilgili dokümantasyon standardını (`XMLDoc`, `TSDoc`, `DocC`, `KDoc`) barındırır.

- [ ] **Step 2: Testi çalıştır ve başarısız olduğunu doğrula**

Run: `bash tests/test-rules-and-agents.sh`
Expected: FAIL (`rules/*.md` dosyaları mevcut değil)

- [ ] **Step 3: Beş kural dosyasını (`rules/AGENTS.md` ve 4 platform kuralı) oluştur**

Özlü, net ve bütçe sınırlarına tam uyumlu kuralları yaz.

- [ ] **Step 4: Testi çalıştır ve geçtiğini doğrula**

Run: `bash tests/run-all.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add rules/AGENTS.md rules/dotnet-clean-arch.md rules/angular-typescript.md rules/ios-swift.md rules/android-kotlin.md tests/test-rules-and-agents.sh
git commit -m "feat(rules): add consolidated AGENTS.md and 4 platform Clean Architecture glob rules"
```

---

### Task 8: Uzman Denetçi Alt Ajanlar (`canon-auditor`, `security-reviewer`, `pr-auditor`)

**Files:**
- Create: `agents/canon-auditor.md`
- Create: `agents/security-reviewer.md`
- Create: `agents/pr-auditor.md`
- Modify: `tests/test-rules-and-agents.sh`

**Interfaces:**
- Consumes: `scripts/stamp-gate.sh` (`canon`, `security`, `clear-pr-audit`), `jev` MCP (`jev_ask`, `jev_triage`, `jev_check`, `jev_score`)
- Produces:
  - `agents/canon-auditor.md`: Antigravity subagent frontmatter (`name: canon-auditor`, `subagent: true`, `mainAgent: false`, `tools: [read_file, run_command, manage_task, call_mcp_tool]`); Niyet Çapası (*Intent Backtranslation*), `glossary.md` + `flows.md` + `lessons.md` uyumu, `jev_ask` yalınlık/karmaşıklık bütçesi testi (`>= 0.60` şişkinlik reddi), Clean Architecture sınır yönü, doküman sonu sözlük kontrolü ve `stamp-gate.sh canon` damgalama protokolü.
  - `agents/security-reviewer.md`: Frontmatter (`name: security-reviewer`, `subagent: true`, `mainAgent: false`, `tools: [read_file, run_command, manage_task, call_mcp_tool]`); `jev_triage` diff ön-elemesi, kimlik doğrulama/yetkilendirme, girdi doğrulama, secret sızıntısı, serileştirme, Firebase kuralları, mobil Keychain/Keystore kontrolü, `jev_score` kalibrasyonu ve `Critical == 0 && Important == 0` şartıyla `stamp-gate.sh security` damgası.
  - `agents/pr-auditor.md`: Frontmatter (`name: pr-auditor`, `subagent: true`, `mainAgent: false`, `tools: [read_file, run_command, manage_task, call_mcp_tool]`); 2 cümlelik **Intent Backtranslation**, `jev_triage` ön-elemesi, **7 boyutlu denetim** (1. Kod Dokümantasyonu/Papağan-Bayat Yorum, 2. Test Kapsamı, 3. Tip/Kontrat, 4. Sessiz Hata Analizi, 5. DDD/Clean Architecture Sınırı, 6. Overengineering/Kapsam Kayması Cezası, 7. Okunabilirlik & Glossary), `jev_check` spekülatif yorum filtresi (`< 0.70` elenir), `jev_score` ciddiyet kalibrasyonu ve `stamp-gate.sh clear-pr-audit` çağrısı.

- [ ] **Step 1: `tests/test-rules-and-agents.sh` dosyasına başarısız olacak alt ajan şema ve kontrat testlerini ekle**

Test senaryosu `test_subagents_frontmatter_and_audit_contracts`:
- Üç `agents/*.md` dosyasında `name:`, `description:`, `subagent: true`, `mainAgent: false`, `tools:` alanları mevcuttur; `^model:` ve `^color:` alanları **yoktur**.
- `canon-auditor.md` ve `pr-auditor.md` içinde `Intent Backtranslation`, `jev_check` / `jev_ask` ve ilgili `stamp-gate.sh` alt komutu yer alır; `pr-auditor.md` tüm 7 denetim boyutunu içerir.

- [ ] **Step 2: Testi çalıştır ve başarısız olduğunu doğrula**

Run: `bash tests/test-rules-and-agents.sh`
Expected: FAIL (`agents/*.md` mevcut değil)

- [ ] **Step 3: `agents/canon-auditor.md`, `agents/security-reviewer.md` ve `agents/pr-auditor.md` dosyalarını oluştur**

Her alt ajanın sistem istemini net girdi, araç sırası, `jev` eşikleri, çıktı şablonu ve `stamp-gate.sh` komutuyla eksiksiz yaz.

- [ ] **Step 4: Testi çalıştır ve geçtiğini doğrula**

Run: `bash tests/run-all.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add agents/canon-auditor.md agents/security-reviewer.md agents/pr-auditor.md tests/test-rules-and-agents.sh
git commit -m "feat(agents): add canon-auditor, security-reviewer, and 7-dimensional pr-auditor subagents"
```

---

### Task 9: 11 Süreç/Uzmanlık Skill'i, Kanon/Walkthrough Şablonları, Takım `README.md` Rehberi ve Uçtan Uca Paket Doğrulaması

**Files:**
- Create: `skills/harness-orchestrator/SKILL.md`
- Create: `skills/harness-doctor/SKILL.md`
- Create: `skills/architecture-tradeoffs/SKILL.md`
- Create: `skills/dependency-versions/SKILL.md`
- Create: `skills/domain-canon/SKILL.md`
- Create: `skills/domain-canon/templates/glossary-template.md`
- Create: `skills/domain-canon/templates/flows-template.md`
- Create: `skills/domain-canon/templates/lessons-template.md`
- Create: `skills/pre-pr-readiness/SKILL.md`
- Create: `skills/pre-pr-readiness/templates/walkthrough-template.md`
- Create: `skills/review-pr/SKILL.md`
- Create: `skills/entropy-sweep/SKILL.md`
- Create: `skills/playwright-e2e/SKILL.md`
- Create: `skills/mobile-diagnostics/SKILL.md`
- Create: `skills/revenuecat-integration/SKILL.md`
- Create: `README.md`
- Create: `tests/test-plugin-bundle.sh`

**Interfaces:**
- Consumes: Task 1–8 içindeki tüm betikler, kurallar ve alt ajanlar.
- Produces:
  - Her `skills/<folder>/SKILL.md` içinde klasör adıyla birebir eşleşen `name: <folder>` ve boş olmayan `description:` frontmatter'ı (toplam 11 skill).
  - 4 şablon (`glossary-template.md`, `flows-template.md`, `lessons-template.md`, `walkthrough-template.md` — son üçü `## Teknik Terimler Sözlüğü` bölümüyle biter; `walkthrough-template.md` en az 2 adet ```` ```mermaid ```` diyagram iskeleti ve 5 zorunlu bölümü taşır).
  - `playwright-e2e/SKILL.md`: `@playwright/mcp` (`browser_console_messages`, `browser_network_requests`), `Chrome DevTools` derin teşhis adımları ve `page.on('pageerror')` + `console.error` / `status >= 500` yakalayan İngilizce `REMEDIATION:` mesajlı temel fixture şablonu.
  - `README.md`: Türkçe kapsamlı takım kurulum kılavuzu (Global `~/.gemini/config/plugins/` ve Proje Bazlı `.agents/plugins/` + `.agents/plugins.json` kurulumu, `.harness-ignore`, `superpowers`, Marketplace eklentileri `firebase`/`postman`/`chrome-devtools-plugin`/`android-cli-plugin`, 8 zorunlu global MCP için kopyala-yapıştır `~/.gemini/config/mcp_config.json` şablonu + opsiyonel `XcodeBuildMCP`, güvenli `~/.config/typesafe/key` sarmalayıcı örneği, `harness-doctor.sh` doğrulaması, mimari akış özeti ve doküman sonu `## Teknik Terimler Sözlüğü`).

- [ ] **Step 1: `tests/test-plugin-bundle.sh` içinde tüm paketi ve uçtan uca PR yaşam döngüsünü doğrulayan başarısız testi yaz**

Test senaryoları:
- `test_all_eleven_skills_frontmatter_and_folder_match`: 11 skill dizininin tamamında `SKILL.md` mevcuttur ve frontmatter `name` alanı klasör adıyla birebir aynıdır.
- `test_templates_and_readme_glossary_and_mermaid_contracts`: `README.md`, `flows-template.md`, `lessons-template.md`, `walkthrough-template.md` ve mevcut tüm `docs/superpowers/{specs,plans}/*.md` dosyaları `harness_has_glossary_section` kontrolünden geçer; `walkthrough-template.md` en az 2 adet ```` ```mermaid ```` bloğu içerir; `README.md` içinde hiçbir gerçek gizli anahtar bulunmaz ve 8 zorunlu MCP sunucu adı da belgelenmiştir.
- `test_end_to_end_simulated_feature_lifecycle`: Geçici bir Git deposunda sırasıyla `SessionStart` -> `main` üzerinde kod yazım engeli -> `feat/billing` dalına geçiş -> `context7` paket damgası + paket kurulum izni -> `subagent-dispatch.json` kaydı + `invoke_subagent` `overwrite` -> `canon-pass.json` + `security-pass.json` + `walkthrough-template.md` tabanlı rehber commit'i -> `gh pr create` kapısından geçiş -> `PostToolUse` bayrağı -> `Stop` kapısının `pr-auditor` istemesi -> `clear-pr-audit` sonrası temiz kapanış adımlarının tamamını uçtan uca çalıştırıp doğrular.

- [ ] **Step 2: Testi çalıştır ve başarısız olduğunu doğrula**

Run: `bash tests/test-plugin-bundle.sh`
Expected: FAIL (`skills/*/SKILL.md` ve `README.md` mevcut değil)

- [ ] **Step 3: 11 `SKILL.md`, 4 şablon ve `README.md` dosyalarını oluştur**

Spec Bölüm 3.2 ve Bölüm 6.3–6.11 içindeki tüm eşik, araç ve mimari kontratları eksiksiz işle.

- [ ] **Step 4: Tüm test paketini (`run-quiet.sh` sarmalayıcısı dahil!) çalıştır ve `%100` geçtiğini doğrula**

Run: `./scripts/run-quiet.sh full-suite -- bash tests/run-all.sh`
Expected: `✅ PASS [full-suite]` (çıkış kodu `0`, tüm test dosyaları hatasız geçer)

- [ ] **Step 5: Commit**

```bash
git add skills/ README.md tests/test-plugin-bundle.sh
git commit -m "feat(skills,docs): add 11 harness skills, canon/walkthrough templates, README, and e2e bundle tests"
```

---

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| **Atomik Dosya Güncellemesi (`tmp + mv`)** | JSON durum dosyalarının yarım yazılmasını veya bozulmasını önlemek için önce geçici dosyaya yazılıp ardından tek işlemle hedef yola taşınması tekniği. |
| **`branch_slug`** | Git dal adlarındaki `/` ve özel karakterlerin dosya sisteminde güvenli dizin adına (`feature/auth` -> `feature-auth`) dönüştürülmüş biçimi. |
| **`codeTreeSha`** | PR rehberi ve otopark dokümanları commit edildiğinde denetim damgalarının bayatlamaması için bu meta-dokümanlar dışarıda bırakılarak hesaplanan Git ağaç karması (*hash*). |
| **Efor Profili (`EFFORT_PROFILE`)** | Antigravity `PreToolUse` `overwrite` kancası aracılığıyla alt ajan isteminin (`Prompt`) başına enjekte edilen araştırma derinliği ve kanıt bütçesi (`LOW`, `MEDIUM`, `HIGH`, `MAX`) direktifi. |
| **Fixture (Test Düzeni)** | Otomatik testlerin çalışması için gereken geçici Git deposu, sahte ikili (`mock binary`) veya tarayıcı hata dinleyicisi (`pageerror`) başlangıç ortamı. |
| **Idempotent (Eştkili)** | Aynı işlemin (ör. `.git/info/exclude` satırı veya `[EFFORT_PROFILE]` etiketi ekleme) birden çok kez çalıştırıldığında sonucu bozmadan aynı çıktıyı üretmesi özelliği. |
| **Karmaşıklık Bütçesi (*Complexity Budget*)** | Aşırı mühendisliği (*overengineering*) ve kapsam kaymasını önlemek için plan başında sabitlenen dosya sayısı, soyutlama gerekçesi ve kapsam dışı sınırlar bütünü. |
| **Remediation Injection (*Düzeltme Enjeksiyonu*)** | Kırılan bir mimari fitness veya E2E testinin hata mesajında ajana sorunu tam olarak nasıl düzelteceğini söyleyen İngilizce `REMEDIATION:` yönergesi döndürmesi deseni. |
| **Review Focus** | Uygulama planında ilk bakışta gözden kaçabilecek en olası 5 gerçek dünya uç durumunun (*edge case*) belirlenip doğrudan ilgili görevlerin testlerine çivilenmesi bölümü. |
| **TDD (*Test-Driven Development*)** | Önce başarısız olan otomatik testi yazma (*Red*), ardından testi geçirecek en yalın kodu yazma (*Green*) ve düzenleme (*Refactor*) döngüsü. |
