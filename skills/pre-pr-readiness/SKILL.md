---
name: pre-pr-readiness
description: "PR açılışı öncesi son doğrulama orkestratörü: sessiz derleme/testleri çalıştırır, diff içindeki tüm dosyaları Ne ve Neden analizleriyle kapsayan derin mühendislik PR rehberini (walkthrough) üretir, canon-auditor ve security-reviewer alt ajanlarını denetleyip damgaları doğrular."
---

# Pre-PR Readiness: PR Öncesi Hazırlık ve Kapsamlı Mühendislik Rehberi

Bu skill, bir geliştirme dalında tüm görevler tamamlandığında ve PR açılmadan hemen önce (`finishing-a-development-branch` aşamasında) çalıştırılan zorunlu kontrol merkezidir.

`pre-command-guard.sh` içindeki 5 maddelik sert PR açma kapısının (dosya bazlı tam walkthrough kapsama kontrolü dahil) sorunsuz geçilmesini sağlar.

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

### Adım 2: Kapsamlı Mühendislik PR Rehberi (Walkthrough) Oluşturma ve Commit
Okuyucunun IDE'yi açmadan tüm işi, mimari kararları ve her bir dosyadaki değişikliği derinlemesine anlayabileceği öğretici mühendislik rehberini hazırlayın. **Tek satırlık yüzeysel özet maddeler kesinlikle yasaktır.**

1. **Önce Tam Dal Farkını Çıkarın (Zorunlu):**
   Walkthrough yazmaya başlamadan önce dalda üretilen, güncellenen ve silinen **tüm** dosyaların tam listesini ve satır istatistiklerini alın:
   ```bash
   git diff --name-status <base>..HEAD
   git diff --stat <base>..HEAD
   ```
2. **Şablonu Okuyun ve Rehberi Üretin:**
   `skills/pre-pr-readiness/templates/walkthrough-template.md` şablonunu okuyun ve `docs/walkthroughs/YYYY-MM-DD-<ozellik>.md` dosyasını oluşturun. Şablondaki köşeli parantez yer tutucularının tamamını gerçek proje bilgileriyle değiştirin:
   - **Problem Bağlamı ve Mimari Kararlar:** Çözülen gerçek kök problemi, neden bu yaklaşımın seçildiğini, elenen alternatifleri ve ödünleşimleri (*trade-offs*) açıklayın.
   - **Mimari ve Veri Akışı Diyagramları (`>= 2` Mermaid):** Jenerik isimler (`[Feature]Controller`, `A --> B`) yerine projedeki gerçek sınıf, arayüz, modül ve metod adlarıyla en az 2 adet ```` ```mermaid ```` diyagramı çizin.
   - **`## 3. Dosya Bazlı Değişiklik Analizi` (Tam Kapsama Zorunluluğu):** `git diff --name-status <base>..HEAD` çıktısındaki (`docs/walkthroughs/*` ve `docs/parking-lot.md` hariç) **her bir dosya** için ayrı bir `### \`<dosya/yolu>\` — [ÜRETİLDİ | GÜNCELLENDİ | SİLİNDİ] (\`<Katman>\`)` alt bloğu açın:
     - **Ne Değişti / Ne Üretildi? (veya Ne Silindi?):** Eklenen/değiştirilen sınıfları, metod imzalarını, veri yapılarını ve kritik iş mantığını somut teknik detaylarla (gerekiyorsa kısa kod kesitiyle) anlatın. Tek cümlelik geçiştirme yasaktır.
     - **Neden Değişti / Neden Üretildi? (veya Neden Silindi?):** Değişikliği zorunlu kılan iş kuralını, Clean Architecture katman sınırını, sözleşmeyi veya kök nedeni açıklayın.
   - **Kritik İş Mantığı, Kenar Durumlar ve Hata Yönetimi:** Sınır durumları ve hata davranışlarını detaylandırın.
   - **Somut Doğrulama Kanıtları:** "Tüm testler geçti" demek yerine hangi test dosyasının neyi kanıtladığını, çalıştırılan gerçek komutları ve gerçek çıktı özetlerini yazın.
   - **Kapsam Dışı ve Sözlük:** `docs/parking-lot.md` notlarını ekleyin ve dokümanı eksiksiz `## Teknik Terimler Sözlüğü` tablosuyla bitirin.
3. **Fiziksel Hook Kuralını Unutmayın:**
   `pre-command-guard.sh`, `git diff --name-only <base>..HEAD` içindeki tek bir dosyanın bile `## Dosya Bazlı Değişiklik Analizi` altında yer almaması veya `Ne` / `Neden` açıklamalarının yüzeysel bırakılması durumunda `gh pr create` ve yerel `git merge` komutlarını `deny` ile fiziksel olarak reddeder!
4. **Rehberi Commit Edin:**
   ```bash
   git add docs/walkthroughs/
   git commit -m "docs: add comprehensive PR engineering walkthrough"
   ```

> [!NOTE]
> `codeTreeSha` hesabı `docs/walkthroughs/` ve `docs/parking-lot.md` dosyalarını otomatik olarak dışarıda bırakır; böylece walkthrough commit edildikten veya güncellendikten sonra denetim damgaları bozulmaz.

---

### Adım 3: `canon-auditor` Denetimi ve Damgası
1. `stamp-gate.sh dispatch` ile `canon-auditor` için kayıt açın:
   ```bash
   ./scripts/stamp-gate.sh dispatch --role "Canon Audit" --type "canon-auditor" --tier "multi_module_integration"
   ```
2. `invoke_subagent` ile `canon-auditor` alt ajanını çalıştırın (`canon-auditor` hem kod/kanon uyumunu hem de walkthrough dokümanının dosya bazlı derinliğini denetler).
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
Çıkış kodu `0` ise, `docs/walkthroughs/*.md` dal farkındaki tüm dosyaları kapsıyorsa ve `git status --porcelain` tamamen temiz ise `gh pr create` komutunu güvenle çalıştırabilirsiniz.
