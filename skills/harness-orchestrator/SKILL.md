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

## 4. Hibrit Alt Ajan Model ve Efor Yönlendirme

Her `invoke_subagent` çağrısından önce, işin karmaşıklığına göre `stamp-gate.sh dispatch` çalıştırarak yönlendirme kararını kaydedin:

```bash
./scripts/stamp-gate.sh dispatch \
  --role "<Alt Ajan Rolü>" \
  --type "self" \
  --tier "trivial_lookup|bounded_execution|multi_module_integration|critical_architecture_or_audit"
```

Katman Eşlemesi:
- **`trivial_lookup`:** `flash_lite` / `EFFORT_PROFILE: LOW`
- **`bounded_execution`:** `flash` / `EFFORT_PROFILE: MEDIUM`
- **`multi_module_integration`:** `inherit` / `EFFORT_PROFILE: HIGH`
- **`critical_architecture_or_audit`:** `pro` / `EFFORT_PROFILE: MAX`

`pre-subagent-guard.sh` hook'u bu kaydı okur, tek seferlik tüketir (`consumed: true`) ve Antigravity'nin yerel `overwrite` yeteneğiyle alt ajanın modelini ve prompt başlığını fiziksel olarak kilitler.

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
