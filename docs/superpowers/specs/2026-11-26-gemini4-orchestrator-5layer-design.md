# `alps-agy-harness` — Gemini 4 (`Neon`, `Carbon`, `Hydrogen`, `Extra`) & İki Fazlı `Orchestrator` + `run_workflow` 5 Katmanlı Entegrasyon Tasarımı

**Tarih:** 2026-11-26  
**Hedef Platform:** Google Antigravity (`agy` CLI `v1.5.10+`, Antigravity App `v2.35+`, Antigravity IDE)  
**Kapsam:** 30 Kasım 2026 model emekliliği sonrası güncel Gemini 4 & `Orchestrator` taksonomisi, iki fazlı Planner/Executor protokolü, Executor turunda denetçi yükseltme kalkanı, `SessionStart` emeklilik uyarısı ve `run_workflow` kanca yüzeyi  
**İlgili Temel Tasarım:** [2026-11-12-alps-agy-harness-design.md](2026-11-12-alps-agy-harness-design.md)

---

## 1. Intent & Canlı Model Envanteri

Canlı `agy models` ve resmi Antigravity dokümantasyonu (`/docs/models`) doğrultusunda güncel model envanteri şu şekilde evrilmiştir:

- **Aktif Frontier & Yürütme Modelleri:**
  - `Gemini 4 Neon` (`low`, `medium`, `high`, `xhigh` / UI'da `Extra` — 512K bağlam penceresi, varsayılan ana model)
  - `Gemini 4 Carbon` (`low`, `medium`, `high` — uzun ufuklu mühendislik ve güvenlik)
  - `Gemini 4 Hydrogen` (`low`, `medium`, `high`, `xhigh` / UI'da `Extra` — hızlı kodlama ve varsayılan Executor)
  - `Claude Opus 5.5` (planner/frontier) ve `Claude Sonnet 5.5` (hızlı executor)
- **İki Fazlı `Orchestrator` Modelleri:**
  - `gemini-pro-orchestrator-neon` (`Orchestrator (Neon)`: Planner=`Neon`, Executor=`Hydrogen`)
  - `gemini-pro-orchestrator` (`Orchestrator (Carbon)`: Planner=`Carbon`, Executor=`Hydrogen`)
- **30 Kasım 2026 İtibarıyla Emekliye Ayrılan Modeller:**
  - `Gemini 4 Argon` (`gemini-4-argon-*`, `Orchestrator (Argon)`), `Gemini 3.8 Flash`, `GPT-OSS-120b` ve `Claude 4.6` modelleri.

Mevcut harness yapısındaki beş temel boşluğu gidermek amacıyla 5 katmanlı bir entegrasyon tasarlanmıştır: (1) `Orchestrator` iki fazlı (`Planner` ↔ `Executor`) protokol ayrımı, (2) 30 Kasım sonrası temiz model taksonomisi + `Extra`/`XHIGH` algılaması + `frontier_low` ve `Opus`/`Sonnet 5.5` ayrımı, (3) `Orchestrator` yürütme turunda denetçilerin (`canon-auditor`, `security-reviewer`, `pr-auditor`) `Hydrogen` executor'a düşmesini önleyen `pro` kalkanı, (4) `SessionStart` ve `select-model` üzerinden emeklilik uyarısı, (5) `run_workflow` dinamik Python iş akışı aracı için `hooks.json` `PreToolUse` güvenlik ve katman kapısı.

---

## 2. Goals, Non-Goals & Anti-Goals

### 2.1. Hedefler (Goals)
1. **İki Fazlı `Orchestrator` Protokol Uyumu:** Salt-okunur Planlama turunda yalnızca `jev_classify`, `jev_check` (`ADR`), `context7` doküman sorgusu ve `ask_question` çalıştırıp `exit_plan_mode` (`Re-plan if:`) ile devretmek; dal/worktree açma, dosya yazma, `stamp-gate.sh` ve PR kapılarını Yürütme turunda icra etmek.
2. **%100 Bash / Python Taksonomi Paritesi:** `scripts/hooks/common.sh` ve `scripts/lib/harness_core.py` arasında `orchestrator_neon`, `orchestrator_carbon`, `orchestrator_argon`, `frontier_low`, `claude_opus`, `claude_sonnet`, `detect_parent_effort_hint` (`Extra`/`XHIGH`) ve `is_deprecated_parent_model` fonksiyonlarında sıfır sapma.
3. **`Orchestrator` Denetçi Düşürme Kalkanı:** `Orchestrator*` oturumlarında `bounded_execution` görevlerini `inherit` (hızlı Executor) üzerinde tutarken, `multi_module_integration` ve `critical_architecture_or_audit` görevlerini `pro` katmanına yükselterek `Hydrogen` / `Sonnet` executor miras alınmasını engellemek.
4. **Emeklilik Görünürlüğü:** `select-model` JSON çıktısına `parentEffortHint` ve `deprecated` alanlarını; `SessionStart` sistem mesajına `[MODEL DEPRECATION WARNING]` satırını eklemek.
5. **`run_workflow` Kanca Koruması:** `hooks.json` matcher'ını `invoke_subagent|swarm|run_workflow` yaparak `subprocess`/`os.system` kabuk atlatmalarını, geçersiz `agent(model=...)` katmanlarını ve gömülü gizli anahtarları engellemek.

### 2.2. Kapsam Dışı (Non-Goals)
- `plugin.json` sürümünü (`1.1.0`) veya `rules/*.md` `globs:` satırlarını değiştirmek.
- Çekirdek eklenti paket dosya sayısını (`53`) artırmak.
- `run_workflow` betiklerinin içindeki geçerli `agent()` çağrılarını bloklayıcı `stamp-gate.sh dispatch` zorunluluğuna bağlamak.

### 2.3. Anti-Hedefler (Anti-Goals)
- `rules/AGENTS.md` boyutunun `8192` bayt sınırını aşması veya test edilen 40 anahtar belirteçten birini kaybetmesi.
- `Orchestrator` oturumlarında `security-reviewer` veya `pr-auditor` alt ajanlarının sessizce Executor (`Hydrogen`) katmanında çalıştırılması.
- Tekil `Gemini 4 Neon (High/Extra)`, `Gemini 4 Carbon (High)` veya `Claude Opus 5.5` oturumlarında kritik denetçilerin `inherit` yerine daha düşük bir katmana düşürülmesi.

---

## 3. Global Constraints

- **Çalışma Zamanı Kilidi:** Yalnızca Python `>= 3.9` standart kütüphanesi, POSIX `bash`, `jq`, `git`, `curl` kullanılır; üçüncü parti bağımlılık eklenmez.
- **Paket ve Boyut Kilitleri:** Çekirdek dosya sayısı tam olarak `53` kalır; `rules/AGENTS.md` `< 8192` bayt ve YAML frontmatter'sızdır; `agents/*.md` 6 satırlı frontmatter yapısını korur.
- **İki Dilli Standart:** Kod, docstring'ler ve kanca hata iletileri İngilizce; Spec, Plan, Walkthrough ve `README.md` Türkçe olup sonunda boş olmayan `## Teknik Terimler Sözlüğü` tablosu içerir.

---

## 4. Architectural Decisions (ADR)

### ADR-01: `Orchestrator` Yürütme Turunda Denetçi `pro` Yükseltmesi vs. Koşulsuz `inherit`
- **Durum:** Onaylandı (`jev_classify = full_project` [1.0], `jev_check = 0.67` [`yes`, eşik `>= 0.65`]).
- **Bağlam:** `Orchestrator` oturumlarında araç çağrıları Planner (`Neon`/`Carbon`) yerine Executor (`Hydrogen`/`Sonnet 5.5`) aktifken çalışır.
- **Karar:** `Orchestrator*` ailelerinde `bounded_execution` işçileri `inherit` (Executor hızında) kalır; buna karşın `multi_module_integration` (`canon-auditor`) ve `critical_architecture_or_audit` (`security-reviewer`, `pr-auditor`) çağrıları `pro` katmanına yönlendirilir. Tekil `neon`, `carbon`, `claude_opus`, `argon` ve `custom` oturumlarında kritik denetçiler `inherit` olarak korunur.
- **Elenen Alternatif:** `Orchestrator` oturumlarında denetçiler için de `inherit` kullanmak (Executor turunda `Hydrogen` miras alma riski nedeniyle elendi).

### ADR-02: `frontier_low` ve `Claude Opus/Sonnet 5.5` Ayrımı + Emeklilik Kalkanı
- **Durum:** Onaylandı.
- **Karar:** Tüm düşük düşünme bütçeli frontier varyantları (`Neon Low`, `Carbon Low`, `Argon Low`, `Opus Low`) tekil `frontier_low` sınıfında toplanır (`bounded_execution -> inherit`, denetçiler `-> pro`). `Claude Opus 5.5` (`claude_opus`) ile `Claude Sonnet 5.5` (`claude_sonnet`) ayrıştırılır. `2026-11-30` itibarıyla emekli olan modeller `is_deprecated_parent_model` ile tespit edilip `SessionStart` ve `select-model` üzerinden bildirilir.

### ADR-03: `run_workflow` Kanca Entegrasyonu (`evaluate_pre_workflow`)
- **Durum:** Onaylandı.
- **Karar:** Yeni kanca betiği veya dosya eklemeden `hooks.json` içindeki `PreToolUse` matcher'ı `invoke_subagent|swarm|run_workflow` olarak genişletilir; `evaluate_pre_workflow`, `Script` ve `ScriptPath` içeriklerinde `PRIVATE_KEY_RE`, doğrudan `subprocess`/`os.system` kabuk atlatmaları ve geçersiz `model="..."` katmanlarını `deny` ile reddeder.

---

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| **Deprecation Warning** | `2026-11-30` tarihinde emekliye ayrılacak modeller (`Argon`, `3.8 Flash`, `GPT-OSS`, `Claude 4.6`) için oturum başında verilen geçiş uyarısı. |
| **Extra (`XHIGH`)** | `Gemini 4 Neon` ve `Gemini 4 Hydrogen` modellerinde en yüksek derinlikli dördüncü düşünme bütçesi kademesi. |
| **frontier_low** | Düşük düşünme bütçeli (`Low`) frontier model oturumlarında kritik denetçilerin `pro` katmanına yükseltilmesini sağlayan sınıflandırma ailesi. |
| **Orchestrator (Two-Phase)** | Salt-okunur Planlama (`Neon`/`Carbon`/`Opus 5.5`) ile Yürütme (`Hydrogen`/`Sonnet 5.5`) arasında otomatik el değiştiren iki fazlı oturum modu. |
| **run_workflow** | Paralel ve aşamalı ajan akışlarını Python betiği ile orkestre eden Antigravity aracı. |
