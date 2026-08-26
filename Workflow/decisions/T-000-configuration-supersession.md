# Decision: T-000 initial model configuration superseded (2026-08-26)

## Context

`Workflow/tasks/T-000.md` acceptance criterion 1 was written at packet-creation
time with placeholder values: models `current-main-conversation` for
main/chief/worker/reviewer, `max_worker_concurrency` 3, `thinking_depth` high.
Those values described the pre-configuration default. After the mandatory
first-run setup, the user answered the six configuration questions and the
confirmed configuration was recorded and persisted. The confirmed values
therefore supersede the T-000 initial acceptance condition.

## Superseding configuration (user-confirmed)

- Decision record: `Workflow/decisions/2026-08-26-model-configuration.md`
  (user answered the six mandatory configuration questions on 2026-08-26).
- Persisted in: `Workflow/config.json` (`configured_at:
  2026-08-26T13:48:33+09:00`, schema v1.4).
- Actual values:
  - main = `current-main-conversation` (unchanged; skill rule fixes Main to the
    current conversation)
  - chief = `ollama/glm-5.2`
  - worker = `ollama/deepseek-v4-flash:0731`
  - reviewer = `ollama/minimax-m2.7`
  - `max_worker_concurrency` = `2`
  - `thinking_depth` = `max`

## Scope

- Supersedes only T-000 acceptance criterion 1 (role model configuration).
  The `Workflow/tasks/T-000.md` original packet is **not rewritten**.
- All other T-000 initialization acceptance criteria (2–7: manifest v1.4,
  STATE READY, PLAN.md/MAIN_BRIEF.md placeholders, AGENTS.md managed section,
  MEMORY.md runtime-config consistency, legacy archive to `Workflow一/`) are
  unaffected and remain as accepted.
- Consistency evidence: `Workflow/events.jsonl` sequence 2
  (`decision_recorded`, 2026-08-26T13:48:47+09:00) and `Workflow/STATE.json`
  T-000 status `PASSED` (reconciled by T-014).
