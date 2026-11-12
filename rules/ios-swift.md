---
trigger: glob
description: iOS (Swift/SwiftUI) local SPM modular Clean Architecture, forbidden-import REMEDIATION fitness tests, Simulator mobile-logs.sh diagnostics, and English Swift DocC
globs: **/*.swift, **/Package.swift, **/*.xcodeproj/**
---

# iOS (Swift / SwiftUI) Clean Architecture & Engineering Contract

Apply these rules whenever inspecting, authoring, or reviewing Swift source files, `Package.swift` manifests, or Xcode project configurations.

## 1. Local Swift Package Manager (SPM) Module Boundaries

Structure iOS code around local SPM targets (`Package.swift`) enforcing strict inward dependency direction: `App` -> (`Features`, `Data`) -> `Domain`.

- **`Domain` Target (Pure Swift Core):**
  - Value-semantic `struct`/`enum` Entities and Value Objects (`Sendable`, `Equatable`), UseCases, Domain Errors, and outbound Repository/Gateway `protocol` contracts.
  - **Zero UI or SDK imports:** `Domain` MUST NOT `import SwiftUI`, `UIKit`, `Combine` UI publishers, `SwiftData`, `CoreData`, `Firebase*`, or `RevenueCat`.
- **`Data` Target (Adapters & Persistence):**
  - Depends on `Domain` (+ network/persistence/SDK packages). Implements `Domain` protocols (`SubscriptionRepository`, `AuthGateway`), `URLSession`/SwiftData/Keychain adapters, and explicit DTO -> `Domain` mappers. Store sensitive tokens exclusively in Keychain (never `UserDefaults`).
- **`Features` Targets (`Features/<BoundedContext>`):**
  - Depends on `Domain` (and shared design-system primitives) — **MUST NOT `import Data` directly**.
  - State management uses Swift Observation (`@Observable`, `@MainActor` ViewModels) with unidirectional intent methods and thin, declarative SwiftUI `View` structs.
- **`App` Target (Composition Root):**
  - Wires concrete `Data` implementations to `Domain` protocols and injects them into `Features` ViewModels.

## 2. Compile & Test-Time Architectural Fitness Tests (`REMEDIATION:` Injection)

Enforce module boundaries both via `Package.swift` target dependency arrays (`Domain` has `dependencies: []`; `Features` depends only on `["Domain"]`) and an executable Swift Testing / `XCTest` architectural scan emitting an **English `REMEDIATION:`** message on violation:

```swift
import Foundation
import Testing

struct ArchitectureFitnessTests {
    @Test("Domain and Features targets respect Clean Architecture import boundaries")
    func verifyCleanArchitectureImports() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ArchitectureTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Package root

        let domainFiles = try swiftFiles(in: packageRoot.appendingPathComponent("Sources/Domain"))
        let forbiddenInDomain = ["SwiftUI", "UIKit", "SwiftData", "CoreData", "Firebase", "RevenueCat", "Data"]

        for file in domainFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            for module in forbiddenInDomain where source.contains("import \(module)") {
                Issue.record(Comment(rawValue:
                    "REMEDIATION: \(file.lastPathComponent) imports forbidden module '\(module)' inside Domain. Keep Domain pure Swift, define a protocol in Sources/Domain, and move SDK/framework adapters to Sources/Data."
                ))
            }
        }

        let featuresFiles = try swiftFiles(in: packageRoot.appendingPathComponent("Sources/Features"))
        for file in featuresFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(
                !source.contains("import Data"),
                "REMEDIATION: \(file.lastPathComponent) in Sources/Features must not import Data directly. Depend on Domain protocols and wire concrete adapters in the App Composition Root."
            )
        }
    }
}
```

## 3. Simulator Diagnostics (`mobile-logs.sh`) & Quiet Build Workflow

- **Never Run Unbounded Simulator Log Streams:** `pre-command-guard.sh` blocks raw `xcrun simctl ... log stream` because infinite streams hang sessions and flood context.
- **Targeted Crash & App Log Extraction:** Always inspect runtime logs, `.ips`/`.crash` stack traces from `~/Library/Logs/DiagnosticReports`, and simulator screenshots via:
  - `./scripts/mobile-logs.sh --platform ios --bundle-id <app.bundle.id> --last 2m`
  - Optional: use `XcodeBuildMCP` when configured on macOS workstations for scheme/simulator inspection, while keeping full build/test invocations wrapped in `./scripts/run-quiet.sh`:
  - `./scripts/run-quiet.sh swift-test -- swift test`
  - `./scripts/run-quiet.sh ios-build -- xcodebuild -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build`

## 4. Production Code Documentation Contract (English `Swift DocC`)

- All `public` and `internal` production `struct`, `class`, `actor`, `protocol`, `enum`, UseCases, and non-trivial methods (`*Tests.swift` excluded) MUST carry **English `Swift DocC`** (`///` summary + `- Parameters:` / `- Returns:` / `- Throws:`) using exact canonical terms from `docs/canon/glossary.md`.
- **No Parrot Comments (Blocking Defect):** Never write `/// Fetches the subscription.` on `fetchSubscription()`. Explain **domain purpose, concurrency/actor isolation preconditions, invariants, and thrown errors**:

```swift
/// Evaluates whether the user's `CustomerSubscriptionTier` grants offline export access
/// at the given `evaluationDate`, accounting for active billing grace periods.
///
/// - Parameters:
///   - entitlement: Canonical domain entitlement snapshot loaded from `SubscriptionRepository`.
///   - evaluationDate: Reference UTC timestamp injected via `ClockProtocol` for deterministic testing.
/// - Returns: `true` while active or within the grace window; `false` once expired or revoked.
/// - Throws: ``EntitlementValidationError/corruptedPeriodWindow`` if `expiresAt < startedAt`.
public func canExportOffline(entitlement: SubscriptionEntitlement, evaluationDate: Date) throws -> Bool { ... }
```
