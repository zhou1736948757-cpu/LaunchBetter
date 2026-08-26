# Decision: Fresh workflow start — archive Workflow一 (2026-08-26)

## Context

User instruction: rename the existing `Workflow/` folder to `Workflow一`,
rebuild a new `Workflow/` folder, and start workflow construction from zero.

## Resolution

1. `Workflow/` → `Workflow一/` (complete archive of the previous v1.3/v1.4 run:
   tasks T-001..T-012, results, reviews, decisions, config, manifest, STATE,
   events, PLAN, MAIN_BRIEF).
2. Legacy `.workflow/` merged into `Workflow一/` (all files already contained;
   only 3 files differed — config.json/manifest.json superseded legacy variants,
   results/T-007.md pre-correction variant documented in
   `Workflow一/ARCHIVE-NOTE.md`), then `.workflow/` removed per user choice.
3. New `Workflow/` initialized from scratch with `init_project_workflow.py`
   (v1.4 schema): models all `current-main-conversation` (session-default,
   routing unverified), `max_worker_concurrency` 3, `thinking_depth` high —
   reusing the user-approved configuration from the previous round
   (see `Workflow一/decisions/2026-08-26-reinit-v1.4.md`).
4. `AGENTS.md` managed section regenerated for the fresh run (history preserved).
   `MEMORY.md` runtime-config block preserved (values unchanged); project memory
   (verified facts, releases, invariants) untouched.

## Fresh-start artifact state

- `Workflow/STATE.json` — status `READY`, empty task ledger.
- `Workflow/PLAN.md` / `Workflow/MAIN_BRIEF.md` — placeholders pending Chief planning.
- `Workflow/events.jsonl` — empty until first event.
- `Workflow/tasks|results|reviews|decisions|review-bundles/` — empty.

## Semantics note

The previous run's conclusions (automated acceptance PASS, `MANUAL_PHYSICAL_GATE`
open for real-device trackpad/compositor validation) remain valid project facts
and are preserved in `MEMORY.md` and `Workflow一/`. They are not re-litigated by
the fresh run unless a new goal requires it.

## Status

Workflow `READY`. Next: user provides the next development goal → Chief Initial
Global Planning → PLAN.md + initial task packets.
