---
name: domain-canon
description: "Üç parçalı yaşayan alan kanonunu (docs/canon/{glossary,flows,lessons}.md) şablonlarla yönetir, Ubiquitous Language sözleşmesini korur, graphify senkronizasyonunu sağlar ve canon-auditor denetimine hazırlar."
---

# Domain Canon: Yaşayan Alan Kanonu Yönetimi

Bu skill, projede iş alanının kurallarını, ortak dilini ve geçmiş mühendislik hafızasını tek bir yaşayan kanonda birleştiren üç parçalı yapıyı yönetir.

Proje kökünde `docs/canon/` altında yaşayan bu kaynaklar, `canon-auditor` alt ajanı ve mimari denetimler için bağlayıcı zemin oluşturur.

---

## 1. Üç Parçalı Alan Kanonu Bileşenleri

### 1. `docs/canon/glossary.md` (Ubiquitous Language)
- **Amaç:** İş birimi, ürün yöneticileri, tasarım dokümanları ve kaynak kod arasındaki kavram karmaşasını sıfırlamak.
- **Şablon:** `skills/domain-canon/templates/glossary-template.md` dosyasını temel alır.
- **Sözleşme:** Tabloda tanımlanan kanonik İngilizce tip ve alan adları (`Canonical Identifier`), kod tabanında, API şemalarında ve dokümanlarda zorunludur. Yasaklı eş anlamlıların (*Forbidden Aliases*) kullanılması bloklayıcı hatadır.

---

### 2. `docs/canon/flows.md` (Kanonik İş Akışları)
- **Amaç:** Kritik uçtan uca iş süreçlerinin değişmez adımlarını, aktörlerini ve hata telafi mantığını belgelemek.
- **Şablon:** `skills/domain-canon/templates/flows-template.md` dosyasını temel alır.
- **Sözleşme:** Her akış bir `Akış Kimliği` (`FLW-xxx`), tetikleyici, sıralı zorunlu adımlar, `sequenceDiagram` veya `stateDiagram-v2` ve `Değişmez Kurallar (Invariants)` taşır. Yeni özellikler bu adımların sırasını kullanıcıdan açık kanon revizyon onayı almadan değiştiremez.

---

### 3. `docs/canon/lessons.md` (Bileşik Öğrenilmiş Dersler Hafızası)
- **Amaç:** Çözülen zor kök nedenlerin, platform tuzaklarının ve gizli hataların tekrar yaşanmasını engellemek.
- **Şablon:** `skills/domain-canon/templates/lessons-template.md` dosyasını temel alır.
- **Sözleşme:** Yalnızca sinsi ve tekrarlanabilir kök nedenler kaydedilir. Planlama ve hata ayıklama aşamasında `jev_triage` ile sıfır-context taranarak ilgili dersler göreve otomatik enjekte edilir.

---

## 2. Kanon İlklendirme ve Şablon Kopyalama

Eğer hedef projede `docs/canon/` henüz mevcut değilse:
1. `mkdir -p docs/canon` komutuyla dizini oluşturun.
2. İlgili şablonları (`templates/*.md`) kopyalayarak mevcut kod tabanındaki sembollere göre ilklendirin:
   ```bash
   cp skills/domain-canon/templates/glossary-template.md docs/canon/glossary.md
   cp skills/domain-canon/templates/flows-template.md docs/canon/flows.md
   cp skills/domain-canon/templates/lessons-template.md docs/canon/lessons.md
   ```
3. Dokümanların `flows.md` ve `lessons.md` dosyalarının sonundaki `## Teknik Terimler Sözlüğü` bölümünü koruyun.

---

## 3. Graphify ve Kod Tabanı Senkronizasyonu

Kanon üzerinde yeni bir kavram veya akış tanımlandığında, `graphify` aracılığıyla kod tabanıyla olan bağlantıları çapraz doğrulayın:
- `query_graph` ile kavramın mevcut sınıflarla ilişkisini sorgulayın.
- PR birleştirildiğinde `post-command-hooks.sh` otomatik olarak `graphify` artımlı güncellemesini tetikler.

---

## 4. `canon-auditor` Denetimine Hazırlık

Kanon güncellendikten veya kod yazımı tamamlandıktan sonra:
1. Planlanan `allowedFiles` listesini kontrol edin.
2. `stamp-gate.sh canon` ile kanon denetim damgasını alın.
