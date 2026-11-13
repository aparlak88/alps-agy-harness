---
name: harness-doctor
description: "Geliştirme ortamı, sistem araçları, 8 zorunlu MCP sunucusu, TYPESAFE_API_KEY ve eklenti bağımlılıklarını tek komutla denetler; eksikliklerde sıfır gizli anahtar sızıntısıyla hazır onarım adımları sunar."
---

# Harness Doctor

Bu skill, geliştiricinin makinesindeki ortam hazırlığını, bağımlılıkları ve MCP sunucularını denetlemek ve eksiklikleri gidermek için rehberlik sağlar.

Oturum başlangıcında uyarı alındığında veya yeni bir projeye başlarken doğrudan çalıştırılır.

---

## 1. Çalıştırma Komutları

Geliştirici ortamını test etmek için çalışma alanı kökünde `harness-doctor.sh` betiğini yürütün:

```bash
# İnsan tarafından okunabilir renkli terminal çıktısı
./scripts/harness-doctor.sh

# Makine tarafından okunabilir JSON çıktısı
./scripts/harness-doctor.sh --json

# Belirli bir çalışma alanını hedeflemek için
./scripts/harness-doctor.sh --workspace /yol/proje
```

---

## 2. Denetlenen Kontrol Grupları

`harness-doctor` aşağıdaki 6 ana grupta toplam 20'den fazla parametreyi saniyeler içinde doğrular:

1. **Sistem İkilileri & CLI Araçları:**
   - `git`, `jq`, `node` (`>= 20`), `python3`, `uv` ve `gh` CLI.
   - `gh auth status`: GitHub kimlik doğrulamasının geçerliliği.
2. **Eklenti Bağımlılıkları:**
   - `superpowers` (`v7.0.0`+).
   - Zorunlu Marketplace eklentileri: `chrome-devtools-plugin`, `firebase`, `postman`, opsiyonel `android-cli-plugin`.
3. **8 Zorunlu Global MCP Sunucusu (`~/.gemini/config/mcp_config.json`):**
   - `jev`, `context7`, `csharp-lsp`, `typescript-lsp`, `playwright`, `graphify`, `revenuecat`, `filesystem`.
   - Opsiyonel: macOS ve iOS projeleri için `XcodeBuildMCP`.
4. **`jev` ve `TYPESAFE_API_KEY` Hazırlığı (Sıfır Gizlilik Sızıntısı):**
   - `TYPESAFE_API_KEY` ortam değişkeni veya `~/.config/typesafe/key` dosyasının mevcudiyeti.
   - Anahtar değerini **asla ekrana veya günlüklere basmaz**; yalnızca `[OK] present` veya `[FAIL] missing` raporlar.
5. **Platform LSP & Mobil Teşhis Araçları:**
   - `csharp-ls` ve `csharp-lsp-mcp` ikilileri.
   - `graphify` erişilebilirliği.
   - Projede iOS (`.swift`, `Package.swift`) veya Android (`.kt`, `build.gradle.kts`) dosyaları varsa `xcrun simctl` ve `adb` hazırlığı.
6. **Aktif Çalışma Alanı Sağlığı:**
   - Kurulum modu (Global veya Proje Bazlı).
   - `.gitignore` veya `.git/info/exclude` içinde `.harness/` kaydı.
   - `docs/canon/{glossary,flows,lessons}.md` ve `graphify-out/graph.json` mevcudiyeti.

---

## 3. Onarım ve Problem Giderme Rehberi

`harness-doctor` çıktısında `[FAIL]` veya `[WARN]` ile işaretlenen her satırın altında hazır kopyala-yapıştır düzeltme komutu (`Fix: ...`) yer alır.

### Sık Karşılaşılan Eksiklikler ve Çözümleri

- **Eksik `TYPESAFE_API_KEY`:**
  ```bash
  mkdir -p ~/.config/typesafe
  echo "<YOUR_TYPESAFE_API_KEY>" > ~/.config/typesafe/key
  chmod 600 ~/.config/typesafe/key
  ```
- **Eksik C# LSP Araçları:**
  ```bash
  dotnet tool install -g csharp-ls
  dotnet tool install -g csharplspmcp
  ```
- **Eksik Graphify:**
  ```bash
  uv tool install graphifyy
  ```
- **Eksik Chrome DevTools Eklentisi:**
  ```bash
  agy plugin install antigravity-plugins-official/plugin/chrome-devtools-plugin
  ```

Tüm düzeltmeleri uyguladıktan sonra `./scripts/harness-doctor.sh` komutunu yeniden çalıştırarak çıkış kodunun `0` olduğunu doğrulayın.
