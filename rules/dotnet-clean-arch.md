---
trigger: glob
description: .NET (C#/XAML) DDD, Clean Architecture, NetArchTest/ArchUnitNET fitness functions, csharp-lsp workflow, and English XMLDoc rules
globs: **/*.cs, **/*.xaml, **/*.csproj, **/*.sln, **/*.slnx, **/Directory.Packages.props
---

# .NET (C# / XAML) Clean Architecture & Engineering Contract

Apply these rules whenever inspecting, authoring, or reviewing `.NET`, `C#`, `XAML`, or MSBuild project/package files.

## 1. Clean Architecture Layer Boundaries & Dependency Direction

Dependencies point strictly **inward**: `Presentation` / `Infrastructure` -> `Application` -> `Domain`.

- **`Domain` Layer (Pure C# Core):**
  - Zero dependencies on `Microsoft.EntityFrameworkCore`, `System.Text.Json`/`Newtonsoft.Json` serialization attributes, `Microsoft.AspNetCore.*`, XAML/UI frameworks, or 3rd-party SDKs (Firebase, RevenueCat, Stripe, etc.). No `[Table]`, `[Column]`, or `[JsonPropertyName]` data annotations on domain models.
  - Model rich **Aggregate Roots** that enforce invariants via domain methods/factories (avoid Anemic Domain Models with public `set` mutators), immutable `readonly record struct` / `record` **Value Objects**, and `IDomainEvent` contracts.
- **`Application` Layer (Use Cases & CQRS):**
  - Depend only on `Domain`. Separate state-mutating **Commands** from read-only **Queries** (CQRS) with explicit use-case handlers, `FluentValidation` validators, and outbound port interfaces (`IXxxRepository`, `IBillingGateway`, `IClock`).
  - Respect the **Rule of Three**: do not wrap internal pure helpers in single-use `IFooHelper` interfaces; define interfaces in `Domain`/`Application` only for true architectural boundaries.
- **`Infrastructure` Layer (Adapters & Persistence):**
  - Implement `Domain`/`Application` interfaces: EF Core `DbContext` + `IEntityTypeConfiguration<T>` (fluent mapping only), external HTTP/SDK adapters, and resilience pipelines (`Polly` / `Microsoft.Extensions.Http.Resilience`). Map external DTOs/entities to `Domain` types inside `Infrastructure` — never leak SDK DTOs inward.
- **`Presentation` Layer (API / XAML UI):**
  - Keep ASP.NET Core Minimal APIs / Controllers thin: bind request DTO -> dispatch Command/Query -> map result/HTTP status. Standardize unhandled error responses via centralized `IExceptionHandler` emitting **`RFC 7807` (`ProblemDetails`)** without leaking stack traces or SQL details.
  - For WPF/MAUI/Avalonia XAML: enforce strict MVVM (`View` binds to `ViewModel` commands/observable properties; zero business or persistence logic in `.xaml.cs` code-behind).

## 2. Compile/Test-Time Architectural Fitness Tests (`REMEDIATION:` Injection)

Greenfield solutions must establish an executable architecture test project (`NetArchTest.Rules` or `ArchUnitNET`) in task 1; brownfield solutions must keep existing architecture tests green (or propose adding them during `architecture-tradeoffs`). Every assertion failure MUST emit an actionable **English `REMEDIATION:`** message:

```csharp
using NetArchTest.Rules;
using Xunit;

public sealed class ArchitectureTests
{
    [Fact]
    public void Domain_Should_Not_Reference_Outer_Layers_Or_Frameworks()
    {
        var result = Types.InAssembly(typeof(OrderAggregate).Assembly)
            .ShouldNot()
            .HaveDependencyOnAny(
                "MyApp.Application",
                "MyApp.Infrastructure",
                "MyApp.Presentation",
                "Microsoft.EntityFrameworkCore",
                "Microsoft.AspNetCore")
            .GetResult();

        Assert.True(
            result.IsSuccessful,
            $"REMEDIATION: Domain layer must remain pure C# and cannot reference outer layers or frameworks ({string.Join(", ", result.FailingTypeNames ?? [])}). Define ports/interfaces in Domain or Application and move EF Core, HTTP, or SDK implementations into Infrastructure.");
    }

    [Fact]
    public void Presentation_Should_Not_Reference_Infrastructure_Persistence_Types_Directly()
    {
        var result = Types.InAssembly(typeof(Program).Assembly)
            .That().DoNotHaveName("Program").And().DoNotResideInNamespace("MyApp.Presentation.CompositionRoot")
            .ShouldNot()
            .HaveDependencyOn("Microsoft.EntityFrameworkCore")
            .GetResult();

        Assert.True(
            result.IsSuccessful,
            "REMEDIATION: Presentation endpoints/views must not query DbContext or Infrastructure persistence types directly. Dispatch an Application Command/Query handler instead.");
    }
}
```

## 3. Mandatory `csharp-lsp` & Quiet Verification Workflow

- **LSP Diagnostics & Refactoring (`csharp-lsp`):**
  - Run `csharp_set_workspace` once per solution/workspace when needed, then inspect compiler/analyzer health with `csharp_diagnostics` after edits.
  - Use `csharp_references` and `csharp_definition` before changing public contracts, and use `csharp_rename` for symbol renames across projects instead of brittle regex replacements.
  - When touching `.xaml` files, run `xaml_validate` and `xaml_find_binding_errors` (plus `xaml_bindings` / `xaml_resources`) to catch broken `DataType`/`Binding` paths before runtime.
- **Central Package Management & Context7:** Respect `Directory.Packages.props` / `*.csproj` locked versions; verify any package addition via `dependency-versions` + `context7` + `stamp-gate.sh context7` first.
- **Quiet Build & Test Execution:** Always wrap `dotnet build` and `dotnet test` in `./scripts/run-quiet.sh`:
  - `./scripts/run-quiet.sh dotnet-build -- dotnet build --nologo`
  - `./scripts/run-quiet.sh dotnet-test -- dotnet test --no-build --nologo`

## 4. Production Code Documentation Contract (English `XMLDoc`)

- All `public` and `internal` production types (`class`, `record`, `struct`, `interface`, `enum`), Aggregate methods, Use-Case handlers, and ports MUST carry **English `XMLDoc`** (`/// <summary>`, plus `<param>`, `<returns>`, `<exception>` where applicable) using exact canonical identifiers from `docs/canon/glossary.md`.
- **Unit/Integration test files (`*Tests.cs`, `*Specs.cs`) are exempt** from XMLDoc requirements.
- **No Parrot Comments (Blocking Defect):** Never repeat the member or type name (`/// <summary>Gets the user.</summary>` on `GetUserAsync`). Document **business intent, domain invariants, boundary preconditions, and failure modes**:

```csharp
/// <summary>
/// Transitions the subscription to <see cref="SubscriptionStatus.GracePeriod"/> when a renewal charge fails,
/// preserving entitlement access until <paramref name="graceExpiresAtUtc"/> elapses.
/// </summary>
/// <param name="graceExpiresAtUtc">UTC deadline supplied by the billing gateway; must be strictly after <c>LastRenewedAtUtc</c>.</param>
/// <exception cref="DomainInvariantViolationException">
/// Thrown when the subscription is already canceled or <paramref name="graceExpiresAtUtc"/> precedes the current period end.
/// </exception>
public void EnterGracePeriod(DateTimeOffset graceExpiresAtUtc) { ... }
```
