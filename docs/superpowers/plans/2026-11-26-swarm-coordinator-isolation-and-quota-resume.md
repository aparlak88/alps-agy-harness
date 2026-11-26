# Uygulama Planı: Swarm Coordinator-Only Koruması ve Çift Katmanlı Kota Bekleme / Otomatik Devam (`v1.4.0`)

**Tarih:** 2026-11-26  
**Hedef:** Antigravity Swarm oturumlarında koordinatör ajanın yalnızca koordinasyon yapmasını fiziksel `PreToolUse` kancalarıyla zorunlu kılmak; 5 saatlik veya haftalık kota dolduğunda işçileri öldürmeden/model değiştirmeden çift katmanlı (`schedule` + `harness-daemon` `agy --conversation`) otomatik bekleme ve devam mekanizmasını eklemek.

**Spec:** `docs/superpowers/specs/2026-11-26-swarm-coordinator-isolation-and-quota-resume-design.md`

---

## Global Constraints

- **Çekirdek Dosya Sayısı:** `tests/test-plugin-bundle.sh` kilidi gereği tam olarak `53` kalmalıdır (0 yeni çekirdek dosya).
- **`rules/AGENTS.md` Boyutu:** YAML frontmatter olmamalı, `< 8192` bayt sınırının altında kalmalı ve mevcut tüm test jetonlarını korumalıdır.
- **Bash 3.2 & Python Stdlib:** macOS `/bin/bash` 3.2 uyumluluğu ve sıfır harici Python paketi.
- **Sıcak Daemon / Soğuk Fallback Paritesi:** `daemon.py` ve `HARNESS_DISABLE_DAEMON=1` birebir aynı kararları vermelidir.

---

## Kapsam (`allowedFiles`)

- `README.md`
- `plugin.json`
- `rules/AGENTS.md`
- `scripts/lib/harness_core.py`
- `scripts/stamp-gate.sh`
- `sidecars/harness-daemon/daemon.py`
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

---

## Görev Listesi ve Doğrulama Odağı

1. **Çekirdek Motor (`scripts/lib/harness_core.py`):**
   - `swarm-coordinator.json` yönetimi (`register_swarm_coordinator`, `is_active_swarm_coordinator`).
   - `evaluate_pre_edit`, `evaluate_pre_command` (güvenli salt-okunur + harness CLI beyaz listesi ve kabuk enjeksiyonu koruması), `evaluate_pre_subagent` ve `evaluate_pre_swarm` (`title` kayıt, `add` güvenli kayıt + `integrator` sözleşmesi, `model`/`kill` `force_ask` koruması).
   - Kota tespiti, pencere sınıflandırma (`5h`/`weekly`), zaman damgası ayrıştırma, `swarm-quota-wait.json` yaşam döngüsü, `attempt_swarm_quota_resume` (`agy --conversation`), `evaluate_stop_gate` `ERROR` yakalama ve `build_session_start_payload` kurtarma mesajları.
2. **Daemon Watchdog (`sidecars/harness-daemon/daemon.py`):**
   - Aktif kota beklemesi olan çalışma alanlarını TTL temizliğinden muaf tutma (`_load_registry` ve `watcher_loop`).
   - `watcher_loop` içinde `nextProbeEpoch` dolduğunda sıfır-token arka plan `_run_swarm_quota_resume` çalıştırma.
   - `GET /health` (`quotaWaits`), `POST /hook/stop-gate` ve `POST /event/swarm-quota-wait` uçları.
3. **CLI (`scripts/stamp-gate.sh`):**
   - `swarm-coordinator` ve `swarm-quota` alt komutları + daemon olay bildirimi.
4. **Kurallar, Skill'ler, `README.md` ve `plugin.json` (`1.4.0`):**
   - `rules/AGENTS.md` (`< 8192`B), `skills/harness-orchestrator/SKILL.md`, `skills/pre-pr-readiness/SKILL.md`, `README.md`, `plugin.json`.
5. **Kapsamlı TDD Testleri ve Tam Doğrulama:**
   - Tüm 9 test paketi `run-quiet.sh` ile yeşil; CWD-bağımsız `(cd /tmp && ...)` koşu; `docs/walkthroughs/2026-11-26-swarm-coordinator-isolation-and-quota-resume.md` ve `stamp-gate.sh review --kind tdd --auto-stamp`.

---

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| **Coordinator-Only Modu** | Swarm koordinatörünün dosya yazma, derleme/test, git mutasyonu ve alt ajan işi çalıştırmasının fiziksel kancalarla engellenip yalnızca koordinasyona ayrıldığı çalışma modu. |
| **Pure-Wait Quota Policy** | 5 saatlik veya haftalık kota dolduğunda işçileri öldürmeden ve model değiştirmeden kota yenilenene kadar bekleyen politika. |
| **Swarm Quota Watchdog** | `harness-daemon` içinde `nextProbeEpoch` anını sıfır token ile bekleyip `agy --conversation` üzerinden oturumu uyandıran arka plan gözcüsü. |
