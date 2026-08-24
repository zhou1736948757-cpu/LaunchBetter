# LaunchBetter Convergence Phase 3 — Evidence

## Baseline

- Phase 2 final HEAD: `79ad4abbda144344f520cac66aca25bda1c27f02`
- Phase 3 baseline: LaunchUI **410 tests / 62 suites**, Debug + Release warning-free
- Phase 3 start: clean `main`, ahead 14 of origin
- Baseline verified: `swift test` 410/62, `swift build -c debug`, `swift build -c release`

## Architecture receipts

### P3-A PageVisual Ownership

- **Before**: `GridViewController` owns cache, renderer, compositor, paging, prepare/prewarm tasks, generations, memory-pressure source
- **After**: Same — no extraction needed
- **Review verdict**: PASS (architecture reviewer confirmed NO on `PageVisualCoordinator`)
- **Rationale**: `PageVisual` is a frozen immutable value with no independent lifecycle. `compositorCanActivate` reads 13 Grid-owned state inputs. A coordinator would re-import all of that — a second, leaky coordinator.
- **Test gaps filled**: 4 new tests (geometry, backing-scale, memory-pressure, drag-begin shutdown)
- **Commit**: `37b2795` (test gaps only; no production change)

### P3-C Window Ownership

- **Before**: `LauncherWindowController` owns background, settings, folder, input routing, search chrome, accessibility, diagnostics
- **After**: Same — no extraction needed
- **Review verdict**: PASS (reviewer confirmed NO on both `LauncherBackgroundController` and `SettingsOwnershipCoordinator`)
- **Rationale**: Background is a sub-effect of window lifecycle with no independent begin/active/invalidate/end. `interactionSurface` has 4 writers (settings, folder, library detail, grid surface); a coordinator would create two writers on shared state. Existing `SettingsOwnershipGate` is the correct extracted boundary.
- **Commit**: none (audit only)

### P3-F LauncherStore Catalog Refresh

- **Before**: `drainExternalCatalogRefreshes()` owns coalescing, generation re-check, retry/backoff, publish
- **After**: Same — no extraction needed
- **Review verdict**: PASS (reviewer confirmed NO on `CatalogRefreshCoordinator`)
- **Rationale**: Drain output is LauncherStore's own `@MainActor` snapshot/index/layout/publication state. Extraction would either move those fields (violating "current snapshots stay with LauncherStore") or create a callback helper (not independent). Stale-result protection already in `AppCatalogActor`, backoff in pure `RetryBackoff`, reconcile in `LayoutStore`.
- **Commit**: none (audit only)

### P3-I Publication Decoupling

- **Before**: `applyMetadataSnapshot` unconditionally `bumpRevision()` + `notifyDataChange()` — every launch usage and category override triggered full grid refresh + PageVisual shutdown/rebuild
- **After**: `applyMetadataSnapshot` calls `notifyLibraryDataChange()` (dataObservers only, no `displayRevision` bump, no grid `onDataChange`). Library live refresh decoupled via `GridViewController` dataObserver → `hostItem.refreshModel()`.
- **Review verdict**: Spec review PASS, Code-quality review PASS (REVISE → fixed)
- **Commit**: `71e3167`

### P3-K Comment Convergence

- **Before**: Two stale doc comments referenced old `bumpRevision + notify` path
- **After**: Comments updated to reflect `notifyLibraryDataChange` path
- **Commit**: `992e21a`

## Correctness

- LaunchUI: **417 tests / 64 suites** (baseline 410 + 7 new)
  - `PublicationDecouplingTests`: 3/3
  - `PageVisualLifecycleTests`: 4/4
  - All existing suites: 410/410 (no regression)
- LaunchCore: 200 tests / 16 suites
- LaunchPlatform: 149 tests / 23 suites
- Debug build: PASS
- Release build: PASS (warning-free)
- App target (`xcodebuild -scheme LaunchBetter -configuration Debug`): BUILD SUCCEEDED

## Complexity — responsibility change

| Component | Before | After |
|---|---|---|
| GridViewController | Sole PageVisual coordinator | Same; 4 test gaps filled |
| PageVisualCoordinator | N/A | Not created (Grid is correct sole owner) |
| LauncherWindowController | Background + Settings + Window lifecycle | Same (no independent extraction justified) |
| LauncherBackgroundController | N/A | Not created (no independent lifecycle) |
| SettingsOwnershipCoordinator | N/A | Not created (existing gate is correct boundary) |
| LauncherStore | All metadata changes bump displayRevision | Metadata-only changes use notifyLibraryDataChange (no grid bump) |
| CatalogRefreshCoordinator | N/A | Not created (Store is correct owner) |

Metrics:
- Old ownership paths deleted: 1 (`bumpRevision + notifyDataChange` in `applyMetadataSnapshot`)
- Duplicate lifecycle groups deleted: 0 (none found)
- New coordinators created: 0
- New callback boundaries: 1 (`notifyLibraryDataChange` private method + `GridViewController` dataObserver)
- New tests: 7 (3 publication decoupling + 4 page visual lifecycle)

## Runtime

- Package-level evidence: grade A (417/64, Debug, Release, app build)
- Physical/hardware gates: MANUAL_PHYSICAL_GATE (see Deferred)

## Deferred

### Physical gates (no hardware/operator in this context)

- 1x ↔ 2x display switching: requires physical display change
- 120Hz trackpad behavior: requires trackpad hardware
- Live accessibility-setting changes: requires System Settings interaction
- Top-level app runtime (show/hide/page/search/library/folder/settings/wallpaper/drag): requires GUI window-server session
- Current evidence: package tests + builds are grade A; hardware/top-level runtime is grade B/manual deferred
- Why deferred: non-interactive CLI agent context cannot provide these
- Exact trigger: human operator with access to the app and display hardware
- Future owner: manual QA / Instruments profiling

### Architectural defer basis (reviewed and rejected, not "不敢改")

- `PageVisualCoordinator`: rejected — Grid is already sole coordinator
- `LauncherBackgroundController`: rejected — no independent lifecycle
- `SettingsOwnershipCoordinator`: rejected — shared `interactionSurface` with 4 writers
- `CatalogRefreshCoordinator`: rejected — Store is correct owner of its own publication state
- Wallpaper request generation-counter hardening: low-severity, equality guard adequate
- Drain-loop direct tests: bounded test debt; underlying seams tested
- Duplicate notification on new-app discovery: split into grid (necessary) + Library-only (necessary) by P3-I fix; no longer over-broad

## Commit receipt

```
992e21a cleanup(store): converge stale metadata notification comments
37b2795 test(grid): cover page visual lifecycle gaps
71e3167 fix(store): decouple metadata-only publication from grid displayRevision
79ad4ab docs(aegis): record Phase 2 convergence evidence  (Phase 2 final, baseline)
```

Phase 3 commits: 3 (1 fix + 1 test + 1 cleanup)
Phase 3 audits: 4 read-only reports (PageVisual, Window, Store, Publication/Runtime)
Phase 3 architecture reviews: 5 (4 extraction verdicts + 1 publication fix spec + 1 publication fix quality + 1 test gap spec)