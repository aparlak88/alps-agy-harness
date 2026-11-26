# Uygulama Planı: Claude Code CLI (`claude -p`) Spec/Plan İncelemesi, Antigravity Fallback ve Fiziksel TDD Kapsam Kapısı

> **For agentic workers:** Bu plan görev bazlı TDD disipliniyle yürütülür. Her görev tamamlandığında ilgili test paketi `run-quiet.sh` ile doğrulanır.

**Goal:** Spec/Plan review ve TDD birim test kapsam denetimi için birincil `claude -p`, şeffaf hata + 30 sn zaman aşımıyla `agy -p` fallback mekanizması ve kod değişikliğine koşullu `tdd-pass.json` fiziksel PR/merge kapısını `alps-agy-harness` çekirdeğine entegre etmek.

**Architecture:** Tüm deterministik yürütme ve damga doğrulama mantığı `scripts/lib/harness_core.py` içine (0 yeni core dosya, 53 dosya kilidi korunarak) yerleştirilir; `scripts/stamp-gate.sh` üzerinden `review` ve `tdd` alt komutları açılır; `sidecars/harness-daemon/daemon.py` `tdd-pass.json` tazeliğini izler; `rules/AGENTS.md` (`< 8192` bayt), `skills/harness-orchestrator/SKILL.md`, `skills/pre-pr-readiness/SKILL.md` ve `README.md` yeni 30 sn `schedule` fallback protokolünü ve TDD kapısını belgeler.

**Tech Stack:** Python 3 (standard library only), Bash 3.2+, `jq`, `claude` CLI, `agy` CLI.

**Spec:** `docs/superpowers/specs/2026-11-26-claude-cli-review-and-tdd-gate-design.md`

## Global Constraints

- `rules/AGENTS.md` boyutu `< 8192` bayt kalmalı ve tüm mevcut doğrulama jetonlarını korumalıdır.
- Çekirdek eklenti dosya sayısı `53` olarak korunmalıdır (`tests/test-plugin-bundle.sh`).
- `claude -p` çağrıları salt-okunur `--permission-mode plan --no-session-persistence --tools Read,Grep,Glob` ile, `agy -p` çağrıları `--mode plan --disable-slash-commands` ile ve `shell=False` + bounded timeout (`HARNESS_REVIEW_TIMEOUT_SEC`, varsayılan `300` sn) ile yürütülmelidir.
- `claude -p` eksik veya başarısız olduğunda sessiz fallback yasaktır; `exit 42` ve sebep + fallback seçeneklerini içeren JSON dönülmelidir.
- `tdd-pass.json` yalnızca dal farkında doküman-dışı kod/betik dosyası değiştiğinde zorunludur; `verdict == "PASS"`, `criticalGaps == 0`, `importantGaps == 0` ve güncel `codeTreeSha` eşleşmesi olmadan PR/merge açılamaz.

## Review Focus

1. `claude` ikilisi yokken veya `exit != 0` / zaman aşımı verdiğinde `stamp-gate.sh review` asla sessizce `agy`'ye geçmemeli; tam sebep + `exit 42` dönmeli.
2. `stamp-gate.sh tdd --verdict PASS` çağrısı `--critical-gaps > 0` veya `--important-gaps > 0` verildiğinde fail-closed reddetmeli ve `tdd-pass.json` yazmamalı.
3. Salt dokümantasyon (`docs/**`, `README.md`, `*.md`) değiştiren dallarda `tdd-pass.json` zorunlu olmamalı; kod/test/betik değişen dallarda ise eksik veya bayat (`codeTreeSha` uyuşmayan) `tdd-pass.json` hem `gh pr create` hem yerel `git merge` komutlarını reddetmeli.
4. `docs/walkthroughs/*` veya `docs/parking-lot.md` commit'leri `tdd-pass.json` damgasını bayatlatmamalı; üretim kodu veya test değişikliği damgayı bayatlatmalı.
5. `HARNESS_CLAUDE_BIN` / `HARNESS_AGY_BIN` ile alt süreç çağrılarında `CLAUDECODE` ortam değişkeni temizlenmeli ve prompt `stdin` üzerinden güvenle iletilmelidir.

---

### Task 1: Çekirdek Motor (`scripts/lib/harness_core.py`) ve Daemon (`sidecars/harness-daemon/daemon.py`)

**Files:**
- Modify: `scripts/lib/harness_core.py`
- Modify: `sidecars/harness-daemon/daemon.py`

- [ ] `requires_tdd_stamp(workspace, diff_files)` fonksiyonunu ekle (doküman-dışı kod/betik dosyası değiştiyse `(True, code_files)` döner).
- [ ] `_evaluate_tdd_stamp_status`, `tdd_stamp_register`, `run_external_review` (`claude -p` / `agy -p` salt-okunur çalıştırıcı, `exit 42` yapılandırılmış hata sözleşmesi, `spec-plan-review.json` / `tdd-review.json` + opsiyonel `--auto-stamp`) fonksiyonlarını ekle.
- [ ] `compute_tree_and_stamp_state`, `verify_pr_stamps` ve `evaluate_pre_command` (yerel `git merge` + `gh pr create`) akışlarına koşullu `tdd-pass.json` doğrulamasını ekle.
- [ ] `main()` içine `tdd-stamp` ve `external-review` alt komutlarını ekle.
- [ ] `sidecars/harness-daemon/daemon.py` `state_mtimes` listesine `"tdd-pass.json"` ekle.

### Task 2: CLI Giriş Noktası (`scripts/stamp-gate.sh`)

**Files:**
- Modify: `scripts/stamp-gate.sh`

- [ ] `stamp-gate.sh review --kind spec-plan|tdd [--provider claude|agy] [--model <id>] [--effort <level>] [--target <path> ...] [--auto-stamp] [--workspace <dir>]` alt komutunu ekle (`exit 42` kodunu koruyarak).
- [ ] `stamp-gate.sh tdd --verdict PASS|FAIL --critical-gaps <n> --important-gaps <n> --provider <p> --model <m> [--effort <e>] [--workspace <dir>]` alt komutunu ekle.

### Task 3: Kurallar, Skill'ler ve Dokümantasyon

**Files:**
- Modify: `rules/AGENTS.md` (`< 8192` bayt kilidi korunarak)
- Modify: `skills/harness-orchestrator/SKILL.md`
- Modify: `skills/pre-pr-readiness/SKILL.md`
- Modify: `README.md`

- [ ] `claude -p` (`opus`/`medium` Spec/Plan, `sonnet`/`high` TDD) → hata durumunda sebepli kullanıcı sorusu + `schedule(DurationSeconds=30, TimerCondition="any")` → `agy -p` (`claude-opus-5-5-medium` / `gemini-4-carbon-high` ve `claude-sonnet-5-5-high` / `gemini-4-neon-medium`) akışını ve `tdd-pass.json` PR/merge kapısını işle.

### Task 4: Kapsamlı Test Paketi ve Regresyon Doğrulaması

**Files:**
- Modify: `tests/test-stamp-and-common.sh`
- Modify: `tests/test-command-hooks.sh`
- Modify: `tests/test-sidecar-daemon.sh`
- Modify: `tests/test-plugin-bundle.sh`
- Modify: `tests/test-rules-and-agents.sh`

- [ ] `claude -p` başarı, `claude` yok (`exit 42`), `claude` hata/quota (`exit 42` + sebep), `agy -p` fallback (Spec/Plan & TDD varsayılan ve açık model), `tdd-pass.json` PASS/FAIL/bayat/doküman-muafiyeti ve daemon paritesi testlerini ekle.
- [ ] Mevcut PR akışı testlerini `tdd-pass.json` kapısına göre güncelle.
- [ ] `./scripts/run-quiet.sh full-tests -- bash tests/run-all.sh` ile tüm 9 test paketini yeşil doğrula.

---

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| **`claude -p`** | Claude Code CLI'nin etkileşimsiz tek tur inceleme yapan `--print` modu. |
| **`agy -p`** | Antigravity CLI'nin açık `--model` kimliği ve salt-okunur `--mode plan` ile çalışan `--print` modu. |
| **`tdd-pass.json`** | Kod değişikliği içeren dallarda TDD birim test kapsam denetiminin geçtiğini `codeTreeSha` ile kanıtlayan damga dosyası. |
| **Fail-Closed** | Eksik veya geçersiz doğrulama durumunda işlemin varsayılan olarak reddedilmesi ilkesi. |
| **Review Focus** | Plan aşamasında belirlenen ve ilgili TDD görevlerine bağlanan yüksek riskli girdi/hata sınıfları listesi. |
