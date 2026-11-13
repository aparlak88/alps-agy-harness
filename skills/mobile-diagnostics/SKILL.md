---
name: mobile-diagnostics
description: "iOS Simulator ve Android Emulator çalışma zamanı loglarını ve kilitlenmelerini (crash/.ips/ANR) inceler; oturum kilitlenmelerini önleyen mobile-logs.sh süzgecini ve XcodeBuildMCP/Android CLI araçlarını yönetir."
---

# Mobile Diagnostics: Mobil Simülatör ve Emülatör Teşhisi

Bu skill, iOS Simulator ve Android Emulator ortamlarında çalışan mobil uygulamaların çalışma zamanı loglarını, beklenmeyen çökmelerini (*crashes*), yanıt vermeyen uygulama durumlarını (*ANR*) ve ekran görüntülerini süzerek incelemek için kullanılır.

`pre-command-guard.sh` kancası, ajanın terminalde süresiz `adb logcat` veya süresiz `xcrun simctl ... log stream` çalıştırmasını oturum kilitlenmesini ve context taşmasını önlemek amacıyla fiziksel olarak engeller.

---

## 1. `scripts/mobile-logs.sh` Kullanımı

Tüm mobil log okuma ve teşhis işlemleri `scripts/mobile-logs.sh` sarmalayıcısı üzerinden yürütülmelidir:

### iOS Simulator Teşhisi
```bash
# Son 2 dakikalık uygulama loglarını ve en güncel .ips çökme raporunu çek
./scripts/mobile-logs.sh --platform ios --bundle-id com.example.app --last 2m

# Ekran görüntüsü ile birlikte teşhis al
./scripts/mobile-logs.sh --platform ios --bundle-id com.example.app --screenshot .harness/logs/ios-screen.png
```
- `xcrun simctl spawn booted log show` komutunu `subsystem` ve `process` filtreleriyle çalıştırır; işletim sisteminin on binlerce satırlık gürültüsünü dışarıda bırakır.
- `~/Library/Logs/DiagnosticReports/` altındaki en güncel `.ips` / `.crash` dosyasından çöken thread'in stack trace'ini ayıklar.
- İstenirse `xcrun simctl io booted screenshot` ile ekran görüntüsü alır.

---

### Android Emulator Teşhisi
```bash
# Hedef paketin PID değerini bulup yalnızca o uygulamanın logcat ve crash dökümünü çek
./scripts/mobile-logs.sh --platform android --package com.example.app

# Ekran görüntüsü ile birlikte teşhis al
./scripts/mobile-logs.sh --platform android --package com.example.app --screenshot .harness/logs/android-screen.png
```
- `adb shell pidof <package>` ile çalışan uygulamanın PID'sini otomatik tespit eder.
- `adb logcat -d --pid=<PID>` ve `adb logcat -b crash -d` komutlarını çalıştırarak yalnızca hedef uygulamanın çıktılarını ve `FATAL EXCEPTION` / `ANR` yığın izlerini yakalar.
- İstenirse `adb exec-out screencap -p` ile ekran görüntüsü alır.

---

## 2. Günlük Kaydı ve Context Yönetimi

`mobile-logs.sh`:
1. Ham terminal ve sistem loglarını `.harness/logs/mobile-<platform>-last.log` dosyasına kaydeder.
2. Context penceresine en fazla **100 satırlık** filtrelenmiş hata, istisna ve stack trace özeti döndürür.
3. Çoklu veya hacimli log dosyalarında `jev_triage` çağrısı yaparak sıfır-context tarama yapın; ana modelin context penceresini kirletmeyin.

---

## 3. Tamamlayıcı Eklentiler ve MCP Sunucuları

- **`XcodeBuildMCP` (macOS / iOS):**
  - iOS projelerinde derleme, şema listeleme ve simülatör yönetimi için `npx -y xcodebuildmcp@latest mcp` MCP sunucusunu kullanın.
- **Android CLI Eklentisi (`antigravity-plugins-official/plugin/android-cli-plugin`):**
  - Gradle task'ları, emülatör başlatma ve APK yükleme akışlarında eklentinin sunduğu komutlardan faydalanın.
