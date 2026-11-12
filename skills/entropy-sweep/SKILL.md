---
name: entropy-sweep
description: "İsteğe bağlı kod tabanı hijyen ve entropi süpürmesi: docs/parking-lot.md maddelerini, ölü kodları ve kanon sapmalarını jev_score ile puanlar; onaylanan maddeler için en fazla 5 dosyalık mikro-PR yürütür."
---

# Entropy Sweep: Kod Tabanı Hijyen ve Entropi Temizliği

Bu skill, kod tabanında zamanla biriken küçük pürüzleri, V2 otoparkında (`docs/parking-lot.md`) biriken teknik borçları ve kanon sapmalarını kontrollü biçimde temizlemek için tasarlanmıştır.

> [!IMPORTANT]
> **Yalnızca Açık İstekle Çalışır:**
> Bu skill özellik geliştirme veya hata ayıklama oturumlarında **asla kendiliğinden tetiklenmez**. Yalnızca kullanıcı açıkça hijyen/temizlik istediğinde veya `plugin.json` içindeki önerilen komutlardan çalıştırıldığında devreye girer.

---

## 1. Toplanan Entropi Kaynakları

1. **V2 Otopark Notları (`docs/parking-lot.md`):**
   - Önceki geliştirme turlarında kapsam dışı bırakılmış teknik borç veya refactoring notları.
2. **Ölü Kod ve Kullanılmayan Dışa Aktarımlar (Dead Exports):**
   - `graphify` veya LSP referans sorgusuyla (`csharp_references` vb.) referansı kalmamış sınıflar, metodlar veya arayüzler.
3. **Kanon Uyuşmazlıkları ve Bayat Yorumlar:**
   - `docs/canon/glossary.md` ile kod sembolleri arasındaki ufak sapmalar ve güncelliğini yitirmiş yorum satırları.
4. **Rule of Three & Karmaşıklık Sapmaları:**
   - Tek bir uygulaması olan ve gereksiz arayüz/fabrika katmanıyla sarılmış yapılar.

---

## 2. `jev_score` ile ROI Puanlaması

Aday maddeler toplanır ve `jev_score` motoruna gönderilerek puanlanır:

```json
{
  "statement": "Bu temizlik maddesinin mevcut mimari bütünlüğe katkısı ve uygulama riski ROI değerlendirmesi.",
  "scale": ["Low_Value", "High_ROI_Micro_Fix", "Needs_Full_Spec"],
  "text": "<Aday temizlik maddesi ve etkilenen dosyalar>"
}
```

- **`Low_Value`:** Değeri düşük, dokunmaya değmeyecek kozmetik maddeler elenir.
- **`Needs_Full_Spec`:** Geniş kapsamlı mimari değişiklik gerektiren maddeler mikro-temizliğe **alınmaz**; `superpowers:brainstorming` gerektiren normal özellik akışına bırakılır.
- **`High_ROI_Micro_Fix`:** Yüksek getirili, risksiz ve yalın temizlik adayları kullanıcı onayına sunulur.

---

## 3. Mikro-PR Yürütme Kuralı (Maksimum 5 Dosya)

Temizlik işlerinin özellik dallarını kirletmesini veya büyük regresyonlara yol açmasını önlemek için aşağıdaki katı kurallar uygulanır:

1. **İzole Temizlik Dalı:**
   `git checkout -b chore/entropy-sweep-<konu>` ile yeni bir dal açılır.
2. **Katı Dosya Limiti:**
   Tek bir mikro-temizlik PR'ı **en fazla 5 dosyaya** dokunabilir. 5 dosyadan fazla değişiklik gerekiyorsa birden fazla bağımsız mikro-PR'a bölünür.
3. **TDD ve Doğrulama:**
   Silinen veya basitleştirilen her bileşenin ardından platform testleri `run-quiet.sh` ile koşturulur.
4. **Otoparkın Güncellenmesi:**
   Tamamlanan maddeler `docs/parking-lot.md` dosyasından silinir.
5. **Standart PR Kapıları:**
   Mikro-PR için öz bir Walkthrough hazırlanır (`walkthrough-template.md`), `canon` ve `security` damgaları alınarak PR açılır.
