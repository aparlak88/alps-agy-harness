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
> **PR Sınır Kapıları Değişmezdir:** İş ne kadar küçük olursa olsun, `pre-pr-readiness` doğrulaması, `canon-pass.json`, `security-pass.json`, kod/betik değiştiyse koşullu `tdd-pass.json`, UI değiştiyse + `impeccable` kuruluysa koşullu `ui-pass.json`, en az 2 Mermaid diyagramı içeren Walkthrough dokümanı ve PR sonrası `pr-auditor` değerlendirmesi **istisnasız her PR için zorunludur**.

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
1. `pre-pr-readiness` skill'ini çağırın (`canon-auditor`, `security-reviewer`, kod/betik değiştiyse `stamp-gate.sh review --kind tdd --auto-stamp` → `tdd-pass.json`, UI değiştiyse + `impeccable` kuruluysa `stamp-gate.sh ui`, Walkthrough).
2. `gh pr create` komutunu çalıştırın.
3. `stop-gate.sh` devreye girdiğinde `review-pr` skill'i ile `pr-auditor` denetimini gerçekleştirin.

---

## 8. Antigravity Swarm Orkestrasyon Modu (Coordinator-Only & Kota Kurtarma)

Kullanıcı `/swarm` veya çoklu ajan koordinasyonu başlattığında ana ajan **yalnızca Koordinatör** rolündedir; `swarm(action="add")` ile eklenen ajanlar ise **Swarm Worker** / **Integrator** rolündedir:

1. **Sıkı Coordinator-Only Kuralı (Fiziksel Kanca Koruması):**
   - Koordinatör yalnızca koordine eder (`swarm`, `post_message`, `read_board`, `swarm_wait`, `schedule`, `manage_task`, `ask_question`, `read_file`, salt-okunur inceleme ve `stamp-gate.sh swarm-coordinator|swarm-quota|dispatch|select-model|verify-pr-stamps`, `harness-doctor.sh` komutları).
   - Aktif Swarm koordinatörü (`.harness/state/swarm/swarm-coordinator.json` veya `/swarm` çağrısı) doğrudan çalışma alanı dosyası yazamaz (`pre-edit-guard.sh` → `deny`), derleme/test/git mutasyonu/merge/`gh pr create` çalıştıramaz (`pre-command-guard.sh` → `deny`) ve iş yürütmek için `invoke_subagent` / `run_workflow` çağıramaz (`pre-subagent-guard.sh` → `deny`).
   - Tüm işler uzman Swarm işçilerine devredilir:
     - **`planner` (`workspace: "inherit"`):** `jev_classify`, `brainstorming`, ADR, Spec ve Plan dokümanları (`feat/<konu>` dalında).
     - **`implementer-*` (`workspace: "share"`):** Kendi alt dallarında (`git checkout -b feat/<konu>-<ad>`) TDD ile kodlama ve test. **Ön koşul:** `workspace: "share"` için çalışma alanının geçerli bir Git deposu olması gerekir.
     - **`verifier` (`workspace: "inherit"`):** Salt-okunur diff/test doğrulaması ve hata bildirimi.
     - **`integrator` (`workspace: "share"` veya koordinasyon dalı):** Tüm işçi dallarını tek `feat/<konu>` entegrasyon dalında birleştirir ve `[SWARM_INTEGRATOR_CONTRACT]` kapsamında `pre-pr-readiness` (Walkthrough, `canon-auditor`, `security-reviewer`, `tdd-pass.json`, koşullu `ui-pass.json`), `gh pr create` ve `review-pr` (`pr-auditor`) kapılarını yürütür.
2. **Engelleyici Olmayan Swarm Kancası (`pre-subagent-guard.sh`):** `hooks.json` hem `invoke_subagent`, hem `swarm`, hem `run_workflow` çağrılarını yakalar. `swarm(action="add")` çağrılarında engelleme yapmadan `overwrite.brief` ile `[EFFORT_PROFILE: ...]` ve `[SWARM_WORKER_CONTRACT ...]` (veya `integrator`/`release`/`pr-shepherd` rolleri için `[SWARM_INTEGRATOR_CONTRACT ...]`) ile `share`/`branch` modunda `[SWARM_BRANCH_GUARD ...]` başlıklarını enjekte eder; yerleşik sistem rollerini (`monitor`/`monitor-N`, `narrator`/`narrator-N`) doğrudan geçirir. `swarm(action="title")` ve `add` çağrıları aktif koordinatör `conversationId` değerini kaydeder.
3. **Swarm Worker Kapsamı:** Normal işçiler yeniden `jev_classify`, `brainstorming`, Spec, Walkthrough veya `gh pr create` başlatmaz; kendi dalı ve atanmış dosyaları içinde TDD, `context7`, `run-quiet.sh`, İngilizce `REMEDIATION:` ve güvenlik/sözlük kurallarını uygular. `docs/parking-lot.md` veya `docs/canon/*` güncellemelerini panoda `@coordinator`'a bildirir. Yalnızca `integrator` rolündeki işçi entegrasyon dalında `pre-pr-readiness`, `gh pr create` ve `pr-auditor` çalıştırır.
4. **Çift Katmanlı Saf Bekleme Kota Kurtarma (5 Saatlik & Haftalık Kota):**
   - **Saf Bekleme Politikası:** 5 saatlik kayan pencere veya haftalık kota dolduğunda işçiler **asla öldürülmez (`kill`)** ve kullanıcı açıkça istemedikçe model **asla değiştirilmez** (`swarm-quota-wait.json` aktifken `swarm(action="model|kill")` çağrıları `force_ask` ile kullanıcı onayına bağlanır).
   - **Katman 1 (Oturum İçi):** İşçi kotaya takıldığında veya `[quota]` uyarısı geldiğinde koordinatör `swarm(action="models")` ile canlı `quota_resets` zamanını okur, `./scripts/stamp-gate.sh swarm-quota pause --resume-at "<ISO>" --window 5h|weekly --member <işçi>` çalıştırır ve yerel `schedule(DurationSeconds=...)` kurup bekler (uzun haftalık beklemelerde 6 saatlik dilimler veya `harness-daemon` kullanılır). Kota açılınca `models` ile `quota_remaining > 0` doğrular, `stamp-gate.sh swarm-quota resume` çalıştırır ve duraklatılan işçileri `@<ad>` ile kaldığı yerden devam ettirir.
   - **Katman 2 (Arka Plan `harness-daemon` Watchdog):** Koordinatörün kendisi kotaya çarpıp `Stop(ERROR)` ile durursa `stop-gate.sh` anlık döngüye girmeden `{}` döner, `swarm-quota-wait.json` dosyasını yazar ve `harness-daemon`'ı uyandırır. Daemon çalışma alanını TTL temizliğinden muaf tutup sıfır token harcayarak bekler ve kota sıfırlanınca `agy --conversation <id> --print=...` ile oturumu otomatik uyandırır. Yeniden başlatmalarda `SessionStart` kancası `[SWARM QUOTA WAIT ACTIVE]` kurtarma bilgisini enjekte eder.

---

## 9. İki Fazlı `Orchestrator` (`Planner ↔ Executor`) ve `run_workflow` Modu

- **İki Fazlı `Orchestrator` (`Neon`/`Carbon`/`Opus 5.5` Planner ↔ `Hydrogen`/`Sonnet 5.5` Executor):**
  1. **Planner Fazı (Salt-Okunur):** `jev_classify`, kod tabanı keşfi, `jev_check` (`ADR`), `context7` doküman sorguları ve `ask_question` kararlarını tamamlayıp `Re-plan if:` tetikleyicileriyle `exit_plan_mode` üzerinden yürütmeye devredin.
  2. **Executor Fazı:** İzole `feat/*` dalı/worktree açıp Spec/Plan/kod yazın, `stamp-gate.sh` ve `run-quiet.sh` doğrulamalarını çalıştırın; başarısız doğrulama veya plan dışı karar gereksiniminde `enter_plan_mode` ile Planner'a dönün.
- **`run_workflow` Koruması:** `hooks.json` (`invoke_subagent|swarm|run_workflow`) dinamik Python iş akışı betiklerinde doğrudan `subprocess`/`os.system` kabuk atlatmalarını, `pty`/`eval`/`exec` kaçışlarını, gömülü gizli anahtarları ve geçersiz statik `agent(model=...)` katmanlarını AST tabanlı analizle fiziksel olarak reddeder.

---

## 10. Claude Code CLI (`claude -p`) Spec/Plan & TDD Kapsam İncelemesi ve 30 sn Fallback

Spec/Plan onayı öncesi ve TDD uygulama sonrası birim test kapsam denetimi birincil olarak yerel `claude -p` (salt-okunur `--permission-mode plan --tools Read,Grep,Glob`) üzerinden yürütülür:

```bash
# 1. Spec / Plan İncelemesi (opus / medium — kayıt: spec-plan-review.json)
./scripts/stamp-gate.sh review --kind spec-plan --target "docs/superpowers/specs/<spec>.md" --target "docs/superpowers/plans/<plan>.md"

# 2. TDD Birim Test Kapsam Denetimi (sonnet / high — temizse tdd-pass.json damgalar)
./scripts/stamp-gate.sh review --kind tdd --auto-stamp
```

### `exit 42` (`claude_unavailable`) Durumunda 30 Saniyelik Fallback Protokolü
1. `claude` CLI kurulu değilse veya herhangi bir sebeple (oturum/auth, kota/rate-limit, ağ, zaman aşımı, sıfır dışı çıkış) çalışmazsa komut **sessiz fallback yapmaz**; `reason` ve `fallbackChoices` içeren JSON dönüp `exit 42` ile çıkar.
2. Ana ajan, `reason` değerini kullanıcıya açıkça bildirerek Antigravity'deki **Claude** modelini mi yoksa **Gemini 4** modelini mi kullanacağını sorar ve **aynı turda** `schedule(DurationSeconds=30, TimerCondition="any")` zamanlayıcısını kurup turu bitirir.
3. Kullanıcı 30 saniye içinde seçim yaparsa o modelle, yanıt gelmezse otomatik varsayılanla `agy -p` çalıştırılır:
   - **Spec / Plan Review:** Antigravity Claude → `--provider agy --model claude-opus-5-5-medium` | Gemini / 30 sn timeout → `--provider agy --model gemini-4-carbon-high`
   - **TDD Kapsam Denetimi:** Antigravity Claude → `--provider agy --model claude-sonnet-5-5-high` | Gemini / 30 sn timeout → `--provider agy --model gemini-4-neon-medium`
4. Kod/betik dosyası değişen her dalda `gh pr create` ve yerel `git merge` öncesi taze `tdd-pass.json` (`criticalGaps == 0`, `importantGaps == 0`, güncel `codeTreeSha`) zorunludur.
