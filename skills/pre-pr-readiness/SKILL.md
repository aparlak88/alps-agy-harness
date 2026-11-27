---
name: pre-pr-readiness
description: "PR açılışı öncesi son doğrulama orkestratörü: sessiz derleme/testleri çalıştırır, diff içindeki tüm dosyaları Ne ve Neden analizleriyle kapsayan derin mühendislik PR rehberini (walkthrough) üretir, canon-auditor ve security-reviewer alt ajanlarını denetleyip damgaları doğrular."
---

# Pre-PR Readiness: PR Öncesi Hazırlık ve Kapsamlı Mühendislik Rehberi

Bu skill, bir geliştirme dalında tüm görevler tamamlandığında ve PR açılmadan hemen önce (`finishing-a-development-branch` aşamasında) çalıştırılan zorunlu kontrol merkezidir.

sert PR açma kapısının (koşullu UI damgası ve dosya bazlı tam walkthrough kapsama kontrolü dahil) sorunsuz geçilmesini sağlar.

---

## 1. Doğrulama Sırası

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
2. **Bayat Otopark Kayıtlarını Temizleyin (`docs/parking-lot.md`):**
   Mevcut dal farkının (`git diff <base>..HEAD`) `docs/parking-lot.md` içindeki herhangi bir maddeyi zaten çözüp çözmediğini kontrol edin; bu dalda çözülmüş maddeleri PR açmadan önce `docs/parking-lot.md` dosyasından temizleyin (`codeTreeSha` hesabı `docs/parking-lot.md` dosyasını dışarıda bıraktığı için mevcut `canon` veya `security` denetim damgalarını bozmaz).
3. **Şablonu Okuyun ve Rehberi Üretin:**
   `skills/pre-pr-readiness/templates/walkthrough-template.md` şablonunu okuyun ve `docs/walkthroughs/YYYY-MM-DD-<ozellik>.md` dosyasını oluşturun. Şablondaki köşeli parantez yer tutucularının tamamını gerçek proje bilgileriyle değiştirin:
   - **Problem Bağlamı ve Mimari Kararlar:** Çözülen gerçek kök problemi, neden bu yaklaşımın seçildiğini, elenen alternatifleri ve ödünleşimleri (*trade-offs*) açıklayın.
   - **Mimari ve Veri Akışı Diyagramları (`>= 2` Mermaid):** Jenerik isimler (`[Feature]Controller`, `A --> B`) yerine projedeki gerçek sınıf, arayüz, modül ve metod adlarıyla en az 2 adet ```` ```mermaid ```` diyagramı çizin.
   - **`## 3. Dosya Bazlı Değişiklik Analizi` (Tam Kapsama Zorunluluğu):** `git diff --name-status <base>..HEAD` çıktısındaki (`docs/walkthroughs/*` ve `docs/parking-lot.md` hariç) **her bir dosya** için ayrı bir `### \`<dosya/yolu>\` — [ÜRETİLDİ | GÜNCELLENDİ | SİLİNDİ] (\`<Katman>\`)` alt bloğu açın:
     - **Ne Değişti / Ne Üretildi? (veya Ne Silindi?):** Eklenen/değiştirilen sınıfları, metod imzalarını, veri yapılarını ve kritik iş mantığını somut teknik detaylarla (gerekiyorsa kısa kod kesitiyle) anlatın. Tek cümlelik geçiştirme yasaktır.
     - **Neden Değişti / Neden Üretildi? (veya Neden Silindi?):** Değişikliği zorunlu kılan iş kuralını, Clean Architecture katman sınırını, sözleşmeyi veya kök nedeni açıklayın.
   - **Kritik İş Mantığı, Kenar Durumlar ve Hata Yönetimi:** Sınır durumları ve hata davranışlarını detaylandırın.
   - **Somut Doğrulama Kanıtları:** "Tüm testler geçti" demek yerine hangi test dosyasının neyi kanıtladığını, çalıştırılan gerçek komutları ve gerçek çıktı özetlerini yazın.
   - **Kapsam Dışı ve Sözlük:** `docs/parking-lot.md` notlarını ekleyin ve dokümanı eksiksiz `## Teknik Terimler Sözlüğü` tablosuyla bitirin.
4. **Fiziksel Hook Kuralını Unutmayın:**
   `pre-command-guard.sh`, `git diff --name-only <base>..HEAD` içindeki tek bir dosyanın bile `## Dosya Bazlı Değişiklik Analizi` altında yer almaması veya `Ne` / `Neden` açıklamalarının yüzeysel bırakılması durumunda `gh pr create` ve yerel `git merge` komutlarını `deny` ile fiziksel olarak reddeder!
5. **Rehberi Commit Edin (veya `.gitignore` İstisnası):**
   ```bash
   git add docs/walkthroughs/
   git commit -m "docs: add comprehensive PR engineering walkthrough"
   ```
   - Eğer hedef depoda `docs/walkthroughs/*` bilerek `.gitignore` altındaysa (`git check-ignore -q docs/walkthroughs/_probe.md` `0` dönüyorsa), `git add -f` yapmanıza gerek yoktur; `pre-command-guard.sh` yerel `<worktree>/docs/walkthroughs/*.md` dosyalarını en yeniden eskiye (`mtime`) tarayarak aynı `Ne`/`Neden` kapsam ve `## Teknik Terimler Sözlüğü` doğrulamasını uygular.

> [!NOTE]
> `codeTreeSha` hesabı `docs/walkthroughs/` ve `docs/parking-lot.md` dosyalarını otomatik olarak dışarıda bırakır; böylece walkthrough commit edildikten veya güncellendikten sonra denetim damgaları bozulmaz.

> [!IMPORTANT]
> **Swarm Entegrasyon Dalı Kuralı:** Antigravity Swarm oturumunda paralel çalışan işçilerin dalları (`feat/<konu>-<işçi>`) doğrudan PR'a gönderilmez ve işçi başına ayrı Walkthrough üretilmez. Çoklu Swarm işçi dalları önce uzman **`integrator` Swarm işçisi** tarafından tek `feat/*` entegrasyon dalında birleştirilir (koordinatörün kendisi birleştirme veya dosya yazma yapmaz); ardından `integrator` bu entegrasyon dalı üzerinde tek bir bütünleşik `docs/walkthroughs/*.md` rehberini hazırlar, `canon-auditor` + `security-reviewer` + `tdd-pass` + koşullu `ui-pass` denetimlerini tek seferde damgalar ve `gh pr create` + `pr-auditor` adımlarını yürütür.

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

### Adım 4b (Kod/Betik Değiştiyse Zorunlu): TDD Birim Test Kapsam Denetimi (`tdd-pass.json`)
Dal farkında doküman-dışı üretim kodu veya betik dosyası değiştiyse `verify-pr-stamps`, `gh pr create` ve yerel `git merge` taze `tdd-pass.json` damgasını zorunlu kılar (salt doküman PR'larında pasiftir):
1. Birincil olarak yerel Claude Code CLI (`claude -p --model sonnet --effort high`, salt-okunur) çalıştırın:
   ```bash
   ./scripts/stamp-gate.sh review --kind tdd --auto-stamp
   ```
2. Komut `exit 42` (`claude_unavailable`) dönerse sessizce geçmeyin: dönen `reason` bilgisini kullanıcıya açıklayıp Antigravity'deki **Claude (`claude-sonnet-5-5-high`)** mı yoksa **Gemini 4 (`gemini-4-neon-medium`)** mı kullanılacağını sorun ve aynı turda `schedule(DurationSeconds=30, TimerCondition="any")` kurun. Seçime veya 30 sn dolumunda varsayılan `gemini-4-neon-medium` modeline göre çalıştırın:
   ```bash
   ./scripts/stamp-gate.sh review --kind tdd --provider agy --model <claude-sonnet-5-5-high|gemini-4-neon-medium> --auto-stamp
   ```
3. Kritik veya önemli test açığı varsa eksikleri tamamlayıp tekrar çalıştırın (veya denetim sonucunu doğrudan damgalayın):
   ```bash
   ./scripts/stamp-gate.sh tdd --verdict PASS --critical-gaps 0 --important-gaps 0 --provider claude-cli --model sonnet --effort high
   ```

---

### Adım 5 (Koşullu): UI/Frontend Kalite ve Anti-Pattern Damgası (`stamp-gate.sh ui`)
Bu adım **yalnızca** dal farkında üretim UI dosyaları (`.html`, `.tsx`, `.css`, `.scss`, `.component.ts`, `.xaml`, SwiftUI `Features`/`Views`, Compose `features`/`ui`) değiştiyse **VE** ortamda `impeccable` kuruluysa zorunludur (saf backend görevlerinde ve `impeccable` kurulu değilken atlanır):
1. Impeccable `critique` / `audit` bulgularında `P0 = 0` ve `P1 = 0` olduğunu doğrulayın (`PRODUCT.md` / `DESIGN.md` uyumu dahil).
2. Web UI dosyaları değiştiyse `stamp-gate.sh ui` komutu otomatik olarak `impeccable detect --json` taramasını (`DO_NOT_TRACK=1 IMPECCABLE_LIVE_COPY_AGENT=off`) çalıştırır ve sıfır bulgu (`exit 0`) aldığında `ui-pass.json` damgasını yazar:
   ```bash
   ./scripts/stamp-gate.sh ui --verdict PASS --p0 0 --p1 0
   ```
   *(Not: `detect` exit kodu `2` dönerse veya `P0`/`P1 > 0` ise `PASS` damgası reddedilir ve `gh pr create` / yerel `merge` kapıları açılmaz.)*

---

## 2. Son Kapı Doğrulaması

Damgaların güncel `codeTreeSha` ile tam eşleştiğini doğrulamak için:
```bash
./scripts/stamp-gate.sh verify-pr-stamps
```
Çıkış kodu `0` ise, `docs/walkthroughs/*.md` dal farkındaki tüm dosyaları kapsıyorsa ve `git status --porcelain` tamamen temiz ise `gh pr create` komutunu güvenle çalıştırabilirsiniz.
