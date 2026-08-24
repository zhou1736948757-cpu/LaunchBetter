# LaunchBetter Phase 3 — Read-Only Change-Publication Matrix & Runtime/Manual-Gate Audit

> **Task**: P3-I / P3-J read-only audit. Baseline HEAD `79ad4abbda144344f520cac66aca25bda1c27f02`, clean `main` (ahead 14 of origin). No production source or Git was edited. The only file created is this document.
> **Method**: source trace of every writer → affected surface → revision/gate → invalidation/publication, then a Phase 2 baseline probe inventory, a Phase 3 focused regression matrix, and an explicit `[DEFER BASIS]` for every measurement/manual gate. No execution of physical/hardware/top-level gates is claimed.

---

## 0. Scope, baseline, and invariants

- **Baseline**: Phase 2 final HEAD `79ad4abb`; LaunchUI `410 tests / 62 suites`; Debug and Release builds warning-free (per `10-intent.md` / `20-checkpoint.md`).
- **Read-only boundary**: this audit only reads source and writes this one document. No `swift test`, no `swift build`, no app launch, no Git mutation.
- **Ownership invariants held by the current code** (verified by trace):
  - `PagingInteractionController` is the only interactive paging motion writer (`GridViewController.paging`; `paging.jumpTo` is the sole clip-offset writer).
  - Semantic page truth stays with `GridViewController` (`currentSurface` / `surfaceBeforeSearch`).
  - Current snapshots stay with `LauncherStore` (`catalogSnapshot` / `layout` / `config` / `metadataSnapshot`).
  - `PageVisualRenderer` receives frozen inputs; async generation/cancellation rejects stale results (`performWorkingSetPrepare` re-verifies `store.displayRevision == capturedRevision` and `Self.languageRevision() == languageRevision` before insert).
  - Window receives actual screen/geometry context (`updateChromeLayoutForCurrentScreen`, `updateBackground(for:)` uses `window.screen` / `window.backingScaleFactor`), not `NSScreen.main` guessing — except the known deferred `currentBackingScale` fallback (see §4).

---

## 1. Change-publication matrix

Legend — **Surfaces**: `Grid` = `GridViewController` display model / diffable snapshot; `PageVisual` = `PageVisualCache`/`PageVisualRenderer`/`PageCompositor`; `Library` = `AppLibraryModel` (host + detail); `Background` = `WallpaperProvider`; `Activation` = `GlobalHotkey`/`HotCornerMonitor`/gesture; `Search` = `SearchIndex`; `LoginItem` = `SMAppService`.
**Verdict**: `NEC` = publication necessary; `NARROW` = correctly narrow (no grid/displayRevision bump); `OVER` = over-broad (publication reaches a surface that does not consume the change).

| # | Change | Writer(s) | Affected surfaces | Revision / gate | Invalidation / publication | Verdict |
|---|--------|-----------|------------------|-----------------|----------------------------|---------|
| 1 | **Catalog add/remove** | `AppCatalogActor` (FSEvents) → `LauncherStore.catalogDidChangeExternally` → `drainExternalCatalogRefreshes`; `applySnapshot`; `reconcileInBackground`; `bootstrap` | Grid, PageVisual, Library, Search | `bumpRevision()` + `notifyDataChange()`; `applySnapshot` short-circuits on equal snapshot (H2) | `GridViewController.refresh()` → `shutdownPageCompositor()` + `applyLatestData()` + `schedulePageVisualPrepare()`; PageVisual key carries `displayRevision` → implicit invalidation; `recordDiscovered` → `applyMetadataSnapshot` → `libraryModelDirty` | **NEC** — catalog legitimately changes grid, search, and Library |
| 2 | **Layout** (reorder / folder create/rename/dissolve / drag-drop) | `LayoutStore` (actor) via `performSerializedLayoutChange` → `commitLayoutChange` | Grid, PageVisual, Library (page-1 fallback) | `layoutMutationInFlight` serialization; `commitLayoutChange` → `bumpRevision()` + `notifyDataChange()`; `searchMetadataChanged=false` for reorder/folder | Same refresh path as #1; folder payload reload is identity-stable (`lastAppliedFolderPayloads`) | **NEC** |
| 3 | **Hidden app** | `LauncherStore.setHidden` → `save(newConfig)` | Grid, Library | `gridDataChanged` includes `hiddenAppIDs` → `bumpRevision()` + `notifyDataChange()`; `libraryInputsChanged` includes `hiddenAppIDs` → `rebuildLibraryModel()` | Grid re-filters display model; Library rebuilds; **Search index NOT rebuilt** (`searchMetadataChanged` = custom names + language only) — consistent because `searchResults()` does not filter hidden | **NEC** (grid + Library); search correctly untouched |
| 4 | **Custom name** | `LauncherStore.setCustomName` → `save` | Grid, PageVisual, Library, Search | `searchMetadataChanged` (customDisplayNames) → `rebuildSearchIndex()`; `libraryInputsChanged` → `rebuildLibraryModel()`; `gridDataChanged` → `bumpRevision()` + `notifyDataChange()` | PageVisual key carries `displayRevision` → implicit invalidation; `GridViewController.refresh()` reloads labels | **NEC** |
| 5 | **Language** | `LauncherStore.save` (`config.language`) + `L10n.configure` | Grid, PageVisual, Library, Search, Settings | `searchMetadataChanged` (language) → `rebuildSearchIndex()`; `libraryInputsChanged` → `rebuildLibraryModel()`; `gridDataChanged` (language) → `bumpRevision()` + `notifyDataChange()`; `onConfigChange` → `reapplyVisualConfig()` | PageVisual key carries `languageRevision` → implicit invalidation; `GridViewController.refresh()` does `reloadData()` when `L10n.currentLanguage` changed; `SettingsWindowController.commit` → `rebuildLocalizedContentPreservingState` | **NEC** |
| 6 | **Icon size** | `LauncherStore.save` (`config.iconSize`) | Grid, PageVisual, icon requests | `gridDataChanged` (iconSize) → `bumpRevision()` + `notifyDataChange()`; `GridViewController.refresh()` detects `iconSize != layout.iconSize` → `applyGeometryConfig` | `applyGeometryConfig` rebuilds layout geometry + `forceRefresh()` + `reloadData()`; PageVisual geometry signature changes → implicit invalidation | **NEC** |
| 7 | **Wallpaper blur** | `LauncherStore.save` (`config.wallpaperBlurRadius`) | Background | **NOT in `gridDataChanged`**; `onConfigChange` → `reapplyVisualConfig()` → `updateBackground(for:)` | `RenderRequest.blurRadius` → `NormalizedRenderRequest.blurRadius` → cache key changes → implicit invalidation; no `displayRevision` bump, no grid notify | **NARROW** — correctly routed to the background immediate-effect path, not the grid |
| 8 | **Launch usage** | `LauncherStore.launch` → `NSWorkspace.open` → `metadataStore.recordLaunch` → `applyMetadataSnapshot` | Library (Recently Added / usage ordering) | `applyMetadataSnapshot` → `libraryModelDirty` + `bumpRevision()` + `notifyDataChange()` | Library model rebuild is necessary; **grid `displayRevision` bump + `notifyDataChange` reaches a surface that does not consume usage** (`DisplayModel(catalog:layout:config:)` has no usage input) | **OVER** — Library rebuild NEC, grid refresh over-broad |
| 9 | **Category override** | `LauncherStore.setCategoryOverride` / `clearCategoryOverride` → `metadataStore` → `applyMetadataSnapshot` | Library (classification) | Same `applyMetadataSnapshot` → `libraryModelDirty` + `bumpRevision()` + `notifyDataChange()` | Library rebuild NEC; grid refresh over-broad (grid does not consume `categoryOverrides`) | **OVER** — Library NEC, grid refresh over-broad |
| 10 | **Hotkey** | `LauncherStore.save` (`config.hotkey`) → `onConfigChange` → `ActivationCoordinator.reconfigure` | Activation | **NOT in `gridDataChanged`**; `onConfigChange` unconditional | `GlobalHotkey.stop()`/`start()`; no grid/displayRevision | **NARROW** |
| 11 | **Hot corner** | `LauncherStore.save` (`config.hotCorner`) → `onConfigChange` → `reconfigureHotCorners` | Activation | **NOT in `gridDataChanged`**; `onConfigChange` unconditional | `HotCornerMonitor` stop/recreate; no grid/displayRevision | **NARROW** |
| 12 | **Launch-at-login** | `SettingsWindowController.commit` → `loginItem.apply`; `DependencyContainer` startup `Task` | LoginItem | **NOT in `gridDataChanged`**; direct `loginItem.apply(config.launchAtLogin)` in `commit()` | `SMAppService` register/unregister; no grid/displayRevision | **NARROW** |
| 13 | **Search query** | `LauncherStore.searchQuery` `didSet` (bump only if changed) | Grid (search mode), Search | `searchQuery` `didSet` → `bumpRevision()` + `notifyDataChange()` | `GridViewController.refresh()` → `applyLatestData()` → `enterSearchMode`/`exitSearchMode`; `surfaceBeforeSearch` restore | **NEC** |
| 14 | **Display / geometry / scale** | window screen change, `backingScaleFactor`, content insets (`setContentInsets`), `updateChromeLayoutForCurrentScreen` | Grid, PageVisual, Background, chrome | PageVisual key carries `backingScale` + `geometry`; `setContentInsets` → `schedulePageVisualPrepare`; `updateBackground` uses `window.backingScaleFactor` | PageVisual implicit invalidation on scale/geometry; wallpaper cache key carries scale; `lastCompositorBackingScale` tracks scale | **NEC** (see §4 for the deferred `NSScreen.main` fallback) |
| 15 | **Memory pressure** | `DispatchSourceMemoryPressure` → `GridViewController.purgePageVisuals` | PageVisual | `memoryPressureSource` (registered in `loadView`) → `purgePageVisuals()` → `pageVisualCache.removeAll()` | Purge only; **no revision bump, no grid notify** | **NARROW** — correctly scoped to the visual cache |

### 1.1 Key findings from the matrix

- **The single `displayRevision` is the coarse grid-visible gate.** `LauncherStore.save` computes `gridDataChanged` for exactly `gridColumns`, `gridRows`, `iconSize`, `hiddenAppIDs`, `customDisplayNames`, `language`; only those bump `displayRevision` + `notifyDataChange`. Wallpaper blur, hotkey, hot corner, launch-at-login, and custom sources are correctly excluded (they ride `onConfigChange` / `onCustomSourcesChange` / direct side-effect paths). This is the Phase 1 P0-11 narrowing and it is intact.
- **Two over-broad publications reach the grid**: launch usage (#8) and category override (#9) both funnel through `applyMetadataSnapshot`, which unconditionally `bumpRevision()` + `notifyDataChange()`. The grid display model does not consume usage or category overrides, so each launch/override triggers a full grid refresh + PageVisual prepare that is not needed. The Library model rebuild (`libraryModelDirty`) is the necessary part. **This is the primary Phase 3 publication target**: split the Library-only metadata publication from the grid-visible revision gate (a bounded owner in `LauncherStore`), without touching the `applyMetadataSnapshot` idempotency or the `recordDiscovered` catalog path.
- **PageVisual invalidation is key-driven, not explicit.** `PageVisualKey(pageIndex, displayRevision, geometry, backingScale, languageRevision, iconEpoch)` means any grid-visible change implicitly invalidates by key miss; `purgePageVisuals()` is reserved for hide / memory pressure / scale / structure. This is the correct "implicit invalidation" model and should be preserved by any Phase 3 PageVisual ownership change.
- **`onConfigChange` is unconditional and is the correct immediate-effect bus** for hotkey/hot-corner/language/wallpaper/search-bar. It is wired once in `DependencyContainer` (`activation.reconfigure` + `windowController.reapplyVisualConfig`). Phase 3 Background/Settings ownership must keep this single wiring point.

---

## 2. Phase 2 baseline probes — inventory

### 2.1 App-level runtime probes (`LaunchBetterApp/Diagnostics/DiagnosticRunner.swift` dispatch)

| Flag | Probe | Coverage | Relevant to Phase 3 |
|------|-------|----------|---------------------|
| `--smoke` | `SmokeProbe` | catalog count, layout pages/flatSlots/capacity, search restore, window visibility; `--dragtest` sub-mode (programmatic begin/update/end drag, unique-layout assertion); `--folders` sub-mode (`FolderProbe`); `--launchtest` real-launch guard | Grid, Store, drag, **top-level launch path** |
| `--perf` | `runPerf` | 10 show/hide cycles, real event-loop timing; `PERF wallpaperReadyMs` | Background, show/hide |
| `--pagingprobe` | `PagingProbe` | synthetic swipe + momentum; momentum-ignored assertion; settle to page 1 | Paging, PageVisual |
| `--pagingeventtrace` | `PagingEventTraceProbe` | per-event trace to `/tmp/lb-paging-eventtrace.log` | Paging |
| `--pagecompositor` | `PageCompositorProbe` | A/B telemetry; compositor activation, clip sync, live reveal, no residue | **PageVisual / PageCompositor** |
| `--pagingstressprobe` | `PagingStressProbe` | 500-round Library↔Page1 stress, 7 gesture patterns, invariant assertions | Paging, Library surface |
| `--pagingscrollprobe` | `PagingScrollProbe` | per-frame wall-clock timing (Library + Page1), 120Hz synthetic drive | Paging perf |
| `--searchprobe` | `SearchProbe` | search overflow, real-icon parity, custom-name search-index rebuild, restore | Search, Store |
| `--gridtest` | `GridProbe` | settings columns/rows/iconSize → layout/capacity/icon-request follow; UI-only config does not rebuild search index | **Grid, Store config gate** |
| `--dragcacheprobe` | `DragProbe` | same-destination 20/50-frame preview/transform write stability | Drag cache |
| `--iconbench` | `IconProbe` | icon cold/warm resolution timing | Icon pipeline |
| `--layoutdiag` | `LayoutProbe` | layout diagnostics | Grid |
| `--hotcornerdiag` | `HotCornerProbe` | hot-corner config + monitor + mouse corner | Activation |
| `--settingsshot` | `SettingsShotProbe` | settings window layer-render PNG | Settings |
| `--settingsownershipprobe` | `SettingsOwnershipProbe` | settings interaction ownership: surface transitions, three-finger/root-drag blocked, outside-click close, drag cancel on open | **Settings ownership** |
| `--libraryshot` | `AppLibraryShotProbe` | Library top/mid/detail/search/settings visual evidence (layer render) | Library |
| `--libraryblanktrace` | `LibraryBlankTraceProbe` | blank-click per-session trace | Library |
| `--libraryinteracttrace` | `LibraryInteractionProbe` | first-event-after-entry activation-click consumption | Library |
| `--threefingerdiag` | `ThreeFingerProbe` | three-finger drag diagnostics | Activation |
| `--touchdebug` / `--touchwatch` | inline | gesture engine status + raw touch frames | Activation |
| `--screenshot` | `captureScreenshot` | self-rendered window PNG (no screen-recording permission) | Visual evidence |
| `--sourcesprobe` | `SourcesProbe` | custom source directories | Store |
| `--showstay` | inline | keep launcher visible for external `screencapture`; `--search-mode`/`--settings`/`--folder-mode`/`--hover-settings` | Visual evidence |
| `--setlang` | `AppDelegate` | persist language via app's own encoding path | Store, L10n |

### 2.2 Test-suite runtime/measurement probes (LaunchUI)

| Probe | Coverage |
|-------|----------|
| `MotionDiagnosticsProbe` | pure lifecycle-only motion diagnostic (launcher/folder/settings transition ownership, stale-rejection, completion-once) — **not** live accessibility |
| `SettingsSliderMeasureProbe` | slider frames + grid geometry across languages |
| `SnapshotIndexMeasurementTests` (A4) | O(N) snapshot index cost during drag (`flatIndex`/`indexPath`) |
| `PA1FrameBudgetTests` | page-dot incremental update, adjacent-page prewarm dedup |

### 2.3 Top-level app launch path

- **Real launch**: `LauncherStore.launch(_:)` → `NSWorkspace.shared.open(record.url)` → on success `metadataStore.recordLaunch` → `applyMetadataSnapshot`. This is the single Library-usage record entry point (shared by main grid and Library).
- **Probe-gated real launch**: `SmokeProbe.finishSmoke` only calls `store.launch` when `--launchtest` is present; otherwise prints `SMOKE launch=SKIPPED (no --launchtest)`. This is the only top-level launch path exercised by a probe, and it is explicitly guarded to avoid test side effects.

---

## 3. Phase 3 focused regression matrix

Phase 3 scope (per `10-intent.md`): converge long-lived ownership in `GridViewController`, `LauncherWindowController`, `LauncherStore` — PageVisual ownership first, then Grid, Background/Settings, Store catalog orchestration. The matrix maps each planned ownership area to existing coverage and the gaps the Phase 3 focused tests must close.

| Phase 3 area | Files in scope | Existing coverage (tests) | Existing coverage (runtime probes) | Focused regression to add / keep |
|--------------|----------------|---------------------------|-------------------------------------|----------------------------------|
| **PageVisual ownership** | `PageVisualCache`, `PageVisualRenderer`, `PageCompositor`, `GridViewController` (prepare/activate/finalize) | `PageVisualCacheTests`, `PageVisualRendererTests`, `PageCompositorTests`, `PageCompositorGridIntegrationTests`, `MemoryPressurePurgeTests`, `PA1FrameBudgetTests`, `PagingDisplayLinkLifecycleTests` | `--pagecompositor`, `--pagingprobe`, `--pagingstressprobe`, `--pagingscrollprobe` | Keep key-driven implicit invalidation; keep stale-result re-verify (`displayRevision`/`languageRevision`); keep `shutdownPageCompositor` on every structure/scale/hide path; keep `purgePageVisuals` on memory pressure |
| **Grid convergence** | `GridViewController` (refresh/applyLatestData/applyGeometryConfig), `PagingGridLayout`, `DragController` | `PagedGridFitTests`, `PagingGridLayoutQueryTests`, `LeadingSurfaceLayoutTests`, `AppLibrarySurfaceNavigationTests`, `GridDragCacheTests`, `DragHotPathTests`, `DragFrameIsolationTests`, `SearchPageRestoreTests` | `--gridtest`, `--smoke`, `--dragcacheprobe`, `--searchprobe` | Keep revision-skip (`lastAppliedRevision`); keep `applyGeometryConfig` full rebuild; keep `surfaceBeforeSearch` restore; keep drag invalidation on display change |
| **Background ownership** | `WallpaperProvider`, `LauncherWindowController.updateBackground` | `WallpaperProviderTests` | `--perf` (`wallpaperReadyMs`), `--showstay` | Keep `NormalizedRenderRequest` (origin-insensitive) cache identity; keep `CIContext` reuse; keep `onConfigChange → reapplyVisualConfig` single wiring |
| **Settings ownership** | `SettingsWindowController`, `SettingsTransitionCoordinator`, `LauncherWindowController` (settings surface) | `SettingsWindowControllerTests`, `SettingsTransitionTests`, `SettingsAccessibilityTests`, `SettingsHiddenAppPickerTests`, `SettingsSliderLoginItemTests`, `SettingsSliderMeasureProbe` | `--settingsownershipprobe`, `--settingsshot` | Keep settings surface ownership (three-finger/root-drag blocked, outside-click close, drag cancel on open); keep `commit()` single save path |
| **Store catalog orchestration** | `LauncherStore` (`save`, `applyMetadataSnapshot`, `drainExternalCatalogRefreshes`, `commitLayoutChange`) | no direct app test target; package suites + probes | `--smoke`, `--searchprobe`, `--gridtest`, `--sourcesprobe` | **Primary target**: split Library-only metadata publication (launch usage #8, category override #9) from the grid-visible `displayRevision` gate; keep `applySnapshot` H2 short-circuit; keep `layoutMutationInFlight` serialization; keep `searchMetadataChanged`/`libraryInputsChanged`/`gridDataChanged` separation |

---

## 4. `[DEFER BASIS]` — measurement and manual gates

The following are **not claimed as executed** in this worktree. Each is a retained manual/physical gate with an explicit basis for why it cannot be run here.

### 4.1 Physical 1x↔2x display switching — `MANUAL_PHYSICAL_GATE`
- **Cannot run here because**: it requires a human operator to physically change display scaling in System Settings (or move the launcher window between displays with different `backingScaleFactor`) and observe the live launcher/Library/detail/settings. This agent context is a non-interactive CLI session (`DISPLAY` empty, no screen-recording/accessibility permission, no human operator). The existing probes (`GridProbe`, `PageVisualRendererTests`, `PageVisualCacheTests`) exercise **synthetic** backing scales only; they do not drive a real display switch.
- **Deferred basis**: `GridViewController.currentBackingScale` still falls back to `NSScreen.main?.backingScaleFactor` when `view.window` is nil (Phase 2 deferred item). Any Phase 3 change to scale handling must not alter this fallback policy without hardware evidence.

### 4.2 120Hz trackpad interaction — `MANUAL_PHYSICAL_GATE`
- **Cannot run here because**: it requires a physical trackpad with 120Hz polling and a real user's finger gestures (three-finger drag, pinch, momentum). The probes (`PagingProbe`, `PagingScrollProbe`, `PageCompositorProbe`, `PagingStressProbe`) synthesize `CGEvent` scroll events at a 120Hz cadence; synthetic events are not equivalent to real trackpad hardware input and cannot validate physical 120Hz behavior.

### 4.3 Live accessibility-settings switching — `MANUAL_PHYSICAL_GATE`
- **Cannot run here because**: it requires a human to toggle Reduce Motion / Reduce Transparency / Increase Contrast in System Settings while the launcher/detail is presented and observe the live effect. `MotionDiagnosticsProbe` is a **pure lifecycle model** (it does not instantiate AppKit coordinators and does not read live accessibility state); `AccessibilityDisplayObserver` observes these settings but the agent cannot toggle System Settings and observe the live UI. The Phase 2 deferred item (live Reduce Motion change while a detail is already presented) remains open.

### 4.4 Top-level application runtime — `MANUAL_PHYSICAL_GATE`
- **Cannot run here because**: running the actual `LaunchBetter.app` as a top-level application requires a GUI window-server session, accessibility/input-monitoring permissions (for gesture capture), and an interactive launch. This is a read-only audit; launching the app would be a side-effecting interactive session and is out of scope. Package tests and in-process diagnostic probes do not constitute a top-level app runtime session. The only real-launch path (`SmokeProbe --launchtest`) is guarded and was not invoked.

### 4.5 Measurement gates (deferred, need dedicated probes/Instruments)
- Wallpaper warm-cache source-stat cost and render allocation cost (Phase 2 reflection "next most valuable verification").
- MainActor p95, PageVisual invalidation counts, slider-triggered snapshot counts, concurrent icon-request counts.
- These require dedicated probes or Instruments and are not claimed from package tests alone.

---

## 5. DONE — source/test references

**Primary publication gate**: `LaunchBetterApp/LauncherStore.swift` — `save(_:)` (`gridDataChanged`/`searchMetadataChanged`/`libraryInputsChanged`/`customSourcesChanged`), `applyMetadataSnapshot` (over-broad grid bump for usage/category), `commitLayoutChange`, `drainExternalCatalogRefreshes`, `searchQuery.didSet`, `displayModel()` revision cache.
**Surfaces**: `Packages/LaunchUI/Sources/LaunchUI/GridViewController.swift` (`refresh`, `applyGeometryConfig`, `performWorkingSetPrepare`, `compositorCanActivate`, `purgePageVisuals`, `currentBackingScale`); `PageVisualCache.swift` (`PageVisualKey`); `PageVisualRenderer.swift`; `PageCompositor.swift`; `LauncherWindowController.swift` (`show`/`hide`, `updateBackground`, `reapplyVisualConfig`, `setContentInsets`); `WallpaperProvider.swift` (`NormalizedRenderRequest`, `invalidate`); `ActivationCoordinator.swift` (`reconfigure`); `SettingsWindowController.swift` (`commit`); `LoginItemController.swift`.
**Config schema**: `Packages/LaunchCore/Sources/LaunchCore/Configuration.swift`.
**Runtime probes**: `LaunchBetterApp/Diagnostics/DiagnosticRunner.swift` + all `Diagnostics/*.swift`; test probes `MotionDiagnosticsProbe.swift`, `SettingsSliderMeasureProbe.swift`, `SnapshotIndexMeasurementTests.swift`, `PA1FrameBudgetTests.swift`.
**Baseline evidence**: `Docs/aegis/work/2026-08-24-launchbetter-convergence-phase2/90-evidence.md`, `99-reflection.md`, `proof-bundle.md`; `Docs/aegis/work/2026-08-24-launchbetter-convergence/90-evidence.md`; `Docs/Tasks/performance-architecture-convergence.md`.

**Bottom line for Phase 3**: the publication architecture is sound and mostly narrow; the one concrete over-broad publication is `applyMetadataSnapshot` bumping the grid-visible `displayRevision` for Library-only changes (launch usage #8, category override #9). Phase 3 should split that Library-only publication from the grid gate in `LauncherStore`, keep PageVisual key-driven implicit invalidation, and preserve the single `onConfigChange` immediate-effect bus. All physical/hardware/top-level gates remain `MANUAL_PHYSICAL_GATE` and are not claimed.
