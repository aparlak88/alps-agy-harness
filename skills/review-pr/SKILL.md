---
name: review-pr
description: "Açık bir PR için çok boyutlu pr-auditor denetimini orkestre eder: 2 cümlelik niyet çapası çıkarır, jev_triage ve spekülatif yorum süzgeciyle 7 boyutta kod incelemesi yapar ve PR denetim bayrağını temizler."
---

# Review PR: PR İnceleme ve pr-auditor Orkestrasyonu

Bu skill, yeni bir PR açıldığında (`stop-gate.sh` kancası tarafından otomatik olarak talep edildiğinde) veya mevcut bir GitHub PR'ını denetlemek için kullanıcı tarafından çağrıldığında devreye girer.

`pr-auditor` alt ajanını ana oturum modeline duyarlı en yüksek katmanda (Carbon / `Orchestrator` / `Argon High` / Claude oturumlarında `inherit`, Hydrogen / `3.8 Flash` oturumlarında `pro` [Gemini 4 Argon] ve `HIGH`/`XHIGH`/`MAX` efor) yönetir; spekülatif soyutlama gürültüsünü filtreleyerek somut mimari bulguları raporlar.

---

## 1. Ne Zaman Çalıştırılır?

1. **`gh pr create` Sonrası (Otomatik Durdurma Engeli):**
   - PR oluşturulduğunda `post-command-hooks.sh` kancası `.harness/state/<branch>/pr-audit-pending.json` dosyasını yazar.
   - Oturumu kapatmak istediğinizde `stop-gate.sh` durmayı engelleyerek bu skill'in çalıştırılmasını zorunlu tutar.
2. **Mevcut PR Denetimi:**
   - Ekip arkadaşınızın veya açık bir PR'ın (`gh pr checkout <num>`) derin mimari incelemesi istendiğinde.

---

## 2. İnceleme Süreci ve `pr-auditor` Yürütme

### Adım 1: Alt Ajan Kaydı (Subagent Dispatch)
Önce `stamp-gate.sh dispatch` ile `pr-auditor` için kayıt oluşturun:
```bash
./scripts/stamp-gate.sh dispatch \
  --role "PR Auditor" \
  --type "pr-auditor" \
  --tier "critical_architecture_or_audit"
```

### Adım 2: `invoke_subagent` ile pr-auditor Çağrısı
`TypeName: "pr-auditor"`, `Role: "PR Auditor"` argümanlarıyla alt ajanı çağırın. `pre-subagent-guard.sh` ana oturum modeline (`HOOK_INPUT.modelName`) göre modeli `inherit` (Carbon / `Orchestrator` / `Argon High` / Claude) veya `pro` (Gemini 4 Argon) olarak kilitler ve prompt başlığını `EFFORT_PROFILE: MAX` (veya `XHIGH` / `HIGH`) ile yeniden yazar.

---

## 3. `pr-auditor` Tarafından Yürütülen 7 Boyutlu Denetim

Alt ajan aşağıdaki adımları sırayla icra eder:

1. **Niyet Çapası (Intent Backtranslation):**
   - Kod bulgularına geçmeden önce yalnızca `git diff` inceleyerek **"Bu değişiklik gerçekte hangi kullanıcı amacını çözüyor?"** sorusunu 2 cümleyle yanıtlar ve Spec'in `Intent` ve `Non-Goals` bölümleriyle karşılaştırır.
2. **`jev_triage` ile Ön-Eleme:**
   - Diff içindeki dosyaları sunucu tarafında tarayarak şüpheli katman ihlallerini ve gizli riskleri saptar.
3. **7 Boyutta İnceleme:**
   1. Kod Dokümantasyonu ve Papağan/Bayat Yorum Analizi (İngilizce standart).
   2. Test Kapsamı ve Eksik Kenar Durumlar.
   3. Tip Tasarımı ve Arayüz Kontratları.
   4. Hata Yönetimi ve Sessiz Hata (Silent Failure) Analizi.
   5. **DDD & Clean Architecture Sınır Denetimi (Bloklayıcı).**
   6. **Fazlalık, Kapsam Kayması ve Overengineering Cezası (Bloklayıcı).**
   7. Okunabilirlik, Basitleştirme ve Glossary Uyumu.
4. **`jev_check` ile Spekülatif Yorum Süzgeci:**
   - Somut bir hata veya katman ihlali kanıtlamayan *"gelecekte genişletilebilirlik için soyutla"* şeklindeki önerileri (`yes_at_or_above < 0.70`) bloklayıcı listeden düşürür.
5. **`jev_score` Ciddiyet Derecelendirmesi:**
   - Bulguları `[Minor, Important, Critical]` olarak sınıflandırır.

---

## 4. Denetim Bayrağının Temizlenmesi (`clear-pr-audit`)

- Eğer `Critical` veya `Important` bulgular varsa: Kod üzerinde gerekli düzeltmeleri yapın, testleri çalıştırın ve yeni commit atın.
- İnceleme tamamlandığında veya bulgular çözüldüğünde:
  ```bash
  ./scripts/stamp-gate.sh clear-pr-audit
  ```
Bu komut `pr-audit-pending.json` dosyasını siler; böylece `stop-gate.sh` oturumun temiz biçimde sonlandırılmasına izin verir (`{}`).
