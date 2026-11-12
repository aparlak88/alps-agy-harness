---
name: revenuecat-integration
description: "RevenueCat MCP ve Clean Architecture ile abonelik, yetki (entitlement) ve webhook entegrasyonu: istemci makbuzuna asla güvenmeme ilkesi, eştkili (idempotent) webhook işleme ve Domain katmanı izolasyonu uygular."
---

# RevenueCat Integration & In-App Purchase Engineering

Bu skill, iOS, Android, Web ve .NET backend platformlarında RevenueCat entegrasyonunu Clean Architecture ve DDD prensiplerine tam uyumlu olarak tasarlamak ve uygulamak için rehberlik eder.

RevenueCat MCP sunucusu (`https://mcp.revenuecat.ai/mcp`) ve `context7` resmi SDK dokümantasyonu ile birlikte çalışır.

---

## 1. Temel Mimari İlkeler (Non-Negotiable Invariants)

1. **Katman İzolasyonu (Domain Saflığı):**
   - RevenueCat SDK'ları (`Purchases`, `CustomerInfo`, `Package`, `Offering` vb.) kesinlikle `Domain` veya `Presentation` (View/Controller) katmanlarına doğrudan sızamaz.
   - `Domain` katmanında sağlayıcıdan bağımsız `ISubscriptionGateway` veya `ISubscriptionRepository` arayüzü tanımlanır.
   - Somut RevenueCat SDK çağrıları yalnızca `Infrastructure` (backend) veya `Data` (mobil/web) katmanındaki adaptör sınıfında yer alır.
2. **Asla İstemci Makbuzuna Güvenme (Server-Side Entitlement Truth):**
   - Mobil istemciden gelen "satın alma başarılı" yanıtına dayanarak kullanıcıya kalıcı hak tanınamaz.
   - Gerçek yetki durumu daima sunucu tarafında doğrulanmış `Entitlements` verisiyle belirlenir.
3. **Eştkili (Idempotent) Webhook Yönetimi:**
   - Apple App Store ve Google Play yenileme, iptal ve süre uzatım olayları RevenueCat webhook'ları üzerinden asenkron gelir.
   - Webhook işleyicisi aynı `event_timestamp_ms` veya `id` ile gelen bildirimleri iki kez işlemez (Idempotency Key / Outbox deseni).

---

## 2. RevenueCat MCP Kullanımı

Projede ürün yapılandırması, yetki adları ve müşteri durumunu doğrulamak için `revenuecat` MCP araçlarından yararlanın:
- Ürün ve paket kimliklerini doğrulamak için Offering listesini çekin.
- Test kullanıcılarının yetki durumunu (`CustomerInfo`) sorgulayın.
- Webhook olay şemalarını ve imza doğrulamasını test edin.

---

## 3. Katman Dağılımı ve Kod Örneği

### Domain Katmanı (Saf İş Mantığı)
```csharp
namespace Domain.Subscriptions;

public record SubscriptionTier(string Value)
{
    public static readonly SubscriptionTier Free = new("free");
    public static readonly SubscriptionTier Pro = new("pro");
}

public interface ISubscriptionGateway
{
    Task<bool> HasActiveEntitlementAsync(string customerId, string entitlementId, CancellationToken ct = default);
}
```

### Infrastructure Katmanı (RevenueCat Adaptörü)
```csharp
namespace Infrastructure.Billing;

using Domain.Subscriptions;

public class RevenueCatBillingGateway : ISubscriptionGateway
{
    private readonly HttpClient _httpClient;

    public RevenueCatBillingGateway(HttpClient httpClient) => _httpClient = httpClient;

    public async Task<bool> HasActiveEntitlementAsync(string customerId, string entitlementId, CancellationToken ct = default)
    {
        var response = await _httpClient.GetAsync($"v1/subscribers/{customerId}", ct);
        response.EnsureSuccessStatusCode();
        // DTO çözümleme ve Domain tipine dönüştürme
        return true;
    }
}
```

---

## 4. Doğrulama ve Testler

- **Birim Testleri:** `ISubscriptionGateway` sahte nesnesi (*mock*) ile iş kurallarını test edin.
- **Entegrasyon Testleri:** Webhook payload'unun veritabanı durumunu doğru güncellediğini ve aynı payload tekrar geldiğinde yan etki üretmediğini doğrulayın.
- **Sürüm Doğrulaması:** Paket eklemeden önce `dependency-versions` skill'i ile sürümü `context7` üzerinden sabitleyin.
