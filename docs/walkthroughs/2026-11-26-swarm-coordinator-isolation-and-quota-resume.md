# Pull Request Mühendislik Rehberi: Swarm Coordinator-Only Koruması ve Çift Katmanlı Kota Bekleme / Otomatik Devam (`v1.4.0`)

---

## 1. Problem Bağlamı ve Mimari Kararlar

### Çözülen Gerçek Problem ve Kök Bağlam
`alps-agy-harness` (`v1.3.1`) içinde Swarm uyumluluk temeli bulunsa da iki kritik davranış boşluğu vardı:
1. **Koordinatör Rol Sızıntısı:** `/swarm` ile başlatılan bir oturumda koordinatör ajan fiziksel olarak kısıtlanmadığı için zaman zaman dosya yazabiliyor, test/derleme koşabiliyor, dal birleştirebiliyor veya `invoke_subagent` / `run_workflow` çağırabiliyordu.
2. **5 Saatlik ve Haftalık Kota Kesintileri:** Uzun soluklu Swarm oturumlarında Antigravity'nin 5 saatlik kayan penceresi veya haftalık kotası dolduğunda işçileri öldürmeden ve model değiştirmeden kota yenilenene kadar bekleyip kaldığı yerden devam eden bir kurtarma hattı yoktu.

### Seçilen Mimari Yaklaşım ve Gerekçesi
- **Dal-Bağımsız `swarm-coordinator.json` + Tam İzolasyon (`ADR-01`):** `.harness/state/swarm/swarm-coordinator.json` içinde `conversationId` anahtarlı koordinatör kaydı tutulur. Aktif koordinatör için `evaluate_pre_edit` tüm çalışma alanı yazmalarını reddeder (`.harness/` ve harici UI `plan.json` yolları hariç), `evaluate_pre_command` yalnızca salt-okunur inceleme ve `stamp-gate.sh`/`harness-doctor.sh` koordinasyon komutlarına izin verir (ve `$(...)`/backtick/dosyaya yönlendirme bypass'larını engeller), `evaluate_pre_subagent` ise `invoke_subagent` ve `run_workflow` çağrılarını reddeder. Birleştirme ve PR kapıları uzman `integrator` Swarm işçisine (`[SWARM_INTEGRATOR_CONTRACT]`) devredilir.
- **Saf Bekleme ve Çift Katmanlı Otomatik Devam (`ADR-02` & `ADR-03`):** Kota dolduğunda `swarm(action="model|kill")` çağrıları `force_ask` ile korunur. Katman 1'de koordinatör `swarm(action="models")` -> `stamp-gate.sh swarm-quota pause` -> `schedule` ile bekler. Katman 2'de koordinatörün kendisi `Stop(ERROR)` ile kotaya takılırsa `stop-gate.sh` anlık döngüye girmeden `{}` döner, `swarm-quota-wait.json` yazar ve `harness-daemon`'ı uyandırır. Daemon çalışma alanını TTL temizliğinden muaf tutar ve `nextProbeEpoch` zamanında `agy --conversation <id> --print=...` ile oturumu uyandırır; kota hâlâ doluysa yeni sıfırlama zamanını ayrıştırır veya sınırlı üstel geri çekilme uygular.

---

## 2. Mimari ve Veri Akışı Diyagramları

### Coordinator-Only Fiziksel Kanca Mimarisi
```mermaid
flowchart TD
    HookIn["HOOK_INPUT (conversationId, lastUserInput, toolCall)"] --> Check["is_active_swarm_coordinator()"]
    Check -->|"Worker prompt or different conversationId"| Normal["Normal Harness Rules"]
    Check -->|"Active Coordinator"| Tool{"Tool Name"}
    Tool -->|"write_file / edit_file"| EditDeny["evaluate_pre_edit: deny workspace edits (.harness & external allowed)"]
    Tool -->|"run_command"| CmdAllow{"_has_unsafe_shell_syntax + _is_allowed_coordinator_command_segment"}
    CmdAllow -->|"Read-only git/gh/ls or stamp-gate swarm-*/dispatch"| Allow["decision: allow"]
    CmdAllow -->|"Build, test, git commit/merge, gh pr create, >file, $()"| CmdDeny["decision: deny (delegate to workers)"]
    Tool -->|"invoke_subagent / run_workflow"| SubDeny["evaluate_pre_subagent: deny (delegate to planner/verifier/integrator)"]
    Tool -->|"swarm(add, name=integrator)"| IntHdr["Inject SWARM_INTEGRATOR_CONTRACT + SWARM_BRANCH_GUARD"]
```

### Çift Katmanlı Kota Bekleme ve Otomatik Devam Akışı
```mermaid
sequenceDiagram
    autonumber
    actor Coord as Swarm Coordinator
    participant Stop as stop-gate.sh
    participant State as .harness/state/swarm/swarm-quota-wait.json
    participant Daemon as harness-daemon (watcher_loop)
    participant Agy as agy --conversation

    Note over Coord: 5h veya haftalik kota doldu (Stop ERROR)
    Coord->>Stop: Stop(terminationReason="ERROR", error="RESOURCE_EXHAUSTED...")
    Stop->>State: record_swarm_quota_pause(window="5h|weekly", nextProbeEpoch)
    Stop->>Daemon: notify_swarm_quota_wait()
    Stop-->>Coord: {} (anlik kota dongusune girmez)
    Note over Daemon: Workspace TTL eviction muaf; sifir token bekleme
    Daemon->>State: status="resuming" (nextProbeEpoch <= now)
    Daemon->>Agy: agy --conversation <id> --print="[SWARM_QUOTA_AUTO_RESUME]..."
    alt Kota hala dolu (429 / quota error)
        Agy-->>Daemon: exit != 0 (quota exhausted)
        Daemon->>State: capped exponential backoff -> status="waiting"
    else Kota acildi
        Agy-->>Daemon: exit 0 -> Coordinator models + swarm-quota resume + @mention workers
        Daemon->>State: status="resumed", attemptCount++
    end
```

---

## 3. Dosya Bazlı Değişiklik Analizi

### `README.md` — [GÜNCELLENDİ] (`Dokümantasyon`)
- **Ne Değişti / Ne Üretildi?:** Başlık sürümü `v1.4.0` olarak güncellendi; `### Antigravity Swarm ile Kullanım` altına Sıkı Coordinator-Only (`swarm-coordinator.json`), `integrator` Swarm işçisi ve 5 Saatlik/Haftalık Saf Bekleme Kota Kurtarma (`swarm-quota-wait.json`, `harness-daemon` `agy --conversation` watchdog) maddeleri eklendi; Bölüm 8 bileşen tablosu ve `## Teknik Terimler Sözlüğü` güncellendi.
- **Neden Değişti / Neden Üretildi?:** Kullanıcıların ve geliştiricilerin Coordinator-Only kurallarını ve uzun soluklu oturumlardaki otomatik kota bekleme/devam akışını doğrudan dokümantasyondan öğrenebilmesi için güncellendi.

### `plugin.json` — [GÜNCELLENDİ] (`Eklenti Manifestosu`)
- **Ne Değişti / Ne Üretildi?:** `version` alanı `"1.3.1"` değerinden `"1.4.0"` değerine yükseltildi.
- **Neden Değişti / Neden Üretildi?:** Yeni Coordinator-Only fiziksel kanca koruması ve çift katmanlı kota kurtarma yeteneği minör sürüm artışı olarak işaretlendi.

### `rules/AGENTS.md` — [GÜNCELLENDİ] (`Evrensel Orkestrasyon Kuralı`)
- **Ne Değişti / Ne Üretildi?:** Bölüm 1–10 metinleri mevcut 47 zorunlu test jetonu korunarak sıkıştırıldı (`7793` bayt `< 8192` sınırı altında); `## 11. Swarm Coordinator-Only, Worker/Integrator & Pure-Wait Quota Recovery` bölümü eklendi.
- **Neden Değişti / Neden Üretildi?:** `always_on` kural dosyasında Antigravity'nin 8 KB sınırını aşmadan koordinatöre mutlak devretme kuralını, `integrator` rolünü ve Saf Bekleme kota kurtarma protokolünü zorunlu kılmak için güncellendi.

### `scripts/lib/harness_core.py` — [GÜNCELLENDİ] (`Paylaşımlı Çekirdek Kütüphane`)
- **Ne Değişti / Ne Üretildi?:** Dal-bağımsız `get_swarm_state_dir()`, `register_swarm_coordinator()`, `is_active_swarm_coordinator()`, `_has_unsafe_shell_syntax_for_coordinator()`, `_is_allowed_coordinator_command_segment()`, `_tokenize_raw_segments()` içinde `>&` / `&>` yönlendirme ayrıştırma düzeltmesi, `SWARM_INTEGRATOR_ROLE_RE` / `SWARM_INTEGRATOR_CONTRACT_HEADER`, `is_quota_exhausted_error()`, `classify_quota_window()`, `parse_quota_reset_epoch()`, `record_swarm_quota_pause()`, `attempt_swarm_quota_resume()`, `evaluate_pre_edit`/`evaluate_pre_command`/`evaluate_pre_subagent`/`evaluate_pre_swarm` koordinatör ve `force_ask` korumaları, `evaluate_stop_gate` `ERROR` yakalayıcısı, `build_session_start_payload` kurtarma satırları ve `swarm-coordinator`/`swarm-quota` CLI alt komutları eklendi.
- **Neden Değişti / Neden Üretildi?:** Sıcak daemon ve soğuk fallback arasında tam eşitlikle hem Coordinator-Only fiziksel kapılarını hem de 5 saatlik/haftalık kota bekleme ve otomatik devam durum makinesini tek doğruluk kaynağında yürütmek için güncellendi.

### `scripts/stamp-gate.sh` — [GÜNCELLENDİ] (`Damga ve Durum CLI`)
- **Ne Değişti / Ne Üretildi?:** `usage()`, `cmd_swarm_coordinator()` ve `cmd_swarm_quota()` alt komutları eklendi (`pause`, `resume`, `status`, `clear`, `attempt-resume`, `--resume-at`, `--wait-seconds`, `--buffer-seconds`, `--window`, `--member`); `pause` çağrısı sonrası sıcak `harness-daemon`'a `/event/swarm-quota-wait` bildirimi gönderilmesi sağlandı.
- **Neden Değişti / Neden Üretildi?:** Koordinatörün oturum içi kota duraklatma/devam durumunu Bash 3.2 uyumlu CLI üzerinden kaydetmesi ve arka plan daemon bekleyicisini anında kurabilmesi için güncellendi.

### `sidecars/harness-daemon/daemon.py` — [GÜNCELLENDİ] (`Arka Plan Sidecar Daemon`)
- **Ne Değişti / Ne Üretildi?:** `HarnessDaemonState` içine `_quota_resume_inflight`, `active_quota_wait_count()`, `notify_swarm_quota_wait()` ve `_run_swarm_quota_resume()` eklendi; `_load_registry()` ve `watcher_loop()` aktif kota beklemesi olan çalışma alanlarını TTL temizliğinden muaf tutacak ve `nextProbeEpoch <= now` olduğunda arka planda `agy --conversation` uyandırması yapacak şekilde güncellendi; `GET /health` (`quotaWaits`), `POST /hook/stop-gate` ve `POST /event/swarm-quota-wait` eklendi.
- **Neden Değişti / Neden Üretildi?:** Koordinatörün kendi kotası dolup `Stop(ERROR)` ile durduğu senaryoda sıfır token harcayarak 5 saatlik ve 7 günlük pencereleri bekleyip oturumu otomatik devam ettirmek için güncellendi.

### `skills/harness-orchestrator/SKILL.md` — [GÜNCELLENDİ] (`Orkestrasyon Skill'i`)
- **Ne Değişti / Ne Üretildi?:** `## 8. Antigravity Swarm Orkestrasyon Modu (Coordinator-Only & Kota Kurtarma)` bölümü sıkı Coordinator-Only kuralları, uzman işçi rolleri (`planner`, `implementer-*`, `verifier`, `integrator`) ve Çift Katmanlı Saf Bekleme Kota Kurtarma protokolüyle yenilendi.
- **Neden Değişti / Neden Üretildi?:** Orkestratör ajana `/swarm` başlatıldığında hangi rolleri nasıl dağıtacağını ve 5 saatlik/haftalık kota sınırında hangi adımları izleyeceğini net tanımlamak için güncellendi.

### `skills/pre-pr-readiness/SKILL.md` — [GÜNCELLENDİ] (`PR Hazırlık Skill'i`)
- **Ne Değişti / Ne Üretildi?:** `Swarm Entegrasyon Dalı Kuralı` callout notu birleştirme, Walkthrough, `canon-auditor`, `security-reviewer`, `tdd-pass`, `ui-pass`, `gh pr create` ve `pr-auditor` adımlarının koordinatör yerine uzman `integrator` Swarm işçisi tarafından yürütüleceğini belirtecek şekilde güncellendi.
- **Neden Değişti / Neden Üretildi?:** Tam izolasyonlu Coordinator-Only modeliyle `pre-pr-readiness` iş akışının çelişmesini önlemek için güncellendi.

### `docs/superpowers/specs/2026-11-26-swarm-coordinator-isolation-and-quota-resume-design.md` — [ÜRETİLDİ] (`Tasarım Spesifikasyonu`)
- **Ne Değişti / Ne Üretildi?:** Problem tanımı, hedefler, ADR-01/ADR-02/ADR-03 kararları (`jev_check`: `0.76`), durum dosyası şemaları ve CLI sözleşmelerini içeren tasarım dokümanı oluşturuldu.
- **Neden Değişti / Neden Üretildi?:** Uygulama öncesinde mimari kararları, güvenlik sınırlarını ve `53` dosya / `< 8192` bayt kısıtlarını kayıt altına almak için üretildi.

### `docs/superpowers/plans/2026-11-26-swarm-coordinator-isolation-and-quota-resume.md` — [ÜRETİLDİ] (`Uygulama Planı`)
- **Ne Değişti / Ne Üretildi?:** `Global Constraints`, `allowedFiles` kapsam listesi, 5 aşamalı görev listesi ve doğrulama odağını içeren uygulama planı oluşturuldu.
- **Neden Değişti / Neden Üretildi?:** Çok adımlı geliştirme sırasında kapsam disiplinini ve doğrulama kriterlerini sabitlemek için üretildi.

### `tests/test-command-hooks.sh` — [GÜNCELLENDİ] (`Komut Kancası Testleri`)
- **Ne Değişti / Ne Üretildi?:** `test_swarm_coordinator_only_command_allowlist_and_bypass_guards` testi eklendi (`git status >/dev/null 2>&1` dahil salt-okunur ve koordinasyon komutlarına izin, derleme/test/mutasyon/`$(...)`/backtick/yönlendirme/`find -delete` komutlarına red, işçiye izin).
- **Neden Değişti / Neden Üretildi?:** `pre-command-guard.sh` üzerinden koordinatör komut beyaz listesinin ve kabuk kaçış korumalarının regresyona karşı kilitlenmesi için güncellendi.

### `tests/test-edit-and-session-hooks.sh` — [GÜNCELLENDİ] (`Dosya ve Oturum Testleri`)
- **Ne Değişti / Ne Üretildi?:** `test_swarm_coordinator_only_pre_edit_and_session_start` testi eklendi (düz metinde yanlış pozitif olmaması, `/swarm` ve `title` ile koordinatör yazma reddi, `.harness/` ve harici UI `plan.json` izni, farklı `conversationId` işçisi izni ve `SessionStart` `[SWARM COORDINATOR MODE]` / `[SWARM QUOTA WAIT ACTIVE]` satırları).
- **Neden Değişti / Neden Üretildi?:** `pre-edit-guard.sh` ve `session-start.sh` davranışlarını tüm sınır durumlarıyla doğrulamak için güncellendi.

### `tests/test-manifest.sh` — [GÜNCELLENDİ] (`Manifesto Testleri`)
- **Ne Değişti / Ne Üretildi?:** `test_plugin_json_required_fields` içindeki beklenen sürüm `"1.4.0"` olarak güncellendi.
- **Neden Değişti / Neden Üretildi?:** `plugin.json` sürüm artışını manifesto test sözleşmesiyle eşitlemek için güncellendi.

### `tests/test-plugin-bundle.sh` — [GÜNCELLENDİ] (`Paket Bütünlüğü Testleri`)
- **Ne Değişti / Ne Üretildi?:** `README.md` içinde `Coordinator-Only` ve `swarm-quota-wait.json`, `skills/pre-pr-readiness/SKILL.md` içinde `integrator` kontrolleri eklendi (`53` çekirdek dosya sayacı korundu).
- **Neden Değişti / Neden Üretildi?:** Yeni dokümantasyon ve skill sözleşmelerinin çekirdek paket bütünlüğü testiyle doğrulanması için güncellendi.

### `tests/test-rules-and-agents.sh` — [GÜNCELLENDİ] (`Kurallar Testleri`)
- **Ne Değişti / Ne Üretildi?:** `rules/AGENTS.md` için `Coordinator-Only`, `integrator`, `swarm-quota`, `quota_resets` ve `schedule` jeton kontrolleri eklendi.
- **Neden Değişti / Neden Üretildi?:** `< 8192` bayt sıkıştırmaları sırasında yeni Swarm koordinatör ve kota kurallarının silinmemesini garanti altına almak için güncellendi.

### `tests/test-sidecar-daemon.sh` — [GÜNCELLENDİ] (`Sidecar Daemon Testleri`)
- **Ne Değişti / Ne Üretildi?:** `test_daemon_swarm_coordinator_parity_and_quota_auto_resume_watchdog` testi eklendi (sıcak daemon vs soğuk fallback paritesi, TTL muafiyeti, `/health` `quotaWaits`, ilk denemede `429` üstel geri çekilme ve ikinci denemede sahte `HARNESS_AGY_BIN` ile `status == "resumed"` geçişi ve `TYPESAFE_API_KEY` temizliği).
- **Neden Değişti / Neden Üretildi?:** Arka plan kota bekleyicisinin gerçek bir izole daemon süreci altında sıfır token harcayarak uyandırma yaptığını uçtan uca kanıtlamak için güncellendi.

### `tests/test-stamp-and-common.sh` — [GÜNCELLENDİ] (`Damga CLI Testleri`)
- **Ne Değişti / Ne Üretildi?:** `test_stamp_gate_swarm_coordinator_and_swarm_quota_cli` testi eklendi (`swarm-coordinator on|status|off`, `swarm-quota pause|status|resume|clear`, 5h/weekly `chunkedScheduleSeconds`, geçersiz argüman reddi).
- **Neden Değişti / Neden Üretildi?:** `stamp-gate.sh` yeni alt komutlarının deterministik CLI davranışını ve hata yönetimini kilitlemek için güncellendi.

### `tests/test-subagent-and-stop-hooks.sh` — [GÜNCELLENDİ] (`Alt Ajan ve Stop Testleri`)
- **Ne Değişti / Ne Üretildi?:** `test_swarm_coordinator_blocks_subagent_workflow_and_enforces_integrator_and_pure_wait` ve `test_stop_gate_detects_coordinator_quota_error_without_looping` testleri eklendi (`invoke_subagent`/`run_workflow` reddi, `integrator` sözleşmesi, worker'ın yardımcı açarken koordinatöre dönüşmemesi, `swarm(model|kill)` `force_ask` koruması, `Stop(ERROR)` 5h/weekly kota tespiti).
- **Neden Değişti / Neden Üretildi?:** Alt ajan delegasyon sınırlarını, Saf Bekleme `force_ask` kuralını ve `Stop` kancası kota tespitini tam kapsamlı doğrulamak için güncellendi.

---

## 4. Kritik İş Mantığı, Kenar Durumlar (Edge Cases) ve Hata Yönetimi

| Senaryo / Kenar Durum | Sistemin Davranışı ve Korunan Kural (*Invariant*) | Üretilen Yanıt / Durum |
| :--- | :--- | :--- |
| **Düz metinde `"swarm"` kelimesi** | Yalnızca `/swarm` slash komutu (`SWARM_SLASH_CMD_RE`) veya `swarm-coordinator.json` kaydı koordinatör sayılır. | Normal görevlerde yanlış pozitif `deny` oluşmaz |
| **Boş `conversationId` geriye dönük uyumu** | `swarm(action="add")` boş `conversationId` ile `"__default__"` koordinatör kaydı oluşturmaz. | Mevcut testler ve tekil akışlar kırılmaz |
| **Koordinatör `git status >/dev/null 2>&1`** | `_tokenize_raw_segments` `>&` ve `&>` yönlendirmelerini arka plan `&` olarak bölmez. | Salt-okunur yönlendirmeli komutlar güvenle geçer |
| **Kota `ERROR` anında `Stop` kancası** | Koordinatör kotaya takıldığında `evaluate_stop_gate` `{}` döner ve `swarm-quota-wait.json` yazar. | Anlık `continue` döngüsü olmaz; `harness-daemon` devralır |
| **Haftalık beklemelerde daemon ömrü** | `has_active_swarm_quota_wait(ws)` True iken `_load_registry` ve `watcher_loop` TTL eviction atlar. | 5 saatlik / 7 günlük beklemelerde kayıt silinmez |

---

## 5. Somut Doğrulama Kanıtları

1. **Tam Depo Test Paketi (`./scripts/run-quiet.sh full-tests -- ./tests/run-all.sh`):**
   `✅ PASS [full-tests] (süre: 324.4s, warnings: 0 — log: .harness/logs/last.log)` — **9/9 paket, 108/108 test, 0 hata:**
   - `tests/test-command-hooks.sh`: `14 passed, 0 failed`
   - `tests/test-edit-and-session-hooks.sh`: `14 passed, 0 failed`
   - `tests/test-manifest.sh`: `9 passed, 0 failed`
   - `tests/test-plugin-bundle.sh`: `3 passed, 0 failed` (`53` çekirdek dosya korundu)
   - `tests/test-rules-and-agents.sh`: `3 passed, 0 failed` (`rules/AGENTS.md` `7793` bayt `< 8192`)
   - `tests/test-sidecar-daemon.sh`: `19 passed, 0 failed`
   - `tests/test-stamp-and-common.sh`: `18 passed, 0 failed`
   - `tests/test-subagent-and-stop-hooks.sh`: `17 passed, 0 failed`
   - `tests/test-utilities.sh`: `11 passed, 0 failed`
2. **CWD-Bağımsız Koşu (`(cd /tmp && ... run-all.sh)`):**
   `✅ PASS [cwd-tmp-tests] (süre: 310.8s, warnings: 0 — log: .harness/logs/last.log)` — tüm paketler `/tmp` dizininden yeşil geçti.

---

## 6. Kapsam Dışı (`docs/parking-lot.md`) ve Operasyonel Notlar

- **Operasyonel Not:** Canlı `harness-daemon` sürecinin yeni `swarm-quota-wait` özelliklerini kullanması için eklenti güncellemesi sonrası arka plan daemon yeniden başlatılmalıdır (aksi halde önceki sürüm soketi devralana kadar mevcut soğuk fallback kancaları koruma sağlar).

---

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| **Coordinator-Only Modu** | Swarm koordinatörünün dosya düzenleme, derleme/test ve git mutasyonu yapmasının fiziksel kancalarla engellenip yalnızca koordinasyona ayrıldığı çalışma modu. |
| **Integrator Worker** | Swarm işçilerinin dallarını tek `feat/*` entegrasyon dalında birleştirip `pre-pr-readiness`, `gh pr create` ve `pr-auditor` kapılarını yürüten uzman işçi rolü. |
| **Pure-Wait Quota Policy** | 5 saatlik veya haftalık kota dolduğunda işçileri öldürmeden ve model değiştirmeden kota yenilenene kadar bekleyen politika. |
| **Capped Exponential Backoff** | Devam denemesi hâlâ kota hatası aldığında bekleme süresini üst sınır (`MAX_BACKOFF`) ile sınırlayarak katlayan yeniden deneme stratejisi. |
| **Walkthrough** | Bir PR'ın mimari kararlarını, değişen tüm dosyaların *Ne*/*Neden* analizlerini ve doğrulama kanıtlarını sunan mühendislik rehberi. |
