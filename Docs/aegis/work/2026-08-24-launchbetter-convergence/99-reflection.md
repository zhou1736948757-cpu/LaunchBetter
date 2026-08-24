# LaunchBetter Convergence — Final Reflection / Before→After

## Scope and gate

- Scope executed: P0→P3 of `Docs/Tasks/performance-architecture-convergence.md` on `/Users/mac/Projects/LaunchBetter`.
- Final source HEAD before documentation commit: `7fdc1a3`.
- `/Users/mac/orca/workspaces/LaunchBetter/siren` and `/Users/mac/Projects/Launchpad_Back` were not touched.
- No persistence/schema migration, product redesign, new package, global bus, broad actorization, or SwiftUI rewrite was introduced.

## Before → After

| Area | Before | After | Evidence / result |
| --- | --- | --- | --- |
| Catalog lookup | `catalogSnapshot.app(with:)` linear scans in two hot lookups | `catalogIndex[appID]` O(1), same fallback semantics | `20740f6`; package tests/builds/probes green |
| Settings hidden rows | Per-row `allApps.first` scan, O(n²) across rows | Presentation-scoped ordered snapshot + O(1) name map | `3de4cd8`; focused 25 tests and full LaunchUI coverage |
| Folder geometry | Live and PageVisual formulas diverged | `FolderThumbnailMetrics` pure LaunchCore contract shared by both consumers | `7f026d5`, `e8d5585`; geometry/wiring tests |
| Folder child icon work | Child requests used full icon size | Requests use metrics-derived floor-sized child point size; app requests unchanged | `e8d5585`; request/frame/raster extent tests |
| Display invalidation | Every successful `LauncherStore.save()` bumped broad `displayRevision` and notified grid observers | Revision/notify gate is exactly grid-visible `{gridColumns, gridRows, iconSize, hiddenAppIDs, customDisplayNames, language}`; immediate config callbacks remain unconditional | `5629e6f`; grid/search/runtime probes |
| Page compositor data refresh | External data revision could replace model while compositor remained active during a swipe | `GridViewController.refresh()` shuts down presentation-only compositor before `applyLatestData()` | `7fdc1a3`; new active-compositor refresh regression + 15-test focused suite |
| Ownership | Existing separate Catalog/Layout/Config/Icon/interaction pipelines | Boundaries preserved; P2 audit found no safe need for new façade/actor/global owner | t27/t28/t32/t33/t34 audits |
| Legacy paths | Candidate dead public invalidation APIs and diagnostic-only paths existed | No unsafe deletion; public zero-caller APIs retained under confirmation-first compatibility gate | t35/t36 anti-entropy audit |

## Performance / correctness receipts

- Final package tests: LaunchCore 200/16 suites; LaunchPlatform 149/23 suites; LaunchUI 395/61 suites.
- Final Xcode Debug and Release builds: `BUILD SUCCEEDED` with `CODE_SIGNING_ALLOWED=NO`.
- Final Release probes: iconbench cold 1.36 ms/icon and warm 0.01 ms/icon; paging 8 inputs/66 frames/12 skipped/1 settle; search 76 results and 56/56 real icons; grid 3 pages/capacity 40/UI-only search rebuild delta 0; drag cache writes stable at 1 through 50 frames; show/hide content-ready 5.0–60.3 ms; smoke catalog 90 apps/3 pages/88 slots.
- No performance claim is made for physical 120 Hz, trackpad feel, real 1x↔2x switching, allocation cost, or concurrent request ceilings.

## Retained debt / manual gates

1. `P0-06` lazy `FolderThumbnailView` allocation: requires Instruments/allocation evidence.
2. Three other icon-cell scale re-request paths: requires real display-scale switch (`MANUAL_PHYSICAL_GATE`).
3. Icon lifecycle helper, global request budget, PageVisual LRU/byte accounting: no measured benefit; deferred.
4. Wallpaper memory bound, main-thread source identity stat, and shared `CIContext`: require ownership-safe design plus timing/allocation evidence.
5. `WallpaperProvider.invalidate()` and `IconRepository.invalidate(appID:)`: zero app production callers, but public package APIs/tests make deletion confirmation-first. No deletion was executed.
6. Physical 120 Hz/trackpad gate remains manual.

## Git / safety receipt

- Atomic source commits: `20740f6`, `7f026d5`, `e8d5585`, `3de4cd8`, `5629e6f`, `7fdc1a3`.
- Documentation/evidence is intentionally committed separately from source.
- Final source changes were limited to the reviewed slices; no unrelated dirty source appeared.
- `git diff --check` passed before final documentation commit.
