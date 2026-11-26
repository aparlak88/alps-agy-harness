# Alps AGY Harness — Universal Orchestration Contract

Wraps `superpowers` workflows with `hooks.json` gates, `jev` calibration, Clean Architecture, and context-rot protection.

## 1. Session Intake, `jev` Routing & Two-Phase `Orchestrator` (`harness-orchestrator`)
- Classify every task via `jev_classify` (`act_above: 0.80`):
  - `quick_fix`: Skip Spec; micro-scope `allowedFiles`, surgical TDD on feature branch.
  - `bug_investigation`: `superpowers:systematic-debugging` -> root-cause plan -> TDD (+ `docs/canon/lessons.md`).
  - `small_change`: Plan (`<= 5` tasks; skip Spec unless trade-offs exist) -> SDD or inline TDD.
  - `full_project`: `superpowers:brainstorming` -> Spec -> `superpowers:writing-plans` -> SDD/inline execution.
  - `pr_review`: Run `review-pr` (`pr-auditor`). *(If `< 0.80`, default to `brainstorming`.)*
- **Two-Phase `Orchestrator` (`Neon`/`Carbon`/`Opus 5.5` Planner ↔ `Hydrogen`/`Sonnet 5.5` Executor):**
  - **Planner:** Run `jev_classify`, research, `jev_check` (`ADR` options), `context7`, `ask_question`; hand off via `exit_plan_mode` + `Re-plan if:` triggers.
  - **Executor:** Branch/worktree, Spec/Plan/code, `stamp-gate.sh`, `run-quiet.sh`, PR gates; return via `enter_plan_mode` on failures/missing assumptions.
- **Zero-Fallback:** `jev` (`TYPESAFE_API_KEY`) is mandatory; if unreachable, **STOP** and run `./scripts/harness-doctor.sh`.

## 2. Branch & Worktree Isolation
- Never edit, commit, merge locally, or push on `main`, `master`, or `trunk` (`pre-edit-guard.sh` & `pre-command-guard.sh` deny).
- Switch to `superpowers:using-git-worktrees` or `feat/*`/`fix/*` before editing source/tests.

## 3. Dependency Version Governance (`dependency-versions` + `context7`)
- **Brownfield:** Read manifests/lockfiles (`package.json`, `package-lock.json`, `pnpm-lock.yaml`, `*.csproj`, `Directory.Packages.props`, `Package.swift`, `Package.resolved`, `libs.versions.toml`, `pyproject.toml`, `uv.lock`) and Spec `Global Constraints`; preserve locked major/minor versions unless upgrading.
- **Greenfield:** Verify latest stable (`npm view`, `dotnet package search`), query `context7` (`resolve-library-id` -> `query-docs`), record in `Global Constraints`, and run `./scripts/stamp-gate.sh context7 --package "<pkg>" --version "<ver>" --source locked|greenfield-latest` before install.

## 4. Architectural Trade-Off Protocol (`architecture-tradeoffs`)
- Before finalizing Spec (`jev_check >= 0.65`), present **2–3 options** (pros/cons + YAGNI pick) in Spec `## Architectural Decisions (ADR)`.

## 5. Three-Part Domain Canon (`domain-canon`)
- **`docs/canon/glossary.md`:** Enforce canonical English identifiers across Specs, Plans, code, and docstrings; forbidden aliases block merge.
- **`docs/canon/flows.md`:** Preserve ordered step contracts/invariants unless approved.
- **`docs/canon/lessons.md`:** Pre-screen via `jev_triage`/`jev_ask` (`>= 0.50`); record non-obvious root causes only.

## 6. Proportionality, Scope Lock & Anti-Overengineering
- **Boundary Over Ceremony:** Keep dependencies inward (`Domain` free of outer/ORM/UI/SDK deps) without pass-through layers.
- **Rule of Three:** No single-use `IFooHelper`, `AbstractBase`, `Factory`, or speculative flags before 3 uses.
- **Scope Lock:** Declare Plan budget, abstraction rationale, `Out-of-Scope` (`jev_ask`), edit only `allowedFiles`, and log extras in `docs/parking-lot.md` (`entropy-sweep`).

## 7. Hybrid `jev`, Gemini 4 / `Orchestrator` Routing & `run_workflow`
- **Tiers:** `invoke_subagent` & `run_workflow` `agent(model=...)` accept `inherit | flash_lite | flash | pro` (`pro`=frontier Gemini 4, `flash`=fast execution, `inherit`=active model). `Argon`, `3.8 Flash`, `GPT-OSS`, `Claude 4.6` retire `2026-11-30` (`SessionStart` warning).
- **Fixed:** `security-reviewer` -> `inherit`|`pro` (`MAX`); `pr-auditor` -> `inherit`|`pro` (`HIGH`/`XHIGH`/`MAX`, `Extra`->`XHIGH`); `browser` -> `flash`; `image-generator` -> pass-through.
- **Dynamic (`self`, `research`, `canon-auditor`, custom):** Score via `jev_classify`/`jev_score` (`>= 0.75`) and register `./scripts/stamp-gate.sh dispatch --role "<Role>" --type "<TypeName>" --tier "<tier>" [--effort LOW|MEDIUM|HIGH|XHIGH|MAX]`:
  - `trivial_lookup` -> `flash_lite` (`LOW`)
  - `bounded_execution` -> `inherit` (`Orchestrator`/Hydrogen/`frontier_low`/`claude_sonnet`), `pro` (Neon/Carbon/`claude_opus`/Argon/custom), else `flash` (`MEDIUM`/`XHIGH`)
  - `multi_module_integration` -> `pro` (`Orchestrator`/Hydrogen/`claude_sonnet`/`frontier_low`/Flash), `inherit` (`claude_opus`/Argon/custom, or Neon/Carbon if `Model: "inherit"`) (`HIGH`; `canon-auditor` floor)
  - `critical_architecture_or_audit` -> `inherit` (Neon/Carbon/`claude_opus`/Argon/custom) else `pro` (`Orchestrator` turns escalate to `pro` so audits never inherit Hydrogen) (`MAX`)
- **`run_workflow` Guard:** `hooks.json` (`invoke_subagent|swarm|run_workflow`) blocks raw `subprocess`/`os.system`, embedded keys, and invalid `model=` tiers.

## 8. Context Window Shield (`run-quiet.sh` & `mobile-logs.sh`)
- Wrap noisy build/test/lint in `./scripts/run-quiet.sh <label> -- <cmd...>` (1-line summary; full log `.harness/logs/last.log`).
- Replace `adb logcat` / `xcrun simctl ... log stream` with `./scripts/mobile-logs.sh --platform ios|android`.

## 9. Bilingual & Mandatory Glossary Standard
- **English Code:** Code, identifiers, docstrings (`XMLDoc`, `TSDoc`, `Swift DocC`, `KDoc`), and fitness checks (`REMEDIATION: ...`) MUST be English matching `docs/canon/glossary.md` (tests exempt).
- **Turkish Docs & Glossary:** User Markdown (`README.md`, Specs, Plans, `docs/walkthroughs/*.md`, `docs/canon/{flows,lessons}.md`) defaults to Turkish and MUST end with a non-empty `## Teknik Terimler Sözlüğü` (`## Technical Glossary`) table (`glossary.md` & `parking-lot.md` exempt).

## 10. Pre-PR, Conditional UI (`impeccable`) & Post-PR Gates
- **Before `gh pr create` (`pre-pr-readiness`):** (1) Commit `docs/walkthroughs/YYYY-MM-DD-<topic>.md` (`>= 2` real `mermaid` diagrams, `## Dosya Bazlı Değişiklik Analizi` covering **every** `git diff --name-status` file with *Ne* & *Neden*, + `## Teknik Terimler Sözlüğü`); (2) `canon-auditor` -> `./scripts/stamp-gate.sh canon --verdict PASS ...`; (3) `security-reviewer` (`Critical=0`, `Important=0`) -> `./scripts/stamp-gate.sh security --verdict PASS --critical 0 --important 0`; (4) If UI files changed AND `impeccable` installed, `./scripts/stamp-gate.sh ui --verdict PASS --p0 0 --p1 0` -> `ui-pass.json` (`DO_NOT_TRACK=1`, `IMPECCABLE_LIVE_COPY_AGENT=chat|off`; `PRODUCT.md`/`DESIGN.md` draftable on `main`; craft/slop in `impeccable` vs console/LCP/E2E in `playwright-e2e`/`chrome-devtools-plugin`); (5) `./scripts/stamp-gate.sh verify-pr-stamps` + clean `git status --porcelain`.
- **After `gh pr create` (`review-pr`):** `post-command-hooks.sh` + `stop-gate.sh` hold exit until `pr-auditor` completes Intent Backtranslation + 7-dimension audit (`jev_check`/`jev_score`) and runs `./scripts/stamp-gate.sh clear-pr-audit`.

## 11. Swarm Coordinator & Worker Mode
- **Coordinator:** Create one `feat/*` branch, run `jev_classify`/Spec/Plan once, spawn writers with `workspace: "share"` (`workspace: "inherit"` for readers), merge into integration branch, then run `pre-pr-readiness` (`canon-auditor`, `security-reviewer` via `invoke_subagent`), Walkthrough, `gh pr create`, and `pr-auditor`.
- **Swarm Worker:** Skip `jev_classify`, `brainstorming`, Spec, Walkthrough, `gh pr create`; run TDD, `context7`, `run-quiet.sh`, glossary/security in your branch, and send `docs/parking-lot.md` or `docs/canon/*` notes to `@coordinator`.
