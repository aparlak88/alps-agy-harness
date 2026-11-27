# Tasarım Spesifikasyonu: Swarm Coordinator-Only Koruması ve Çift Katmanlı Kota Bekleme / Otomatik Devam (`v1.3.2`)

**Tarih:** 2026-11-26  
**Durum:** Onaylandı  
**Kapsam:** `alps-agy-harness` (`scripts/lib/harness_core.py`, `sidecars/harness-daemon/daemon.py`, `scripts/stamp-gate.sh`, `rules/AGENTS.md`, `skills/harness-orchestrator/SKILL.md`, `skills/pre-pr-readiness/SKILL.md`, `README.md`, `plugin.json`, `tests/*.sh`)

---

## 1. Niyet (Intent) ve Problem Tanımı

Mevcut `alps-agy-harness` (`v1.3.1`) Antigravity Swarm uyumluluğunda iki önemli operasyonel açık bulunmaktadır:
1. **Koordinatör Rol Sızıntısı:** Kullanıcı `/swarm` ile çoklu ajan çalışması başlattığında, koordinatör ajan (`Coordinator`) yalnızca koordinasyon yapmak yerine dosya yazmaya, derleme/test çalıştırmaya, dal birleştirmeye, Walkthrough üretmeye veya doğrudan `gh pr create` / `invoke_subagent` / `run_workflow` çağırmaya yönelebilmektedir. Bu durum hem kullanıcı kararlılığını bozar hem de koordinatörün swarm yönetimini duraklatır.
2. **Uzun Soluklu Swarm Oturumlarında 5 Saatlik / Haftalık Kota Kesintisi:** Uzun soluklu Swarm oturumlarında 5 saatlik kayan pencere (*5-hour rolling window*) veya haftalık kota (*weekly quota*) dolduğunda işçiler ve koordinatör durabilir. Mevcut sistemde kota yenilenene kadar bekleyip aynı modelle kaldığı yerden devam ettiren deterministik bir bekleme/uyandırma mekanizması yoktur.

Bu tasarım ile:
- **Tam İzolasyon (Coordinator-Only):** Aktif Swarm koordinatörü fiziksel `PreToolUse` kancalarıyla (`pre-edit-guard.sh`, `pre-command-guard.sh`, `pre-subagent-guard.sh`) yalnızca koordinasyon ve salt-okunur inceleme yapabilir; tüm işleri uzman Swarm işçilerine (`planner`, `implementer-*`, `verifier`, `integrator`) devreder.
- **Saf Bekleme (Pure Wait) ve Çift Katmanlı Otomatik Devam:** Kota dolduğunda işçiler öldürülmez ve kullanıcı açıkça istemedikçe model değiştirilmez (`swarm(action="model|kill")` aktif bekleme sırasında `force_ask` ile korunur). Oturum içi `schedule` katmanı ve oturum dışı `harness-daemon` sıfır-token arka plan bekleyicisi (`agy --conversation`) kota açıldığında oturumu otomatik devam ettirir.

---

## 2. Hedefler, Kapsam Dışı (Non-Goals) ve Anti-Hedefler

### Hedefler (Goals)
- **Fiziksel Coordinator-Only Koruması:** `.harness/state/swarm/swarm-coordinator.json` (dal-bağımsız durum dosyası) üzerinden aktif koordinatör `conversationId` takibi, yazma/düzenleme reddi, salt-okunur + harness CLI beyaz listeli komut filtresi, `invoke_subagent`/`run_workflow` reddi ve `integrator` işçi sözleşmesi (`[SWARM_INTEGRATOR_CONTRACT]`).
- **Saf Bekleme Kota Politikası:** `swarm-quota-wait.json` ile kota penceresini (`5h` | `weekly` | `unknown`), duraklatılan işçileri ve `resumeAtEpoch` / `nextProbeEpoch` zamanını kaydetmek; aktif bekleme sırasında `swarm(action="model|kill")` çağrılarını `force_ask` ile korumak.
- **Çift Katmanlı Otomatik Devam:**
  - *Katman 1 (Oturum İçi):* `swarm(action="models")` -> `quota_resets` -> `stamp-gate.sh swarm-quota pause` -> yerel `schedule(DurationSeconds=...)` -> kota açılınca `stamp-gate.sh swarm-quota resume` + `@mention`.
  - *Katman 2 (Arka Plan Daemon Watchdog):* Koordinatörün kendisi kotaya takılıp `Stop(terminationReason="ERROR")` ile durduğunda `stop-gate.sh` `{}` döner (anlık döngüye girmez), `swarm-quota-wait.json` yazar ve `harness-daemon`'ı uyandırır. Daemon çalışma alanını TTL temizliğinden muaf tutar ve `nextProbeEpoch` zamanında `agy --conversation <id> --print=...` ile oturumu uyandırır; kota hâlâ doluysa yeni sıfırlama zamanını ayrıştırır veya sınırlı üstel geri çekilme (*capped exponential backoff*) uygular.
- **Yeniden Başlatma Kurtarma:** `SessionStart` kancası aktif koordinatörler için `[SWARM COORDINATOR MODE]` ve bekleyen kota durumları için `[SWARM QUOTA WAIT ACTIVE]` bağlamını enjekte eder.

### Kapsam Dışı (Non-Goals)
- Otomatik çoklu sağlayıcı veya harici API anahtarına geçiş (*failover*) yapmak (Saf Bekleme kuralı gereği yasaktır).
- Mevcut `53` çekirdek dosya sayısını artırmak veya `rules/AGENTS.md` dosyasını `8192` bayt sınırının üzerine çıkarmak.

### Anti-Hedefler (Anti-Goals)
- Boş `conversationId` içeren mevcut kanca testlerini veya `/swarm` içermeyen normal sohbetleri yanlışlıkla koordinatör olarak kilitlemek.
- Kota `ERROR` sonrasında `stop-gate.sh` içinden `decision: "continue"` dönerek anlık kota hata döngüsü yaratmak.

---

## 3. Global Constraints

- **Çekirdek Paket Dosya Sayısı (`53`):** `tests/test-plugin-bundle.sh` kilidi gereği yeni çekirdek dosya açılmaz; tüm mantık mevcut dosyalara eklenir.
- **`rules/AGENTS.md` Boyut Kilidi:** YAML frontmatter içermez ve `< 8192` bayt sınırında kalır.
- **Platform & Güvenlik:** Python 3 standart kütüphanesi (sıfır harici paket), POSIX Bash `3.2`, `fcntl.flock` + atomik yazma, `shell=False` alt süreç çalıştırma ve `REVIEW_SCRUB_ENV_KEYS` ortam temizliği.
- **Sıcak Daemon / Soğuk Fallback Paritesi:** Tüm `PreToolUse`, `Stop` ve `SessionStart` kararları daemon açıkken ve `HARNESS_DISABLE_DAEMON=1` iken birebir aynıdır.

---

## 4. Architectural Decisions (ADR)

### ADR-01: Dal-Bağımsız `swarm-coordinator.json` + Fiziksel `PreToolUse` Kısıtlaması
- **Durum:** Onaylandı (`jev_check`: `0.76`)
- **Seçenekler:**
  - **Seçenek A (Seçilen — YAGNI):** `.harness/state/swarm/swarm-coordinator.json` içinde `conversationId` anahtarlı koordinatör durumunu saklayıp mevcut `evaluate_pre_edit`, `evaluate_pre_command` ve `evaluate_pre_subagent` fonksiyonlarını genişletmek.
    - *Artılar:* `53` dosya kilidini korur, dal geçişlerinden etkilenmez, işçileri `conversationId` ve `lastUserInput` üzerinden kesin ayırt eder.
    - *Eksiler:* `harness_core.py` içinde koordinatör komut beyaz listesi bakımı gerektirir.
  - **Seçenek B (Elenen):** Ayrı `swarm-coordinator-guard.sh` ve kanca grubu eklemek.
    - *Elenme Nedeni:* `53` çekirdek dosya sınırını bozar ve worktree/daemon mantığını kopyalar.

### ADR-02: Saf Bekleme Kota Politikası + `force_ask` Koruması
- **Durum:** Onaylandı
- **Karar:** Kota dolduğunda işçiler öldürülmez ve model otomatik değiştirilmez. `swarm-quota-wait.json` aktifken (`waiting`/`resuming`) koordinatörün `swarm(action="model")` veya `swarm(action="kill")` çağrıları `force_ask` ile kullanıcı onayına bağlanır.

### ADR-03: Çift Katmanlı Kota Bekleme (`schedule` + `Stop ERROR` → `harness-daemon` `agy --conversation`)
- **Durum:** Onaylandı
- **Seçenekler:**
  - **Seçenek A (Seçilen):** Oturum içi `schedule` + `Stop(ERROR)` kancası üzerinden `harness-daemon` arka plan bekleyicisi (`agy --conversation <id> --print=...`) ve `SessionStart` kurtarma mesajı.
    - *Artılar:* Koordinatörün kendi kotası dolsa bile sıfır token harcayarak 5 saatlik ve haftalık pencereleri bekler ve otomatik devam eder.
  - **Seçenek B (Elenen):** Harici `launchd`/`cron` betikleri kurmak.
    - *Elenme Nedeni:* Platform bağımlılığı ve daemon yaşam döngüsü dışına çıkan sahipsiz iş riski yaratır.

---

## 5. Durum Dosyaları ve CLI Sözleşmesi

- `.harness/state/swarm/swarm-coordinator.json`:
  - `coordinators[<convId|__default__>]`: `{active, explicitlyDisabled, title, source, workers[], startedAt, updatedAt}`
- `.harness/state/swarm/swarm-quota-wait.json`:
  - `{status: "waiting|resuming|resumed|cleared", conversationId, model, window: "5h|weekly|unknown", reason, pausedMembers[], source, pausedAt, resumeAt, resumeAtEpoch, nextProbeEpoch, attemptCount, lastAttemptAt, lastAttemptError, resumedAt}`
- CLI Alt Komutları (`scripts/stamp-gate.sh`):
  - `stamp-gate.sh swarm-coordinator on|off|status [--conversation-id <id>] [--title <title>] [--workspace <dir>]`
  - `stamp-gate.sh swarm-quota pause|resume|status|clear [--resume-at <iso>] [--wait-seconds <sec>] [--buffer-seconds <sec>] [--window 5h|weekly|unknown] [--model <id>] [--reason <text>] [--member <name> ...] [--conversation-id <id>] [--workspace <dir>]`

---

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| **Coordinator-Only Modu** | Swarm koordinatörünün dosya yazma, derleme/test, git mutasyonu ve alt ajan işi çalıştırmasının fiziksel kancalarla engellenip yalnızca koordinasyona ayrıldığı çalışma modu. |
| **Integrator Worker** | Swarm işçilerinin dallarını tek `feat/*` entegrasyon dalında birleştirip `pre-pr-readiness`, `gh pr create` ve `pr-auditor` kapılarını yürüten uzman işçi rolü. |
| **Pure-Wait Quota Policy** | 5 saatlik veya haftalık kota dolduğunda işçileri öldürmeden ve model değiştirmeden kota yenilenene kadar bekleyen politika. |
| **Capped Exponential Backoff** | Devam denemesi hâlâ kota hatası aldığında bekleme süresini üst sınır (`MAX_BACKOFF`) ile sınırlayarak katlayan yeniden deneme stratejisi. |
| **Zero-Token Watchdog** | Kota beklemesi süresince yapay zeka modeli çağırmadan yalnızca zamanlayıcı ve dosya durumu izleyen arka plan daemon döngüsü. |
