# Phase 3 — Reflection

## What Phase 3 set out to do

Phase 3 targeted three long-lived ownership complexity centers: `GridViewController` (PageVisual), `LauncherWindowController` (background/settings), and `LauncherStore` (catalog refresh orchestration). The goal was not to split large files, but to determine whether independent lifecycles, invalidation, resource ownership, and async workflows were already correctly owned or needed extraction.

## What actually happened

The audits produced a result that may seem counterintuitive: **zero new coordinators were created**. All four proposed extractions — PageVisualCoordinator, LauncherBackgroundController, SettingsOwnershipCoordinator, CatalogRefreshCoordinator — were reviewed and rejected with source evidence. The existing ownership boundaries were already correct:

- `GridViewController` is the sole coordinator of PageVisual state; splitting it would create a second coordinator that re-imports 13 Grid-owned state inputs.
- `LauncherWindowController` background is a sub-effect of window lifecycle, not an independent owner.
- `SettingsOwnershipGate` is already the correct extracted boundary for settings ownership.
- `LauncherStore.drainExternalCatalogRefreshes()` is the correct owner of catalog-refresh glue; its output is the store's own `@MainActor` state.

This is itself a convergence result: the architecture is healthier than the plan assumed. The audits proved that the existing decompositions (PageVisualRenderer/Cache/Compositor as leaf services, SettingsOwnershipGate as pure value type, RetryBackoff/LayoutReconciler as pure helpers) were already at the right boundaries.

## What was actually fixed

The one actionable finding was a **publication correctness issue** that the ownership audits surfaced: `applyMetadataSnapshot` unconditionally bumped `displayRevision` for Library-only metadata changes (launch usage, category override), triggering unnecessary full grid refreshes. This was a real waste — every app launch was causing a PageVisual shutdown/rebuild cycle — but it was invisible from the ownership perspective because it wasn't a duplication of owners; it was an over-broad publication from one owner.

The fix was minimal: a new `notifyLibraryDataChange()` that fires only `dataObservers`, plus a `GridViewController` dataObserver that calls `hostItem.refreshModel()`. The Library surface still updates live, but the grid no longer refreshes on every launch.

## What was learned

1. **Audit before extracting.** The Phase 3 plan assumed all three centers needed extraction. The audits proved none did. If we had extracted first and audited after, we would have created four callback-heavy wrapper classes with no ownership gain — exactly the anti-pattern the plan's STOP rules were designed to prevent.

2. **Publication is not ownership.** The over-broad `displayRevision` bump was a real waste, but it wasn't an ownership duplication. It was one owner publishing too broadly. The fix was to narrow the publication, not to extract a new owner.

3. **Test gaps are real debt.** The PageVisual audit identified four focused test gaps (geometry, scale, memory-pressure, drag-begin). These were not speculative — they were verified by the architecture reviewer as genuine coverage holes. Filling them with integration tests was proportional and valuable.

4. **"Not justified" is a valid result.** The plan explicitly allowed for this: "if Reviewer can prove extraction would create a second, leaky coordinator, STOP." All four extractions met this criterion. The Phase 3 work was proving the existing boundaries were correct, not creating new ones.

## Remaining debt

Phase 3 leaves no ownership debt. The four proposed coordinators were rejected with evidence, not deferred out of caution. The one publication fix was implemented and verified. The physical/hardware gates remain `MANUAL_PHYSICAL_GATE` — these require a human operator with display hardware, not architectural decisions.

The next phase, if any, should shift from "preventing architecture decay" to "measuring runtime performance with Instruments" — exactly as the user suggested. The architecture is now clean enough that further structural work without runtime measurement would be speculative.