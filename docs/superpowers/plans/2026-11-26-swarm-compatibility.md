# Antigravity Swarm Tam Uyumluluk Uygulama Planı (`v1.1.0`)

**Tarih:** 2026-11-26  
**Hedef:** `alps-agy-harness` eklentisini Antigravity Swarm (`swarm` aracı, `workspace: "share"` / `"inherit"` / `"branch"`, paralel oturumlar, detached HEAD ve yeni Gemini 4 model aileleri) ile %95+ tam uyumlu hale getirmek; ardından izole scratchpad projesi üzerinde uçtan uca doğrulayıp PR ile `main` dalına birleştirmek.

---

## Global Constraints

- **Çalışma Zamanı Kilidi:** Yalnızca Python `>= 3.9` standart kütüphanesi, POSIX `bash`, `jq`, `git`, `curl` kullanılır; üçüncü parti paket bağımlılığı eklenmez.
- **`rules/AGENTS.md` Boyut Kilidi:** `rules/AGENTS.md` YAML frontmatter içermemeli ve kesinlikle `< 8192` bayt sınırının altında kalmalıdır (`tests/test-rules-and-agents.sh` içindeki 35 zorunlu anahtar belirtecin tamamı korunur).
- **Çekirdek Paket Dosya Sayısı:** `tests/test-plugin-bundle.sh` tarafından doğrulanan çekirdek dosya sayısı tam olarak `53` kalmalıdır; yeni çekirdek dosya eklenmeden mevcut dosyalar genişletilir.
- **Manifest Sürümü:** `plugin.json` sürümü (`1.1.0`) değiştirilmez (`tests/test-manifest.sh`).
- **Sıcak Daemon / Soğuk Fallback Paritesi:** `harness_core.py` değişiklikleri hem `daemon.py` üzerinden hem `HARNESS_DISABLE_DAEMON=1` soğuk fallback üzerinden birebir aynı sonucu üretmelidir; `common.sh` ve `harness_core.py` arasında slug ve model sınıflandırma paritesi korunur.
- **İki Dilli Standart & Sözlük:** Kod, yorumlar, docstring'ler ve yeni hata iletileri İngilizce (mevcut testlerin eşleştirdiği Türkçe mesajlar ve yeni Swarm başlıkları hariç); Markdown dokümanları Türkçe ve sonunda boş olmayan `## Teknik Terimler Sözlüğü` tablosu içerir.

---

## Karmaşıklık Bütçesi ve Kapsam (`allowedFiles` & `Out-of-Scope`)

- **Dosya Sayısı Bütçesi:** `0` yeni çekirdek dosya; `17` güncellenen mevcut dosya + `2` yaşam döngüsü dokümanı (`Plan`, `Walkthrough`).
- **`allowedFiles`:**
  - `README.md`
  - `hooks.json`
  - `rules/AGENTS.md`
  - `scripts/hooks/common.sh`
  - `scripts/lib/harness_core.py`
  - `scripts/stamp-gate.sh`
  - `skills/harness-orchestrator/SKILL.md`
  - `skills/pre-pr-readiness/SKILL.md`
  - `tests/test-command-hooks.sh`
  - `tests/test-edit-and-session-hooks.sh`
  - `tests/test-manifest.sh`
  - `tests/test-plugin-bundle.sh`
  - `tests/test-rules-and-agents.sh`
  - `tests/test-sidecar-daemon.sh`
  - `tests/test-stamp-and-common.sh`
  - `tests/test-subagent-and-stop-hooks.sh`
  - `tests/test-utilities.sh`
- **Soyutlama Gerekçesi:** Tüm kanca ve durum kuralları mevcut `scripts/lib/harness_core.py` tek doğruluk kaynağında genişletilir; ek yardımcı modül oluşturulmaz (`Rule of Three`).
- **Kapsam Dışı (`Out-of-Scope`):** `plugin.json` sürüm artışı, `swarm` için zorunlu bloke edici `dispatch` kapısı (sharding akışını kırmamak için non-blocking `overwrite.brief` kullanılır), yeni harici bağımlılık eklenmesi.

---

### Task 1: Phase 1A — P0 Swarm Sözleşmesi, `hooks.json` Matcher ve `evaluate_pre_swarm`

**Hedeflenen Dosyalar:** `rules/AGENTS.md`, `skills/harness-orchestrator/SKILL.md`, `hooks.json`, `scripts/lib/harness_core.py`, `tests/test-manifest.sh`, `tests/test-rules-and-agents.sh`, `tests/test-subagent-and-stop-hooks.sh`.

1. **`rules/AGENTS.md` (`< 8192` bayt, YAML frontmatter yok):**
   - Bölüm 1–10 metinlerini yaklaşık 500–700 bayt sıkıştır; ancak `tests/test-rules-and-agents.sh` (satır 53–86) içindeki 35 belirtecin tamamını birebir koru: `harness-orchestrator`, `jev_classify`, `TYPESAFE_API_KEY`, `harness-doctor.sh`, `dependency-versions`, `context7`, `architecture-tradeoffs`, `ADR`, `domain-canon`, `docs/canon/glossary.md`, `docs/canon/flows.md`, `docs/canon/lessons.md`, `Rule of Three`, `parking-lot.md`, `stamp-gate.sh`, `trivial_lookup`, `bounded_execution`, `multi_module_integration`, `critical_architecture_or_audit`, `Orchestrator`, `Carbon`, `Argon`, `Hydrogen`, `XHIGH`, `run-quiet.sh`, `mobile-logs.sh`, `Teknik Terimler Sözlüğü`, `REMEDIATION:`, `pre-pr-readiness`, `Dosya Bazlı Değişiklik Analizi`, `canon-auditor`, `security-reviewer`, `review-pr`, `pr-auditor`.
   - Kısa bir **Swarm Coordinator / Worker Mode** kuralı ekle:
     - **Coordinator:** `main` yerine tek entegrasyon dalına (`feat/*`) geçer, `jev_classify`/Spec/Plan'ı bir kez yürütür, yazan işçileri `workspace: "share"` ile alt dallarda çalıştırır, işçi dallarını entegrasyon dalında birleştirdikten sonra `pre-pr-readiness` (`canon-auditor`, `security-reviewer` via `invoke_subagent`), tek Walkthrough, `gh pr create` ve `pr-auditor` çalıştırır.
     - **Swarm Worker:** Koordinatörden `brief` aldığında yeniden `jev_classify`, `brainstorming`, Spec, Walkthrough veya `gh pr create` başlatmaz; kendi dalında/dosyalarında TDD, `context7`, `run-quiet.sh` ve güvenlik/sözlük kurallarıyla çalışır; `docs/parking-lot.md` ve `docs/canon/*` notlarını doğrudan düzenlemek yerine panoda `@coordinator`'a bildirir.
   - `wc -c rules/AGENTS.md` çıktısının `< 8192` olduğunu doğrula.
2. **`skills/harness-orchestrator/SKILL.md` (`< 24000` bayt):**
   - `## 8. Antigravity Swarm Orkestrasyon Modu` bölümünü ekle: entegrasyon dalı topolojisi (`feat/<konu>`), yazıcılar için `workspace: "share"` + alt dal, okuyucular için `workspace: "inherit"`, Swarm Worker kapsamı ve `swarm` (paralel işçiler) vs. `invoke_subagent` (salt-okunur `canon-auditor`, `security-reviewer`, `pr-auditor` profilleri) görev ayrımı.
3. **`hooks.json`:**
   - 3. `PreToolUse` matcher'ını `"invoke_subagent"` yerine `"invoke_subagent|swarm"` yap (`command` `./scripts/hooks/pre-subagent-guard.sh`, `timeout: 15` değişmez).
4. **`scripts/lib/harness_core.py`:**
   - Sabitler ekle:
     - `SWARM_WORKER_CONTRACT_HEADER = "[SWARM_WORKER_CONTRACT — Koordinatör brief kapsamına sadık kal; yeniden jev_classify, brainstorming, Spec, Walkthrough veya gh pr create çalıştırma; docs/parking-lot.md ve docs/canon/* önerilerini panoda @coordinator'a bildir.]"`
     - `SWARM_BRANCH_GUARD_HEADER = "[SWARM_BRANCH_GUARD — Koda dokunmadan önce kendi özellik dalını aç (git checkout -b feat/<konu>-<ad>); detached HEAD veya main üzerinde kalma.]"`
   - `evaluate_pre_swarm(workspace: Path, hook_input: dict[str, Any]) -> dict[str, Any]` fonksiyonunu ekle ve `evaluate_pre_subagent()` içinde `tool_name == "swarm"` olduğunda doğrudan çağır:
     - `action = str(args.get("action") or "").strip().lower()`. `action != "add"` ise `{"decision": "allow"}` döndür.
     - `brief = str(args.get("brief") or "")`; boşsa `{"decision": "allow"}` döndür.
     - `worker_name = str(args.get("name") or "").strip()`, `ws_mode = str(args.get("workspace") or "inherit").strip().lower()`.
     - `_try_consume_optional_dispatch` yardımcı fonksiyonuna `expected_type: Optional[str] = None` (varsayılan `None`) ve `cur_conv: str = ""` desteği ekle; `evaluate_pre_swarm` yalnızca `expected_type="swarm"` (kayıtta `typeName == ""` veya `"swarm"` ise eşleşir, `"self"`/`"research"` kayıtlarını tüketmez) olarak opsiyonel `worker_name` kontrolü yapar. Eşleşen geçerli `effortProfile` varsa onu, yoksa `"MEDIUM"` kullanır.
     - İdempotent başlık listesi oluştur:
       - `"[EFFORT_PROFILE:"` `brief` içinde yoksa `EFFORT_PROFILE_HEADERS[effort]` ekle.
       - `"[SWARM_WORKER_CONTRACT"` `brief` içinde yoksa `SWARM_WORKER_CONTRACT_HEADER` ekle.
       - `ws_mode in ("share", "branch")` ve `"[SWARM_BRANCH_GUARD"` `brief` içinde yoksa `SWARM_BRANCH_GUARD_HEADER` ekle.
     - Başlık listesi boşsa `{"decision": "allow"}` döndür; doluysa `new_brief = "\n".join(headers) + "\n\n" + brief` (orijinal `brief` baytlarını ve sondaki satır sonlarını koruyarak) ile `{"decision": "allow", "overwrite": {"brief": new_brief}}` döndür (`tasks`, `n`, `name`, `workspace`, `model`, `fork` alanlarına dokunma).
5. **Testler (TDD — önce RED yazıp doğrula, sonra implement et, sonra GREEN):**
   - `tests/test-manifest.sh`: `test_hooks_json_root_wiring` matcher listesini `["write_file|edit_file","run_command","invoke_subagent|swarm"]` olarak güncelle.
   - `tests/test-rules-and-agents.sh`: `rules/AGENTS.md` içinde `"Swarm"` ve `workspace: "share"` kontrollerini ekle.
   - `tests/test-subagent-and-stop-hooks.sh`: `test_swarm_pre_tool_use_brief_enrichment_and_passthrough` testini ekle (`status|models|title|model|kill` passthrough, `add` + `share` + `tasks` + çok satırlı UTF-8 + sondaki `\n\n`, `inherit` için branch guard yokluğu, idempotency, opsiyonel `swarm` dispatch tüketimi ve `"self"` kaydının tüketilmemesi).
   - Doğrulama: `bash tests/test-manifest.sh && bash tests/test-rules-and-agents.sh && bash tests/test-subagent-and-stop-hooks.sh`.

---

### Task 2: Phase 1B — P0 Detached HEAD Linked-Worktree Slug Stabilizasyonu

**Hedeflenen Dosyalar:** `scripts/lib/harness_core.py`, `scripts/hooks/common.sh`, `tests/test-stamp-and-common.sh`, `tests/test-command-hooks.sh`.

1. **`scripts/lib/harness_core.py` (`get_branch_slug`):**
   - `symbolic-ref` boş döndüğünde (detached HEAD):
     - `_run_git(workspace, ["rev-parse", "--git-dir", "--git-common-dir"])` çalıştır.
     - İki yolu `workspace` bazında mutlak hale getirip `os.path.realpath` ile çöz.
     - `real_git_dir != real_common_dir` ve `real_git_dir.parent.name == "worktrees"` ve `real_git_dir.name` dolu ise `f"detached-wt-{slugify_branch(real_git_dir.name)}"` döndür.
     - Aksi halde mevcut `f"detached-{short_sha}"` / `"detached-unknown"` davranışını koru (ana repo detached HEAD geriye dönük uyumlu kalır).
2. **`scripts/hooks/common.sh` (`harness_branch_slug`):**
   - `harness_core.py` ile %100 parite:
     - `symbolic-ref` başarısız olduğunda `git -C "$workspace" rev-parse --git-dir --git-common-dir` ile iki satırı oku, göreceli yolları `$workspace/` ile birleştirip `(cd ... && pwd -P)` ile canonical path'e çevir.
     - `real_gd != real_cd` ve `basename "$(dirname "$real_gd")"` == `"worktrees"` ise `basename "$real_gd"` adını aynı `sed` slug kuralıyla dönüştürüp `detached-wt-${wt_slug}` yazdır; yoksa `detached-${short_sha}` / `detached-unknown` yazdır.
3. **Testler (TDD):**
   - `tests/test-stamp-and-common.sh`: `test_detached_head_linked_worktree_stable_slug_across_commits` ekle (ana repo detached `detached-<7sha>`, linked `--detach` worktree `detached-wt-<name>`, `common.sh` == `harness_core.py` paritesi, yeni commit sonrası slug ve `context7-verified.json` korunumu).
   - `tests/test-command-hooks.sh`: `test_detached_linked_worktree_context7_survives_commit` ekle (detached linked worktree'de commit öncesi `context7` damgası sonrası commit atılsa bile `npm install` `allow` kalır).
   - Doğrulama: `bash tests/test-stamp-and-common.sh && bash tests/test-command-hooks.sh`.

---

### Task 3: Phase 2 — P1 Paralel Aynı-`Role` Dispatch, `HOOK_INPUT.cwd`, Güncel Model Aileleri ve `SessionStart` Guardrails

**Hedeflenen Dosyalar:** `scripts/lib/harness_core.py`, `scripts/hooks/common.sh`, `scripts/stamp-gate.sh`, `tests/test-subagent-and-stop-hooks.sh`, `tests/test-stamp-and-common.sh`, `tests/test-command-hooks.sh`, `tests/test-edit-and-session-hooks.sh`, `tests/test-sidecar-daemon.sh`.

1. **Paralel Aynı-`Role` Dispatch Kuyruğu + `conversationId` Yakınlığı (`scripts/lib/harness_core.py`, `scripts/stamp-gate.sh`):**
   - `scripts/stamp-gate.sh` (`cmd_dispatch`): isteğe bağlı `--conversation-id <id>` / `--conversation-id=<id>` (varsayılan `${HARNESS_CONVERSATION_ID:-}`) ekle ve `harness_core.py dispatch-register --conversation-id` ile ilet.
   - `scripts/lib/harness_core.py`:
     - `dispatch_register(..., conversation_id: str = "")`: `locked_state_file(state_dir, "subagent-dispatch")` altında:
       - `entry` oluştur (boş değilse `"conversationId": conversation_id` ekle).
       - `pendingQueues` sözlüğünü (`data.setdefault("pendingQueues", {})`) yönet: `role` için henüz `pendingQueues[role]` yokken `entries[role]` içinde tüketilmemiş eski bir kayıt varsa önce `[dict(entries[role])]` ile tohumla; ardından yeni `entry`'yi kuyruğa ekle; eski tüketilmiş kayıtları en fazla son 20 adet kalacak şekilde buda.
       - Geriye dönük uyumluluk için `entries[role] = dict(entry)` yaz.
     - `evaluate_pre_subagent` ve `_try_consume_optional_dispatch` içinde `pendingQueues[role]` varsa FIFO olarak eşleşen tüketilmemiş kaydı seç (önce `cur_conv` ile tam eşleşen `conversationId`, yoksa en eski uyumlu kayıt), `consumed = True` yap ve `entries[role]` durumunu kalan tüketilmemiş kayıt varsa bir sonrakine, yoksa `consumed: True` durumuna senkronize et. Kuyruk yoksa eski `entries[role]` mantığına düş. `mismatch_type`, `invalid_entry`, `saw_consumed` hata semantiğini aynen koru.
2. **`HOOK_INPUT.cwd` Çözümlemesi (`scripts/lib/harness_core.py`):**
   - `_resolve_initial_cwd(workspace: Path, hook_input: dict[str, Any]) -> Path` ekle: `hook_input.get("cwd")` geçerli bir dizinse `Path(os.path.realpath(...))`, değilse `workspace` döndür.
   - `evaluate_pre_command` ve `evaluate_post_command` içinde `iter_command_segments_with_cwd(cmd_line, initial_cwd)` kullan.
   - `evaluate_pre_edit` içinde: `file_path` göreceli ise ve `initial_cwd != workspace` ise, `file_path` önce `initial_cwd` üzerinden çözümlenir; kardeş worktree içine düşüyorsa `effective_ws = linked_wt` olarak değerlendirilir.
3. **Güncel Model Aileleri (`scripts/lib/harness_core.py` & `scripts/hooks/common.sh` — %100 Parite):**
   - `classify_parent_model` ve `harness_classify_parent_model`:
     - `*neon*` → `-low`/`(low)`/` low` ise `"argon_low"`, değilse `"neon"`.
     - Diğer eşleşmemiş `*gemini-4*` / `*gemini 4*` → low ise `"argon_low"`, değilse `"argon"`.
   - `resolve_subagent_model` ve `harness_resolve_subagent_model`:
     - `"neon"` ailesi `carbon` gibi frontier yönlendirilir (`trivial_lookup -> flash_lite`, `bounded_execution -> pro`, `multi_module_integration -> inherit if caller_model == "inherit" else pro`, `critical_architecture_or_audit -> inherit`).
     - `"custom"` ailesi `bounded_execution` için `"flash"` yerine `"pro"` döndürür (`unset` ve `flash` aileleri `"flash"` kalır).
4. **`SessionStart` Guardrails (`scripts/lib/harness_core.py` `build_session_start_payload`):**
   - `- Protocols:` altına Swarm Worker Mode satırı ekle.
   - `branch in ("main", "master")` ve `live_head != "UNBORN"` ise `[BRANCH GUARD]` satırı ekle.
   - `branch == "HEAD"` ise `[DETACHED HEAD]` satırı ekle.
5. **Testler (TDD):**
   - `tests/test-subagent-and-stop-hooks.sh`: aynı `role` paralel 2 dispatch → 2 tüketim + 3. `deny`, `conversationId` yakınlığı ve `gemini-4-neon-high` / `custom` testleri.
   - `tests/test-stamp-and-common.sh`: `neon`, `gemini-4-*` ve `custom` için Bash/Python parite testleri.
   - `tests/test-command-hooks.sh` & `tests/test-edit-and-session-hooks.sh`: `HOOK_INPUT.cwd` kardeş worktree (`git push`, `npm install`, `gh pr create`, `post-command-hooks.sh`, göreceli `write_file`) ve `SessionStart` (`Swarm Worker Mode`, `[BRANCH GUARD]`, `[DETACHED HEAD]`) testleri.
   - `tests/test-sidecar-daemon.sh`: sıcak daemon vs soğuk fallback paritesi (`swarm add`, `HOOK_INPUT.cwd`, paralel aynı-`Role` dispatch).
   - Doğrulama: `bash tests/test-subagent-and-stop-hooks.sh && bash tests/test-stamp-and-common.sh && bash tests/test-command-hooks.sh && bash tests/test-edit-and-session-hooks.sh && bash tests/test-sidecar-daemon.sh`.

---

### Task 4: Phase 3 — P2 `harness-doctor`, `pre-pr-readiness`, `README.md` ve Tam Paket Doğrulama

**Hedeflenen Dosyalar:** `scripts/lib/harness_core.py`, `skills/pre-pr-readiness/SKILL.md`, `README.md`, `tests/test-utilities.sh`, `tests/test-plugin-bundle.sh`.

1. **`scripts/lib/harness_core.py` (`run_doctor_checks`):**
   - `install_mode` kontrolü proje bazlı `.agents/plugins` veya `.agents/plugins.json` tespit ettiğinde `healthy` durumunu bozmayan `INFO` seviyesinde `"swarm_install_advisory"` kontrolü ekle (Swarm `share`/`branch` kopyalarında kancaların devralınması için global kurulum veya `--recurse-submodules` önerisi).
2. **`skills/pre-pr-readiness/SKILL.md`:**
   - Adım 2 altına **Swarm Entegrasyon Dalı Kuralı** notunu ekle (çoklu Swarm işçi dalları önce koordinatörün tek `feat/*` entegrasyon dalında birleştirilir, ardından tek bütünleşik Walkthrough + `canon-auditor` + `security-reviewer` çalıştırılır).
3. **`README.md`:**
   - **"Antigravity Swarm ile Kullanım"** alt bölümü ekle (entegrasyon dalı topolojisi, `workspace: "share"` + alt dal, `invoke_subagent|swarm` kancası, `detached-wt-*` kararlı slug, global kurulum önerisi).
   - Bölüm 8 Bileşenler Özeti tablosundaki `pre-subagent-guard.sh` açıklamasını `invoke_subagent|swarm` içerecek şekilde güncelle.
   - En sondaki `## Teknik Terimler Sözlüğü` tablosuna **`Swarm (Antigravity Swarm)`** terimini ekle.
4. **Testler (TDD) & Tam Paket Doğrulama:**
   - `tests/test-utilities.sh`: proje bazlı `.agents/plugins` ortamında `swarm_install_advisory` (`INFO`, `healthy: true`) kontrolünü test et.
   - `tests/test-plugin-bundle.sh`: `README.md` Swarm bölümü varlığını doğrula ve `53` çekirdek dosya + sözlük kontratının geçtiğini teyit et.
   - Tam koşu: `./scripts/run-quiet.sh full-suite -- ./tests/run-all.sh` ve `(cd /tmp && /Volumes/SDCARD/Projects/alps-agy-harness/tests/run-all.sh)`.

---

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| **Antigravity Swarm** | Koordinatör ve ortak mesaj panosu üzerinden paralel çalışan işçi ajanlardan oluşan çoklu ajan yürütme mimarisi. |
| **`detached-wt-<name>`** | Linked Git worktree içinde detached HEAD durumunda commit değişse bile `.harness/state/` yolunu sabit tutan çalışma ağacı kimlik slug'ı. |
| **`HOOK_INPUT.cwd`** | Antigravity kanca JSON yükünde aracın çalıştığı aktif çalışma dizinini bildiren alan. |
| **Non-Blocking Overwrite** | `swarm(action="add")` çağrısını reddetmeden `brief` başına sözleşme ve efor profili başlıklarını ekleyen `PreToolUse` dönüşümü. |
| **SDD (Subagent-Driven Development)** | Her görevi izole bir uygulayıcı alt ajana verip ardından bağımsız spec ve kod kalitesi denetimi çalıştıran geliştirme yöntemi. |
