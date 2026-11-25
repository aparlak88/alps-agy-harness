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

Antigravity'nin `invoke_subagent` aracı yalnızca `inherit | flash_lite | flash | pro` katmanlarını kabul eder (`pro` = **Gemini 4 Argon**, `flash` = **Gemini 3.8 Flash**, `inherit` = ana oturumun aktif **Carbon / Neon / Argon / Hydrogen / `Orchestrator` / Claude / custom** modeli; diğer `Gemini 4` adları varsayılan olarak `Argon` / `Argon-Low` sınıfına eşlenir).

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
- **`bounded_execution` (`MEDIUM` / `XHIGH`):** `Orchestrator`, **Gemini 4 Hydrogen** ve `Argon (Low)` (veya `Neon Low`) oturumlarında `inherit` (kodlayıcılar eski 3.8 Flash'a düşmez); **Gemini 4 Carbon**, **Neon**, `Argon (Med/High)`, genel `Gemini 4`, Claude ve `custom` oturumlarında `pro` (**Gemini 4 Argon**); `3.8 Flash` ve `unset` oturumlarında `flash`.
- **`multi_module_integration` (`HIGH`, `canon-auditor` tabanı):** `Orchestrator`, `Argon (Med/High)`, genel `Gemini 4`, Claude ve `custom` oturumlarında `inherit`; `Carbon` ve `Neon` oturumlarında varsayılan `pro` (**Argon**; açık `Model: "inherit"` verilirse Carbon/Neon korunur); `Hydrogen`, `Argon (Low)` ve `3.8 Flash` oturumlarında `pro` (**Argon**'a yükseltilir).
- **`critical_architecture_or_audit` (`MAX`, `security-reviewer` ve `pr-auditor`):** `Carbon`, `Neon`, `Orchestrator`, `Argon (Med/High)`, genel `Gemini 4`, Claude ve `custom` oturumlarında `inherit` (üst seviye model asla Argon Medium'a düşürülmez); `Hydrogen`, `Argon (Low)` ve `3.8 Flash` oturumlarında `pro` (**Argon**'a yükseltilir).

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

## 7. Yaşam Döngüsü Tamamlama

Uygulama tamamlandığında:
1. `pre-pr-readiness` skill'ini çağırın (`canon-auditor`, `security-reviewer`, Walkthrough).
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
