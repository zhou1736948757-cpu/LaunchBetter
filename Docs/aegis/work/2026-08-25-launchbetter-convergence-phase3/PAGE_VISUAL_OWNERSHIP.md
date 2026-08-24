# P3-A01 — PageVisual Read-Only Ownership Audit

- **Task**: `launchbetter-convergence-phase3` / P3-A01
- **Baseline**: `79ad4abbda144344f520cac66aca25bda1c27f02` (Phase 2 final), clean `main`
- **Scope**: read-only. No production source or Git edits. Only this report is created.
- **Method**: grep/read call-site evidence across `Packages/LaunchUI/Sources/LaunchUI` and `Packages/LaunchUI/Tests/LaunchUITests`. No assumptions.
- **Verdict (headline)**: **PageVisual has NO independent lifecycle** (it is a frozen immutable value). **PageVisualCoordinator = NO** — `GridViewController` is already the single coordinator of every page-visual state object, and it owns the paging engine plus the surface/geometry/search/drag state that compositor eligibility depends on. Splitting would create a second, leaky coordinator.

---

## 1. Source map (evidence anchors)

| File | Role | Key lines |
|---|---|---|
| `PageVisual.swift` | Value types: `PageVisual`, `PageVisualKey`, `PageVisualGeometrySignature` | 9–58 (signature), 64–71 (key), 79–91 (visual) |
| `PageVisualCache.swift` | Bounded working-set cache (≤3) | 10–12 (cap), 36–44 (read), 53–75 (insert/LRU), 79–95 (remove/removeAll), 118–233 (working-set queries) |
| `PageVisualRenderer.swift` | Stateless rasterizer + icon resolver | 11–28 (frozen request), 31–48 (icon set), 137–234 (resolveIcons), 240–305 (prepare), 308–363 (rasterize) |
| `PageCompositor.swift` | Presentation-only compositor | 97–133 (state), 146–188 (activate), 191–216 (applyOffset), 220–260 (finishSettle/abort/shutdown/teardown) |
| `PagingInteractionController.swift` | Sole motion engine / sole offset writer | 17–22 (phase), 25–41 (injected seams), 102–110 (shutdown), 317–344 (beginGesture), 537–555 (applyScroll) |
| `GridViewController.swift` | **The coordinator** — owns all of the above | 152 (paging), 157–160 (cache/renderer/compositor), 167–202 (flags/generations/scale), 175 (memory source), 407–453 (memory pressure), 461–468 (scale change), 612–646 (refresh), 685–726 (search), 782–802 (geometry config), 984–1035 (prewarm), 1262–1328 (paging wiring), 1335–1378 (offset routing), 1392–1494 (compositor lifecycle), 1506–1632 (prepare) |
| `LauncherWindowController.swift` | External callers of compositor shutdown | 459, 1112–1113, 1296, 1355 |

---

## 2. Complete ownership table

Legend — **Owner**: the object that holds the state and is responsible for its lifecycle. **Writer**: who mutates it. **Readers**: who reads it. **Lifetime**: when it exists. **Invalidation**: what makes it stale/removed.

| State / Method | Current Owner | Writer | Readers | Lifetime | Invalidation |
|---|---|---|---|---|---|
| **PageVisualCache** | `GridViewController` (`private let pageVisualCache`, GVC:157) | `GridViewController` — `insert` (GVC:1622), `removeAll` via `purgePageVisuals` (GVC:1493) | `GridViewController` — `compositorCanActivate` (GVC:1406), `tryActivatePageCompositor` (GVC:1429), diagnostics (GVC:1656–1680); tests | Lifetime of `GridViewController` (property) | Key-based (any `PageVisualKey` component change = natural miss); `removeAll` on hide/memory-pressure/scale/search (GVC:1491–1494); LRU eviction at cap 3 (PVC:71–74) |
| **PageVisualRenderer** | `GridViewController` (`private let pageVisualRenderer`, GVC:158) | None (stateless; only GVC calls its methods) | `GridViewController` — `resolveIcons` (GVC:1572), `epoch` (GVC:1580), `makeKey` (GVC:1581,1611), `prepare` (GVC:1591) | Lifetime of `GridViewController` (property) | None (stateless service; no stored state) |
| **PageCompositor** | `GridViewController` (`let pageCompositor`, GVC:160) | `GridViewController` — `activate` (GVC:1458), `applyOffset` via `routeScroll` (GVC:1347), `finishSettle` via `finalizePageCompositor` (GVC:1476), `shutdown` via `shutdownPageCompositor` (GVC:1487) | `GridViewController` — `readPagingOffset` (GVC:1337), `routeScroll` (GVC:1346), `advanceRealClipBehindCover` (GVC:1365), `onSyncClip` (GVC:1301), diagnostics (GVC:1662–1668); tests | Lifetime of `GridViewController`; active/inactive sub-lifecycle per gesture | `shutdown`/`abort` on structural change (search/folder/settings/hide/drag/config/scale/revision); `onSyncClip` syncs real clip on teardown |
| **Current rendered visual (`PageVisual`)** | **None** — immutable value (PageVisual.swift:79–91) | `PageVisualRenderer.prepare` → `PageVisualCache.insert` (GVC:1591→1622) | `PageCompositor.activate` reads `image`/`rasterScale`/`logicalBounds` (PC:169–171, 1442–1454) | Cache-entry lifetime (LRU eviction / purge) | Key change (revision/geometry/scale/language/iconEpoch) |
| **prepare / prewarm tasks** | `GridViewController` — `pageVisualPrepareTask` (GVC:192), `pageVisualPrepareInFlight` (GVC:195), `pagePrewarmTask` (GVC:980) | `GridViewController` — `schedulePageVisualPrepare` (GVC:1506), `prewarmAdjacentPages` (GVC:984) | `GridViewController` — `prepareWorkingSetVisuals` (GVC:1536) | Task lifetime; generation-guarded | Generation increment cancels stale debounce (GVC:1508–1510); in-flight prepare intentionally NOT cancelled (F10, GVC:1502–1505) |
| **render generation** | `GridViewController` — `pageVisualPrepareGeneration` (GVC:188), `pagePrewarmGeneration` (GVC:982) | `GridViewController` — `schedulePageVisualPrepare` (GVC:1508), `prewarmAdjacentPages` (GVC:1011) | `GridViewController` — generation checks (GVC:1514, 1520, 1034) | Monotonic per schedule | Increment on each schedule |
| **active compositor** | `GridViewController` (`pageCompositor.isActive`) | `GridViewController` — `tryActivatePageCompositor`→`activate` (GVC:1417→1458); `finalizePageCompositor`→`finishSettle` (GVC:1474→1476); `shutdownPageCompositor`→`shutdown` (GVC:1486→1487) | `GridViewController` — `readPagingOffset`, `routeScroll`, `compositorCanActivate`, `onSyncClip`; tests | Per-gesture (activate on `onWillBeginGesture`, teardown on `onPhaseIdle`/shutdown) | Shutdown on structural change / drag / search / hide / scale / geometry |
| **memory warning handling** | `GridViewController` — `memoryPressureSource` (GVC:175) | `GridViewController` — `registerMemoryPressureObserver` (GVC:408), `purgePageVisuals` (GVC:1491) | `GridViewController` — purge + reschedule (GVC:418–421) | `loadView` → `deinit` (GVC:404, 451–453) | Purge + reschedule on `.warning`/`.critical` |
| **cache invalidation** | `GridViewController` (`purgePageVisuals`, GVC:1491) + `PageVisualCache` (key-based) | `GridViewController` | `GridViewController` | N/A | Purge (hide/memory/scale/search) + key change |
| **page working set** | `GridViewController` (`prepareWorkingSetVisuals`, GVC:1536) + `PageVisualCache` (`workingSetKeys`, PVC:118) | `GridViewController` | `GridViewController` — `compositorCanActivate`, `tryActivatePageCompositor` | Per `currentPage` | Page change → new working-set keys (prev/current/next) |
| **geometry invalidation** | `GridViewController` — `applyGeometryConfig` (GVC:782), `setContentInsets` (GVC:221), `viewDidLayout` (GVC:455) | `GridViewController` | `PageVisualGeometrySignature` (derived from `GridGeometry`, PV:21–32) | N/A | Geometry-signature change → new key → natural miss; explicit shutdown+purge on config change (GVC:785) |
| **data revision invalidation** | `GridViewController` — `refresh` (GVC:612), `applyLatestData` (GVC:654) | `GridViewController` | `PageVisualKey.displayRevision` | N/A | `displayRevision` change → shutdown compositor (GVC:632) + new key |
| **scale invalidation** | `GridViewController` — `viewDidLayout` (GVC:461–468), `currentBackingScale` (GVC:1634) | `GridViewController` | `PageVisualKey.backingScale` | N/A | Backing-scale change → shutdown + purge + rebuild (GVC:463–467) |
| **search transition** | `GridViewController` — `enterSearchMode` (GVC:685), `exitSearchMode` (GVC:718) | `GridViewController` | `compositorCanActivate` search gate (GVC:1396) | N/A | Enter search → shutdown + purge (GVC:689–690); exit → re-prepare |
| **drag transition** | `LauncherWindowController` (calls shutdown) + `GridViewController` (eligibility gate) | `LauncherWindowController` — `threeFingerDragBegin` (LWC:1296), grid drag begin (LWC:1355) | `GridViewController` — `compositorCanActivate` drag gate (GVC:1398) | N/A | Drag begin → shutdown compositor; drag in progress → not eligible |

---

## 3. Does `PageVisual` have an independent lifecycle?

**NO.** `PageVisual` is a frozen immutable value type:

- `PageVisual.swift:79–91` — `struct PageVisual: Sendable` with only `let` stored properties (`key`, `image`, `logicalBounds`, `rasterScale`) and a computed `bytes`. No class, no `deinit`, no mutable state, no owner, no state transitions.
- Its "lifecycle" is entirely delegated to the two objects that hold it:
  - **Cache** governs retention/eviction: LRU cap 3 (PVC:71–74), `removeAll` purge (PVC:89–95).
  - **Key** governs validity: any of `pageIndex`/`displayRevision`/`geometry`/`backingScale`/`languageRevision`/`iconEpoch` changing produces a new key → old visual is naturally invalid (PV:64–71; PVC:36–44).
- It is produced by `PageVisualRenderer.prepare` (PVR:240–305), stored by `PageVisualCache.insert`, and consumed read-only by `PageCompositor.activate` (PC:169–171). It never mutates after creation.

**Conclusion**: `PageVisual` is a pure render output with no independent lifecycle. It must not be given an owner/coordinator of its own.

---

## 4. Should `PageVisualCoordinator` be introduced? **NO** — with source evidence

`GridViewController` is already the single coordinator of every page-visual state object, and it is the only object that holds the state the compositor eligibility depends on:

- It owns the cache, renderer, compositor, and paging engine (GVC:152, 157–160).
- It owns the prepare/prewarm task machinery and generations (GVC:188–195, 978–982).
- It owns the memory-pressure source (GVC:175).
- **Compositor eligibility reads GridViewController-owned state exclusively** — `compositorCanActivate` (GVC:1392–1414) gates on `pageVisualCompositorEnabled`, `pageCompositor.isActive`, `paging.isEnabled`, `searchMode`, `currentSurface`, `dragController?.isDragging`, `currentPage`, `currentPageItemCount`, `pageCount`, `geometry`, `store.displayRevision`, `currentBackingScale`, `lastPreparedLanguageRevision`. Every one of these is a `GridViewController` property or a value it already reads.
- The compositor is wired to the paging engine through `GridViewController`'s seams: `onWillBeginGesture`→`tryActivatePageCompositor` (GVC:1286–1288), `onPhaseIdle`→`finalizePageCompositor` (GVC:1293–1296), `onSyncClip` (GVC:1301–1314), `onScroll`→`routeScroll` (GVC:1277–1280).

**Why a separate coordinator is not justified**: a `PageVisualCoordinator` would need to be fed `searchMode`, `currentSurface`, `dragController`, `currentPage`, `pageCount`, `geometry`, `store.displayRevision`, `lastPreparedLanguageRevision`, and the paging phase — i.e. it would re-import the very state `GridViewController` already owns, creating a second coordinator with a leaky dependency on `GridViewController`. That is strictly worse than the current single-owner arrangement.

**Minimal API / ownership boundary (if a coordinator were ever wanted — currently NOT recommended)**:
- The existing `GridViewController` page-visual surface is already the minimal API: `schedulePageVisualPrepare` (GVC:1506), `prepareWorkingSetVisuals` (GVC:1536), `shutdownPageCompositor` (GVC:1486), `purgePageVisuals` (GVC:1491), `tryActivatePageCompositor` (GVC:1417), `finalizePageCompositor` (GVC:1474), `compositorCanActivate` (GVC:1392), plus the read/write offset seams `readPagingOffset`/`routeScroll` (GVC:1335, 1345).
- **Non-ownership boundary**: `PageVisualCache`, `PageVisualRenderer`, and `PageCompositor` are leaf services owned by `GridViewController`; they must not reach back into `GridViewController`, `LauncherStore`, the diffable data source, or the view tree. `PagingInteractionController` remains the sole motion writer (see §6). `LauncherWindowController` may only *call* `shutdownPageCompositor`/`purgePageVisuals` (LWC:459, 1112–1113, 1296, 1355) — it must not own or mutate page-visual state.

---

## 5. Immutable render input / capture hazards

- **Frozen request**: `PageVisualRenderRequest` is a `Sendable` value (PVR:11–28). `CellRenderSpec` captures `colorRGBA`, `letter`, `label`, and `icon: CGImage?` (PVR:24–27). The request is fully materialized on the `@MainActor` before the detached rasterize (PVR:257–298), so the background `rasterize` (PVR:301–303, `Task.detached(priority: .utility)`) reads only frozen data. **No capture hazard** in the request path.
- **Icon capture**: `PageVisualIconSet` holds `CGImage`s resolved on `@MainActor` (PVR:31–48, 137–234). These are retained by the request; a concurrent `trimMemoryForHidden` (LWC:1116) cannot invalidate an already-retained `CGImage`. `CGImage` is thread-safe for drawing. **Safe**.
- **Icon provider capture**: `resolveIcons` captures `iconProvider` strongly in `TaskGroup` closures (PVR:200–205). The comment notes `IconImageProviding` is `Sendable` and implementations are `@MainActor final class`; the `await iconProvider.icon(...)` hops to `@MainActor`. **Safe**.
- **Name closures**: `prepareWorkingSetVisuals` passes `displayName`/`folderName` closures `{ [weak self] id in self?.store... ?? "" }` (GVC:1594–1595). These are called synchronously on `@MainActor` to build cells — no cross-thread capture. **Safe**.
- **Snapshot recheck**: before insert, `performWorkingSetPrepare` re-validates `currentKey == visual.key` (geometry match), `store.displayRevision == capturedRevision`, and `Self.languageRevision() == languageRevision` (GVC:1611–1621). A stale visual is dropped, not inserted. **This is the guard that makes the frozen-input pipeline safe against mid-prepare data/geometry/language change.** Covered by `snapshotRecheckDropsStaleVisualsOnce` (PCGIT:584–619).
- **Residual hazard (low)**: `lastPreparedLanguageRevision` is committed only on full success (GVC:1629–1631). A recheck failure leaves it stale relative to the actual cache keys; the next successful round re-commits. This is intentional (comment GVC:1560–1561) but is a subtle state the reader should be aware of.

---

## 6. `PagingInteractionController` sole-motion-writer invariant

**Invariant holds.** `PagingInteractionController` is the sole motion engine and the sole driver of every clip write:

- `PagingInteractionController` owns the display link and is the only caller of `onScroll` (via `applyScroll`, PIC:537–555). `GridViewController` injects `onScroll = { routeScroll($0) }` (GVC:1277–1280).
- `GridViewController` never writes clip directly except through paging-driven paths:
  - `routeScroll` (GVC:1345–1356) — the only real-clip writer, called only from `paging.onScroll`.
  - `onSyncClip` (GVC:1301–1314) — one-shot clip sync on compositor teardown, driven by `onPhaseIdle`→`finalizePageCompositor`→`finishSettle` or by `shutdownPageCompositor` (structural change).
  - `advanceRealClipBehindCover` (GVC:1364–1373) — settling-frame incremental clip advance, called only from `routeScroll` (GVC:1349), i.e. only from the paging engine.
- The compositor's `applyOffset` (layer movement) is likewise called only from `routeScroll` (GVC:1347), so compositor motion is also paging-driven.
- **Test evidence**: `PagingOffsetOwnershipTests.gridHasSingleHorizontalOffsetWriter` asserts exactly 3 `contentView.scroll(` occurrences in `GridViewController` and the presence of `routeScroll`/`readPagingOffset`/`advanceRealClipBehindCover` (POOT:32–49). `jumpCancelsAnimationAndWritesExactOffset` asserts `jumpTo` writes exactly once through `onScroll` (POOT:52–79). `PagingLifecycleTests` asserts disabling paging stops the display link and produces no further writes (PLT:45–64).

**Boundary**: `GridViewController` may route/forward offsets but must never originate a clip write outside the paging engine. `LauncherWindowController` and the Library surface reuse the same engine (`handleAppLibraryHorizontalScroll` → `paging.handleWheel`, GVC:1711–1714) and must not create a second writer/settle.

---

## 7. Focused tests required (mapped to existing coverage + gaps)

| Required focus | Existing coverage | Gap |
|---|---|---|
| **Data replacement** | `dataRefreshShutsDownPageCompositor` (PCGIT:482–508) — active compositor retired before page-model replacement; `snapshotRecheckDropsStaleVisualsOnce` (PCGIT:584–619) — stale visual dropped on mid-prepare revision bump | None |
| **Geometry** | Unit: `keyComponentInvalidation` geometry component (PVCT:82–88) | **GAP — no integration test** that `applyGeometryConfig` (GVC:782) tears down an active compositor, purges the cache, and rebuilds under the new geometry signature. `applyGeometryConfig` is only exercised in `DragRepresentationTests:129` (non-compositor context). |
| **Scale** | Unit: `keyComponentInvalidation` scale component (PVCT:78) | **GAP — no integration test** that a backing-scale change (`viewDidLayout`, GVC:461–468) tears down the compositor, purges, and rebuilds at the new scale. No test references `lastCompositorBackingScale` or the scale-change branch. |
| **Memory pressure** | `MemoryPressurePurgeTests` — register on load, purge on trigger, deinit teardown, idempotent teardown (MPPT:14–57) | **Partial GAP** — no test that purge → `schedulePageVisualPrepare` (GVC:418–421) actually rebuilds the working set (the "blank page" regression the reschedule exists to prevent). |
| **Idempotent shutdown** | `PageCompositorTests.shutdownIdempotent` (PCT:191–214); `PagingDisplayLinkLifecycleTests.shutdownIsIdempotent` (PDLLT:36–45) | None |

**Recommended focused tests (proportional, not RED/GREEN):**
1. **Geometry**: drive `applyGeometryConfig` while compositor active → assert `!pageCompositorActiveForDiag`, cache purged, then `waitPrepared` rebuilds 3 pages under the new geometry signature.
2. **Scale**: simulate backing-scale change through the `viewDidLayout` branch → assert compositor shutdown + purge + rebuild at new `backingScale` (key `backingScale` component changes).
3. **Memory pressure rebuild**: after `triggerMemoryPressurePurgeForDiag`, assert `schedulePageVisualPrepare` repopulates the working set to 3 (guards the blank-page regression).
4. **Drag-begin shutdown**: assert `shutdownPageCompositor` is invoked on drag begin (currently only the eligibility gate `dragController?.isDragging` is tested at PCGIT:143–155; the LWC:1296/1355 shutdown calls are untested at the Grid level).

---

## 8. Risks, unknowns, and [DEFER BASIS]

- **Risk — compositor eligibility coupling**: `compositorCanActivate` (GVC:1392–1414) reads a large, implicit set of `GridViewController` state. Any future change to `searchMode`/`currentSurface`/`dragController`/`pageCount`/`geometry`/`lastPreparedLanguageRevision` semantics silently changes compositor eligibility. This coupling is the *reason* a separate coordinator is not warranted, but it should be documented as a single-owner invariant.
- **Risk — in-flight prepare not cancelled**: `schedulePageVisualPrepare` cancels only the 100 ms debounce shell, not the already-running `pageVisualPrepareInFlight` (F10, GVC:1502–1505). The snapshot recheck (GVC:1611–1621) is the only guard against a stale insert after a structural change. If the recheck ever regresses, stale visuals can enter the cache mid-gesture.
- **Risk — `lastPreparedLanguageRevision` staleness**: committed only on full success (GVC:1629–1631); a recheck failure leaves it stale. Intentional, but a subtle source of a one-round mismatch between the committed language revision and the actual cache keys.
- **Unknown — default-on state**: `pageVisualCompositorEnabled` defaults on (v0.5.0, GVC:162–169) with `--disable-pagecompositor` as the kill switch. Whether this is the intended Phase 3 production posture is a product decision, not an ownership finding.
- **Unknown — `NSScreen.main` fallback**: `currentBackingScale` falls back to `NSScreen.main` (GVC:1634–1639). The Phase 3 intent flags "window receives actual screen/geometry context rather than guessing with `NSScreen.main`" (10-intent.md:21). This is a separate audit concern (window/geometry), not a PageVisual-ownership defect.
- **[DEFER BASIS — PageVisualCoordinator]**: Not justified. `GridViewController` already owns every page-visual state object and every input the compositor eligibility reads (§4). Introducing a coordinator would split a single owner into two and create a leaky dependency. Defer unless a future requirement (e.g. page visuals used outside `GridViewController`) creates a genuine second consumer.
- **[DEFER BASIS — PageVisual lifecycle]**: Not applicable. `PageVisual` is a frozen value with no lifecycle to own (§3).

---

## 9. DONE

- **Verdict**: `PageVisual` = no independent lifecycle; `PageVisualCoordinator` = **NO**; `GridViewController` is the single coordinator.
- **Sole-motion-writer invariant**: holds (PagingInteractionController drives all three clip-write paths).
- **Focused test gaps**: geometry integration, scale integration, memory-pressure rebuild, drag-begin shutdown.
- **No implementation performed.** Only this report was created.
- **Evidence anchors**: `PageVisual.swift:79–91`; `PageVisualCache.swift:10–12,71–74,118–233`; `PageVisualRenderer.swift:11–28,240–305`; `PageCompositor.swift:146–260`; `PagingInteractionController.swift:537–555`; `GridViewController.swift:152,157–160,407–453,461–468,612–646,685–726,782–802,984–1035,1262–1328,1335–1378,1392–1494,1506–1632`; `LauncherWindowController.swift:459,1112–1113,1296,1355`; tests `PagingOffsetOwnershipTests.swift:32–49`, `PageCompositorGridIntegrationTests.swift:482–508,584–619`, `MemoryPressurePurgeTests.swift:14–57`, `PageCompositorTests.swift:191–214`, `PagingDisplayLinkLifecycleTests.swift:36–45`.
