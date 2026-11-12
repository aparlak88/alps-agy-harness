---
name: pre-pr-readiness
description: "PR açılışı öncesi son doğrulama orkestratörü: sessiz derleme/testleri çalıştırır, 2-Mermaid görsel PR rehberini (walkthrough) üretir, canon-auditor ve security-reviewer alt ajanlarını denetleyip damgaları doğrular."
---

# Pre-PR Readiness: PR Öncesi Hazırlık ve Doğrulama

Bu skill, bir geliştirme dalında tüm görevler tamamlandığında ve PR açılmadan hemen önce (`finishing-a-development-branch` aşamasında) çalıştırılan zorunlu kontrol merkezidir.

`pre-command-guard.sh` içindeki 5 maddelik sert PR açma kapısının sorunsuz geçilmesini sağlar.

---

## 1. Dört Aşamalı Doğrulama Sırası

PR açılmadan önce aşağıdaki adımlar sırayla tamamlanmalıdır:

### Adım 1: Sessiz Derleme, Test ve Fitness Koşusu
Tüm platform derleme ve testlerini `run-quiet.sh` üzerinden çalıştırın:
```bash
./scripts/run-quiet.sh test-suite -- dotnet test
# veya
./scripts/run-quiet.sh test-suite -- npm test
```
- Mimari fitness testlerinin (`NetArchTest`, `Sheriff`, `Konsist`) geçtiğini doğrulayın.
- Web UI dosyaları değiştiyse `playwright-e2e` ile sıfır-konsol-hatası kontrolü yapın.
- Mobil dosyalar değiştiyse `mobile-diagnostics` (`mobile-logs.sh`) ile kilitlenme ve log temizliğini kontrol edin.

---

### Adım 2: Görsel PR Rehberi (Walkthrough) Oluşturma ve Commit
Dala yeni katılan junior bir geliştiriciye anlatır gibi sade ve öğretici bir dille görsel rehber hazırlayın:
1. `skills/pre-pr-readiness/templates/walkthrough-template.md` şablonunu okuyun.
2. `docs/walkthroughs/YYYY-MM-DD-<ozellik>.md` yolunda rehberi oluşturun.
3. Rehberin **en az 2 adet ```` ```mermaid ```` diyagramı** (ör. `flowchart LR` ve `sequenceDiagram`) içerdiğinden ve dokümanın sonunda `## Teknik Terimler Sözlüğü` tablosunun bulunduğundan emin olun.
4. Rehberi commit edin:
   ```bash
   git add docs/walkthroughs/
   git commit -m "docs: add PR walkthrough guide"
   ```

> [!NOTE]
> `codeTreeSha` hesabı `docs/walkthroughs/` ve `docs/parking-lot.md` dosyalarını otomatik olarak dışarıda bırakır; böylece walkthrough commit edildikten sonra denetim damgaları bozulmaz.

---

### Adım 3: `canon-auditor` Denetimi ve Damgası
1. `stamp-gate.sh dispatch` ile `canon-auditor` için kayıt açın:
   ```bash
   ./scripts/stamp-gate.sh dispatch --role "Canon Audit" --type "canon-auditor" --tier "multi_module_integration"
   ```
2. `invoke_subagent` ile `canon-auditor` alt ajanını çalıştırın.
3. Denetim başarılı olduğunda `stamp-gate.sh canon` ile damgalayın:
   ```bash
   ./scripts/stamp-gate.sh canon --verdict PASS --allow-file "src/..."
   ```

---

### Adım 4: `security-reviewer` Taraması ve Damgası
1. `stamp-gate.sh dispatch` ile `security-reviewer` için kayıt açın:
   ```bash
   ./scripts/stamp-gate.sh dispatch --role "Security Review" --type "security-reviewer" --tier "critical_architecture_or_audit"
   ```
2. `invoke_subagent` ile `security-reviewer` alt ajanını çalıştırın (`pro` model ve `MAX` efor ile çalışır).
3. `Critical` ve `Important` bulgular 0 olduğunda damgalayın:
   ```bash
   ./scripts/stamp-gate.sh security --verdict PASS --critical 0 --important 0
   ```

---

## 2. Son Kapı Doğrulaması

Damgaların güncel `codeTreeSha` ile tam eşleştiğini doğrulamak için:
```bash
./scripts/stamp-gate.sh verify-pr-stamps
```
Çıkış kodu `0` ise ve `git status --porcelain` tamamen temiz ise `gh pr create` komutunu güvenle çalıştırabilirsiniz.
