# Opsiyonel Koşullu Sert UI Kapısı (`Impeccable`) Uygulama Planı

**Tarih:** 2026-11-26  
**Hedef:** `pbakaus/impeccable` modülünü UI/Frontend projelerinde algılandığında deterministik sert PR/merge kapısı (`ui-pass.json`) uygulayan opsiyonel bir bileşen olarak `alps-agy-harness` içine entegre etmek.  
**Tasarım Dokümanı:** [2026-11-26-impeccable-ui-gate-design.md](../specs/2026-11-26-impeccable-ui-gate-design.md)

---

## Global Constraints

- **Çalışma Zamanı Kilidi:** Yalnızca Python `>= 3.9` standart kütüphanesi, POSIX `bash`, `jq`, `git`, `curl` kullanılır; çekirdek paketlere yeni üçüncü parti bağımlılık eklenmez.
- **Çekirdek Paket Dosya Sayısı:** `tests/test-plugin-bundle.sh` tarafından doğrulanan izlenen dosya sayısı tam olarak `53` kalmalıdır.
- **`rules/AGENTS.md` Sınırları:** YAML frontmatter içermez, `< 8192` bayt sınırının altında kalır ve mevcut 37 zorunlu anahtar belirtecin tamamını korur.
- **Platform Kuralları & Manifest Kilidi:** `rules/*.md` içindeki `globs:` satırları, `agents/*.md` 6 satırlı frontmatter yapısı, `plugin.json` (`1.1.0`) ve `hooks.json` matcher dizisi değiştirilmez.
- **Test İzolasyonu:** `HARNESS_CONFIG_DIR` açıkça verildiğinde `detect_impeccable()` ana makinenin gerçek `~/.agents/skills/impeccable`, `~/.impeccable/bin/impeccable` veya `PATH` ikililerine düşmemelidir.

---

## Karmaşıklık Bütçesi ve Kapsam (`allowedFiles` & `Out-of-Scope`)

- **Dosya Bütçesi:** `0` yeni çekirdek dosya; `18` güncellenen mevcut dosya + `2` yaşam döngüsü dokümanı (`Spec`, `Plan`).
- **`allowedFiles`:**
  - `README.md`
  - `rules/AGENTS.md`
  - `rules/angular-typescript.md`
  - `rules/dotnet-clean-arch.md`
  - `rules/ios-swift.md`
  - `rules/android-kotlin.md`
  - `scripts/lib/harness_core.py`
  - `scripts/stamp-gate.sh`
  - `sidecars/harness-daemon/daemon.py`
  - `skills/harness-orchestrator/SKILL.md`
  - `skills/pre-pr-readiness/SKILL.md`
  - `skills/harness-doctor/SKILL.md`
  - `tests/test-stamp-and-common.sh`
  - `tests/test-edit-and-session-hooks.sh`
  - `tests/test-command-hooks.sh`
  - `tests/test-utilities.sh`
  - `tests/test-rules-and-agents.sh`
  - `tests/test-sidecar-daemon.sh`
- **Soyutlama Gerekçesi:** Tüm algılama, sınıflandırma, detector çalıştırma ve kapı kuralları mevcut `scripts/lib/harness_core.py` tek doğruluk kaynağında toplanır; daemon ile fallback birebir aynı kodu paylaşır (`Rule of Three`).
- **Kapsam Dışı (`Out-of-Scope`):** Impeccable dosyalarını repoya kopyalamak, `plugin.json` sürüm artışı, senkron `write_file`/`edit_file` içine tarayıcı/detector eklemek.

---

## Uygulama Adımları

1. **Çekirdek Motor (`scripts/lib/harness_core.py`, `scripts/stamp-gate.sh`, `sidecars/harness-daemon/daemon.py`):**
   - `detect_ui_workspace`, `classify_ui_files`, `detect_impeccable`, `run_impeccable_detect`, `ui_stamp_register`, `requires_ui_stamp` ekle.
   - `evaluate_pre_edit` içinde `.impeccable/` (private key kontrolü korunarak) ve kök `PRODUCT.md`/`DESIGN.md` taslak izinlerini ekle.
   - `evaluate_pre_command` içinde `impeccable live` için `IMPECCABLE_LIVE_COPY_AGENT=chat|off` kapısını (Gate 5) ve `gh pr create` / yerel `git merge` için `ui-pass.json` doğrulamasını ekle.
   - `verify_pr_stamps`, `compute_tree_and_stamp_state`, `run_doctor_checks` (`impeccable_ui`), `build_session_start_payload` (`Impeccable UI Gate` & `[UI ADVISORY]`), `daemon.py` signature izleme ve `stamp-gate.sh ui` CLI alt komutunu bağla.
2. **Kurallar, Skill'ler ve Dokümantasyon:**
   - `rules/AGENTS.md` (`< 8192` bayt) ve 4 platform kural dosyasına (`angular-typescript.md`, `ios-swift.md`, `android-kotlin.md`, `dotnet-clean-arch.md`) Impeccable görev ayrımı ve `stamp-gate.sh ui` kurallarını ekle.
   - `skills/harness-orchestrator/SKILL.md`, `skills/pre-pr-readiness/SKILL.md`, `skills/harness-doctor/SKILL.md` ve `README.md` dosyalarını güncelle.
3. **TDD Test Kapsamı:**
   - `tests/test-stamp-and-common.sh`, `tests/test-edit-and-session-hooks.sh`, `tests/test-command-hooks.sh`, `tests/test-utilities.sh`, `tests/test-rules-and-agents.sh` ve `tests/test-sidecar-daemon.sh` içine yeni test senaryolarını ekle.
4. **Tam Doğrulama ve Commit:**
   - `./scripts/run-quiet.sh full-tests -- bash tests/run-all.sh` ile tüm testleri çalıştır; `rules/AGENTS.md` boyutunu (`< 8192`) ve `53` dosya kilidini doğrula; değişiklikleri `feat/impeccable-ui-gate` dalına commit et.

---

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| **Dual-Condition Activation** | UI PR kapısının yalnızca dal farkında UI dosyası değiştiğinde ve Impeccable kurulu olduğunda zorunlu kılınması. |
| **Hook Parity (Daemon / Fallback)** | Arka plan `harness-daemon` açıkken ve `HARNESS_DISABLE_DAEMON=1` iken kancaların birebir aynı kararı üretmesi. |
| **Impeccable Detector** | Web arayüz dosyalarını LLM gerektirmeden 62 statik/DOM kuralına göre tarayan deterministik CLI aracı. |
| **Sandbox Guard** | `impeccable live` komutunun onaysız dış ajan tetiklemesini `IMPECCABLE_LIVE_COPY_AGENT` kontrolüyle engelleyen kanca. |
| **ui-pass.json** | `stamp-gate.sh ui` tarafından yazılan ve güncel `codeTreeSha` ile doğrulanan UI kalite damgası dosyası. |
