# Tasarım Spesifikasyonu: Claude Code CLI (`claude -p`) Spec/Plan İncelemesi, Antigravity Fallback ve Fiziksel TDD Kapsam Kapısı

**Tarih:** 2026-11-26  
**Durum:** Onaylandı  
**Kapsam:** `alps-agy-harness` (Çekirdek Python Motoru, `stamp-gate.sh`, Daemon, Orkestrasyon Kuralları, Skill'ler ve Test Paketi)

---

## 1. Niyet (Intent) ve Problem Tanımı

Mevcut `alps-agy-harness` mimarisinde:
1. **Spec ve Plan incelemeleri** yalnızca Antigravity'nin soyut 4 katmanlı `invoke_subagent` (`inherit | flash_lite | flash | pro`) mekanizması üzerinden `canon-auditor` ile yapılmakta; kullanıcının mevcut **Claude Pro (`claude` CLI)** aboneliği ve belirli model/efor eşleşmeleri (`opus/medium`, `sonnet/high`, `gemini-4-carbon-high`, `gemini-4-neon-medium`) kullanılamamaktadır.
2. **TDD birim test kapsamı** yalnızca süreç kuralları (`superpowers:test-driven-development`) ve PR sonrası `pr-auditor` denetimine bırakılmış olup `gh pr create` veya yerel `git merge` öncesinde `codeTreeSha` kilitli fiziksel bir kapıya (`tdd-pass.json`) bağlı değildir.

Bu tasarım, hem **Spec/Plan İncelemesini** hem de **TDD Birim Test Kapsam Denetimini** birincil olarak yerel **`claude -p`** (Claude Code CLI print modu) üzerinden çalıştırır; `claude` CLI mevcut değilse veya herhangi bir nedenle (oturum/auth hatası, kota/rate-limit, ağ kesintisi, zaman aşımı, sıfır dışı çıkış kodu) başarısız olursa **sessizce atlamadan** sebebini kullanıcıya bildirip Antigravity modelleri arasında seçim ister, **30 saniye** içinde yanıt alınamazsa otomatik olarak belirlenen Gemini 4 varsayılanına (`agy -p`) geçer ve TDD denetimini `tdd-pass.json` üzerinden sert PR/merge kapısına bağlar.

---

## 2. Hedefler, Kapsam Dışı (Non-Goals) ve Anti-Hedefler

### Hedefler (Goals)
- **Birincil Sağlayıcı (`claude -p`):**
  - **Spec / Plan Review:** `claude -p --model opus --effort medium --permission-mode plan --no-session-persistence --tools Read,Grep,Glob --output-format text` (son satırda makine-okunur `VERDICT_JSON: {...}`).
  - **TDD Kapsam Denetimi:** `claude -p --model sonnet --effort high --permission-mode plan --no-session-persistence --tools Read,Grep,Glob --output-format text` (son satırda makine-okunur `VERDICT_JSON: {...}`).
- **Şeffaf Hata Raporlama ve 30 Saniyelik Antigravity Fallback:**
  - `claude` CLI kurulu değilse veya herhangi bir nedenle başarısız olursa CLI **sessiz fallback yapmaz**; çıkış kodu `42` ve makine-okunur JSON (`status: "claude_unavailable"`, `reason`, `fallbackChoices`) döner.
  - Orkestratör hatanın tam sebebini kullanıcıya açıklar, Antigravity'deki Claude modeli ile Gemini 4 modeli arasında seçim sorar ve aynı turda **`schedule(DurationSeconds=30, TimerCondition="any")`** kurar.
  - 30 saniye içinde kullanıcı yanıt verirse seçilen modelle, yanıt gelmezse otomatik varsayılanla **`agy -p --mode plan --disable-slash-commands --model <id>`** çalıştırılır:

| İnceleme Türü | Birincil (`claude -p`) | Antigravity Claude (`agy -p`) | Antigravity Gemini / 30 sn Timeout (`agy -p`) | Durum Dosyası | PR Kapısı |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Spec / Plan Review** | `opus` (`medium`) | `claude-opus-5-5-medium` | `gemini-4-carbon-high` | `spec-plan-review.json` | Orkestrasyon & Kayıt |
| **TDD Kapsam Denetimi** | `sonnet` (`high`) | `claude-sonnet-5-5-high` | `gemini-4-neon-medium` | `tdd-pass.json` | **Fiziksel PR/Merge Kapısı** *(kod değiştiyse)* |

- **Koşullu Sert TDD Kapısı (`tdd-pass.json`):**
  - Dal farkında (`<base>..HEAD`) üretim kodu veya çalıştırılabilir betik dosyası değiştiyse (`docs/**`, `*.md`, `assets/**`, `medium-kit/**`, `.gitignore`, `.harness-ignore` hariç) `verify-pr-stamps`, `gh pr create` ve yerel `git merge` taze (`codeTreeSha` eşleşen), `verdict == "PASS"`, `criticalGaps == 0` ve `importantGaps == 0` içeren `tdd-pass.json` damgasını zorunlu kılar.
  - Salt dokümantasyon PR'larında `tdd-pass.json` kapısı pasiftir.
- **TDD Kapsam Denetim Rubriği:**
  - İnceleyici; değişen üretim kodu ve ilgili test dosyalarını salt-okunur okuyarak: (1) davranışsal doğrulama (totolojik mock-echo reddi), (2) kenar durumlar (`null`/boş/sınır/hata/rollback), (3) mutasyon direnci (yanlış sabit, dal, eksik yan etki, varsayılan dönüş, geçersiz girdi) ve (4) regresyon/eşzamanlılık bariyerlerini denetler; `criticalGaps` ve `importantGaps` sayılarını raporlar.
- **Çekirdek Kısıtların Korunması:**
  - `rules/AGENTS.md` `< 8192` bayt sınırında kalır.
  - Çekirdek eklenti dosya sayısı (`53`) korunur (yeni temel dosya açılmadan mevcut `scripts/lib/harness_core.py`, `scripts/stamp-gate.sh`, `sidecars/harness-daemon/daemon.py` genişletilir).
  - Test edilebilirlik için `HARNESS_CLAUDE_BIN` ve `HARNESS_AGY_BIN` ortam değişkeni geçersiz kılmaları (*override*) desteklenir; testler canlı API'ye çıkmadan sahte/mock ikililerle tüm yolları %100 deterministik doğrular.

### Kapsam Dışı (Non-Goals)
- Mevcut `canon-auditor`, `security-reviewer`, `pr-auditor` veya `ui-pass.json` (`impeccable`) kapılarını kaldırmak veya yerine geçmek.
- Spec/Plan incelemesini (`spec-plan-review.json`) `gh pr create` için bloklayıcı kapı yapmak (yalnızca TDD kapsamı `tdd-pass.json` bloklayıcıdır).
- Otomatik sayısal line/branch coverage aracı (`nyc`, `coverlet`, `jacoco`) zorunluluğu dayatmak.

### Anti-Hedefler (Anti-Goals)
- `claude -p` hatasını gizleyip kullanıcıya sebep söylemeden sessizce `agy -p`'ye düşmek.
- `claude -p` veya `agy -p` inceleyicilerine dosya yazma veya kabuk komutu çalıştırma yetkisi vermek (inceleyiciler kesinlikle **salt-okunur** kalmalıdır).
- `claude -p` / `agy -p` çağrılarını `shell=True` veya sınırsız zaman aşımıyla çalıştırmak.

---

## 3. Global Constraints

- **Platform & Runtime:** Python 3 standart kütüphanesi (sıfır harici Python paketi), POSIX/Bash `3.2` uyumluluğu (`scripts/stamp-gate.sh`, `tests/*.sh`).
- **Dosya & Boyut Kısıtları:** `rules/AGENTS.md` `< 8192` bayt; çekirdek eklenti dosya sayısı `53` (`tests/test-plugin-bundle.sh` kilidi).
- **Salt-Okunur İnceleyici İzolasyonu:**
  - `claude`: `--print --model <opus|sonnet> --effort <medium|high> --permission-mode plan --no-session-persistence --tools Read,Grep,Glob --output-format text` (prompt `stdin` üzerinden iletilir).
  - `agy`: `--model <model-id> --mode plan --disable-slash-commands --output-format text --print=<prompt>`
- **Güvenlik & Zaman Aşımı:** `subprocess.run(..., shell=False, timeout=HARNESS_REVIEW_TIMEOUT_SEC)` (varsayılan `300` sn); alt süreç ortamından `CLAUDECODE`, `TYPESAFE_API_KEY` ve hassas host token'ları temizlenir; `--auto-stamp` kirli çalışma ağacında (`dirtyWorkingTree: true`) damga yazmaz.
- **Kriptografik Tazelik:** `tdd-pass.json` mevcut `compute_code_tree_sha` kilidine bağlanır (`docs/walkthroughs/` ve `docs/parking-lot.md` değişiklikleri damgayı bozmaz; kod/test değişikliği damgayı bayatlatır).

---

## 4. Mimari Karar Kayıtları (ADR)

### ADR-01: Tek Merkezli Motor (`harness_core.py` + `stamp-gate.sh`) vs. Ayrı Betikler
- **Durum:** Onaylandı
- **Seçenekler:**
  - **Seçenek A (Seçilen — YAGNI):** `stamp-gate.sh review` ve `stamp-gate.sh tdd` alt komutlarını doğrudan `scripts/lib/harness_core.py` ve `scripts/stamp-gate.sh` içine eklemek.
    - *Artılar:* Çekirdek paket dosya sayısı (`53`) değişmez; `codeTreeSha`, `get_state_dir`, `locked_state_file`, worktree çözümleme ve daemon `mtime` takibi tek merkezden paylaşılır.
    - *Eksiler:* `harness_core.py` dosya boyutu ~250 satır büyür.
  - **Seçenek B (Elenen):** Ayrı `scripts/external-review.sh` ve `scripts/lib/review_runner.py` eklemek.
    - *Elenme Nedeni:* Paket dosya sayısını artırır ve mevcut durum/hash/worktree yardımcılarının tekrar bağlanmasını gerektirir.

### ADR-02: İki Aşamalı CLI Çıkış Sözleşmesi (`exit 42`) + `schedule(DurationSeconds=30)`
- **Durum:** Onaylandı
- **Seçenekler:**
  - **Seçenek A (Seçilen):** `stamp-gate.sh review --kind spec-plan|tdd` varsayılan olarak `--provider claude` çalıştırır. Başarısız olursa (ikili yok, auth/kota hatası, ağ hatası, zaman aşımı, exit != 0) `stdout`'a yapılandırılmış JSON (`status: "claude_unavailable"`, `reason`, `fallbackChoices`) yazıp `exit 42` döner. Orkestratör kullanıcıya sebebi bildirerek Antigravity Claude vs. Gemini 4 sorar ve `schedule(DurationSeconds=30, TimerCondition="any")` kurar; seçim veya 30 sn dolumu sonrası `stamp-gate.sh review --provider agy --model <id>` çalıştırır.
  - **Seçenek B (Elenen):** Bash içinde `read -t 30` ile terminalden sormak.
    - *Elenme Nedeni:* Antigravity `run_command` ortamı non-TTY olduğundan `read -t 30` kullanıcıya ulaşmadan boşa düşer. Chat + `schedule(30s)` Antigravity'de gerçekten çalışan tek zaman aşımı yoludur.

### ADR-03: Kod Değişikliğine Koşullu `tdd-pass.json` PR/Merge Kapısı
- **Durum:** Onaylandı (Kullanıcı Kararı A1)
- **Karar:** `requires_tdd_stamp(workspace, diff_files)` dal farkında doküman-dışı kod/betik dosyası değiştiğinde `True` döner. `verify_pr_stamps`, `evaluate_pre_command` (`gh pr create` ve yerel `git merge`) ve `sidecars/harness-daemon/daemon.py` (`tddStampStatus` / `tddStampValid`) taze `tdd-pass.json` (`verdict == "PASS"`, `criticalGaps == 0`, `importantGaps == 0`, `codeTreeSha` eşleşmesi) arar. `spec-plan` incelemesi ise `.harness/state/<branch>/spec-plan-review.json` dosyasına kaydedilir ancak PR kapısını bloklamaz.
- **Sonuç:** Mevcut uçtan uca PR testleri (`test-plugin-bundle.sh`, `test-command-hooks.sh`, `test-stamp-and-common.sh`, `test-sidecar-daemon.sh`) kod değişikliği yapan senaryolarda `stamp-gate.sh tdd --verdict PASS ...` adımını da içerecek şekilde güncellenir; salt doküman PR'larında ise `tdd-pass.json` istenmediği ayrıca test edilir.

---

## 5. CLI ve Veri Sözleşmesi

### 5.1 `stamp-gate.sh review`
```bash
./scripts/stamp-gate.sh review \
  --kind spec-plan|tdd \
  [--provider claude|agy] \
  [--model <explicit-model-id>] \
  [--effort <low|medium|high|xhigh|max>] \
  [--target <relpath> ...] \
  [--auto-stamp] \
  [--workspace <dir>]
```
- **Çıkış Kodları:**
  - `0`: İnceleme tamamlandı (JSON özet `stdout`'a, ham inceleme raporu `.harness/state/<branch>/<kind>-review.md` ve meta veri `<kind>-review.json` dosyasına yazılır; `--auto-stamp` ve `kind=tdd` iken yapılandırılmış karar `PASS` ise `tdd-pass.json` da yazılır).
  - `42`: Birincil `claude` CLI yok veya çalıştırılamadı (`stdout` JSON içinde `status: "claude_unavailable"`, `reason`, `fallbackChoices` döner).
  - `1`: Geçersiz argüman, `agy` fallback hatası veya beklenmeyen sistem hatası.

### 5.2 `stamp-gate.sh tdd`
```bash
./scripts/stamp-gate.sh tdd \
  --verdict PASS|FAIL \
  --critical-gaps <n> \
  --important-gaps <n> \
  --provider claude-cli|agy-cli|subagent \
  --model <model-id> \
  [--effort <level>] \
  [--file <relpath> ...] \
  [--workspace <dir>]
```
- `--verdict PASS` iken `--critical-gaps > 0` veya `--important-gaps > 0` ise fail-closed reddeder (`exit 1`) ve `tdd-pass.json` yazmaz.
- `tdd-pass.json` şeması:
  ```json
  {
    "verdict": "PASS",
    "codeTreeSha": "<sha>",
    "provider": "claude-cli",
    "model": "sonnet",
    "effort": "high",
    "criticalGaps": 0,
    "importantGaps": 0,
    "auditedFiles": ["src/Billing.ts", "tests/Billing.test.ts"],
    "timestamp": "2026-11-26T15:30:00Z"
  }
  ```

---

## 6. Etkilenecek Bileşenler

1. **`scripts/lib/harness_core.py`:** `requires_tdd_stamp`, `run_external_review`, `tdd_stamp_register`, `_evaluate_tdd_stamp_status`, `compute_tree_and_stamp_state` & `verify_pr_stamps` & `evaluate_pre_command` (`gh pr create` + yerel `merge`) entegrasyonu, `main()` CLI alt komutları (`external-review`, `tdd-stamp`).
2. **`scripts/stamp-gate.sh`:** `review` ve `tdd` alt komutları.
3. **`sidecars/harness-daemon/daemon.py`:** `tdd-pass.json` mtime takibi.
4. **`rules/AGENTS.md`:** `< 8192` bayt sınırı korunarak `stamp-gate.sh review` (`claude -p` → sebep + 30s `schedule` → `agy -p` fallback) ve `tdd-pass.json` PR kapısı sözleşmesi.
5. **`skills/harness-orchestrator/SKILL.md` ve `skills/pre-pr-readiness/SKILL.md`:** Spec/Plan review ve TDD kapsam denetimi orkestrasyon adımları, 30 sn `schedule` protokolü ve `tdd-pass.json` damgalama sırası.
6. **`README.md`:** Yeni Claude CLI / Antigravity fallback review akışı ve `tdd-pass.json` kapısının belgelenmesi.
7. **`tests/`:** Yeni birim/entegrasyon testleri (`claude -p` başarılı, `claude` yok/hata → `exit 42` + sebep JSON, `agy -p` fallback, `tdd-pass.json` PASS/FAIL/bayat/doküman-muafiyeti, daemon paritesi) + mevcut PR akışı testlerinin güncellenmesi.

---

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| **`claude -p`** | Claude Code CLI'nin etkileşimsiz (non-interactive) tek tur çıktı üreten `--print` çalışma modu. |
| **`agy -p`** | Antigravity CLI'nin belirli bir model kimliği (`--model`) ve salt-okunur plan modu (`--mode plan`) ile tek tur çıktı üreten `--print` modu. |
| **Fail-Closed** | Eksik damga, sıfır dışı kritik/önemli test açığı veya başarısız doğrulama durumunda işlemin varsayılan olarak reddedilmesi ilkesi. |
| **Mutation Resistance** | Üretim kodunda yapılan kasıtlı küçük hataların (yanlış sabit, ters koşul, eksik doğrulama) en az bir birim testi kırmızıya düşürmesi özelliği. |
| **`codeTreeSha`** | Çalışma ağacındaki kod ve test dosyalarının özetini temsil eden, `docs/walkthroughs/` ve `docs/parking-lot.md` dışındaki değişikliklerde damgaları geçersiz kılan kriptografik hash. |
| **`tdd-pass.json`** | Dal farkında üretim kodu değiştiğinde TDD birim test kapsam denetiminin geçtiğini `codeTreeSha` kilidiyle belgeleyen PR/merge ön koşul damgası. |
| **`schedule` Timeout Fallback** | Chat ortamında kullanıcıya sorulan fallback sorusuna 30 saniye yanıt gelmezse oturumu otomatik uyandırıp varsayılan Gemini 4 modelini tetikleyen zamanlayıcı mekanizması. |
