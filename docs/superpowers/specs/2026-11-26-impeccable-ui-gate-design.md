# `alps-agy-harness` — Opsiyonel Koşullu Sert UI Kapısı (`Impeccable`) Tasarım Dokümanı

**Tarih:** 2026-11-26  
**Hedef Platform:** Google Antigravity (`agy` CLI, Antigravity IDE, Antigravity 2.0)  
**Kapsam:** `pbakaus/impeccable` (`>= 4.11.0`) tasarım/anti-pattern modülünün UI/Frontend projelerinde algılandığında deterministik sert kapı uygulayacak şekilde `alps-agy-harness` içine entegre edilmesi  
**İlgili Temel Tasarım:** [2026-11-12-alps-agy-harness-design.md](2026-11-12-alps-agy-harness-design.md)

---

## 1. Intent & Problem Bağlamı

`alps-agy-harness`, çok platformlu Clean Architecture katman sınırlarını, sürüm kilidini (`context7`), olasılıksal kalibrasyonu (`jev`), sıfır konsol/ağ hatasını (`playwright-e2e`) ve derin PR denetimini fiziksel kancalarla güvence altına alır. Ancak mevcut yapıda kullanıcı arayüzü (Web ve Native UI) katmanının görsel hiyerarşisi, tipografi/boşluk kalitesi ve yapay zeka şablonlarına özgü tekrarlayan estetik kusurlar (*AI slop*: aşırı kullanılan jenerik fontlar, mor-mavi gradyanlar, iç içe kartlar, düşük kontrast, erişilebilirlik ihlalleri) için deterministik bir kapı bulunmamaktadır.

Öte yandan `pbakaus/impeccable`:
1. Antigravity yerel skill çıktılarına (`.agent/skills/impeccable`, `~/.gemini/config/skills/impeccable`, `~/.agents/skills/impeccable`) ve 24 hedefli tasarım komutuna sahiptir.
2. Web arayüzleri için LLM/API anahtarı gerektirmeyen 62 deterministik kuralı çalıştıran `impeccable detect --json` ikilisi sunar (`exit 0` temiz, `exit 2` bulgu var, `exit 1` tarama hatası).
3. `PRODUCT.md` içindeki platform bilgisine göre SwiftUI (Apple HIG) ve Jetpack Compose (Material 3) için native kaynak denetimi (`audit`/`critique`) uygular.

Ancak Impeccable doğrudan kurulduğunda Antigravity'de yerel bir tasarım kancası çalıştırmaz, `.impeccable/` ve `PRODUCT.md`/`DESIGN.md` yazımları `main` dalı kilidine takılabilir ve `/impeccable live` kopya uygulama akışı güvenli ortam değişkeni (`IMPECCABLE_LIVE_COPY_AGENT`) verilmezse sarmalanmamış CLI çağrıları başlatabilir. Bu tasarım, Impeccable'ı saf backend projelerini etkilemeden yalnızca UI/Frontend projelerinde devreye giren ve algılandığında sert PR/merge kapısı uygulayan bir modül olarak sarmalar.

---

## 2. Goals, Non-Goals & Anti-Goals

### 2.1. Hedefler (Goals)
1. **Çift Koşullu Akıllı Aktivasyon:** Saf backend/CLI projelerinde sıfır sürtünme ve sıfır ek damga şartı; UI/Frontend değişikliği + Impeccable kurulumu birlikte algılandığında ise fiziksel olarak atlanamayan `ui-pass.json` (`codeTreeSha` kilitli) sert PR ve yerel `merge` kapısı.
2. **Sıfır Düzenleme Gecikmesi:** `write_file`/`edit_file` senkron kancalarını yavaşlatmadan PR hazırlığı (`pre-pr-readiness` + `stamp-gate.sh ui`) aşamasında deterministik `impeccable detect --json` doğrulaması ve Native UI için `P0=0, P1=0` denetim damgası.
3. **Proaktif Ortam Farkındalığı:** `harness-doctor.sh` ve `session-start.sh` üzerinden çalışma alanının UI durumuna göre `active` (`OK`), `advisory` (`WARN` + `npx impeccable install --scope=global`) veya `dormant` (`INFO`) bilgisini sunmak.
4. **Çalışma Alanı ve Güvenlik İzolasyonu:** `.impeccable/` önbellek/rapor dizinini özel anahtar taramasından ödün vermeden `main` kilidi ve sözlük kuralından muaf tutmak; `PRODUCT.md`/`DESIGN.md` taslaklarına `main` üzerinde izin vermek; `DO_NOT_TRACK=1` ve `IMPECCABLE_LIVE_COPY_AGENT=chat|off` ile telemetri ve sarmalanmamış `live` ajan tetiklemesini fiziksel olarak engellemek.
5. **Araç Rollerinin Ayrıştırılması:** `impeccable` (görsel tasarım, UX eleştirisi, statik slop tespiti) ile `playwright-e2e` / `chrome-devtools-plugin` (konsol/5xx sıfır hata, fonksiyonel E2E, LCP/ağ) görevlerini net biçimde ayırmak.

### 2.2. Kapsam Dışı (Non-Goals)
- Impeccable paketinin kaynak dosyalarını veya ikili motorunu `alps-agy-harness` reposuna kopyalamak (`vendor` etmek).
- Impeccable kurulu değilken UI projelerinin PR açmasını engellemek (yalnızca `WARN`/`[UI ADVISORY]` üretilir).
- `plugin.json` sürümünü (`1.1.0`) veya `hooks.json` matcher dizisini değiştirmek.
- `alps-agy-harness` çekirdek paket dosya sayısını (`53`) artırmak.

### 2.3. Anti-Hedefler (Anti-Goals)
- Backend-only (`Domain`, API, test) değişikliklerinde `ui-pass.json` damgası isteyerek geliştiriciyi bloklamak.
- `impeccable detect` exit kodu `2` (bulgu var) döndüğünde sessizce `PASS` damgası yazmak veya eksik/çalışmayan detector ikilisini fail-open geçmek.
- `HARNESS_CONFIG_DIR` izole edilmiş test ortamlarında ana makinenin `~/.agents/skills/impeccable` veya `PATH` üzerindeki gerçek kurulumunu sızdırmak.

---

## 3. Global Constraints

- **Çalışma Zamanı Kilidi:** Yalnızca Python `>= 3.9` standart kütüphanesi (`stdlib`), POSIX `bash`, `jq`, `git`, `curl` kullanılır. Harici `impeccable >= 4.11.0` yalnızca çalışma ortamında algılandığında isteğe bağlı eşlikçi (*companion*) olarak çalıştırılır.
- **Paket Bütünlüğü:** Çekirdek eklenti dosya sayısı tam olarak `53` kalır; `rules/AGENTS.md` `< 8192` bayt ve frontmatter'sızdır; platform kurallarının `globs:` satırları ve alt ajan frontmatter şemaları değiştirilmez.
- **İki Dilli Standart:** Kod, docstring'ler, kanca ve CLI hata iletileri İngilizce; Markdown tasarım/plan/walkthrough dokümanları Türkçe ve sonunda boş olmayan `## Teknik Terimler Sözlüğü` tablosu içerir.

---

## 4. Architectural Decisions (ADR)

### ADR-01: Çift Koşullu Akıllı Aktivasyon
- **Durum:** Onaylandı (`jev_classify = full_project` [1.0], `jev_check = 0.86` [`yes`]).
- **Bağlam:** Harness hem saf backend/.NET/Go hem de Angular/React/SwiftUI/Compose projelerinde kullanılmaktadır.
- **Karar:** Sert UI kapısı yalnızca **(1) dal farkında (`ACMR`) en az bir üretim Web veya Native UI dosyası değişmişse VE (2) Impeccable skill/ikilisi algılanmışsa** zorunlu olur (veya dal state dizininde mevcut bir `ui-pass.json` varsa geçerliliği doğrulanır). UI projesi olup Impeccable kurulu değilse yalnızca `doctor` (`WARN`) ve `SessionStart` (`[UI ADVISORY]`) uyarısı verilir; `healthy` `true` kalır.
- **Elenen Alternatifler:** (1) *Sıkı UI Kapısı* (Impeccable kurulu olmayan ekiplerde PR blokladığı için opsiyonellik ilkesiyle çelişti); (2) *Salt Proje Opt-in* (global kurulu `impeccable` kullanıcısının unutulan repolarda sessizce korumasız kalmasına yol açtığı için elendi).

### ADR-02: `stamp-gate.sh ui` + `codeTreeSha` Kilitli PR/Merge Sert Kapısı (`ui-pass.json`)
- **Durum:** Onaylandı.
- **Karar:** Senkron `pre-edit-guard.sh` (~30ms bütçe) içine dış tarayıcı/detector süreci koymak yerine `stamp-gate.sh ui --verdict PASS|FAIL --p0 <n> --p1 <n> [--target ...]` komutu tanımlanır. `PASS` verilebilmesi için `p0 == 0` ve `p1 == 0` olmalı, ayrıca değişen Web UI dosyaları mevcutsa `impeccable detect --json` `exit 0` dönmelidir (`exit 2` bulgu durumunda damga reddedilir). `ui-pass.json` mevcut `codeTreeSha` mekanizmasına bağlanır; `verify-pr-stamps`, `gh pr create` ve yerel `git merge` kapıları bu damgayı doğrular.
- **Elenen Alternatifler:** Her `write_file`/`edit_file` kancasında `impeccable detect` çalıştırmak (edit döngüsünü yavaşlattığı için elendi); yalnızca kural dokümantasyonuyla yetinmek (fiziksel kapı güvencesi vermediği için elendi).

### ADR-03: `.impeccable/` İzolasyonu, `PRODUCT.md`/`DESIGN.md` Taslak İzni ve `live` Modu Sandbox Koruması
- **Durum:** Onaylandı.
- **Karar:** `evaluate_pre_edit`, `.impeccable/` altındaki geçici çalışma dosyalarına tüm dallarda izin verir (ancak `PRIVATE_KEY_RE` gizli anahtar taramasını korur) ve kök dizindeki `PRODUCT.md` / `DESIGN.md` tasarım dosyalarının `main` üzerinde taslaklanmasına izin verir. `evaluate_pre_command` ise `impeccable live` komutlarını `IMPECCABLE_LIVE_COPY_AGENT=chat` veya `off` ortam değişkeni ayarlı değilse `deny` ile engeller. Detector çağrıları her zaman `DO_NOT_TRACK=1`, `IMPECCABLE_LIVE_COPY_AGENT=off`, `IMPECCABLE_TELEMETRY_CHANNEL=disabled` ile çalıştırılır.

---

## 5. Bileşen Tasarımı ve Veri Şemaları

### `.harness/state/<slug>/ui-pass.json`
```json
{
  "verdict": "PASS",
  "codeTreeSha": "<40-char git tree sha>",
  "p0Count": 0,
  "p1Count": 0,
  "detectorFindings": 0,
  "scannedWebFiles": ["src/app/hero.component.html"],
  "auditedNativeFiles": ["Sources/Features/PaywallView.swift"],
  "timestamp": "2026-11-26T12:00:00Z"
}
```

### `tree-state.json` Ek Alanları
`uiStampStatus` (`fresh|stale|fail|missing`), `uiStampValid` (`bool`), `uiStampSha` (`str`).

---

## Teknik Terimler Sözlüğü

| Terim | Açıklama |
| :--- | :--- |
| **ADR (Architectural Decision Record)** | Bir mimari kararın bağlamını, seçilen çözümü, elenen alternatifleri ve sonuçlarını kaydeden yapılandırılmış karar kaydı. |
| **AI Slop** | Yapay zeka modellerinin tasarım yönlendirmesi olmadan ürettiği tekrarlayan, düşük kontrastlı ve şablonvari arayüz kusurları bütünü. |
| **codeTreeSha** | `docs/walkthroughs/` ve `docs/parking-lot.md` hariç tutularak hesaplanan, denetim damgalarının bayatlamasını yakalayan deterministik Git ağaç özeti. |
| **Dual-Condition Activation** | Sert kapının yalnızca hem dal farkında UI dosyası değiştiğinde hem de Impeccable kurulu olduğunda devreye girmesi kuralı. |
| **Impeccable (`impeccable.style`)** | Ajanlar için tasarım sözlüğü, Native/Web UX denetimi ve 62 kurallı deterministik `detect` tarayıcısı sunan açık kaynak tasarım skill paketi. |
| **P0 / P1 Findings** | Impeccable `critique` ve `audit` çıktılarında sırasıyla engelleyici (kritik) ve yüksek öncelikli arayüz/erişilebilirlik bulgu seviyeleri. |
| **ui-pass.json** | `stamp-gate.sh ui` tarafından üretilen ve `gh pr create` ile yerel `git merge` kapılarında doğrulanan `codeTreeSha` kilitli UI kalite damgası. |
