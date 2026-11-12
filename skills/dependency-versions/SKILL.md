---
name: dependency-versions
description: "Paket ve bağımlılık sürümlerini kilit dosyalarından veya Context7 MCP üzerinden doğrular, güncel kararlı sürümleri Spec içine sabitler ve stamp-gate context7 ile paket kurulumuna izin verir."
---

# Dependency Versions & Context7 Protocol

Bu skill, modelin kendi eğitim verisinden hayali, eski veya var olmayan paket sürümleri ve API imzaları uydurmasını engellemek için paket yönetişimi uygular.

`pre-command-guard.sh` kancası, doğrulanmamış hiçbir 3. parti paketin (`npm install`, `pnpm add`, `dotnet add package`, `uv add` vb.) yüklenmesine izin vermez.

---

## 1. Üç Adımlı Doğrulama Protokolü

### Adım 1: Mevcut Sürüm Kilidi Tespiti (Brownfield Önceliği)
Projede mevcut bir paket veya altyapı varsa, modelin sürüm yükseltme önermesi veya daha yeni bir sürümün API'sini yazması **kesinlikle yasaktır**.

Önce çalışma alanındaki kilit dosyalarını tarayın:
- **Node / TypeScript:** `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `package.json`
- **.NET / C#:** `Directory.Packages.props`, `*.csproj`, `packages.lock.json`
- **iOS / Swift:** `Package.resolved`, `Package.swift`, `Podfile.lock`
- **Android / Kotlin:** `gradle/libs.versions.toml`, `build.gradle.kts`
- **Python:** `uv.lock`, `poetry.lock`, `pyproject.toml`

Eğer sürüm zaten projede tanımlıysa, mevcut ana ve alt sürüm **kesin olarak korunur**. `context7` MCP sunucusu bu sabitlenmiş sürümün dokümantasyonu için sorgulanır.

---

### Adım 2: Yeni Paket Doğrulaması (Greenfield ve Context7)
Eğer paket projede henüz bulunmuyorsa:
1. Resmi paket kayıt defteri üzerinden (`npm view <pkg> version`, `dotnet package search`, `search_web`) **güncel kararlı (latest stable)** sürümü öğrenin.
2. `context7` MCP araçlarını çağırarak ilgili sürümün resmi dokümantasyonunu okuyun:
   - `resolve-library-id`: Kütüphanenin Context7 kimliğini çözer.
   - `query-docs`: Sürüme özel API imzalarını, breaking change'leri ve doğru kullanım örneklerini çeker.

---

### Adım 3: Sabitleme ve Damgalama
Doğrulanan sürüm iki noktaya kaydedilir:

1. **Spec Dokümanı (`Global Constraints`):**
   ```markdown
   ## Global Constraints
   - **Packages:**
     - `zod`: 3.23.8 (TypeScript runtime validation)
   ```
2. **Harness Damgası (`stamp-gate.sh context7`):**
   Paket kurulum komutunu (`npm install` vb.) çalıştırmadan önce terminalde damgayı oluşturun:
   ```bash
   ./scripts/stamp-gate.sh context7 \
     --package "<paket-adı>" \
     --version "<sürüm-numarası>" \
     --source "locked|greenfield-latest"
   ```

Bu komut `.harness/state/<branch>/context7-verified.json` dosyasını günceller. `pre-command-guard.sh` bu damgayı gördüğünde paket kurulum komutuna izin verir (`decision: allow`).
