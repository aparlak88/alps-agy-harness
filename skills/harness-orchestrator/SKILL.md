---
name: harness-orchestrator
description: "Ana orkestrasyon skill'i: kullanıcı talebini jev_classify ile sınıflandırır, superpowers akışlarını orantılı rotalara yönlendirir, worktree izolasyonunu, hibrit alt ajan model/efor atamasını ve PR kapılarını yönetir."
---

# Harness Orchestrator

Bu skill, `alps-agy-harness` eklentisinin **zorunlu ana giriş noktasıdır**. Her yeni kullanıcı talebinde, özellik isteğinde, hata ayıklama oturumunda veya refactoring sürecinde ilk olarak devreye girer.

`superpowers` geliştirme çerçevesini silmeden veya kopyalamadan sarmalar; sürecin boyutuna göre deterministik mühendislik kapıları uygular.

---

## 1. İlk Adım: `jev_classify` ile İş Boyutu Sınıflandırma

Kullanıcının ilk isteğini veya hedefini alarak `jev_classify` çağrısı yapın:

```json
{
  "classes": ["quick_fix", "bug_investigation", "small_change", "full_project", "pr_review", "entropy_sweep"],
  "query": "<Kullanıcının isteği>",
  "act_above": 0.80
}
```

> [!CRITICAL]
> **Sıfır Fallback Kuralı:** Eğer `TYPESAFE_API_KEY` tanımlı değilse veya `jev` MCP çağrısı başarısız olursa **asla varsayım yapmayın veya sessizce atlamayın**. Derhal durun ve geliştiriciye `./scripts/harness-doctor.sh` komutunu çalıştırmasını söyleyin.

Eğer sınıflandırma güven skoru `< 0.80` ise en güvenli yol olan `full_project` (`superpowers:brainstorming`) rotasını seçin.

---

## 2. Dört Orantılı Rota ve Aşama Matrisi

| Rota / Sınıf | Spec & Brainstorming | Uygulama Planı | Yürütme Modu | Zorunlu PR Kapıları |
| :--- | :--- | :--- | :--- | :--- |
| **`quick_fix` (Trivial)** | Atlanır | Mikro-kapsam (Doğrudan `allowedFiles`) | TDD ile tek dosya | `canon-auditor`, `security-reviewer`, 2-Mermaid Walkthrough, `pr-auditor` |
| **`bug_investigation` (Bugfix)** | Atlanır (`systematic-debugging`) | Kök neden sonrası kısa plan | TDD ile düzeltme | Kök neden ve test kanıtlı Walkthrough, tüm PR kapıları |
| **`small_change` (Standard)** | Atlanır (mimari trade-off yoksa) | Kısa Plan (`<= 5` görev) | SDD veya Inline TDD | Standart Walkthrough (min. 2 Mermaid), tüm PR kapıları |
| **`full_project` (Architectural)** | Zorunlu (`brainstorming` + `ADR`) | Kapsamlı DDD Planı (`writing-plans`) | SDD (İzole Worktree) | Kapsamlı Walkthrough, tüm PR kapıları |

> [!IMPORTANT]
> **PR Sınır Kapıları Değişmezdir:** İş ne kadar küçük olursa olsun, `pre-pr-readiness` doğrulaması, `canon-pass.json`, `security-pass.json`, en az 2 Mermaid diyagramı içeren Walkthrough dokümanı ve PR sonrası `pr-auditor` değerlendirmesi **istisnasız her PR için zorunludur**.

---

## 3. Çalışma Alanı ve Worktree İzolasyonu

Kodlama aşamasına geçmeden önce `main` dalında doğrudan kod yazımı `pre-edit-guard.sh` tarafından fiziksel olarak kilitlenmiştir:
1. `superpowers:using-git-worktrees` skill'ini çağırarak veya `git checkout -b feat/<konu>` ile izole bir dal açın.
2. Tasarım dokümanları (`docs/superpowers/specs/` ve `docs/canon/`) `main` üzerinde taslaklanabilir; ancak üretim koduna dokunmadan önce özellik dalına geçiş zorunludur.

---

## 4. Hibrit `jev` ve Gemini 4 / `Orchestrator` Duyarlı Alt Ajan Yönlendirme

Antigravity'nin `invoke_subagent` ve `run_workflow` (`agent(model=...)`) araçları yalnızca `inherit | flash_lite | flash | pro` katmanlarını kabul eder (`pro` = frontier Gemini 4 katmanı, `flash` = hızlı yürütme katmanı, `inherit` = ana oturumun aktif modeli). **Not:** `Gemini 4 Argon`, `Gemini 3.8 Flash`, `GPT-OSS-120b` ve `Claude 4.6` modelleri **30 Kasım 2026**'da emekliye ayrılır (`SessionStart` uyarısı verilir).

Her dinamik `invoke_subagent` çağrısından önce, işin karmaşıklığına göre `stamp-gate.sh dispatch` çalıştırarak yönlendirme kararını kaydedin:

```bash
./scripts/stamp-gate.sh dispatch \
  --role "<Alt Ajan Rolü>" \
  --type "self" \
  --tier "trivial_lookup|bounded_execution|multi_module_integration|critical_architecture_or_audit" \
  [--effort "LOW|MEDIUM|HIGH|XHIGH|MAX"]
```

Ana Oturum (`HOOK_INPUT.modelName`) Duyarlı Katman Eşlemesi:
- **`trivial_lookup` (`LOW`):** Tüm ana oturumlarda `flash_lite`.
- **`bounded_execution` (`MEDIUM` / `XHIGH`):** `Orchestrator` (`Neon`/`Carbon`), **Gemini 4 Hydrogen**, `Claude Sonnet 5.5` ve `frontier_low` (`Neon/Carbon/Opus Low`) oturumlarında `inherit`; **Gemini 4 Neon**, **Gemini 4 Carbon**, `Claude Opus 5.5` ve `custom` oturumlarında `pro`; eski `3.8 Flash` ve `unset` oturumlarında `flash`.
- **`multi_module_integration` (`HIGH`, `canon-auditor` tabanı):** `Orchestrator`, **Gemini 4 Hydrogen**, `Claude Sonnet 5.5`, `frontier_low` ve `Flash` oturumlarında `pro` (yürütme turundaki Executor'ın miras alınmasını önler); `Neon` ve `Carbon` oturumlarında varsayılan `pro` (açık `Model: "inherit"` verilirse korunur); `Claude Opus 5.5` ve `custom` oturumlarında `inherit`.
- **`critical_architecture_or_audit` (`MAX`, `security-reviewer` ve `pr-auditor`):** `Neon`, `Carbon`, `Claude Opus 5.5` ve `custom` oturumlarında `inherit` (tekil frontier oturumlarda düşürülmez; `Neon/Hydrogen (Extra)` için `pr-auditor` varsayılan eforu `XHIGH` olur); **`Orchestrator`**, `Hydrogen`, `Claude Sonnet 5.5`, `frontier_low` ve `Flash` oturumlarında `pro` (Executor turundaki denetimler frontier `pro` katmanına kilitlenir).

`pre-subagent-guard.sh` hook'u canlı `HOOK_INPUT.modelName` alanını ve dispatch kaydını okur, kaydı tek seferlik tüketir (`consumed: true`) ve Antigravity'nin yerel `overwrite` yeteneğiyle alt ajanın modelini ve `[EFFORT_PROFILE: ...]` başlığını fiziksel olarak kilitler.

---

## 9. İki Fazlı `Orchestrator` (`Planner ↔ Executor`) ve `run_workflow` Modu

- **İki Fazlı `Orchestrator` (`Neon`/`Carbon`/`Opus 5.5` Planner ↔ `Hydrogen`/`Sonnet 5.5` Executor):**
  1. **Planner Fazı (Salt-Okunur):** `jev_classify`, kod tabanı keşfi, `jev_check` (`ADR`), `context7` doküman sorguları ve `ask_question` kararlarını tamamlayıp `Re-plan if:` tetikleyicileriyle `exit_plan_mode` üzerinden yürütmeye devredin.
  2. **Executor Fazı:** İzole `feat/*` dalı/worktree açıp Spec/Plan/kod yazın, `stamp-gate.sh` ve `run-quiet.sh` doğrulamalarını çalıştırın; başarısız doğrulama veya plan dışı karar gereksiniminde `enter_plan_mode` ile Planner'a dönün.
- **`run_workflow` Koruması:** `hooks.json` (`invoke_subagent|swarm|run_workflow`) dinamik Python iş akışı betiklerinde doğrudan `subprocess`/`os.system` kabuk atlatmalarını, gömülü gizli anahtarları ve geçersiz `agent(model=...)` katmanlarını fiziksel olarak reddeder.

---

## 5. Sessiz Komut Çalıştırma (`run-quiet.sh`)

Context çürümesini önlemek için tüm derleme, test ve statik analiz komutlarını `scripts/run-quiet.sh` üzerinden yürütün:
```bash
./scripts/run-quiet.sh <etiket> -- <komut...>
```
Başarılı komutlar tek satır özet döner (`✅ PASS [...]`); ham çıktılar `.harness/logs/last.log` dosyasında saklanır.

---

## 6. Kapsam Kilidi ve V2 Otoparkı (`docs/parking-lot.md`)

Görev yürütülürken plan dışı dosyalarda düzenleme (*drive-by refactoring*) yapmayın. Görevle doğrudan ilgisi olmayan bir eksiklik veya teknik borç fark ederseniz:
1. Koda dokunmayın.
2. Maddeyi tek satır olarak `docs/parking-lot.md` dosyasına kaydedin.
3. Mevcut görevin kapsamına sadık kalın.

---

## 7. Yaşam Döngüsü Tamamlama ve Koşullu UI Tasarım Kapısı (`impeccable`)

UI/Frontend içeren `small_change` veya `full_project` görevlerinde `impeccable` kurulu ise:
- **Araç Görev Ayrımı:** Görsel tasarım yönlendirme (`shape`, `bolder`, `polish`), UX eleştirisi (`critique`) ve statik AI-slop tespiti (`detect`) için `impeccable` kullanın; sıfır-konsol/5xx hatası, fonksiyonel E2E ve LCP/ağ incelemeleri için `playwright-e2e` ve `chrome-devtools-plugin` kullanın.
- **Güvenli Ortam:** `impeccable` komutlarını ve `/impeccable live` oturumlarını her zaman `DO_NOT_TRACK=1 IMPECCABLE_LIVE_COPY_AGENT=chat` (veya `off`) ile çalıştırın; `.impeccable/` dizini ve kök `PRODUCT.md`/`DESIGN.md` dosyaları `main` kilidine takılmadan taslaklanabilir.
- **Saf Backend İzolasyonu:** Backend/CLI görevlerinde `impeccable` tamamen pasiftir ve `ui-pass.json` üretilmez.

Uygulama tamamlandığında:
1. `pre-pr-readiness` skill'ini çağırın (`canon-auditor`, `security-reviewer`, UI değiştiyse + `impeccable` kuruluysa `stamp-gate.sh ui`, Walkthrough).
2. `gh pr create` komutunu çalıştırın.
3. `stop-gate.sh` devreye girdiğinde `review-pr` skill'i ile `pr-auditor` denetimini gerçekleştirin.

---

## 8. Antigravity Swarm Orkestrasyon Modu

Kullanıcı `/swarm` veya çoklu ajan koordinasyonu başlattığında ana ajan **Koordinatör**, `swarm(action="add")` ile eklenen ajanlar ise **Swarm Worker** rolündedir:

1. **Tek Entegrasyon Dalı Topolojisi (`feat/<konu>`):** Koordinatör kodlama öncesinde `main` üzerinden tek bir `feat/<konu>` entegrasyon dalına geçer (`jev_classify`, `brainstorming`, Spec ve Plan yalnızca burada, bir kez yürütülür).
2. **İzole Çalışma Alanı (`workspace: "share"` vs `"inherit"`):**
   - Dosya düzenleyen veya test/derleme çalıştıran yazıcı işçiler mutlaka `workspace: "share"` ile başlatılır ve koda dokunmadan önce kendi alt dallarını (`git checkout -b feat/<konu>-<ad>`) açar.
   - Salt-okunur inceleme/keşif işçileri `workspace: "inherit"` kullanır; birden fazla işçi aynı ortak dizine aynı anda yazmaz.
3. **Engelleyici Olmayan Swarm Kancası (`pre-subagent-guard.sh`):** `hooks.json` hem `invoke_subagent` hem `swarm` çağrılarını yakalar. `swarm(action="add")` çağrılarında engelleme yapmadan `overwrite.brief` ile `[EFFORT_PROFILE: ...]` ve `[SWARM_WORKER_CONTRACT ...]` başlıklarını (ve `share`/`branch` modunda `[SWARM_BRANCH_GUARD ...]`) enjekte eder; `status`, `models`, `title`, `model`, `kill` çağrılarını doğrudan geçirir. İsteğe bağlı olarak `--type "swarm"` ile `stamp-gate.sh dispatch` kaydı da tüketilebilir.
4. **Swarm Worker Kapsamı:** Koordinatörden `brief` alan işçi yeniden `jev_classify`, `brainstorming`, Spec, Walkthrough veya `gh pr create` başlatmaz; kendi dalı ve atanmış dosyaları içinde TDD, `context7`, `run-quiet.sh`, İngilizce `REMEDIATION:` ve güvenlik/sözlük kurallarını uygular. `docs/parking-lot.md` veya `docs/canon/*` güncellemelerini doğrudan yazmak yerine mesaj panosunda `@coordinator`'a bildirir.
5. **`swarm` vs. `invoke_subagent` Görev Ayrımı:**
   - **`swarm`:** Paralel uygulayıcı işçiler, paylaşılan mesaj panosu koordinasyonu ve `share`/`branch` alt dallarında eşzamanlı kodlama için kullanılır.
   - **`invoke_subagent`:** Tekil salt-okunur profiller ve zorunlu denetim kapıları (`canon-auditor`, `security-reviewer`, `pr-auditor`, `research`, `browser`) için kullanılır. Tüm işçi dalları entegrasyon dalında birleştirildikten sonra koordinatör `pre-pr-readiness`, tek Walkthrough, `gh pr create` ve `review-pr` (`pr-auditor`) adımlarını yürütür.
