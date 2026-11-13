# Alan Kanonu: Bileşik Öğrenilmiş Dersler Hafızası (Compound Lessons)

Bu doküman, projede karşılaşılan sinsi tuzakların, mimari kenar durumların ve çözülen zor kök nedenlerin biriktirildiği kalıcı proje hafızasıdır.

> [!IMPORTANT]
> **Gürültü Önleyici Yazım Kuralı (Zero-Noise):**
> Basit sözdizimi hataları, tek seferlik yazım yanlışları veya sıradan tip uyuşmazlıkları bu dosyaya **yazılamaz**. Yalnızca `superpowers:systematic-debugging` ile çözülen sinsi kök nedenler veya PR incelemesinde yakalanan tekrarlanabilir mimari, SDK ve platform tuzakları 3–5 satırlık somut kural olarak kaydedilir.

---

## Ders Kayıt Tablosu

| Ders Kimliği | Tarih / PR | Platform / Modül | Sinsi Tuzak ve Kök Neden | Zorunlu Önleyici Kural / Değişmez | Kanıt Dosyası / Test |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `LSN-001` | 2026-11-12 (PR #14) | .NET / EF Core | EF Core `AsNoTracking()` ile sorgulanan varlık üzerinde yapılan değişikliklerin sessizce veritabanına yazılmaması; birim testte fark edilmeyip entegrasyon testinde patlaması. | Durum değiştiren komutlarda (`Command`) kesinlikle `AsTracking()` veya doğrudan `DbContext` takibi kullanılmalı; salt okuma sorguları (`Query`) ayrılmalıdır. | `src/Billing/UpdateSubscriptionCommandHandler.cs` |
| `LSN-002` | 2026-11-12 (PR #22) | Angular / Signals | `computed()` sinyali içinde yan etki (*side-effect*) veya HTTP çağrısı tetiklenmesi sonucu sonsuz döngü ve donma yaşanması. | `computed()` yalnızca saf hesaplama yapmalıdır; dış yan etkiler için `effect()` kullanılmalı ve `allowSignalWrites: true` gerekmedikçe kaçınılmalıdır. | `src/app/billing/billing-store.ts` |
| `LSN-003` | 2026-11-12 (PR #35) | Mobil / RevenueCat | Webhook bildirimlerinin mobil istemci satın alımından önce sunucuya ulaşıp yetkisiz kullanıcı durumuna düşürmesi yarış durumu (*race condition*). | Webhook işleyicileri `idempotent` olmalı; istemci satın alım işlemi ile webhook olayları aynı `OriginalTransactionId` üzerinden kilitlenerek güncellenmelidir. | `src/Billing/RevenueCatWebhookHandler.cs` |

---

## Yeni Ders Ekleme Kılavuzu

Yeni bir ders eklerken aşağıdaki formatı takip edin:
1. **Ders Kimliği:** `LSN-` ile başlayan sıralı numara.
2. **Kök Neden Açıklaması:** Sorunun neden ilk bakışta anlaşılmadığı ve hangi katmanlar arası etkileşimden kaynaklandığı.
3. **Önleyici Kural:** Gelecekte benzer hatayı engelleyecek mimari fitness testi veya kodlama kuralı.
4. **Doğrulama:** Hatayı engelleyen test dosyasının konumu.

---

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| **Compound Memory (Bileşik Hafıza)** | Her çözülen zor problemin kalıcı bir kurala dönüştürülerek sonraki geliştirmelerde hata payını sıfıra indiren mühendislik hafızası. |
| **Idempotency (Eştkili İşlem)** | Bir işlemin aynı parametrelerle birden fazla kez çalıştırıldığında sistem durumunda ilk işlemden farklı bir yan etki üretmemesi güvencesi. |
| **Race Condition (Yarış Durumu)** | İki eşzamanlı işlemin çalışma sırasına bağlı olarak beklenmeyen veya tutarsız sonuçlar üretmesi durumu. |
| **Side-Effect (Yan Etki)** | Bir fonksiyonun dönüş değeri üretmek dışında dış durum veya bellek alanını değiştirmesi (ör. HTTP isteği, UI mutasyonu). |
