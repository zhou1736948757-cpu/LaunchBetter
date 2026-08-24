# LaunchBetter Convergence — Evidence Bundle (baseline)

## Automated

| Check | Result |
| --- | --- |
| LaunchCore `swift test` | PASS — 188 tests |
| LaunchPlatform `swift test` | PASS — 149 tests |
| LaunchUI `swift test` | PASS — 387 tests |
| Xcode Debug build | PASS — `BUILD SUCCEEDED` |
| Xcode Release build | PASS — `BUILD SUCCEEDED` |
| Initial Git status | PASS — clean `main`, at `v0.5.4` |

## Runtime probes (fresh Release binary, pre-change)

| Probe | Result |
| --- | --- |
| `--iconbench` cold | PASS — 86 resolved, 1282.3 ms total, 14.91 ms/icon |
| `--iconbench` warm | PASS — 86 resolved, 4.7 ms total, 0.05 ms/icon |
| `--pagingprobe` | PASS — input 8, frames 57, scroll 36, skipped 21, settle 1, settle 748 ms |
| `--searchprobe` | PASS — query results 76, real icons 56/56, search rebuild on custom name +1 |
| `--gridtest 8 5 80` | PASS — 3 pages, capacity 40, UI-only search rebuild delta 0 |
| `--dragcacheprobe` | PASS — 20/50 frame probes keep preview/transform/overlay writes at 1 |
| `--perf` | PASS — 10 show/hide cycles; content-ready 10.0–136.2 ms in this run |
| LaunchUI Settings focused test | PASS — 25 tests |
| LaunchUI full suite after P0-03 | PASS — 390 tests / 60 suites |
| LaunchCore full suite after P0-04 | PASS — 200 tests / 16 suites |

## Read-only findings already confirmed

- Pre-change: `LauncherStore` exposed a single `displayRevision`; `catalogIndex` existed, but `iconContentVersion(for:)` and `moveToTrash(_:)` used `catalogSnapshot.app(with:)`. t4 replaced both with O(1) `catalogIndex` lookups; index rebuild sites are unchanged.
- Pre-change: `SettingsWindowController` hidden-row path called `handler.allApps.first { ... }`. t5 replaced it with a presentation-scoped map and added refresh/complexity tests; `SettingsHandling` protocol is unchanged.
- `AppCellView` eagerly constructs `FolderThumbnailView`; live folder requests use the regular `iconPointSize` path.
- Live and PageVisual folder geometry duplicate formulas; PageVisual folder request planning is separate from live-cell layout.
- `PageVisualKey` includes broad `displayRevision`; `PageVisualCache` has O(n) array LRU touches and byte estimate `width * height * 4`.
- `WallpaperProvider` owns IO/cache/rendering but creates `CIContext` in the render path and source selection is internal to the provider.
- Several UI cells independently implement generation/cancel/stale-result icon lifecycle.

## Architecture gate (t3, reviewer-minimax)

- PASS: P0-04/05 folder metrics and child sizing are bounded and behavior-compatible.
- MINOR: P0-02 catalogIndex replacement is a safe two-line O(1) correction.
- MAJOR: P0-03 hidden-row lookup is O(n²) across rows; use a presentation-scoped dictionary.
- MAJOR: P0-11 unconditional `LauncherStore.save` displayRevision bump needs a separate visual-config revision slice; not bundled into t4/t5.
- DEFER/NOTE: P0-06 eager folder thumbnail allocation lacks fresh evidence; P0-09/10 typed revisions and P0-08 ownership remain separate decisions.
- Test gaps called out: index parity, hidden lookup complexity/snapshot refresh, searchQuery didSet guard, per-domain revision behavior, and folder geometry.

## Missing evidence

- Fresh runtime request counts, PageVisual invalidation counts, slider-triggered snapshots, wallpaper cold/warm timings, MainActor p95, and physical gesture/120 Hz metrics. These require probes, Instruments, or `MANUAL_PHYSICAL_GATE`; do not fabricate.

## Post-P0 evidence (HEAD `5629e6f`)

| Check | Result |
| --- | --- |
| LaunchCore `swift test` | PASS — 200 tests / 16 suites |
| LaunchPlatform `swift test` | PASS — 149 tests / 23 suites |
| LaunchUI `swift test` | PASS — 394 tests / 61 suites |
| Xcode Debug build | PASS — `BUILD SUCCEEDED`, `CODE_SIGNING_ALLOWED=NO` |
| Xcode Release build | PASS — `BUILD SUCCEEDED`, `CODE_SIGNING_ALLOWED=NO` |
| Release `--iconbench` | PASS — cold 86 icons / 126.2 ms / 1.47 ms/icon; warm 0.9 ms / 0.01 ms/icon |
| Release `--pagingprobe` | PASS — input 8, frames 63, scroll 53, skipped 10, settle 1 / 745 ms |
| Release `--searchprobe` | PASS — 76 results, real icons 56/56, custom-name rebuild +1, restore OK |
| Release `--gridtest 8 5 80` | PASS — 3 pages, capacity 40, search rebuild delta 0, restore OK |
| Release `--dragcacheprobe` | PASS — preview/transform/overlay writes remain 1 at 20/50 frames |
| Release `--perf` | PASS — 10 show cycles; content-ready 4.7–60.9 ms in this run |
| Release `--smoke` | PASS — catalog 90 apps, 3 pages, 88 flat slots, search restore path OK |

### P0-11 source evidence

- `LauncherStore.save()` now computes `gridDataChanged` before persistence for exactly `gridColumns`, `gridRows`, `iconSize`, `hiddenAppIDs`, `customDisplayNames`, and `language`.
- `displayRevision` and `notifyDataChange()` are gated by `gridDataChanged`; `onConfigChange` and `onCustomSourcesChange` remain unconditional and callback order for grid changes is preserved.
- Existing `searchMetadataChanged`/`libraryInputsChanged` branches only rebuild indexes/models; they do not bump or notify, so hidden/custom-name/language remain in the grid gate.
- No app test target exists for direct `LauncherStore` unit coverage; package suites, Xcode builds, source assertions, and runtime probes provide the evidence instead.

## Post-P1 evidence (HEAD `7fdc1a3`)

| Check | Result |
| --- | --- |
| Focused `PageCompositorGridIntegrationTests` | PASS — 15 tests / 1 suite |
| LaunchUI full `swift test` | PASS — 395 tests / 61 suites |
| Xcode Debug build | PASS — `BUILD SUCCEEDED`, `CODE_SIGNING_ALLOWED=NO` |

### P1 decision and source evidence

- Read-only audits t27/t28 found no measurable icon lifecycle/cache optimization; request budgets are bounded, cancellation/stale-result guards are correct, and `PageVisualCache` is capped at three visuals. P0-06 lazy folder allocation, shared lifecycle helper, global request budget, dead icon invalidation API, and physical backing-scale behavior remain deferred.
- t28 identified a correctness boundary: external data revision refresh could replace the page model while a presentation-only compositor remained active during a swipe.
- `GridViewController.refresh()` now calls `shutdownPageCompositor()` after the display-revision change gate and before `applyLatestData()`. This is idempotent and leaves geometry/search-specific shutdown paths unchanged.
- The new regression starts an active compositor, increments the store revision, refreshes, and verifies compositor inactive, live layer revealed, no compositor layer frames, and a clip aligned to the current page.
- Wallpaper memory eviction, main-thread wallpaper source stat, and per-render `CIContext` reuse were explicitly deferred: each needs an ownership-safe design and dedicated measurement before changing behavior or platform boundaries.

## Final completion evidence (HEAD `7fdc1a3`)

| Check | Result |
| --- | --- |
| LaunchCore final `swift test` | PASS — 200 tests / 16 suites |
| LaunchPlatform final `swift test` | PASS — 149 tests / 23 suites |
| LaunchUI final `swift test` | PASS — 395 tests / 61 suites |
| Final Xcode Debug build | PASS — `BUILD SUCCEEDED`, `CODE_SIGNING_ALLOWED=NO` |
| Final Xcode Release build | PASS — `BUILD SUCCEEDED`, `CODE_SIGNING_ALLOWED=NO` |
| Final Release `--iconbench` | PASS — cold 86 icons / 116.9 ms / 1.36 ms/icon; warm 0.9 ms / 0.01 ms/icon |
| Final Release `--pagingprobe` | PASS — input 8, frames 66, scroll 54, skipped 12, settle 1 / 746 ms |
| Final Release `--searchprobe` | PASS — 76 results, real icons 56/56, custom-name rebuild +1, restore OK |
| Final Release `--gridtest 8 5 80` | PASS — 3 pages, capacity 40, search rebuild delta 0, restore OK |
| Final Release `--dragcacheprobe` | PASS — preview/transform/overlay writes remain 1 at 20/50 frames |
| Final Release `--perf` | PASS — 10 show cycles; content-ready 5.0–60.3 ms in this run |
| Final Release `--smoke` | PASS — catalog 90 apps, 3 pages, 88 flat slots, search restore path OK |
| Final `git diff --check` | PASS — no whitespace errors |

### P2/P3 gate receipts

- P2 t32/t33/t34: no code change justified; drag/press/placeholder/Store/actor boundaries remain coherent, backing-scale is `MANUAL_PHYSICAL_GATE`, and public zero-caller invalidation APIs are retained confirmation-first.
- P3 t35/t36: no deletion executed; before/after retirement is source-of-truth convergence rather than destructive cleanup. Remaining debt is explicitly listed above and below.
- Manual gates not claimed as automated: physical 120 Hz/trackpad behavior, real 1x↔2x display switching for Library/detail/settings, allocations, concurrent icon-request counts, and confirmation of external consumers of public invalidation APIs.
