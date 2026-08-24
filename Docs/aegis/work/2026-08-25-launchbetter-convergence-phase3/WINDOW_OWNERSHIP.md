# P3-C — LauncherWindowController Ownership Audit

- **Task:** P3-C read-only `LauncherWindowController` ownership audit.
- **Baseline:** `79ad4abbda144344f520cac66aca25bda1c27f02` (clean `main`, ahead 14 of origin).
- **Scope:** `LauncherWindowController.swift` (1636 lines), `LauncherWindow.swift`, `WallpaperProvider.swift`, `SettingsWindowController.swift`, `LauncherInteractionOwnership.swift`, `LauncherTransitionLifecycle.swift`, `LauncherTransitionCoordinator.swift`, `AccessibilityDisplayObserver.swift`, `LauncherWindowCoordinator.swift`, `SettingsOwnershipProbe.swift`, and the focused tests.
- **Mode:** read-only. No production source or Git was modified. Only this file was created.
- **File refs:** `LWC` = `Packages/LaunchUI/Sources/LaunchUI/LauncherWindowController.swift`; `LW` = `LauncherWindow.swift`; `WP` = `WallpaperProvider.swift`; `SWC` = `SettingsWindowController.swift`; `LIO` = `LauncherInteractionOwnership.swift`; `LTL` = `LauncherTransitionLifecycle.swift`; `LTC` = `LauncherTransitionCoordinator.swift`; `ADO` = `AccessibilityDisplayObserver.swift`.

---

## 1. Executive verdict

1. **`LauncherBackgroundController` is NOT justified as an independent owner.** The background/wallpaper is a *sub-effect* of the window lifecycle with no independent begin/active/invalidate/end. Its layers are shared with `LauncherTransitionCoordinator` (which is the sole owner of opacity/transform), and its request geometry is derived from `window.screen`/`contentView.bounds`. The rendering/caching is already correctly owned by `WallpaperProvider`. Extracting a controller would create a callback-driven class with no independent resource or lifecycle boundary. **[DEFER BASIS — see §6.1]**

2. **`SettingsOwnershipCoordinator` is NOT justified as a separate class.** Settings ownership is a *mode* of the window controller's input-routing state machine. It shares `interactionSurface` with folder/library/grid surface logic (three other writers), and it reaches back into the window controller for every collaborator (`gridViewController`, `dragController`, `interactionShield`, `settingsController`). The correct extraction level already exists: `SettingsOwnershipGate` (LWC 165–212) is a pure, generation-based value type that is already well unit-tested. **[DEFER BASIS — see §6.2]**

3. **What must remain in `LauncherWindowController`:** the window lifecycle, the top-level surface, background orchestration, settings ownership (as a mode), folder overlay, input routing, three-finger routing, search chrome, accessibility observation, and diagnostics. These are all modes of one window lifecycle and share `interactionSurface` and the transition coordinator.

4. **Screen/scale context:** the hot paths use the *actual* `window.screen` (LWC 1048, 999, 910; SWC 503–505, 441), but there are `NSScreen.main` *fallback guesses* in `init` (LWC 526) and in fallback branches (LWC 999, LW 44, SWC 504, 441). The invariant "window receives actual screen/geometry context rather than guessing with `NSScreen.main`" is *mostly* held but not fully — the fallbacks are guesses. See §5.

5. **Generation/stale-result/cancellation:** the transition lifecycle (LTL), transition coordinator (LTC), and settings gate (LWC 165–212) are all generation-correct. The wallpaper background guard (`backgroundRequest == request`, LWC 1075) is a *weak equality guard*, not a generation counter — adequate but the weakest of the four. See §7.

---

## 2. Ownership inventory by category

For each category: **state**, **writers**, **readers**, **lifecycle**, **dependencies**, **invalidation**, **independent owner boundary**.

### 2.1 Window lifecycle

| Item | Evidence |
|---|---|
| State | `visible` (LWC 297); `transition = LauncherTransitionLifecycle` (LWC 300); `transitionCoordinator` (LWC 293); `lastShowStart`/`wallpaperShowCounter` (LWC 1091–1092); `onVisibilityChange` (LWC 306); `onOpenSettings` (LWC 309); `settingsController` weak (LWC 312); `notificationTokens` (LWC 279). |
| Writers | `show()` (LWC 780–824), `hide()` (LWC 1094–1138), `toggle()` (LWC 1140–1142). `transition.beginShow/beginHide/completeShow/completeHide` (LWC 785, 812, 1102, 1127). `transitionCoordinator.transition(to:policy:completion:)` (LWC 808, 1124). |
| Readers | `isVisible` (LWC 1144), `isActuallyVisible` (LWC 1145), `transitionStateForDiag` (LWC 303), `LauncherWindowCoordinator` (LWC 13–23). |
| Lifecycle | `beginShow → presenting → completeShow → visible`; `beginHide → dismissing → completeHide → hidden` (LTL 29–64). Generation token + expectedState + one-shot (LTL 66–76). |
| Dependencies | `LauncherWindow` (LW 21–35), `LauncherTransitionCoordinator` (LTC 78–277), `MotionEnvironment.launcherPolicy` (LWC 788, 1103). |
| Invalidation | Generation-based token (LTL 19–26); stale completion rejected by `canComplete` (LTL 66–76). |
| Independent owner boundary | **Yes — this is the true independent lifecycle.** `LauncherTransitionLifecycle` is a pure value type (LTL 11) and `LauncherTransitionCoordinator` owns the CA animation serial (LTC 84, 124–127). |

### 2.2 Top-level surface

| Item | Evidence |
|---|---|
| State | `foregroundView` (LWC 292); `root` (local, LWC 584); `backgroundLayer` (LWC 290); `dimLayer` (LWC 291). |
| Writers | `configureWindow` builds `root`/`foregroundView` and adds layers (LWC 584–615); `LauncherTransitionCoordinator.apply` writes opacity/transform (LTC 206–215); `applyBackground` writes `backgroundLayer.contents` (LWC 1081–1089). |
| Readers | `LauncherTransitionCoordinator` (LTC 92–102), `runtimeLayoutDiagnostics` (LWC 861–898), `captureContentScreenshot` (LWC 1434–1453). |
| Lifecycle | Created once in `configureWindow`; lives for the window's lifetime. |
| Dependencies | `foregroundView` hosts grid/search/settings/page-dots (LWC 672, 685, 712). |
| Invalidation | None — surface is permanent; only its presentation values change. |
| Independent owner boundary | **No.** The surface is the shared canvas for grid/search/settings and the transition coordinator. It is not independently owned. |

### 2.3 Background / wallpaper

| Item | Evidence |
|---|---|
| State | `wallpaperProvider` (LWC 278); `backgroundRequest` (LWC 294); `backgroundLayer`/`dimLayer` (LWC 290–291); `lastShowStart`/`wallpaperShowCounter` (LWC 1091–1092). |
| Writers | `updateBackground(for:)` (LWC 1047–1079) builds `RenderRequest`, sets layer frames, checks cache, and launches `Task.detached` render; `applyBackground(_:)` (LWC 1081–1089) sets `backgroundLayer.contents`. |
| Readers | `LauncherTransitionCoordinator` animates `backgroundLayer`/`dimLayer` opacity (LTC 156–171, 206–215). |
| Lifecycle | Driven by `show()` (LWC 804), `reapplyVisualConfig()` (LWC 1016), and `NSWindow.didChangeScreenNotification` → `updateChromeLayoutForCurrentScreen` (LWC 565–573). **No independent begin/active/invalidate/end.** |
| Dependencies | `window.screen` (LWC 1048), `window.contentView?.bounds` (LWC 1051), `window.backingScaleFactor` (LWC 1054), `store.wallpaperBlurRadius` (LWC 1055), `WallpaperProvider` (WP 84–155). |
| Invalidation | `backgroundRequest == request` equality guard on the main-thread apply (LWC 1075). `WallpaperProvider.invalidate()` clears the cache (WP 170–174). |
| Independent owner boundary | **No.** The background is a sub-effect of the window lifecycle, and its opacity is owned by the transition coordinator. The rendering/caching is already owned by `WallpaperProvider`. |

### 2.4 Settings ownership

| Item | Evidence |
|---|---|
| State | `interactionSurface` (LWC 315); `settingsReturnSurface` (LWC 320); `interactionShield` (LWC 323); `settingsOwnership = SettingsOwnershipGate` (LWC 327); `settingsCloseFallbackDelay` (LWC 329). |
| Writers | `presentSettingsWindow` (LWC 336–381), `bindSettingsController` (LWC 383–390), `openSettingsFromMenu` (LWC 393–397), `requestSettingsClose` (LWC 400–402), `settingsDidClose` (LWC 405–418), `shieldClickConsumed` (LWC 421–424), `endSettingsOwnership` (LWC 427–440), `scheduleSettingsCloseFallback` (LWC 483–498), `installSettingsShield` (LWC 500–516). |
| Readers | `currentInteractionSurface` (LWC 332), `settingsReturnSurfaceForDiag` (LWC 949–951), `SettingsOwnershipProbe` (LaunchBetterApp/Diagnostics/SettingsOwnershipProbe.swift 34–94). |
| Lifecycle | `beginSession` → (`beginConsumingSequence` / `receiveCloseCallback`) → `finishSession` (LWC 174–211). Generation-based fallback token (LWC 166–168, 194–198). |
| Dependencies | `gridViewController.suspendPagingForSurface/resumePagingForSurface` (LWC 368, 438), `dragController.cancelDrag` (LWC 358, 439), `gridViewController.closeAppLibraryDetail` (LWC 363), `settingsController.present` (LWC 377), `SettingsChildWindowAttachment` (LWC 248–265). |
| Invalidation | `SettingsOwnershipGate` generation (LWC 170, 207); fallback token bound to current session (LWC 194–198). |
| Independent owner boundary | **Partial.** The *gate* is an independent pure value type (LWC 165–212) and is well tested. But the *ownership mode* is entangled with `interactionSurface`, which has three other writers (folder, library detail, grid surface). See §6.2. |

### 2.5 Folder overlay

| Item | Evidence |
|---|---|
| State | `folderViewController` (LWC 281); `folderTransitionCoordinator` (LWC 282). |
| Writers | `openFolder` (LWC 1149–1207), `closeFolderView` (LWC 1209–1227), `finishFolderClose` (LWC 1229–1243). |
| Readers | `handleKeyDown` Escape branch (LWC 1603–1604), `control(_:doCommandBy:)` (LWC 746–747), `hide()` (LWC 1115), `presentSettingsWindow` (LWC 359). |
| Lifecycle | `openFolder` → `FolderTransitionCoordinator.startOpening` (LWC 1206); `closeFolderView` → `requestClose`/`cancelAndTeardown` → `finishFolderClose` (LWC 1215–1226). |
| Dependencies | `gridViewController.folderTransitionSource` (LWC 1152), `dragController.beginFolderExitDrag` (LWC 1164), `interactionSurface = .folder` (LWC 1184). |
| Invalidation | `finishFolderClose` guards `self.folderViewController === folderViewController` (LWC 1230) — identity guard against stale close completion. |
| Independent owner boundary | **No.** Folder is a temporary overlay mode of the window controller, sharing `interactionSurface` and `dragController`. |

### 2.6 Input routing

| Item | Evidence |
|---|---|
| State | `dragController` (LWC 289); `gridViewController` (LWC 280); `interactionSurface` (LWC 315). |
| Writers | `beginRootDragIfPermitted` (LWC 1344–1357), `handleKeyDown` (LWC 1594–1621), `launchFirstSearchResult` (LWC 1623–1628), `controlTextDidChange` (LWC 1632–1635), `handleGridSurfaceChange` (LWC 449–463), `handleLibraryDetailChange` (LWC 468–479). |
| Readers | `SettingsInteractionShield` (LIO 29–100), `LauncherInteractionSurface` (LIO 9–19), `ThreeFingerDragRoute` (LWC 231–243). |
| Lifecycle | `interactionSurface` transitions: `.launcher` ↔ `.appLibrary` ↔ `.appLibraryCategory` ↔ `.folder` ↔ `.settings` (LIO 9–19). |
| Dependencies | `gridViewController`, `dragController`, `appLibraryControllerForDiag`. |
| Invalidation | Surface gate on every input entry (LWC 619, 627, 663, 667, 1345, 1611). |
| Independent owner boundary | **No.** `interactionSurface` is the shared input-ownership state across all surfaces. |

### 2.7 Three-finger routing

| Item | Evidence |
|---|---|
| State | `ThreeFingerDragRoute` (LWC 231–243); `interactionSurface` (LWC 315). |
| Writers | `threeFingerDragBegin/Update/End` (LWC 1289–1336), `threeFingerDragCancel` (LWC 1411–1414). |
| Readers | `SettingsOwnershipProbe` (probe 44). |
| Lifecycle | Per-gesture; routed by `ThreeFingerDragRoute.make(for:)` (LWC 236–242). |
| Dependencies | `currentPointerInWindow` (LWC 1339–1341), `dragController`, `appLibraryControllerForDiag`. |
| Invalidation | Surface gate (LWC 1290, 1308, 1321). |
| Independent owner boundary | **No.** Pure routing seam (LWC 231) + surface gate. |

### 2.8 Search chrome

| Item | Evidence |
|---|---|
| State | `searchField` (LWC 283); `searchFieldWidth/Height/TopConstraint` (LWC 284–286); `settingsButtonView` (LWC 288); `settingsButtonTopConstraint` (LWC 287); `LauncherChromeMetrics` (LWC 39–48). |
| Writers | `configureWindow` (LWC 681–723), `updateChromeLayoutForCurrentScreen` (LWC 997–1010), `reapplyVisualConfig` (LWC 1014–1020), `currentContentInsets` (LWC 978–993). |
| Readers | `runtimeLayoutDiagnostics` (LWC 861–898), `settingsButtonFrameDiagnostics` (LWC 828–837), `searchFieldFrameDiagnostics` (LWC 839–844), `settingsButtonCenterOnScreen` (LWC 761–776). |
| Lifecycle | Created in `configureWindow`; constraints updated on screen change / config change. |
| Dependencies | `store.searchBarWidth` (LWC 689, 1000), `window.screen` safe area (LWC 999), `GridGeometry` insets (LWC 1008). |
| Invalidation | None — constraints are re-applied, not invalidated. |
| Independent owner boundary | **No.** Chrome is layout state owned by the window controller. |

### 2.9 Accessibility

| Item | Evidence |
|---|---|
| State | `accessibilityDisplayObserver` (LWC 295); `LauncherSurfaceAppearance` (LWC 81–110); `SettingsButtonAppearance` (LWC 113–159). |
| Writers | `applyAccessibilitySnapshot` (LWC 1025–1040), `teardownAccessibilityDisplayObservation` (LWC 1042–1045), `AccessibilityDisplayObserver.start/teardown` (ADO 39–59). |
| Readers | `AccessibilityMaterialPolicy` (LWC 1026), `folderViewController.applyAccessibilityMaterialPolicy` (LWC 1039). |
| Lifecycle | `start()` in `init` (LWC 543); `teardown()` on `NSWindow.willCloseNotification` (LWC 574–583). |
| Dependencies | `MotionEnvironment.liveSnapshot` (LWC 530, 534), `AccessibilityDisplayObserver` (ADO 12–64). |
| Invalidation | Observer teardown (LWC 1042–1045); appearance apply is idempotent and only touches settled material (LWC 1022–1024). |
| Independent owner boundary | **Partial.** `AccessibilityDisplayObserver` is a self-contained owner of the live snapshot (ADO 3–10), but its lifecycle is owned by the window controller. |

### 2.10 Diagnostics

| Item | Evidence |
|---|---|
| State | Many read-only diagnostic accessors (LWC 828–1578). |
| Writers | None (all read-only). |
| Readers | `SettingsOwnershipProbe` (LaunchBetterApp/Diagnostics/SettingsOwnershipProbe.swift), runtime probes, `--perf`/`--inputtrace` prints (LWC 821, 1057, 1086, 1346, 1351). |
| Lifecycle | N/A. |
| Dependencies | `gridViewController`, `dragController`, `window`. |
| Invalidation | N/A. |
| Independent owner boundary | **No.** Diagnostics are read-only seams over the window controller's state. |

---

## 3. `LauncherBackgroundController` — justification analysis

**Proposed ownership:** `backgroundLayer`, `dimLayer`, `backgroundRequest`, `wallpaperProvider`, `lastShowStart`/`wallpaperShowCounter`.

**What it would own (if extracted):**
- Build `RenderRequest` from window geometry (LWC 1052–1056).
- Set `backgroundLayer.frame`/`dimLayer.frame` (LWC 1062–1063).
- Cache-hit apply (LWC 1065–1068) and async render + generation-guarded apply (LWC 1070–1078).

**Why it is NOT an independent owner:**

1. **No independent lifecycle.** The background has no begin/active/invalidate/end of its own. It is driven by `show()` (LWC 804), `reapplyVisualConfig()` (LWC 1016), and `didChangeScreen` (LWC 565–573). Every trigger is a window-lifecycle event. A controller with no independent lifecycle is not an owner — it is a callback sink.

2. **Layer ownership is split.** `backgroundLayer`/`dimLayer` are added to `root.layer` in `configureWindow` (LWC 592–593) and their *opacity* is animated by `LauncherTransitionCoordinator` (LTC 156–171, 206–215). The invariant is explicit: "The transition coordinator remains the sole owner of opacity and transform" (LWC 79–80, 1022–1024). A `LauncherBackgroundController` would either (a) leak the layers to the transition coordinator, or (b) steal opacity ownership — both violate the invariant.

3. **Rendering is already owned.** `WallpaperProvider` owns discovery, decode, cover-crop, blur, memory cache, disk cache, and in-flight dedup (WP 84–155). The window controller's remaining role is a ~30-line orchestration that is tightly coupled to `window.screen`/`contentView.bounds`/`backingScaleFactor` (LWC 1047–1079).

4. **The generation guard is already present** (`backgroundRequest == request`, LWC 1075). Extraction would not add correctness.

**Verdict:** **[DEFER BASIS]** — do not extract `LauncherBackgroundController`. The background is a sub-effect of the window lifecycle; its opacity is owned by the transition coordinator; its rendering is owned by `WallpaperProvider`. The orchestration is small and window-geometry-coupled. The only genuine improvement is strengthening the generation guard (see §7), which is a change *inside* `LauncherWindowController`, not an extraction.

---

## 4. `SettingsOwnershipCoordinator` — justification analysis

**Proposed ownership:** `interactionSurface`, `settingsReturnSurface`, `interactionShield`, `settingsOwnership`, `settingsCloseFallbackDelay`.

**What it would own (if extracted):**
- `presentSettingsWindow` (LWC 336–381), `bindSettingsController` (LWC 383–390), `openSettingsFromMenu` (LWC 393–397), `requestSettingsClose` (LWC 400–402), `settingsDidClose` (LWC 405–418), `shieldClickConsumed` (LWC 421–424), `endSettingsOwnership` (LWC 427–440), `scheduleSettingsCloseFallback` (LWC 483–498), `installSettingsShield` (LWC 500–516).

**Why it is NOT an independent owner:**

1. **`interactionSurface` is shared, not settings-owned.** It is written by four distinct paths: settings (LWC 369), folder (LWC 1184, 1240), library detail (LWC 471, 476), and grid surface change (LWC 455, 461). A `SettingsOwnershipCoordinator` that owns `interactionSurface` would either (a) steal the folder/library/grid writers, or (b) share the variable with the window controller — two writers on one state, which is exactly the anti-pattern this phase targets.

2. **Every collaborator lives in the window controller.** The settings ownership reaches into `gridViewController.suspendPagingForSurface/resumePagingForSurface` (LWC 368, 438), `dragController.cancelDrag` (LWC 358, 439), `gridViewController.closeAppLibraryDetail` (LWC 363), and `settingsController.present` (LWC 377). A coordinator would be a callback-heavy class that forwards to the window controller for every action — no independent resource ownership.

3. **The correct extraction already exists.** `SettingsOwnershipGate` (LWC 165–212) is a pure, generation-based value type that encapsulates the timing/close-callback/mouse-sequence logic. It is already well unit-tested (SettingsTransitionTests 187–258; AppLibraryInteractionOwnershipTests 30–65). The gate is the right level of extraction; a coordinator above it adds no boundary.

4. **The shield is a view in the launcher window** (LIO 29–100), not in the settings window. Its lifecycle (install/remove) is inherently a window-controller concern (LWC 500–516, 436–437).

**Verdict:** **[DEFER BASIS]** — do not extract `SettingsOwnershipCoordinator`. Settings ownership is a *mode* of the window controller's input-routing state machine, sharing `interactionSurface` with three other writers and reaching into window-owned collaborators. The pure `SettingsOwnershipGate` is the correct, already-extracted boundary.

---

## 5. Screen / scale context — actual `window.screen` vs guesses

| Site | Uses actual `window.screen`? | Evidence |
|---|---|---|
| `init` initial frame | **GUESS** — `NSScreen.main ?? NSScreen.screens[0]` | LWC 526 |
| `LauncherWindow.showOnScreen` | **Actual** — `screenFor(mouseLocation)` → `NSScreen.main` fallback | LW 38–52, 54–66 |
| `updateChromeLayoutForCurrentScreen` safe area | **Actual with guess fallback** — `window?.screen ?? NSScreen.main` | LWC 999 |
| `updateBackground` | **Actual** — `window.screen` | LWC 1048 |
| `movePointerToSettingsButtonForDiagnostic` | **Actual** — `window.screen` | LWC 910 |
| `settingsButtonCenterOnScreen` | **Actual** — `window.convertPoint(toScreen:)` | LWC 775 |
| `SettingsWindowController.positionWindowForFreshPresentationIfNeeded` | **Actual with guess fallback** — `launcherWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame` | SWC 503–505 |
| `SettingsWindowController.hiddenIconScale` | **Actual with guess fallback** — `window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2` | SWC 440–442 |
| `WallpaperProvider.wallpaperSourceURL` | **Deterministic, not `NSScreen.main`** — matches by size over `NSScreen.screens` | WP 224–239, 243–259 |

**Finding:** The hot paths use the *actual* `window.screen` (LWC 1048, 999, 910; SWC 503–505, 441). The `NSScreen.main` references are **fallback guesses** in `init` (LWC 526) and in the fallback branches (LWC 999, LW 44, SWC 504, 441). The invariant "window receives actual screen/geometry context rather than guessing with `NSScreen.main`" is **mostly held but not fully** — the fallbacks are guesses.

**Risk:** The `init` guess (LWC 526) only sets the initial frame; the window is re-positioned on `show()` via `showOnScreen(containing: mouseLocation)` (LWC 798, LW 38–52), so the guess is transient. The `updateChromeLayoutForCurrentScreen` fallback (LWC 999) only fires when `window.screen` is nil (window not on a screen), which is a degenerate state. The `hiddenIconScale` fallback (SWC 441) only affects the hidden-app row icon scale. **Severity: low.** No production change is required; the fallbacks are defensive and only reachable in degenerate states.

---

## 6. DEFER BASIS items

### 6.1 `LauncherBackgroundController` — DEFER
- **Basis:** no independent lifecycle; layer opacity owned by `LauncherTransitionCoordinator` (LTC 206–215); rendering owned by `WallpaperProvider` (WP 84–155); orchestration is ~30 lines coupled to window geometry (LWC 1047–1079). Extraction would create a callback sink with no independent boundary.
- **What stays in `LauncherWindowController`:** `updateBackground`/`applyBackground`/`backgroundRequest`/`backgroundLayer`/`dimLayer` orchestration.

### 6.2 `SettingsOwnershipCoordinator` — DEFER
- **Basis:** `interactionSurface` has four writers (settings LWC 369, folder LWC 1184/1240, library detail LWC 471/476, grid surface LWC 455/461); every collaborator lives in the window controller; the pure `SettingsOwnershipGate` (LWC 165–212) is the correct, already-extracted boundary and is already tested.
- **What stays in `LauncherWindowController`:** the settings ownership *mode* (present/close/end/fallback) and the shield lifecycle.

### 6.3 `NSScreen.main` fallback guesses — DEFER (low severity)
- **Basis:** all fallbacks are reachable only in degenerate states (window not on a screen, or initial frame before first `show`). The hot paths already use actual `window.screen`. No production change required; note as a bounded hardening item if a future change touches these lines.

---

## 7. Generation / stale-result / cancellation requirements

| Mechanism | Guard | Evidence | Assessment |
|---|---|---|---|
| Launcher transition | Generation token + expectedState + one-shot | LTL 19–26, 66–76 | **Correct.** |
| Transition coordinator | Serial counter drops interrupted CA completions | LTC 84, 124–127, 185–198 | **Correct.** |
| Settings ownership | Generation-based fallback token | LWC 165–212, 483–498 | **Correct.** |
| Wallpaper background | `backgroundRequest == request` equality | LWC 1075 | **Weakest — adequate but not a generation counter.** |

**Wallpaper guard analysis (LWC 1070–1078):** the `Task.detached` render is not cancellable; on completion it checks `self.backgroundRequest == request` before applying. Because `RenderRequest` includes `screenFrame` (with origin, WP 13–23), the equality distinguishes screens. The risk is limited to: a new `show()` with an *identical* request while an old render is in flight → the old completion applies the same image (benign). **No correctness defect.** If hardening is desired, replace the equality with a monotonic generation counter (like LTL/LTC), but this is optional and low priority.

**Cache identity note:** `WallpaperProvider.normalizedRequest` ignores `screenFrame.origin` (WP 46–51, 68–76), so two same-size screens with different wallpapers share a cache entry and could show the wrong blurred wallpaper. This is a **pre-existing, low-severity** edge case (blurred background, same dimensions), already deferred in Phase 2 evidence (P2-C, "same-size monitor identity ambiguity"). Not a Phase 3 window-ownership concern.

---

## 8. Focused tests

### Already covered
- `SettingsOwnershipGate` — SettingsTransitionTests 187–258 (normal mouseUp, force release, stale fallback, re-present generation); AppLibraryInteractionOwnershipTests 30–65. **Comprehensive.**
- `LauncherTransitionLifecycle` — LauncherTransitionLifecycleTests. **Comprehensive.**
- `WallpaperProvider` — WallpaperProviderTests (8 tests): render edges, disk cache versioning, source separation, cache identity, source selection. **Comprehensive for the provider.**
- `SettingsWindowController` — SettingsWindowControllerTests (live UI, lists, sliders, language rebuild). **Comprehensive for the settings surface.**
- `SettingsOwnershipProbe` — LaunchBetterApp/Diagnostics/SettingsOwnershipProbe.swift (runtime probe, not a unit test).

### Recommended focused tests (proportional, not strict TDD)
1. **Window show/hide transition staleness** — assert that a `hide()` during an in-flight `show()` (and vice versa) does not let the stale completion orderOut/orderFront. This is the LTL token + LTC serial contract at the controller boundary. (Currently only the pure LTL/LTC layers are tested; the controller wiring is not.)
2. **Background request generation guard** — assert that a stale `backgroundRequest` does not apply after a newer request. Requires injecting a fake `WallpaperProvider`; assert `applyBackground` is called only for the current request.
3. **Screen/scale context** — assert `updateChromeLayoutForCurrentScreen` uses `window.screen` (not `NSScreen.main`) when a window is on a non-main screen. This is the invariant in the Phase 3 intent (10-intent.md line 21).
4. **Settings ownership end-to-end** — assert `endSettingsOwnership` restores `settingsReturnSurface` (`.appLibrary` when opened from Library, LWC 362–367) and resumes paging. The probe covers this at runtime; a unit test would lock the surface-restore contract.

---

## 9. Summary of what must remain in `LauncherWindowController`

- **Window lifecycle:** `show`/`hide`/`toggle`, `transition` (LTL), `transitionCoordinator` (LTC), `visible`, `onVisibilityChange`, `onOpenSettings`, `settingsController`, `notificationTokens`.
- **Top-level surface:** `foregroundView`, `root`, `backgroundLayer`, `dimLayer` (as the shared canvas).
- **Background orchestration:** `updateBackground`/`applyBackground`/`backgroundRequest` (coupled to window geometry + transition coordinator).
- **Settings ownership (as a mode):** `interactionSurface`, `settingsReturnSurface`, `interactionShield`, `settingsOwnership` gate, present/close/end/fallback.
- **Folder overlay:** `folderViewController`, `folderTransitionCoordinator`, open/close/finish.
- **Input routing:** `dragController`, `gridViewController`, `beginRootDragIfPermitted`, `handleKeyDown`, `launchFirstSearchResult`, `controlTextDidChange`, `handleGridSurfaceChange`, `handleLibraryDetailChange`.
- **Three-finger routing:** `threeFingerDragBegin/Update/End/Cancel`, `ThreeFingerDragRoute`, `currentPointerInWindow`.
- **Search chrome:** `searchField`, constraints, `settingsButtonView`, `updateChromeLayoutForCurrentScreen`, `currentContentInsets`, `reapplyVisualConfig`.
- **Accessibility:** `accessibilityDisplayObserver`, `applyAccessibilitySnapshot`, `teardownAccessibilityDisplayObservation`.
- **Diagnostics:** all read-only diagnostic seams.

**Net recommendation:** no new owner class is justified. The two proposed extractions (`LauncherBackgroundController`, `SettingsOwnershipCoordinator`) are both **[DEFER BASIS]**. The existing pure value types (`LauncherTransitionLifecycle`, `SettingsOwnershipGate`, `WallpaperProvider`, `AccessibilityDisplayObserver`) are the correct ownership boundaries. The only actionable items are the optional wallpaper generation-counter hardening (§7) and the four focused tests (§8).
