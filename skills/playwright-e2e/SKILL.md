---
name: playwright-e2e
description: "Web arayüz E2E ve çalışma zamanı hata denetimi: @playwright/mcp araçlarıyla konsol/ağ analizi yapar, Chrome DevTools derin teşhisini uygular ve sıfır-konsol-hatası Playwright temel test fixture'ı sağlar."
---

# Playwright E2E & Zero-Console-Error Quality Gate

Bu skill, Web ve Angular uygulamalarında görsel olarak çizilse bile arka planda gizlenen çalışma zamanı JavaScript hatalarını, başarısız API çağrılarını ve performans darboğazlarını yakalamak için 3 katmanlı E2E kalite kalkanı sağlar.

---

## 1. `@playwright/mcp` ile Anlık Konsol ve Ağ Okuma

E2E testleri yazılırken veya canlı web sayfası incelenirken `@playwright/mcp` araçları kullanılır:
- **`browser_navigate`:** Hedef sayfayı tarayıcıda açar.
- **`browser_snapshot`:** Sayfanın erişilebilirlik ağacını (*accessibility snapshot*) okur; kırılgan CSS seçiciler yerine rol ve etiket tabanlı (`getByRole`, `getByLabel`) Page Object Model üretilmesini sağlar.
- **`browser_console_messages`:** Sayfada tetiklenen tüm `error` ve `warning` seviyesindeki konsol mesajlarını okur.
- **`browser_network_requests`:** `4xx`, `5xx` veya CORS hataları alan tüm ağ isteklerini listeler.

---

## 2. `Chrome DevTools` Eklentisi ile Derin Teşhis

Ağ veya çalışma zamanı hatası saptandığında `antigravity-plugins-official/plugin/chrome-devtools-plugin` eklentisi devreye girer:
1. **Request / Response Gövdesi İncelemesi:** Başarısız API çağrısının yükünü (*payload*) ve sunucu yanıtını inceler.
2. **Network Waterfall & Performans:** İstek zincirindeki gecikmeleri ve kaynak yükleme sıralamasını denetler.
3. **Dev-Server Eşleştirmesi:** `5xx` sunucu hatalarında arka planda çalışan geliştirme sunucusu görev logundaki (`ng serve` / `dotnet run` logları, `manage_task` veya `.harness/logs/`) stack trace ile istemci hatasını eşleştirir.

---

## 3. Yeniden Kullanılabilir "Sıfır Konsol Hatası" Playwright Fixture'ı

Projedeki `@playwright/test` testlerinde sayfa açıldığında gizli JS istisnalarını (`page.on('pageerror')`) veya sunucu hatalarını yakalamak için aşağıdaki temel fixture kullanılır. Test patladığında doğrudan **İngilizce `REMEDIATION:`** yönergesi döndürür:

```typescript
import { test as base, expect } from '@playwright/test';

export const test = base.extend({
  page: async ({ page }, use) => {
    const uncaughtErrors: Error[] = [];
    const consoleErrors: string[] = [];
    const failedRequests: { url: string; status: number }[] = [];

    // 1. Yakalanmamış sayfa istisnaları (Uncaught Exceptions)
    page.on('pageerror', (exception) => {
      uncaughtErrors.push(exception);
    });

    // 2. Konsola düşen hata seviyesindeki mesajlar (console.error)
    page.on('console', (msg) => {
      if (msg.type() === 'error') {
        const text = msg.text();
        // Zararsız 3. parti analitik hatalarını yoksay
        if (!text.includes('analytics-vendor.com')) {
          consoleErrors.push(text);
        }
      }
    });

    // 3. Beklenmeyen 5xx sunucu hataları ve kritik 4xx yanıtları
    page.on('response', (response) => {
      const status = response.status();
      const url = response.url();
      if (status >= 500) {
        failedRequests.push({ url, status });
      }
    });

    // Testi yürüt
    await use(page);

    // Test sonu doğrulamaları
    if (uncaughtErrors.length > 0) {
      throw new Error(
        `REMEDIATION: Uncaught JavaScript exceptions detected during page execution. Inspect Angular/React component lifecycle and fix null reference errors.\n` +
        uncaughtErrors.map(e => `  - ${e.message}\n${e.stack}`).join('\n')
      );
    }

    if (consoleErrors.length > 0) {
      throw new Error(
        `REMEDIATION: Unexpected console.error messages logged during test run. Resolve runtime errors or explicitly allowlist harmless third-party messages.\n` +
        consoleErrors.map(m => `  - ${m}`).join('\n')
      );
    }

    if (failedRequests.length > 0) {
      throw new Error(
        `REMEDIATION: Backend HTTP 5xx responses received. Check backend dev server logs via manage_task or inspect database connection.\n` +
        failedRequests.map(r => `  - [${r.status}] ${r.url}`).join('\n')
      );
    }
  }
});

export { expect };
```

---

## 4. Testleri `run-quiet.sh` ile Yürütme

Playwright testlerinizi daima sessiz derleme sarmalayıcısıyla çalıştırın:
```bash
./scripts/run-quiet.sh e2e-web -- npx playwright test
```
Testler başarılı olduğunda tek satır özet döner; hata oluştuğunda başarısız adımın stack trace'i ve `REMEDIATION:` mesajı terminale basılır.
