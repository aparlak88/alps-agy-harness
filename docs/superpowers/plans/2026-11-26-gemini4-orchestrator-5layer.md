# Gemini 4, `Orchestrator` ve `run_workflow` 5 Katmanlı Entegrasyon Uygulama Planı

**Tarih:** 2026-11-26  
**Hedef:** 5 katmanlı Gemini 4 (`Neon`, `Carbon`, `Hydrogen`, `Extra`/`XHIGH`), iki fazlı `Orchestrator`, model emekliliği uyarısı ve `run_workflow` kanca entegrasyonunu uygulayıp tüm PR/merge kapılarından geçirerek `main` dalına birleştirmek.  
**Tasarım Dokümanı:** [2026-11-26-gemini4-orchestrator-5layer-design.md](../specs/2026-11-26-gemini4-orchestrator-5layer-design.md)

---

## Global Constraints

- **Çalışma Zamanı Kilidi:** Yalnızca Python `>= 3.9` standart kütüphanesi, POSIX `bash`, `jq`, `git`, `curl` kullanılır; yeni dış paket eklenmez.
- **Paket Bütünlüğü:** Çekirdek dosya sayısı tam olarak `53` kalmalıdır; yeni çekirdek dosya oluşturulmaz.
- **`rules/AGENTS.md` Kilidi:** YAML frontmatter içermez, `< 8192` bayt sınırının altında kalır ve `tests/test-rules-and-agents.sh` içindeki 40 zorunlu belirtecin tamamını korur.
- **Bash / Python Paritesi:** `scripts/hooks/common.sh` ve `scripts/lib/harness_core.py` model sınıflandırma, katman çözümleme, efor ipucu ve emeklilik tespitinde birebir aynı sonucu üretir.

---

## Karmaşıklık Bütçesi ve Kapsam (`allowedFiles` & `Out-of-Scope`)

- **Dosya Bütçesi:** `0` yeni çekirdek dosya; `16` güncellenen mevcut dosya + `3` yaşam döngüsü dokümanı (`Spec`, `Plan`, `Walkthrough`).
- **`allowedFiles`:**
  - `README.md`
  - `hooks.json`
  - `agents/canon-auditor.md`
  - `agents/pr-auditor.md`
  - `agents/security-reviewer.md`
  - `rules/AGENTS.md`
  - `scripts/hooks/common.sh`
  - `scripts/lib/harness_core.py`
  - `scripts/stamp-gate.sh`
  - `skills/harness-orchestrator/SKILL.md`
  - `skills/review-pr/SKILL.md`
  - `tests/test-edit-and-session-hooks.sh`
  - `tests/test-manifest.sh`
  - `tests/test-plugin-bundle.sh`
  - `tests/test-rules-and-agents.sh`
  - `tests/test-sidecar-daemon.sh`
  - `tests/test-stamp-and-common.sh`
  - `tests/test-subagent-and-stop-hooks.sh`
- **Soyutlama Gerekçesi:** `evaluate_pre_workflow` ve model sınıflandırma yardımcıları mevcut `scripts/lib/harness_core.py` ve `scripts/hooks/common.sh` tek doğruluk kaynakları içinde genişletilir (`Rule of Three`).
- **Kapsam Dışı (`Out-of-Scope`):** `plugin.json` sürüm artışı, `rules/*.md` `globs:` değişiklikleri, harici bağımlılık eklenmesi.

---

## Uygulama Adımları

1. **Çekirdek Kanca & Taksonomi Motoru (`hooks.json`, `common.sh`, `harness_core.py`, `stamp-gate.sh`):**
   - `hooks.json` 3. `PreToolUse` matcher'ını `invoke_subagent|swarm|run_workflow` yap.
   - `common.sh` ve `harness_core.py` içinde `orchestrator_neon`, `orchestrator_carbon`, `orchestrator_argon`, `frontier_low`, `claude_opus`, `claude_sonnet`, `detect_parent_effort_hint` (`Extra`/`XHIGH`), `is_deprecated_parent_model` ve `Orchestrator` denetçi `pro` kalkanını uygula.
   - `stamp-gate.sh select-model` çıktısına `parentEffortHint` ve `deprecated` ekle; `build_session_start_payload` içine `[MODEL DEPRECATION WARNING]` ve `pr-auditor` için `Extra`->`XHIGH` efor yükseltmesini ekle; `evaluate_pre_workflow` güvenlik kapısını ekle.
2. **Kurallar, Skill'ler, Alt Ajanlar ve Dokümantasyon:**
   - `rules/AGENTS.md` (`< 8192` bayt) içine iki fazlı `Orchestrator` (`exit_plan_mode` / `enter_plan_mode`), post-Nov-30 yönlendirme ve `run_workflow` kurallarını ekle.
   - `skills/harness-orchestrator/SKILL.md`, `skills/review-pr/SKILL.md`, `agents/*.md` ve `README.md` dosyalarını güncelle.
3. **TDD Testleri ve Tam Paket Doğrulaması:**
   - Tüm test dosyalarını yeni taksonomi, emeklilik uyarısı, `Orchestrator` `pro` kalkanı ve `run_workflow` kapısı için güncelle ve `./scripts/run-quiet.sh full-tests -- bash tests/run-all.sh` ile doğrula.
4. **PR Hazırlığı, Denetimler, PR Açılışı ve `main` Birleştirme:**
   - Eski arka plan daemon'ını yenile, tam dal farkını kapsayan derin Walkthrough üretip `validate-walkthrough` ile doğrula, `canon-auditor` ve `security-reviewer` çalıştır, `gh pr create` aç, `pr-auditor` çalıştırıp `gh pr merge --squash` ile `main` dalına birleştir.

---

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| **Bash / Python Parity** | Kabuk kancaları (`common.sh`) ile Python çekirdeğinin (`harness_core.py`) model ve yönlendirme kararlarında birebir aynı sonucu üretmesi. |
| **Executor Turu** | `Orchestrator` modunda plan devri sonrası `Hydrogen` veya `Claude Sonnet 5.5` üzerinde dosya ve komut araçlarının çalıştığı yürütme aşaması. |
| **Planner Turu** | `Orchestrator` modunda salt-okunur keşif ve `exit_plan_mode` planlaması yapan `Neon`/`Carbon`/`Opus 5.5` aşaması. |
| **run_workflow** | Python iş akışı betiği içinde `agent`, `parallel` ve `pipeline` primitiflerini çalıştıran Antigravity aracı. |
| **Walkthrough** | PR kapsamındaki tüm değişen dosyaları *Ne* ve *Neden* analizleriyle belgeleyen mühendislik rehberi. |
