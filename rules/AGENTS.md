# Alps AGY Harness — Universal Orchestration Contract

This always-on contract wraps `superpowers` workflows with deterministic lifecycle hooks, `jev` calibration, Clean Architecture governance, and context-rot protection. Every gate below is physically enforced by `hooks.json` and audited at PR boundaries.

## 1. Session Intake & Mandatory `jev` Routing (`harness-orchestrator`)
- Classify every new task upfront via `jev_classify` (`act_above: 0.80`) into its proportional track:
  - `quick_fix` *(trivial)*: Skip Spec; micro-scope `allowedFiles`, surgical TDD on a feature branch.
  - `bug_investigation` *(bugfix)*: `superpowers:systematic-debugging` -> root-cause fix plan -> TDD (+ `docs/canon/lessons.md` if non-obvious trap).
  - `small_change` *(standard_feature)*: Short plan (`<= 5` tasks; skip Spec unless trade-offs exist) -> SDD or inline TDD.
  - `full_project` *(cross_cutting_or_architectural)*: `superpowers:brainstorming` -> Spec -> `superpowers:writing-plans` -> SDD/inline execution.
  - `pr_review`: Run `review-pr` (`pr-auditor`) directly on the target PR. *(If `jev_classify < 0.80`, default safely to `brainstorming`.)*
- **Zero-Fallback Policy:** `jev` (`TYPESAFE_API_KEY`) is mandatory. If `jev` tools or `TYPESAFE_API_KEY` are missing or unreachable, **STOP immediately** — never invent heuristic probabilities — and instruct the user to run `./scripts/harness-doctor.sh`.

## 2. Branch & Worktree Isolation
- Never edit production code/configs, commit, merge feature branches locally, or push directly on `main`, `master`, or `trunk` (`pre-edit-guard.sh` and `pre-command-guard.sh` deny violations).
- Always switch to an isolated Git worktree (`superpowers:using-git-worktrees`) or `feat/*` / `fix/*` branch before touching implementation or test files.

## 3. Dependency Version Governance (`dependency-versions` + `context7`)
- **Brownfield First:** Read manifest/lockfiles (`package.json`, `package-lock.json`, `pnpm-lock.yaml`, `*.csproj`, `Directory.Packages.props`, `Package.swift`, `Package.resolved`, `libs.versions.toml`, `pyproject.toml`, `uv.lock`) and Spec `Global Constraints`. Preserve locked major/minor versions unless explicitly asked to upgrade.
- **Greenfield / New Packages:** Never guess versions or APIs from training memory. Verify the latest stable release via official registries (`npm view`, `dotnet package search`, official release index), then read version-matched docs via `context7` (`resolve-library-id` -> `query-docs`).
- **Mandatory Stamp:** Record verified versions in Spec `Global Constraints` and run `./scripts/stamp-gate.sh context7 --package "<pkg>" --version "<ver>" --source locked|greenfield-latest` before any package-install command.

## 4. Architectural Trade-Off Protocol (`architecture-tradeoffs`)
- Before finalizing any Spec (`jev_check` `yes_at_or_above: 0.65`), whenever multiple valid architectural patterns or module boundaries exist, present **2–3 viable options** with a pros/cons matrix and a YAGNI-aligned recommendation, then record the chosen option and rejected alternatives in Spec `## Architectural Decisions (ADR)`.

## 5. Three-Part Domain Canon (`domain-canon`)
- **`docs/canon/glossary.md` (Ubiquitous Language):** Use canonical English type/field names across Specs, Plans, code, and docstrings; forbidden aliases block merge.
- **`docs/canon/flows.md` (Canonical Flows):** Preserve ordered step contracts and invariants; flow changes require explicit user canon-revision approval.
- **`docs/canon/lessons.md` (Compound Lessons):** Pre-screen via zero-context `jev_triage` / `jev_ask` (`>= 0.50`) before planning or debugging. Record only non-obvious root causes/SDK pitfalls (never syntax typos).

## 6. Proportionality, Scope Lock & Anti-Overengineering
- **Boundary Over Ceremony:** Protect inward dependency direction (`Domain` has zero outer/ORM/UI/SDK dependencies) without inventing empty pass-through layers on `quick_fix` or `small_change` tasks.
- **Rule of Three:** Outside external boundaries (repositories, 3rd-party SDK/HTTP gateways), never extract single-use `IFooHelper` interfaces, `AbstractBase` classes, `Factory` wrappers, or speculative flags before 3 concrete uses.
- **Complexity Budget & Scope Lock:** Every Plan declares file-count budget, 1-sentence justification per abstraction, and `Out-of-Scope` items (`jev_ask` simplicity check). Edit **only** planned `allowedFiles`; write out-of-scope ideas or tech debt as 1-line notes in `docs/parking-lot.md` (cleaned via user-invoked `entropy-sweep`).

## 7. Hybrid `jev` Subagent Model & Effort Routing
- **Fixed Subagents (`pre-subagent-guard.sh` auto-overwrites):** `security-reviewer` -> `Model: "pro"` (`EFFORT_PROFILE: MAX`); `pr-auditor` -> `Model: "pro"` (`EFFORT_PROFILE: HIGH`/`MAX`); `browser` -> `Model: "flash"` default; `image-generator` -> pass-through.
- **Dynamic Subagents (`self`, `research`, `canon-auditor`, custom):** Before **every** `invoke_subagent`, classify the brief via `jev_classify` / `jev_score` (`act_above: 0.75`; round uncertain up), register via `./scripts/stamp-gate.sh dispatch --role "<Role>" --type "<TypeName>" --tier "<tier>"`, and pass the matching `Model` (`pre-subagent-guard.sh` locks `Model` + `[EFFORT_PROFILE: ...]`):
  - `trivial_lookup` -> `flash_lite` (`EFFORT_PROFILE: LOW`)
  - `bounded_execution` -> `flash` (`EFFORT_PROFILE: MEDIUM`)
  - `multi_module_integration` -> `inherit` (`EFFORT_PROFILE: HIGH`; floor for `canon-auditor`)
  - `critical_architecture_or_audit` -> `pro` (`EFFORT_PROFILE: MAX`)

## 8. Context Window Shield (`run-quiet.sh` & `mobile-logs.sh`)
- Wrap noisy build/test/lint commands (`dotnet build/test`, `npm test`, `ng build`, `npx playwright test`, `xcodebuild`, `./gradlew test/check`) in `./scripts/run-quiet.sh <label> -- <cmd...>` (1-line pass summary; full output in `.harness/logs/last.log`).
- Never run unbounded `adb logcat` or `xcrun simctl ... log stream`; always use `./scripts/mobile-logs.sh --platform ios|android`.

## 9. Bilingual & Mandatory Glossary Standard
- **English Code & Fitness Contracts:** Source code, identifiers, production docstrings (`XMLDoc`, `TSDoc`, `Swift DocC`, `KDoc`), and fitness failure messages (`REMEDIATION: ...`) MUST be in **English** aligned with `docs/canon/glossary.md`, documenting business intent, invariants, edge cases, and errors — parrot comments (`/// Gets the user`) are forbidden; test files are exempt.
- **Turkish Docs & End-of-Doc Glossary:** User-facing Markdown (`README.md`, Specs, Plans, `docs/walkthroughs/*.md`, `docs/canon/{flows,lessons}.md`) defaults to **Turkish** and MUST end with a non-empty `## Teknik Terimler Sözlüğü` (or `## Technical Glossary`) table (`docs/canon/glossary.md` and `docs/parking-lot.md` exempt).

## 10. Pre-PR Readiness & Post-PR Audit Gates (Zero Exceptions)
- **Before `gh pr create` (`pre-pr-readiness`):** (1) Commit comprehensive Engineering Walkthrough `docs/walkthroughs/YYYY-MM-DD-<topic>.md` (`>= 2` real-class `mermaid` diagrams, `## Dosya Bazlı Değişiklik Analizi` documenting **every** file in `git diff --name-status` with concrete *Ne* & *Neden* — 1-line summary bullets or omitted files are `Important` PR blockers, plus `## Teknik Terimler Sözlüğü`); (2) `canon-auditor` -> `./scripts/stamp-gate.sh canon --verdict PASS ...`; (3) `security-reviewer` (`Critical=0`, `Important=0`) -> `./scripts/stamp-gate.sh security --verdict PASS --critical 0 --important 0`; (4) `./scripts/stamp-gate.sh verify-pr-stamps` + clean `git status --porcelain`.
- **After `gh pr create` (`review-pr`):** `post-command-hooks.sh` + `stop-gate.sh` block exit until `pr-auditor` runs its Intent Backtranslation + 7-dimension audit (`jev_check`/`jev_score`) and clears `./scripts/stamp-gate.sh clear-pr-audit`.
