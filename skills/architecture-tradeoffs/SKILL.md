---
name: architecture-tradeoffs
description: "Önemli tasarım ve kütüphane kararlarında 2–3 somut seçeneğin artı/eksi matrisini çıkarır, jev_check ile mimari trade-off kalibrasyonu yapar ve kararı Spec içine ADR olarak kaydeder."
---

# Architecture Trade-offs

Bu skill, `superpowers:brainstorming` aşamasında ajanın seçenekleri arka planda sessizce eleyip tek öneriyle ilerleme eğilimini ortadan kaldırır.

Önemli mimari kararlarda (kimlik doğrulama, state yönetimi, veri tabanı erişim modeli, modüller arası iletişim, önbellekleme, hata kurtarma vb.) kullanıcıya yapılandırılmış bir seçim matrisi sunulmasını zorunlu kılar.

---

## 1. Ne Zaman Tetiklenir?

- Yeni bir özellik veya modül için Spec (`docs/superpowers/specs/`) yazılırken.
- Birden fazla uygulanabilir mimari desen veya kütüphane alternatifi olduğunda.
- `jev_check` ile yapılan mimari karar taramasında `yes` veya `uncertain` skoru alındığında (`yes_at_or_above: 0.65`).

---

## 2. 2–3 Somut Seçenek Kuralı

Ajan asla varsayımda bulunarak tek bir çözümü dayatamaz. Karşılaştırma için **en az 2, en fazla 3 gerçekçi ve uygulanabilir yaklaşım** belirlenir.

Her yaklaşım aşağıdaki boyutlarda değerlendirilir:
1. **Karmaşıklık ve Bakım Maliyeti:** Kaç yeni dosya, sınıf ve kavram ekleniyor?
2. **Test Edilebilirlik:** Birim ve entegrasyon testleri ne kadar kolay yazılıyor? Dış servislere sahte nesne (*mock*) ihtiyacı ne düzeyde?
3. **Katman Saflığı (Clean Architecture):** `Domain` katmanı dış bağımlılıklardan tamamen izole kalıyor mu?
4. **YAGNI & Rule of Three:** Şimdiden tek kullanımlık arayüzler ve geleceğe yönelik gereksiz soyutlamalar üretiliyor mu?

---

## 3. `jev` Kalibrasyonu

Seçenekleri formüle ederken `jev_check` ve `jev_score` araçlarını kullanarak nesnel güven analizi yapın:

```json
{
  "statement": "Seçilen Yaklaşım A, sistemin mevcut Clean Architecture ve DDD sınırlarını ihlal etmeden en yalın çözümü sunmaktadır.",
  "yes_at_or_above": 0.65
}
```

Eğer güven skoru eşiğin altında kalıyorsa veya gizli katman sızıntısı riski yüksekse alternatif yaklaşımı (Yaklaşım B) öneri olarak öne çıkarın.

---

## 4. Karar Sunumu ve `ask_question`

Kullanıcıya artı/eksi matrisini sade ve net bir dille sunun:

```markdown
### Mimari Karar Seçenekleri: [Konu Başlığı]

| Seçenek | Ne Kazanırız? (Artılar) | Ne Kaybederiz? (Eksiler / Maliyet) | Öneri Durumu |
| :--- | :--- | :--- | :--- |
| **Seçenek 1: [Yaklaşım A]** | Yalın, hızlı, sıfır yeni katman | İleride çoklu sağlayıcı gerektiğinde refactoring ister | **Önerilen (YAGNI)** |
| **Seçenek 2: [Yaklaşım B]** | Sağlayıcıdan bağımsız tam soyutlama | +4 yeni arayüz/adaptör, dolaylı test kurgusu | Alternatif |
```

Kullanıcının tercihini almak için `ask_question` aracını veya doğrudan soru yanıtını kullanın.

---

## 5. Kararın ADR Olarak Kaydedilmesi

Kullanıcı onayından sonra seçilen karar, elenen alternatifler ve elenme gerekçeleriyle birlikte Spec dokümanındaki `## Architectural Decisions (ADR)` bölümüne işlenir:

```markdown
## Architectural Decisions (ADR)

### ADR-01: [Karar Başlığı]
- **Durum:** Onaylandı
- **Bağlam:** [Çözülmek istenen mimari problem]
- **Karar:** [Seçilen yaklaşım]
- **Elenen Alternatifler:** [Elenen seçenekler ve elenme nedenleri]
- **Sonuçlar:** [Kabul edilen ödünler ve kurallar]
```
