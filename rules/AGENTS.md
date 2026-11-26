# Alps AGY Harness — Universal Orchestration Contract

Wraps `superpowers` workflows with `hooks.json` gates, `jev` calibration, Clean Architecture rules, and context-rot protection.

## 1. Session Intake & Mandatory `jev` Routing (`harness-orchestrator`)
- Classify every task upfront via `jev_classify` (`act_above: 0.80`):
  - `quick_fix` *(trivial)*: Skip Spec; micro-scope `allowedFiles`, surgical TDD on a feature branch.
  - `bug_investigation` *(bugfix)*: `superpowers:systematic-debugging` -> root-cause plan -> TDD (+ `docs/canon/lessons.md`).
  - `small_change` *(standard)*: Plan (`<= 5` tasks; skip Spec unless trade-offs exist) -> SDD or inline TDD.
  - `full_project` *(architectural)*: `superpowers:brainstorming` -> Spec -> `superpowers:writing-plans` -> SDD/inline execution.
  - `pr_review`: Run `review-pr` (`pr-auditor`) on target PR. *(If `< 0.80`, default to `brainstorming`.)*
- **Zero-Fallback Policy:** `jev` (`TYPESAFE_API_KEY`) is mandatory. If missing/unreachable, **STOP immediately** — never invent heuristic probabilities — and instruct running `./scripts/harness-doctor.sh`.

## 2. Branch & Worktree Isolation
- Never edit code/configs, commit, merge locally, or push directly on `main`, `master`, or `trunk` (`pre-edit-guard.sh` and `pre-command-guard.sh` deny violations).
- Switch to an isolated worktree (`superpowers:using-git-worktrees`) or `feat/*` / `fix/*` branch before touching source/test files.

## 3. Dependency Version Governance (`dependency-versions` + `context7`)
- **Brownfield:** Read manifests/lockfiles (`package.json`, `package-lock.json`, `pnpm-lock.yaml`, `*.csproj`, `Directory.Packages.props`, `Package.swift`, `Package.resolved`, `libs.versions.toml`, `pyproject.toml`, `uv.lock`) and Spec `Global Constraints`; preserve locked major/minor versions unless upgrading.
- **Greenfield / New Packages:** Verify latest stable via official registries (`npm view`, `dotnet package search`), then read version-matched docs via `context7` (`resolve-library-id` -> `query-docs`).
- **Stamp:** Record in Spec `Global Constraints` and run `./scripts/stamp-gate.sh context7 --package "<pkg>" --version "<ver>" --source locked|greenfield-latest` before install.

## 4. Architectural Trade-Off Protocol (`architecture-tradeoffs`)
- Before finalizing Spec (`jev_check` `>= 0.65`), when multiple valid architectures exist, present **2–3 options** with pros/cons and a YAGNI recommendation, recording chosen and rejected alternatives in Spec `## Architectural Decisions (ADR)`.

## 5. Three-Part Domain Canon (`domain-canon`)
- **`docs/canon/glossary.md` (Ubiquitous Language):** Enforce canonical English identifiers across Specs, Plans, code, and docstrings; forbidden aliases block merge.
- **`docs/canon/flows.md` (Canonical Flows):** Preserve ordered step contracts and invariants unless user approves canon revision.
- **`docs/canon/lessons.md` (Compound Lessons):** Pre-screen via zero-context `jev_triage` / `jev_ask` (`>= 0.50`) before planning/debugging; record non-obvious root causes only.

## 6. Proportionality, Scope Lock & Anti-Overengineering
- **Boundary Over Ceremony:** Keep inward dependencies (`Domain` free of outer/ORM/UI/SDK deps) without empty pass-through layers on small tasks.
- **Rule of Three:** Outside external boundaries, never extract single-use `IFooHelper`, `AbstractBase`, `Factory` wrappers, or speculative flags before 3 concrete uses.
- **Scope Lock:** Declare Plan file budget, abstraction rationale, and `Out-of-Scope` (`jev_ask`). Edit only `allowedFiles`; log out-of-scope ideas as 1-line notes in `docs/parking-lot.md` (cleaned via `entropy-sweep`).

## 7. Hybrid `jev` & Gemini 4 Parent-Aware Subagent Routing
- **Runtime Tiers:** `invoke_subagent` uses `inherit | flash_lite | flash | pro` (`pro` = Argon, `flash` = 3.8 Flash, `inherit` = parent's Carbon/Neon/Argon/Hydrogen/`Orchestrator`/Claude/custom). `pre-subagent-guard.sh` reads `HOOK_INPUT.modelName`: Carbon/Neon/`Orchestrator`/Argon(Med,High)/Claude/custom audits keep `inherit`; Hydrogen/Argon-Low/Flash escalate via `pro`.
- **Fixed:** `security-reviewer` -> `inherit`|`pro` (`MAX`); `pr-auditor` -> `inherit`|`pro` (`HIGH`/`XHIGH`/`MAX`); `browser` -> `flash` default; `image-generator` -> pass-through.
- **Dynamic (`self`, `research`, `canon-auditor`, custom):** Classify via `jev_classify`/`jev_score` (`>= 0.75`) and register `./scripts/stamp-gate.sh dispatch --role "<Role>" --type "<TypeName>" --tier "<tier>" [--effort LOW|MEDIUM|HIGH|XHIGH|MAX]`:
  - `trivial_lookup` -> `flash_lite` (`LOW`)
  - `bounded_execution` -> `inherit` (`Orchestrator`/Hydrogen/Argon-Low), `pro` (Carbon/Neon/Argon-Med,High/Claude/custom), else `flash` (Flash/`unset`) (`MEDIUM`/`XHIGH`)
  - `multi_module_integration` -> `inherit` (`Orchestrator`/Argon-Med,High/Claude/custom) or `pro` (`inherit` on Carbon/Neon if `Model: "inherit"`; else `pro`) (`HIGH`; `canon-auditor` floor)
  - `critical_architecture_or_audit` -> `inherit` (Carbon/Neon/`Orchestrator`/Argon-Med,High/Claude/custom) else `pro` (`MAX`)

## 8. Context Window Shield (`run-quiet.sh` & `mobile-logs.sh`)
- Wrap noisy build/test/lint commands in `./scripts/run-quiet.sh <label> -- <cmd...>` (1-line summary; full log in `.harness/logs/last.log`).
- Never run unbounded `adb logcat` or `xcrun simctl ... log stream`; use `./scripts/mobile-logs.sh --platform ios|android`.

## 9. Bilingual & Mandatory Glossary Standard
- **English Code & Fitness Contracts:** Code, identifiers, docstrings (`XMLDoc`, `TSDoc`, `Swift DocC`, `KDoc`), and fitness failures (`REMEDIATION: ...`) MUST be English matching `docs/canon/glossary.md`, explaining intent/invariants (no parrot comments; tests exempt).
- **Turkish Docs & Glossary:** User Markdown (`README.md`, Specs, Plans, `docs/walkthroughs/*.md`, `docs/canon/{flows,lessons}.md`) defaults to Turkish and MUST end with a non-empty `## Teknik Terimler Sözlüğü` (`## Technical Glossary`) table (`glossary.md` & `parking-lot.md` exempt).

## 10. Pre-PR, Conditional UI (`impeccable`) & Post-PR Gates
- **Before `gh pr create` (`pre-pr-readiness`):** (1) Commit `docs/walkthroughs/YYYY-MM-DD-<topic>.md` (`>= 2` real `mermaid` diagrams, `## Dosya Bazlı Değişiklik Analizi` covering **every** `git diff --name-status` file with *Ne* & *Neden*, plus `## Teknik Terimler Sözlüğü`); (2) `canon-auditor` -> `./scripts/stamp-gate.sh canon --verdict PASS ...`; (3) `security-reviewer` (`Critical=0`, `Important=0`) -> `./scripts/stamp-gate.sh security --verdict PASS --critical 0 --important 0`; (4) If UI files changed AND `impeccable` is installed, run `./scripts/stamp-gate.sh ui --verdict PASS --p0 0 --p1 0` -> `ui-pass.json` (`DO_NOT_TRACK=1`, `IMPECCABLE_LIVE_COPY_AGENT=chat|off`; `PRODUCT.md`/`DESIGN.md` draftable on `main`; keep visual craft/slop in `impeccable` vs console/LCP/E2E in `playwright-e2e`/`chrome-devtools-plugin`); (5) `./scripts/stamp-gate.sh verify-pr-stamps` + clean `git status --porcelain`.
- **After `gh pr create` (`review-pr`):** `post-command-hooks.sh` + `stop-gate.sh` block exit until `pr-auditor` runs Intent Backtranslation + 7-dimension audit (`jev_check`/`jev_score`) and clears `./scripts/stamp-gate.sh clear-pr-audit`.

## 11. Swarm Coordinator & Worker Mode
- **Coordinator:** Switch from `main` to one `feat/*` integration branch, run `jev_classify`/Spec/Plan once, spawn writing Swarm workers with `workspace: "share"` on worker sub-branches (`workspace: "inherit"` for read-only workers), merge worker branches into the integration branch, then run `pre-pr-readiness` (`canon-auditor`, `security-reviewer` via `invoke_subagent`), one Walkthrough, `gh pr create`, and `pr-auditor`.
- **Swarm Worker:** When dispatched with a `brief`, never re-run `jev_classify`, `brainstorming`, Spec, Walkthrough, or `gh pr create`; execute TDD, `context7`, `run-quiet.sh`, and glossary/security rules within your branch/files, and report `docs/parking-lot.md` or `docs/canon/*` suggestions to `@coordinator` on the board instead of editing shared docs directly.
