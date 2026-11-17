# Alan Kanonu: Bileşik Öğrenilmiş Dersler Hafızası (Compound Lessons)

Bu doküman, projede karşılaşılan sinsi tuzakların, mimari kenar durumların ve çözülen zor kök nedenlerin biriktirildiği kalıcı proje hafızasıdır.

> [!IMPORTANT]
> **Gürültü Önleyici Yazım ve Yürütülebilir Ders Koruması (`Executable Lesson Guard`):**
> Basit sözdizimi hataları, tek seferlik yazım yanlışları veya sıradan tip uyuşmazlıkları bu dosyaya **yazılamaz**. Yalnızca `superpowers:systematic-debugging` ile çözülen sinsi kök nedenler veya PR incelemesinde yakalanan tekrarlanabilir mimari, SDK ve platform tuzakları 3–5 satırlık somut kural olarak kaydedilir.
>
> Statik veya davranışsal olarak test edilebilir her `LSN-*` kaydı, kuralı koruyan **otomatik birim/entegrasyon/mimari fitness testini** **ve** bu testin **PR CI kapısında** (`.github/workflows/*` veya proje CI iş akışında) çalıştığını belirtmelidir. Yalnızca dış ağ, donanım veya bulut çalışma zamanında gözlemlenebilen ve CI'da deterministik olarak test edilemeyen davranışlar için açık **`[Runtime-Only]`** muafiyeti ve gerekçesi yazılabilir.

---

## Ders Kayıt Tablosu

| Ders Kimliği | Tarih / PR | Platform / Modül | Sinsi Tuzak ve Kök Neden | Zorunlu Önleyici Kural / Değişmez | Koruyucu Test & PR CI Kapısı |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `LSN-001` | 2026-11-12 (PR #14) | Backend / ORM | İzleme kapalı (`AsNoTracking` / salt-okuma) sorguyla yüklenen varlık üzerindeki mutasyonların sessizce kalıcı depoya yazılmaması; birim testte gizlenip entegrasyon testinde patlaması. | Durum değiştiren komutlarda (`Command`) izlemeli (*tracking*) oturum zorunludur; salt-okuma sorguları (`Query`) ayrı tutulmalıdır. | `tests/Persistence.IntegrationTests/CommandTrackingTests` + `.github/workflows/pr-checks.yml` (`integration-tests`) |
| `LSN-002` | 2026-11-12 (PR #22) | Frontend / Reactive State | Türetilmiş durum (`computed` / `derived`) hesaplayıcısı içinde yan etki (*side-effect*) veya ağ çağrısı tetiklenmesi sonucu sonsuz döngü ve arayüz donması yaşanması. | Türetilmiş durum seçicileri saf ve yan etkisiz olmalıdır; dış yan etkiler yalnızca açık etki/komut kanallarında çalıştırılmalıdır. | `tests/Architecture.Tests/ReactivePurityFitnessTests` + `.github/workflows/pr-checks.yml` (`lint-and-unit`) |
| `LSN-003` | 2026-11-12 (PR #35) | Entegrasyon / Webhook | Asenkron dış webhook olaylarının istemci yönlendirmesinden önce ulaşıp yarış durumu (*race condition*) ile yetki veya sipariş durumunu geri alması. | Webhook işleyicileri tekil işlem anahtarı (`IdempotencyKey`) üzerinden kilitlemeli ve eşzamanlı yarışta daha ileri durum geçişini asla düşürmemelidir. | `[Runtime-Only]` Dış sağlayıcı canlı teslim sırası CI dışında gözlemlenir; `tests/Webhook/IdempotencyTests` + `.github/workflows/pr-checks.yml` ile çekirdek kilit korunur. |

---

## Yeni Ders Ekleme Kılavuzu

Yeni bir ders eklerken aşağıdaki formatı takip edin:
1. **Ders Kimliği:** `LSN-` ile başlayan sıralı numara.
2. **Kök Neden Açıklaması:** Sorunun neden ilk bakışta anlaşılmadığı ve hangi katmanlar arası etkileşimden kaynaklandığı.
3. **Önleyici Kural:** Gelecekte benzer hatayı engelleyecek mimari fitness testi veya kodlama kuralı.
4. **Koruyucu Test & PR CI Kapısı (`Executable Lesson Guard`):** Kuralı zorlayan otomatik birim/entegrasyon/fitness testinin yolu **ve** bu testin çalıştığı PR CI iş akışı adı (yalnızca dış ağ/bulut çalışma zamanı davranışları için açık `[Runtime-Only]` muafiyet etiketi ve gerekçesi).

---

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| **Compound Memory (Bileşik Hafıza)** | Her çözülen zor problemin kalıcı bir kurala dönüştürülerek sonraki geliştirmelerde hata payını sıfıra indiren mühendislik hafızası. |
| **Executable Lesson Guard** | `docs/canon/lessons.md` içindeki test edilebilir her `LSN-*` dersinin hem koruyucu bir otomatik teste hem de PR CI kapısına bağlanmasını zorunlu kılan doğrulama kuralı. |
| **Idempotency (Eştkili İşlem)** | Bir işlemin aynı parametrelerle birden fazla kez çalıştırıldığında sistem durumunda ilk işlemden farklı bir yan etki üretmemesi güvencesi. |
| **Race Condition (Yarış Durumu)** | İki eşzamanlı işlemin çalışma sırasına bağlı olarak beklenmeyen veya tutarsız sonuçlar üretmesi durumu. |
| **Side-Effect (Yan Etki)** | Bir fonksiyonun dönüş değeri üretmek dışında dış durum veya bellek alanını değiştirmesi (ör. HTTP isteği, UI mutasyonu). |
