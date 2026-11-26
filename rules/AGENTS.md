# Alps AGY Harness — Universal Orchestration Contract

Wraps `superpowers` with `hooks.json` gates, `jev` calibration, Clean Architecture, and context-rot protection.

## 1. Session Intake, `jev` Routing & Two-Phase `Orchestrator` (`harness-orchestrator`)
- Classify via `jev_classify` (`act_above: 0.80`):
  - `quick_fix`: Skip Spec; micro `allowedFiles`, surgical TDD on feature branch.
  - `bug_investigation`: `superpowers:systematic-debugging` -> root-cause plan -> TDD (+ `docs/canon/lessons.md`).
  - `small_change`: Plan (`<= 5` tasks; skip Spec unless trade-offs exist) -> SDD/inline TDD.
  - `full_project`: `superpowers:brainstorming` -> Spec -> `superpowers:writing-plans` -> SDD/inline execution.
  - `pr_review`: `review-pr` (`pr-auditor`). *(If `< 0.80`, default to `brainstorming`.)*
- **Two-Phase `Orchestrator` (`Neon`/`Carbon`/`Opus 5.5` Planner ↔ `Hydrogen`/`Sonnet 5.5` Executor):**
  - **Planner:** `jev_classify`, research, `jev_check` (`ADR` options), `context7`, `ask_question`; hand off via `exit_plan_mode` + `Re-plan if:`.
  - **Executor:** Branch/worktree, Spec/Plan/code, `stamp-gate.sh`, `run-quiet.sh`, PR gates; `enter_plan_mode` on failures/gaps.
- **Zero-Fallback:** `jev` (`TYPESAFE_API_KEY`) is mandatory; if unreachable, **STOP** and run `./scripts/harness-doctor.sh`.

## 2. Branch & Worktree Isolation
- Never edit/commit/merge/push on `main`, `master`, or `trunk` (`pre-edit-guard.sh` & `pre-command-guard.sh` deny).
- Switch to `superpowers:using-git-worktrees` or `feat/*`/`fix/*` before editing source/tests.

## 3. Dependency Version Governance (`dependency-versions` + `context7`)
- **Brownfield:** Read lockfiles/manifests & Spec `Global Constraints`; preserve locked major/minor versions.
- **Greenfield:** Verify latest stable, query `context7`, record in `Global Constraints`, run `stamp-gate.sh context7 --package "<pkg>" --version "<ver>" --source locked|greenfield-latest` before install.

## 4. Architectural Trade-Off Protocol (`architecture-tradeoffs`)
- Before finalizing Spec (`jev_check >= 0.65`), present **2–3 options** (pros/cons + YAGNI pick) in Spec `## Architectural Decisions (ADR)`.

## 5. Three-Part Domain Canon (`domain-canon`)
- **`docs/canon/glossary.md`:** Canonical English identifiers in Specs, Plans, code, docstrings; forbidden aliases block merge.
- **`docs/canon/flows.md`:** Preserve ordered step contracts/invariants unless approved.
- **`docs/canon/lessons.md`:** Pre-screen via `jev_triage`/`jev_ask` (`>= 0.50`); record non-obvious root causes only.

## 6. Proportionality, Scope Lock & Anti-Overengineering
- **Boundary Over Ceremony:** Keep deps inward (`Domain` free of outer/ORM/UI/SDK deps), no pass-through layers.
- **Rule of Three:** No single-use `IFooHelper`, `AbstractBase`, `Factory`, or speculative flags before 3 uses.
- **Scope Lock:** Declare Plan budget, abstraction rationale, `Out-of-Scope` (`jev_ask`), edit only `allowedFiles`, log extras in `docs/parking-lot.md` (`entropy-sweep`).

## 7. Hybrid `jev`, Gemini 4 / `Orchestrator` Routing & `run_workflow`
- **Tiers:** `invoke_subagent` & `run_workflow` `agent(model=...)` accept `inherit | flash_lite | flash | pro`. `Argon`, `3.8 Flash`, `GPT-OSS`, `Claude 4.6` retire `2026-11-30` (`SessionStart` warning).
- **Fixed:** `security-reviewer` -> `inherit`|`pro` (`MAX`); `pr-auditor` -> `inherit`|`pro` (`HIGH`/`XHIGH`/`MAX`, `Extra`->`XHIGH`); `browser` -> `flash`; `image-generator` -> pass-through.
- **Dynamic (`self`, `research`, `canon-auditor`, custom):** Score via `jev_classify`/`jev_score` (`>= 0.75`) and register `./scripts/stamp-gate.sh dispatch --role "<Role>" --type "<TypeName>" --tier "<tier>" [--effort LOW|MEDIUM|HIGH|XHIGH|MAX]`:
  - `trivial_lookup` -> `flash_lite` (`LOW`)
  - `bounded_execution` -> `inherit` (`Orchestrator`/Hydrogen/`frontier_low`/`claude_sonnet`), `pro` (Neon/Carbon/`claude_opus`/Argon/custom), else `flash` (`MEDIUM`/`XHIGH`)
  - `multi_module_integration` -> `pro` (`Orchestrator`/Hydrogen/`claude_sonnet`/`frontier_low`/Flash), `inherit` (`claude_opus`/Argon/custom, or Neon/Carbon if `Model: "inherit"`) (`HIGH`; `canon-auditor` floor)
  - `critical_architecture_or_audit` -> `inherit` (Neon/Carbon/`claude_opus`/Argon/custom) else `pro` (`Orchestrator` turns escalate to `pro`) (`MAX`)
- **`run_workflow` Guard:** `hooks.json` (`invoke_subagent|swarm|run_workflow`) blocks raw `subprocess`/`os.system`, embedded keys, and invalid `model=` tiers.

## 8. Context Window Shield (`run-quiet.sh` & `mobile-logs.sh`)
- Wrap noisy build/test/lint in `./scripts/run-quiet.sh <label> -- <cmd...>` (1-line summary; log `.harness/logs/last.log`).
- Replace `adb logcat` / `xcrun simctl ... log stream` with `./scripts/mobile-logs.sh --platform ios|android`.

## 9. Bilingual & Mandatory Glossary Standard
- **English Code:** Code, identifiers, docstrings (`XMLDoc`, `TSDoc`, `Swift DocC`, `KDoc`), and fitness checks (`REMEDIATION: ...`) MUST be English matching `docs/canon/glossary.md` (tests exempt).
- **Turkish Docs & Glossary:** User Markdown (`README.md`, Specs, Plans, `docs/walkthroughs/*.md`, `docs/canon/{flows,lessons}.md`) defaults to Turkish and MUST end with non-empty `## Teknik Terimler Sözlüğü` (`## Technical Glossary`) (`glossary.md` & `parking-lot.md` exempt).

## 10. CLI Reviews (`claude -p`/`agy -p`), Pre-PR, UI (`impeccable`) & Post-PR Gates
- **Spec/Plan & TDD Review (`stamp-gate.sh review`):** Run `./scripts/stamp-gate.sh review --kind spec-plan|tdd [--auto-stamp]` (`claude -p`). On `exit 42`, report `reason`, ask user, set `schedule(DurationSeconds=30, TimerCondition="any")`; run `--provider agy --model <id>` (`spec-plan`: `claude-opus-5-5-medium`/`gemini-4-carbon-high`; `tdd`: `claude-sonnet-5-5-high`/`gemini-4-neon-medium`).
- **Before `gh pr create` (`pre-pr-readiness`):** (1) Commit `docs/walkthroughs/YYYY-MM-DD-<topic>.md` (`>= 2` `mermaid`, `## Dosya Bazlı Değişiklik Analizi` for every diff file with *Ne* & *Neden*, + `## Teknik Terimler Sözlüğü`); (2) `canon-auditor` -> `stamp-gate.sh canon`; (3) `security-reviewer` -> `stamp-gate.sh security --verdict PASS --critical 0 --important 0`; (4) If code changed, `tdd-pass.json`; (5) If UI changed + `impeccable` installed, `stamp-gate.sh ui` -> `ui-pass.json` (`DO_NOT_TRACK=1`, `IMPECCABLE_LIVE_COPY_AGENT=chat|off`); (6) `stamp-gate.sh verify-pr-stamps` + clean `git status`.
- **After `gh pr create` (`review-pr`):** `stop-gate.sh` holds exit until `pr-auditor` completes 7-dimension audit and runs `stamp-gate.sh clear-pr-audit`.

## 11. Swarm Coordinator-Only, Worker/Integrator & Pure-Wait Quota Recovery
- **Coordinator-Only (Strict):** On `/swarm` or Swarm tasks, Coordinator ONLY coordinates (`swarm`, `post_message`, `read_board`, `swarm_wait`, `schedule`, `read_file`). Hooks physically block direct edits, builds/tests, git mutations, Walkthroughs, `gh pr create`, `invoke_subagent`, and `run_workflow`. Delegate ALL work to Swarm workers: `planner` (`jev_classify`/Spec/Plan), writers (`workspace: "share"`), `verifier`, and `integrator` (merge into `feat/*`, `pre-pr-readiness`, `gh pr create`, `pr-auditor`).
- **Swarm Worker:** Skip `jev_classify`, `brainstorming`, Spec, Walkthrough, `gh pr create`; run TDD, `context7`, `run-quiet.sh`, glossary/security in your branch, and send `docs/parking-lot.md`/`docs/canon/*` notes to `@coordinator`. (`integrator` runs PR/audit gates on `feat/*`.)
- **Pure-Wait Quota Recovery (5h / Weekly):** On quota exhaustion, NEVER kill workers or silently switch models (`force_ask` guard). Query `swarm(action="models")` (`quota_resets`), run `stamp-gate.sh swarm-quota pause`, wait via `schedule` (+ `Stop` `ERROR` -> `harness-daemon` `agy --conversation` watchdog), then `stamp-gate.sh swarm-quota resume` and `@mention` paused workers.
