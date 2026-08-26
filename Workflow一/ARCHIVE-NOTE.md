# Archive note — merge of legacy .workflow/ (2026-08-26)

## Context

User requested a fresh workflow start: `Workflow/` renamed to `Workflow一`
(archive), legacy `.workflow/` merged and removed, new `Workflow/` initialized
from scratch.

## Merge verification

`.workflow/` file set is a strict subset of `Workflow一/`. `cp -Rn` merge +
per-file `cmp` check found 3 differing files:

| File | .workflow (legacy) | Workflow一 (kept) | Verdict |
|---|---|---|---|
| `config.json` | v1.1 schema, 537 B (identical to pre-reinit Workflow config) | v1.4 reconfigured | superseded, no loss |
| `manifest.json` | v1.1, artifact_root `.workflow` | v1.4, role_assignments updated | superseded, no loss |
| `results/T-007.md` | pre-correction variant (LaunchUI 459, per MEMORY work log 2026-08-25T23:38:50) | final corrected variant (LaunchUI 467, references T-012-r2 PASS) | final kept; see below |

## T-007.md pre-correction variant

The pre-correction T-007 content is preserved in `MEMORY.md` work log:

- Action: Completed final package verification.
- Result: LaunchCore 200, LaunchUI 459, LaunchPlatform 149; diff check clean.
- Next: Workflow complete with physical gate open.
- Later corrected to 467 (T-008..T-012 evidence) — see the kept
  `results/T-007.md` ("已纠正") and `reviews/T-012-r2.md`.

No other content differed; all other `.workflow/` files were byte-identical to
their `Workflow一/` counterparts.

## Aftermath

- `.workflow/` removed (fully redundant after merge).
- `Workflow一/` retains the complete T-001..T-012 run artifacts (tasks, results,
  reviews, decisions, config, manifest, STATE, events, PLAN, MAIN_BRIEF).
- New `Workflow/` initialized fresh at v1.4 — see
  `Workflow/decisions/2026-08-26-fresh-start.md`.
