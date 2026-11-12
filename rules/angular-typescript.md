---
trigger: glob
description: Angular & TypeScript bounded-context Clean Architecture, Sheriff/ESLint boundaries REMEDIATION rules, typescript-lsp, Playwright/Chrome DevTools zero-console-error gates, and English TSDoc
globs: **/*.ts, **/*.tsx, **/*.html, **/angular.json, **/tsconfig*.json
---

# Angular & TypeScript Clean Architecture & Engineering Contract

Apply these rules whenever inspecting, authoring, or reviewing TypeScript, Angular templates, or workspace configuration files.

## 1. Bounded-Context Vertical Slicing & Clean Architecture Layers

Slice features by **Bounded Context** (`src/app/features/<context>/` or `libs/<context>/`) with strict inward dependency direction: `presentation/` & `infrastructure/` -> `application/` -> `model/`.

- **`model/` (Pure Domain Layer):**
  - Pure TypeScript types, branded IDs, immutable domain entities/value objects, and pure domain validation functions.
  - **Zero framework or transport imports:** must NEVER import `@angular/*`, `rxjs/ajax`, `HttpClient`, `localStorage`, DOM APIs, or 3rd-party SDKs (Firebase, RevenueCat, etc.).
- **`application/` (Signal Store / Use-Case Facade):**
  - Orchestrates feature state and use cases using Angular **Signals** (`signal`, `computed`, `linkedSignal` / `rxResource` where appropriate in the project's locked Angular version) and outbound port tokens/interfaces (`InjectionToken<OrderGateway>`).
  - Must NOT import concrete `HttpClient` adapters from `infrastructure/` or UI components from `presentation/`.
- **`infrastructure/` (Adapters & Mappers):**
  - Concrete API clients (`HttpClient`), storage/Firebase/RevenueCat adapters, and explicit **DTO -> Domain mappers**. Never bind raw backend snake_case DTOs directly into templates; map them to canonical domain models defined in `model/` and `docs/canon/glossary.md`.
- **`presentation/` (Standalone UI):**
  - **Standalone components only** (`NgModule` is forbidden for new code), `ChangeDetectionStrategy.OnPush`, signal inputs/outputs (`input()`, `output()`), and native control flow (`@if`, `@for` with explicit `track`, `@switch`, `@defer`).
  - Keep templates thin and declarative; never call `HttpClient` from components or use `bypassSecurityTrust*` / `innerHTML` with untrusted data.

## 2. Architectural Fitness Rules (`@softarc/sheriff` or `eslint-plugin-boundaries`)

Enforce module/layer boundaries at lint/test time using `@softarc/sheriff` (`sheriff.config.ts`) or `eslint-plugin-boundaries` so forbidden imports fail CI with an actionable **English `REMEDIATION:`** message:

```typescript
// eslint.config.js (eslint-plugin-boundaries / @softarc/sheriff companion rule)
{
  rules: {
    'boundaries/element-types': ['error', {
      default: 'disallow',
      message: 'REMEDIATION: Architectural boundary violation (${file.type} -> ${dependency.type}). Domain (model/) must stay pure TypeScript with zero @angular/* or infrastructure imports, and presentation/ must communicate via application/ Signal facades rather than importing infrastructure/ directly.',
      rules: [
        { from: 'model', allow: ['model'] },
        { from: 'application', allow: ['model', 'application'] },
        { from: 'infrastructure', allow: ['model', 'application', 'infrastructure'] },
        { from: 'presentation', allow: ['model', 'application', 'presentation'] }
      ]
    }]
  }
}
```

## 3. Mandatory `typescript-lsp`, `@playwright/mcp` & `Chrome DevTools` Workflow

- **Compiler & Symbol Precision (`typescript-lsp`):**
  - Use `typescript-lsp` diagnostics, hover, definition, and reference lookups before editing shared types or Angular component contracts; maintain strict TypeScript (`noImplicitAny`, `strictNullChecks`, zero unjustified `any` casts).
- **3-Layer Web Runtime Verification (`playwright-e2e`):**
  1. **Live Console & Network Gate (`@playwright/mcp`):** Inspect accessibility snapshots alongside `browser_console_messages` (`error`/`warning`) and `browser_network_requests` (`4xx`/`5xx`/CORS). Author resilient E2E specs using `getByRole` / `getByLabel` locators rather than brittle CSS paths.
  2. **Deep Diagnostics (`Chrome DevTools`):** When diagnosing failed requests, layout shifts, memory leaks, or slow hydration, inspect request/response payloads, network waterfalls, and performance traces via `Chrome DevTools` (`chrome-devtools-plugin`) and correlate `5xx` responses with backend dev-server logs.
  3. **Zero-Console-Error E2E Shield:** Base `@playwright/test` fixtures must attach `page.on('pageerror')`, unexpected `console.error`, and `response.status() >= 500` listeners that fail the test with an English `REMEDIATION:` message even if the UI renders visually.
- **Quiet Verification:** Wrap builds, lints, and tests in `./scripts/run-quiet.sh`:
  - `./scripts/run-quiet.sh ng-build -- npx ng build`
  - `./scripts/run-quiet.sh ng-test -- npm test -- --watch=false`
  - `./scripts/run-quiet.sh pw-e2e -- npx playwright test`

## 4. Production Code Documentation Contract (English `TSDoc`)

- All exported production classes, Signal stores/facades, domain functions, mapper contracts, and complex interfaces (`*.spec.ts` and `*.test.ts` excluded) MUST carry **English `TSDoc`** (`/** ... */` with `@param`, `@returns`, `@throws`) aligned with `docs/canon/glossary.md`.
- **No Parrot Comments (Blocking Defect):** Never restate identifier names (`/** Gets user profile. */` on `getUserProfile`). Document **why the contract exists, state/signal invariants, edge cases, and error semantics**:

```typescript
/**
 * Computes the prorated upgrade credit in minor currency units (`ClientBillingCredit`)
 * before submitting a plan transition to the billing gateway.
 *
 * @param currentCycle - Active billing window; `periodEndUtc` must be strictly greater than `periodStartUtc`.
 * @param usedSeconds - Elapsed billable seconds clamped to `[0, totalCycleSeconds]`.
 * @returns Non-negative integer credit in minor units (e.g., cents), rounded half-even.
 * @throws {InvalidBillingCycleError} When `currentCycle` timestamps are inverted or zero-length.
 */
export function calculateProratedCredit(currentCycle: BillingCycle, usedSeconds: number): number { ... }
```
