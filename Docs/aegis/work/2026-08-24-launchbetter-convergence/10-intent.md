# LaunchBetter Convergence — Task Intent

## Aegis Visibility
This is a multi-phase architecture/performance workstream with subagents, review gates, possible context continuation, source-of-truth changes, and legacy retirement. Checkpoints and evidence are mandatory.

## Goal
Execute the user-approved Performance & Architecture Convergence prompt on `/Users/mac/Projects/LaunchBetter`, beginning at `main`/`v0.5.4`, while preserving user-visible behavior and reducing invalid work, duplicate ownership, and unnecessary MainActor work.

## Scope fence
- In scope: P0→P3 items from `Docs/Tasks/performance-architecture-convergence.md`.
- Out of scope: product redesign, SwiftUI rewrite, new package, global event bus, broad dependency upgrades, unrelated refactors, automatic tag/release/push, touching `/Users/mac/Projects/Launchpad_Back`.
- `AGENTS.md` has been read for this execution because the current request explicitly asks to complete the prompt; its architecture and Git rules are binding.

## BaselineReadSetHint
- `/Users/mac/Projects/LaunchBetter/AGENTS.md`
- `/Users/mac/Projects/LaunchBetter/MEMORY.md`
- `Docs/Architecture/0001-module-boundaries.md`
- `Docs/Architecture/0002-app-library-surface.md`
- `Docs/PhaseReports/phase-04-icon-pipeline.md`
- `Docs/PhaseReports/stage-02-interaction-performance.md`
- Current symbols in `LauncherStore`, `GridViewController`, `AppCellView`, `PageVisual*`, `WallpaperProvider`, `IconMemoryCache`, `IconRepository`, Settings hidden rows.

## TaskStartSnapshot
- Root: `/Users/mac/Projects/LaunchBetter`
- HEAD: `3f39124f92fa00202354d9448e2dab4088e1d43d` (`v0.5.4`)
- Branch: `main`, upstream `origin/main`, divergence `0/0`
- Initial worktree: clean
- Active Git operation: none
- Worktrees: main checkout plus `/Users/mac/orca/workspaces/LaunchBetter/siren` (separate checkout, do not touch)

## BaselineUsageDraft
- LaunchCore package tests: 188 tests passed.
- LaunchPlatform package tests: 149 tests passed.
- LaunchUI package tests: 387 tests passed.
- Xcode Debug build: `BUILD SUCCEEDED`.
- Xcode Release build: `BUILD SUCCEEDED`.
- No pre-change performance counters beyond existing project reports; physical 120 Hz/trackpad gates remain manual unless fresh evidence is collected.

## ImpactStatementDraft
Expected changes narrow internal performance/ownership paths only. Preserve Catalog/Layout/Config/IconRepository separation, paging single writer, stale generation protections, App Library semantic surface, Search restore, drag and settings behavior. Any deletion of legacy code is internal code retirement and must be justified by current call-site evidence; persistence/schema and user data remain confirmation-sensitive.

## Stop conditions
Stop and ask the user for a Major Decision Gate if a product behavior changes, a persistence migration/data deletion is required, an external contract cannot be observed safely, unrelated dirty work appears, or a task requires a new package/global abstraction.
