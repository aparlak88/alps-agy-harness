# Alan Kanonu: Ortak Dil Sözlüğü (Ubiquitous Language Glossary)

Bu doküman, projede iş birimi, ürün yönetimi, mimari dokümanlar (Spec, Plan, Walkthrough) ve kaynak kod arasında terim birliğini sağlamak için kullanılan tekil gerçeği (**Ubiquitous Language**) tanımlar.

Spec, Plan, kod veya kod içi dokümantasyon yorumlarında buradaki kanonik İngilizce tanımlayıcılar haricinde alternatif eş anlamlıların kullanılması bloklayıcı mimari hatadır.

| İngilizce Kod Terimi (Canonical Identifier) | Türkçe Karşılığı | Bağlam (Bounded Context) | İş Tanımı ve Değişmez Kurallar (Invariants) | Kaçınılacak Eş Anlamlılar (Forbidden Aliases) |
| :--- | :--- | :--- | :--- | :--- |
| `CustomerSubscription` | Müşteri Aboneliği | Billing / Subscriptions | Müşterinin aktif veya süresi dolmuş abonelik kaydı; her zaman tekil bir `Tier` ve `ExpirationDateUtc` taşır. | `Plan`, `Membership`, `UserTier` |
| `SubscriptionTier` | Abonelik Seviyesi | Billing / Catalog | Müşterinin sahip olabileceği yetki seviyesi (`Free`, `Pro`, `Enterprise`); değiştirilemez değer nesnesidir (*Value Object*). | `Level`, `PackageType`, `Grade` |
| `BillingGateway` | Faturalandırma Geçidi | Infrastructure / Payment | Dış ödeme ve abonelik sağlayıcısı (RevenueCat/Stripe) adaptörü; domain katmanında yalnızca arayüzü bulunur. | `PaymentProcessor`, `StoreKitBridge` |
| `ClientWorkAddress` | Müşteri İş Adresi | Customer Management | Müşterinin kayıtlı fatura ve iş adresi; ülke kodu ISO 3166-1 alpha-2 formatında olmak zorundadır. | `OfficeLocation`, `Workplace`, `CompanyAddr` |
| `OrderFulfillmentStatus` | Sipariş Karşılama Durumu | Fulfillment / Shipping | Siparişin depodan çıkış ve teslim durumunu belirten kesin durum makinesi (`Pending`, `Packed`, `Shipped`, `Delivered`). | `ShippingState`, `DeliveryStatus` |
