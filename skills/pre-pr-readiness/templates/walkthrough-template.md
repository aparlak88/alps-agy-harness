# Pull Request Görsel Rehberi: [Özellik / Düzeltme Başlığı]

Bu doküman, bu PR ile yapılan değişikliklerin amacını, mimari katman dağılımını, veri akışını ve doğrulama adımlarını yeni katılan bir geliştiricinin kolayca anlayabileceği sadelikte açıklar.

---

## 1. İş Amacı ve Mimari Özet

### Neyi ve Neden Değiştirdik?
- **İş Problemi / İhtiyaç:** [Kullanıcının veya sistemin karşılaştığı temel problem]
- **Çözüm Özeti:** [Mimariyi bozmadan uygulanan yalın çözüm yaklaşımı]
- **Etkilenen Bounded Context:** [Ör. Subscriptions, Catalog, Identity]

---

## 2. Katman ve Modül Değişiklik Haritası

Aşağıdaki diyagram, bu PR kapsamında değiştirilen veya yeni eklenen bileşenlerin Clean Architecture katmanlarındaki yerleşimini ve bağımlılık yönünü gösterir:

```mermaid
flowchart LR
    subgraph Presentation ["Presentation / UI Katmanı"]
        Controller["[Feature]Controller / Minimal API"]
        ViewModel["[Feature]ViewModel / Component"]
    end

    subgraph Application ["Application Katmanı (CQRS)"]
        Handler["[Feature]CommandHandler"]
        Validator["[Feature]CommandValidator"]
    end

    subgraph Domain ["Domain Katmanı (Saf İş Mantığı)"]
        Aggregate["[Entity] Aggregate Root"]
        ValueObj["[Value] Value Object"]
        Interface["I[Feature]Repository"]
    end

    subgraph Infrastructure ["Infrastructure / Data Katmanı"]
        RepoImpl["[Feature]Repository"]
        Gateway["ExternalGatewayAdapter"]
    end

    Controller --> Handler
    ViewModel --> Handler
    Handler --> Validator
    Handler --> Aggregate
    Handler --> Interface
    RepoImpl -.-> Interface
    Gateway -.-> Interface
```

---

## 3. Veri ve Durum Akışı Diyagramları

### Uçtan Uca İstek ve Yanıt Akışı
```mermaid
sequenceDiagram
    autonumber
    actor Client as İstemci (Web / Mobil)
    participant API as Controller / Presentation
    participant App as Application Handler
    participant Domain as Domain Aggregate
    participant DB as Veritabanı / Altyapı

    Client->>API: HTTP POST /api/v1/[feature]
    API->>App: ExecuteCommand(request)
    App->>Domain: ExecuteBusinessRule()
    Domain-->>App: BusinessRuleAppliedEvent
    App->>DB: SaveChangesAsync()
    DB-->>App: OK
    App-->>API: CommandResult(Success)
    API-->>Client: 200 OK / 201 Created
```

### Durum Değişimi veya Yaşam Döngüsü
```mermaid
stateDiagram-v2
    [*] --> InitialState: Başlatıldı
    InitialState --> Processing: İstek Doğrulandı
    Processing --> Completed: İş Kuralı Başarılı
    Processing --> Failed: Kural İhlali / Hata
    Failed --> [*]
    Completed --> [*]
```

---

## 4. Doğrulama Kanıtları

- **Birim ve Entegrasyon Testleri:** `run-quiet.sh` üzerinden tüm testler sıfır hata ile geçti.
- **Mimari Fitness Testi:** Katman sınırları (`NetArchTest` / `Sheriff` / `Konsist`) denetlendi; katman sızıntısı yok.
- **Konsol ve Çalışma Zamanı Teşhisi:** Sıfır konsol hatası (`pageerror`, `console.error`) ve mobil log temizliği doğrulandı.
- **Denetim Damgaları:**
  - `canon-pass.json`: `PASS` (Glossary, Flows ve Clean Arch tam uyumlu)
  - `security-pass.json`: `PASS` (0 Critical, 0 Important güvenlik bulgusu)

---

## 5. Kapsam Dışı Bırakılanlar

- **V2 Otopark Maddeleri (`docs/parking-lot.md`):**
  - [İleride ele alınacak performans iyileştirmesi veya ikincil özellik]
- **Riskler ve Dikkat Edilecek Noktalar:**
  - [Önemli çalışma zamanı ön koşulu veya ortam değişkeni gereksinimi]

---

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| **Clean Architecture** | İş kurallarını veritabanı, UI ve dış kütüphanelerden bağımsız kılan, bağımlılıkların içe doğru baktığı yazılım mimarisi. |
| **Command & Query (CQRS)** | Durum değiştiren komutlar ile yalnızca veri okuyan sorguların modellerini ve işleyicilerini birbirinden ayıran desen. |
| **Flowchart** | Bileşenlerin ve katmanların birbirine olan bağımlılık yönlerini gösteren yönlendirilmiş akış diyagramı. |
| **Sequence Diagram** | İstemci ile sunucu bileşenleri arasındaki mesajlaşma ve çağrı sırasını adım adım gösteren diyagram. |
| **Value Object** | Kimliği olmayan, taşıdığı değerlerle tanımlanan ve değiştirilemez (*immutable*) DDD nesnesi. |
