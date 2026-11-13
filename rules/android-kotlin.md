---
trigger: glob
description: Android (Kotlin/Jetpack Compose) multi-module Gradle Clean Architecture, Konsist/JUnit REMEDIATION fitness tests, mobile-logs.sh diagnostics, and English KDoc
globs: **/*.kt, **/*.kts, **/libs.versions.toml
---

# Android (Kotlin / Jetpack Compose) Clean Architecture & Engineering Contract

Apply these rules whenever inspecting, authoring, or reviewing Kotlin source files, Gradle Kotlin DSL scripts (`.kts`), or version catalogs (`libs.versions.toml`).

## 1. Multi-Module Gradle & Clean Architecture Boundaries

Enforce Google App Architecture + DDD across isolated Gradle modules with strict inward dependency direction: `:app` -> (`:features:*`, `:data`) -> `:domain`.

- **`:domain` Module (Pure Kotlin JVM):**
  - Apply `kotlin("jvm")` (or pure Kotlin multiplatform common) — **NEVER `com.android.library`**. Zero `android.*`, `androidx.*`, Room, Retrofit, Hilt/Dagger runtime, Firebase, or RevenueCat imports.
  - Contains immutable Entities, `@JvmInline value class` / `data class` Value Objects, `operator fun invoke(...)` UseCases, sealed Domain Error/Result hierarchies, and outbound Repository `interface` contracts.
- **`:data` Module (Adapters, Persistence & SDKs):**
  - Implements `:domain` repository interfaces using Room DAOs/Entities, Retrofit/OkHttp services, DataStore/Keystore encrypted storage, Firebase, or RevenueCat SDKs, wired via Hilt `@Binds` modules.
  - Keep Room `@Entity` and network `@Serializable` DTOs private/internal to `:data` with explicit DTO/Entity -> `:domain` mapper functions.
- **`:features:*` Modules (UDF Presentation & Jetpack Compose):**
  - Depend on `:domain` and shared UI design modules — **MUST NOT depend on `:data` in `build.gradle.kts`**.
  - Enforce Unidirectional Data Flow (UDF): `@HiltViewModel` exposes immutable `StateFlow<UiState>`, Compose screens collect state via `collectAsStateWithLifecycle()`, and stateless `@Composable` functions accept state + event lambdas (`UiEvent -> Unit`) without touching ViewModels or repositories directly.
- **`:app` Module (Composition Root):**
  - Assembles Hilt dependency graph, navigation host, and build variants. Manage all dependency versions centrally in `gradle/libs.versions.toml` (verified via `dependency-versions` + `context7` + `stamp-gate.sh context7`).

## 2. Architectural Fitness Tests (`Konsist` / JUnit `REMEDIATION:` Injection)

Enforce layer rules at both Gradle module level (`:domain` pure `kotlin("jvm")`; `:features:*` never declaring `implementation(project(":data"))`) and unit-test level via `Konsist` (or JUnit source assertions) emitting an actionable **English `REMEDIATION:`** failure message:

```kotlin
import com.lemonappdev.konsist.api.Konsist
import com.lemonappdev.konsist.api.verify.assertFalse
import org.junit.jupiter.api.Test

class ArchitectureFitnessTest {
    @Test
    fun `domain module must not import android, persistence, networking, or data packages`() {
        Konsist.scopeFromModule("domain")
            .files
            .assertFalse(
                additionalMessage = "REMEDIATION: :domain must remain pure Kotlin (kotlin(\"jvm\")) with zero android.*, androidx.*, Room, Retrofit, Firebase, RevenueCat, or :data imports. Define repository interfaces in :domain and move framework/SDK adapters into :data."
            ) { file ->
                file.imports.any { imp ->
                    imp.name.startsWith("android.") ||
                        imp.name.startsWith("androidx.") ||
                        imp.name.startsWith("retrofit2.") ||
                        imp.name.contains(".data.") ||
                        imp.name.startsWith("com.revenuecat.")
                }
            }
    }

    @Test
    fun `feature modules must not import concrete data layer implementations`() {
        Konsist.scopeFromDirectory("features")
            .files
            .assertFalse(
                additionalMessage = "REMEDIATION: :features:* modules must not reference :data classes directly. Inject :domain UseCases or Repository interfaces via Hilt @Binds in :data/:app."
            ) { file ->
                file.imports.any { it.name.contains(".data.") }
            }
    }
}
```

## 3. Emulator Diagnostics (`mobile-logs.sh`), `Android CLI` & Quiet Build Workflow

- **Never Run Unbounded `adb logcat`:** `pre-command-guard.sh` denies raw `adb logcat` without `-d` to prevent terminal hangs and system-wide logcat noise.
- **PID-Scoped Crash & ANR Diagnostics:** Always inspect app runtime logs, `AndroidRuntime` `FATAL EXCEPTION` crashes, ANR traces, and emulator screenshots via:
  - `./scripts/mobile-logs.sh --platform android --package <application.id>`
  - Use the `Android CLI` plugin when installed for SDK/AVD tooling guidance, and wrap all Gradle verification tasks in `./scripts/run-quiet.sh`:
  - `./scripts/run-quiet.sh gradle-test -- ./gradlew testDebugUnitTest`
  - `./scripts/run-quiet.sh gradle-check -- ./gradlew lintDebug check`

## 4. Production Code Documentation Contract (English `KDoc`)

- All `public` and `internal` production classes, interfaces, `value class` / `data class` models, UseCases, ViewModels, and public/internal functions (`*Test.kt` excluded) MUST carry **English `KDoc`** (`/** ... */` with `@param`, `@return`, `@throws`) using canonical identifiers from `docs/canon/glossary.md`.
- **No Parrot Comments (Blocking Defect):** Never write `/** Updates the address. */` on `updateAddress()`. Document **business intent, coroutine/threading expectations, domain invariants, and failure conditions**:

```kotlin
/**
 * Validates and persists a new [ClientWorkAddress] as the customer's primary dispatch location,
 * atomically demoting any previously active primary address within the same transaction.
 *
 * @param customerId Canonical customer identifier; must belong to an active account.
 * @param candidate Validated postal and geofence coordinates in the customer's bounded region.
 * @return Updated [AddressBookSnapshot] reflecting the single-primary invariant.
 * @throws ServiceAreaOutOfBoundsException When [candidate] falls outside supported dispatch polygons.
 */
suspend operator fun invoke(customerId: CustomerId, candidate: ClientWorkAddress): AddressBookSnapshot { ... }
```
