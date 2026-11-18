# `harness-daemon` Arka Plan Sidecar Uygulama Planı (`v1.1.0`)

**Tarih:** 2026-11-19  
**Hedef:** Sıfır harici bağımlılıklı Python 3 (`stdlib`) arka plan daemon sidecar'ı (`sidecars/harness-daemon/`), paylaşımlı tek doğruluk kaynağı (`scripts/lib/harness_core.py`), Unix Domain Socket sıcak kanca entegrasyonu, `.harness/cache/*.json` ön-hesaplama önbellekleri, otomatik test paketi ve `v1.1.0` sürüm artışı.  
**Spec:** [2026-11-19-harness-daemon-sidecar-design.md](file:///Volumes/SDCARD/Projects/alps-agy-harness/docs/superpowers/specs/2026-11-19-harness-daemon-sidecar-design.md)

---

## Global Constraints

- **Çalışma Zamanı Kilidi:** Yalnızca Python `>= 3.9` standart kütüphanesi, POSIX `bash`, `jq`, `git`, `curl` (`--unix-socket` destekli). Üçüncü parti `pip`/`npm` bağımlılığı yasaktır.
- **İki Dilli Standart:** Python kaynak dosyaları ve docstring'ler **İngilizce**; Markdown dokümanları (`Spec`, `Plan`, `Walkthrough`, `README.md`) **Türkçe** ve sonunda boş olmayan `## Teknik Terimler Sözlüğü` tablosu içerir.
- **Manifest & Bundle Uyumu:** `plugin.json` (`version: "1.1.0"`) yalnızca izin verilen anahtarları taşır; `hooks.json` matcher/timeout kontratı değişmez; `tests/test-plugin-bundle.sh` çekirdek dosya sayısı `49` → `53` olarak güncellenir.
- **Sıfır Sır Sızıntısı & Fail-Closed:** `TYPESAFE_API_KEY` değeri asla diske, cache'e, loglara veya soket yanıtlarına yazılmaz; soket erişim hatasında veya timeout'ta her kanca sessizce yerel deterministik kural motoruna düşer.

---

## Karmaşıklık Bütçesi ve Kapsam (`allowedFiles` & `Out-of-Scope`)

- **Dosya Sayısı Bütçesi:** `4` yeni çekirdek dosya + `13` güncellenen mevcut dosya + `3` yaşam döngüsü dokümanı (`Spec`, `Plan`, `Walkthrough`).
- **`allowedFiles` (Üretim / Test / Manifest / Skill):**
  - `.gitignore`
  - `plugin.json`
  - `README.md`
  - `scripts/lib/harness_core.py` *(Yeni)*
  - `sidecars/harness-daemon/sidecar.json` *(Yeni)*
  - `sidecars/harness-daemon/daemon.py` *(Yeni)*
  - `scripts/hooks/common.sh`
  - `scripts/hooks/session-start.sh`
  - `scripts/hooks/pre-edit-guard.sh`
  - `scripts/hooks/pre-command-guard.sh`
  - `scripts/hooks/post-command-hooks.sh`
  - `scripts/harness-doctor.sh`
  - `scripts/mobile-logs.sh`
  - `skills/harness-doctor/SKILL.md`
  - `tests/test-manifest.sh`
  - `tests/test-plugin-bundle.sh`
  - `tests/test-sidecar-daemon.sh` *(Yeni)*
- **Soyutlama Gerekçesi:** `scripts/lib/harness_core.py`, `daemon.py` ile 7 yerel hook/CLI betiği arasında ayrıştırma ve doğrulama kurallarının kopyalanmasını önleyen tek doğruluk kaynağıdır (`Rule of Three`).
- **Kapsam Dışı (`Out-of-Scope`):** Aux Pane Web UI (`has_web_ui`), zamanlanmış `"builtin": "schedule"` `entropy-sweep` sidecar'ı, arka planda sürekli `adb logcat` akışı.

---

## Uygulama Adımları

1. **`.gitignore` ve `plugin.json` (`v1.1.0`):** `.gitignore` sonuna `__pycache__/` ve `*.pyc` ekle; `plugin.json` içinde `"version": "1.1.0"` yap ve `"description"` alanını sidecar dahil güncelle.
2. **Ortak Çekirdek (`scripts/lib/harness_core.py`):** Git/state yardımcıları, `compute_code_tree_sha`, `parse_command_segments`, `extract_install_packages`, `build_spec_package_index`, `has_glossary_section`, `validate_walkthrough`, `compute_tree_and_stamp_state`, `verify_pr_stamps`, `evaluate_pre_edit`, `evaluate_pre_command`, `evaluate_post_command`, `build_session_start_payload`, iOS bundle ID & `.ips`/`.crash` ayrıştırıcı, `run_doctor_checks` (dahili `harness_daemon` kontrolü) ve fallback CLI alt komutlarını uygula.
3. **Sidecar Paketi (`sidecars/harness-daemon/sidecar.json` & `daemon.py`):** `sidecar.json` manifestosu; secure `/tmp/agy-hd-<uid>/d.sock` (`0700`/`0600`), `fcntl.flock` pasif bekleme, tek seferlik login shell `PATH` zenginleştirme, `TYPESAFE_API_KEY` startup-bool + scrub, `ThreadingUnixHTTPServer`, çoklu çalışma alanı TTL kaydı, hedefli `1.5s` watcher (`tree-state`, `spec-packages`, `doc-validation`, `health`, koşullu iOS `mobile-crashes`), single-flight debounced `graphify` işçisi ve `SIGTERM` temiz kapanış uygula.
4. **Mevcut Betik Entegrasyonları:** `common.sh` (`harness_daemon_call`), `session-start.sh`, `pre-edit-guard.sh`, `pre-command-guard.sh`, `post-command-hooks.sh`, `harness-doctor.sh` ve `mobile-logs.sh` betiklerini sıcak soket + fail-closed `harness_core.py` fallback mimarisine bağla.
5. **Testler & Dokümantasyon:** `tests/test-manifest.sh` (`1.1.0`), `tests/test-plugin-bundle.sh` (`53`), yeni `tests/test-sidecar-daemon.sh`, `skills/harness-doctor/SKILL.md` ve `README.md` güncellemelerini tamamla; `bash tests/run-all.sh` ile `9/9` test paketini doğrula.
6. **PR Hazırlığı, Denetimler ve `main` Merge:** Kapsamlı Türkçe walkthrough (`docs/walkthroughs/2026-11-19-harness-daemon-sidecar.md`), `canon-auditor`, `security-reviewer`, `gh pr create`, `pr-auditor`, `clear-pr-audit`, `gh pr merge --squash --delete-branch` ve `main` üzerinde son test koşusu.

---

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| **Single Source of Truth** | Kural ve ayrıştırma mantığının yalnızca `scripts/lib/harness_core.py` içinde tutulup daemon ile fallback arasında birebir eşitlik sağlanması. |
| **Fail-Closed Fallback** | Daemon yanıt vermediğinde veya bozuk veri döndüğünde işlemin izinsiz geçmeyip yerel deterministik kancaya devredilmesi. |
| **Single-Flight & Debounce** | Ardışık `graphify` tetiklemelerini 3 sn pencerede birleştirip çalışma alanı başına aynı anda tek alt süreç çalıştırma deseni. |
| **SemVer (`1.1.0`)** | Geriye dönük uyumlu yeni özellik eklendiğinde minor sürüm basamağının (`1.0.0` → `1.1.0`) artırılması standardı. |
