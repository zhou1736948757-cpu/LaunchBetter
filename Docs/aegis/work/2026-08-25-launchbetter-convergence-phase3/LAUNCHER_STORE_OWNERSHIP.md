# P3-F — LauncherStore Catalog-Refresh Orchestration Ownership Audit

- **Task**: P3-F read-only orchestration ownership audit (Store catalog orchestration).
- **Repo**: `/Users/mac/Projects/LaunchBetter`, baseline HEAD `79ad4abbda144344f520cac66aca25bda1c27f02`, clean `main`.
- **Mode**: read-only. No production source or Git edits. Only this file is created.
- **Scope**: `LauncherStore` + catalog/layout adapters (`AppCatalogActor`, `LayoutStore`, `LayoutSnapshotStore`, `LayoutReconciler`, `DirectoryMonitor`, `AppLibraryMetadataStore`, `RetryBackoff`) + wiring (`DependencyContainer`) + focused tests.
- **Verdict (headline)**: **A truly independent `CatalogRefreshCoordinator` is NOT justified.** The catalog-refresh orchestration is a LauncherStore-internal workflow whose output is LauncherStore's own `@MainActor` snapshot/index/layout/publication state. Extracting it would either move those fields out of the store (violating the Phase 3 invariant "current snapshots stay with LauncherStore") or create a coordinator that merely calls back into the store (not independent). The current private `drainExternalCatalogRefreshes()` is the correct owner. A smaller, safe, optional alternative is a pure decision helper; it is not required.

---

## 1. Ownership classification

### 1.1 State fields (`LaunchBetterApp/LauncherStore.swift`)

| Field | Line | Class |
|---|---|---|
| `catalogSnapshot` | 69 | **Snapshot** (MainActor cache of `AppCatalogActor.snapshot`) |
| `catalogIndex` | 70 | **Derived Index** (from `catalogSnapshot.apps`) |
| `layout` | 71 | **Snapshot** (MainActor cache of `LayoutStore.layout`) |
| `config` | 72 | **Snapshot** (MainActor cache of `SettingsStore`) |
| `searchIndex` | 73 | **Derived Index** (from catalog + config display names) |
| `metadataSnapshot` | 75 | **Snapshot** (MainActor cache of `AppLibraryMetadataStore.memory`) |
| `libraryModelCache` | 77 | **Derived Index** (memory-only App Library model) |
| `libraryModelDirty` | 80 | **Coordination** (lazy rebuild flag) |
| `layoutMutationInFlight` | 82 | **Coordination** (mutation serialization gate) |
| `externalCatalogRefreshPending` | 85 | **Coordination** (drain coalescing flag) |
| `externalCatalogRefreshTask` | 86 | **Coordination** (drain task handle) |
| `cachedDisplayModel` / `cachedDisplayModelRevision` | 397–398 | **Derived Index** (revision-keyed display cache) |
| `displayRevision` | 104 | **Publication** (revision counter) |
| `searchIndexRebuildCount` / `notifyCount` | 107–108 | **Side Effects / diagnostics** |

### 1.2 Methods

| Method | Line | Class |
|---|---|---|
| `bumpRevision()` | 110–112 | **Publication** |
| `notifyDataChange()` | 114–121 | **Publication** (side effect: `onDataChange` + observers) |
| `bootstrap()` | 175–185 | **Coordination** (startup orchestration) |
| `reconcileInBackground()` | 198–203 | **Coordination** (startup full reconcile) |
| `applySnapshot(_:)` | 205–213 | **Coordination** (change-trigger; does NOT assign — see §3) |
| `commitLayoutChange(...)` | 217–231 | **Coordination + Publication** |
| `performSerializedLayoutChange(...)` | 233–260 | **Coordination** (mutation serialization) |
| `rebuildCatalogIndex()` | 262–264 | **Derived Index** |
| `rebuildSearchIndex()` | 266–277 | **Derived Index** |
| `rebuildLibraryModel()` | 310–318 | **Derived Index** |
| `applyMetadataSnapshot(_:)` | 322–330 | **Coordination + Publication** |
| `flushMetadataForTermination()` | 335–345 | **Side Effects** (termination bridge) |
| `displayModel()` | 400–412 | **Derived Index** (revision-keyed cache) |
| `catalogDidChangeExternally()` | 600–606 | **Coordination** (public entry; coalescing) |
| `drainExternalCatalogRefreshes()` | 608–665 | **Coordination + Publication** (the orchestration under audit) |

---

## 2. Catalog-refresh orchestration trace

### 2.1 Entry points that reach the drain

1. **Startup** — `bootstrap()` (175–185): `layoutStore.start` → `metadataStore.start` → `catalogActor.start(seed:)` → `bootstrapLibraryMetadata` → `applySnapshot(result.snapshot)` (183) → `reconcileInBackground()` (184).
2. **FSEvents** — `DependencyContainer.swift:145–152`: `directoryMonitor.onChange` → `catalogActor.applyChangeSummary(summary)` → if delta non-empty → `store.catalogDidChangeExternally()` (150).
3. **Custom sources** — `DependencyContainer.swift:158–171`: `store.onCustomSourcesChange` → `directoryMonitor.reconfigure` → `catalogActor.updateSources(fullSources)` → if delta non-empty → `store.catalogDidChangeExternally()` (168).
4. **Internal** — `applySnapshot(_:)` (205–213) calls `catalogDidChangeExternally()` (212) when the incoming snapshot differs from the cache.

### 2.2 The drain loop (`drainExternalCatalogRefreshes`, 608–665)

```
while externalCatalogRefreshPending {          // 610
  externalCatalogRefreshPending = false        // 611
  generation = catalogActor.snapshotGeneration()          // 612
  snapshot = catalogActor.currentSnapshot(ifGeneration:)   // 613
  if nil → pending=true, retry.reset(), continue          // 614–618
  result = layoutStore.reconcileWithResult(catalog:now:)  // 619
  if !result.committed → pending=true, sleep(backoff), continue  // 620–631
  if currentSnapshot(ifGeneration:) == nil → pending=true, retry.reset(), continue  // 632–638
  retry.reset()                                            // 640
  catalogSnapshot = snapshot; rebuildCatalogIndex()        // 641–642
  layout = result.layout; rebuildSearchIndex()             // 643–644
  bumpRevision(); notifyDataChange()                        // 645–646
  Task { recordDiscovered(appIDs: catalogSnapshot.apps) → applyMetadataSnapshot }  // 649–657
}
externalCatalogRefreshTask = nil                            // 659
if externalCatalogRefreshPending { catalogDidChangeExternally() }  // 662–664
```

### 2.3 Coalescing correctness

- `catalogDidChangeExternally()` (600–606) sets `pending=true` and only spawns a task if `externalCatalogRefreshTask == nil` (602). A running task picks up the flag on its next loop iteration.
- The loop clears the flag at the top of each iteration (611); any call during an `await` re-sets it and is seen on the next iteration.
- The defensive restart (662–664) covers a call landing between the last clear and `task = nil`.
- **Verdict**: coalescing is correct; no duplicate drain task can run concurrently.

---

## 3. Is a truly independent `CatalogRefreshCoordinator` justified? — **NO**

### 3.1 Why not

The drain loop's output is **LauncherStore's own `@MainActor` state and publication**:

- It writes `catalogSnapshot` (641), `catalogIndex` (642), `layout` (643), `searchIndex` (644), `displayRevision` (645), and calls `notifyDataChange()` (646).
- It spawns a task that calls `applyMetadataSnapshot` (651), which writes `metadataSnapshot`, `libraryModelDirty`, `bumpRevision`, `notifyDataChange` (322–330).
- All of these are `private`/`private(set)` fields of the `@MainActor` `LauncherStore` (69–86, 104).

A "truly independent" coordinator would have to **own** those fields to be independent. That directly violates the Phase 3 invariant **"current snapshots stay with LauncherStore"** (`10-intent.md:21`). The alternative — a coordinator that calls back into the store to mutate them — is not independent; it is a helper that delegates the actual state mutation back to the store, adding a layer without adding ownership.

### 3.2 The orchestration is already decomposed at the right seams

- **Stale-result protection** is owned by `AppCatalogActor` via `snapshotGeneration()` (136–138) + `currentSnapshot(ifGeneration:)` (141–143). The drain is a *consumer* of that contract, not its owner.
- **Retry/backoff scheduling** is already a pure value type `RetryBackoff` in `LaunchCore` (`RetryBackoff.swift:8–39`), with its own tests. The drain only calls `nextDelayMilliseconds()` / `reset()`.
- **Layout reconciliation** is owned by `LayoutStore.reconcileWithResult` (`LayoutStore.swift:83–90`) → `LayoutReconciler` (pure, `LayoutReconciler.swift:117–186`).
- **Persistence durability** is owned by `LayoutStore.commit`/`commitReconciliation` (`LayoutStore.swift:150–194`).
- **Catalog discovery/persistence** is owned by `AppCatalogActor` (`reconcileFromDisk` 152–185, `applyChangeSummary` 271–289, `updateSources` 195–213).

What remains in the drain is exactly the **store-local glue**: coalescing, generation re-check, retry loop, and publishing to the store's own cache. That glue is correctly owned by the store.

### 3.3 Public/protocol surface

- `catalogDidChangeExternally()` is `public` but **not** part of any protocol (`LauncherStoring`, `LayoutMutationCompleting`, `SettingsHandling`, `AppLibraryDataProviding`, `AppLibraryCategoryOverriding` — `LauncherStoring.swift:25,128,163,173`). It is called only by `DependencyContainer` (150, 168) on the concrete type.
- LaunchUI does **not** reference `catalogDidChangeExternally` or `drainExternalCatalogRefreshes` (grep: zero matches in `Packages/LaunchUI`). The orchestration is app-layer-internal.
- Moving it to a coordinator would change the `DependencyContainer` call sites (150, 168) and add a new type for no ownership gain.

### 3.4 Smaller safe alternative (optional, not required)

If direct test coverage of the drain's control flow is desired, extract only the **pure decision** into a testable helper while the store keeps ownership of applying the result:

- Input (frozen): `generation: Int`, `snapshot: CatalogSnapshot?`, `reconcileResult: LayoutStore.ReconcileCommitResult`, `isCurrent: Bool`.
- Output: an enum `CatalogRefreshStep { case publish(snapshot, layout), retry(delayMs), restart }`.
- The store's drain loop then switches on the step and performs the publish (641–646) itself.

This keeps all store fields in the store, adds no new owner, and makes the generation/retry/coalescing decision unit-testable. It is a refactor, not a new independent coordinator, and is **deferred** (see §10) because the current loop is correct and only ~57 lines.

---

## 4. Second current-state source of truth

- **Catalog**: `AppCatalogActor.snapshot` (42) is authoritative; `LauncherStore.catalogSnapshot` (69) is a MainActor cache. The cache is written only in the drain (641) after a generation-checked read, so it is always synced to the actor's latest at publish time. This is the documented §62 cache pattern (`LauncherStore.swift:50–51`). **Not a second source of truth** — a cache with a defined sync path.
- **Layout**: `LayoutStore.layout` (32) is authoritative; `LauncherStore.layout` (71) is a cache, synced via `commitLayoutChange` re-read (`currentLayout()`, 221) and the drain (643). Same pattern.
- **Metadata**: `AppLibraryMetadataStore.memory` (20) is authoritative; `LauncherStore.metadataSnapshot` (75) is a cache, synced via `applyMetadataSnapshot` (322–330).
- **Config**: `SettingsStore` is authoritative; `LauncherStore.config` (72) is a cache, synced via `save` (697).

No field in `LauncherStore` is a second *authoritative* source; all are caches with explicit sync points.

---

## 5. Stale-result hazards

- **Drain**: generation-checked at 612–613 and re-checked at 632 after layout persistence. Correct.
- **`applySnapshot`** (205–213): short-circuits on `snapshot == catalogSnapshot` (Equatable) and otherwise only *triggers* a drain (212). It never assigns `catalogSnapshot` directly — the drain re-reads the latest generation. So a stale `applySnapshot` argument cannot publish stale state.
- **`reconcileInBackground`** (198–203): reads `currentSnapshot()` (201) without `ifGeneration`. However, `applySnapshot` only triggers a drain, and the drain re-validates generation before publishing. **No stale publication**; the un-checked read is a benign minor observation (a newer snapshot may be read, but the drain re-reads anyway).
- **`recordDiscovered` task** (649–657): reads `self.catalogSnapshot.apps` at task-run time; `recordDiscovered` is idempotent (only writes `firstSeen` for new IDs, `AppLibraryMetadataStore.swift:97–115`), so a newer snapshot is harmless. Comment at 648 documents the generation guard.

**Verdict**: no stale-result hazard in the catalog-refresh path.

---

## 6. Duplicate publication

- A single catalog refresh that **discovers new apps** emits **two** `onDataChange` notifications:
  1. The drain publish (646).
  2. The `recordDiscovered` → `applyMetadataSnapshot` path (649–657 → 329), which bumps revision and notifies again when the metadata snapshot changes.
- When no new apps appear, `recordDiscovered` returns the same snapshot and `applyMetadataSnapshot` no-ops (guard at 323), so only one notification is emitted.
- **Assessment**: not a correctness bug (catalog change and metadata change are two distinct data changes), but a minor double-refresh inefficiency on the new-app path. Flagged as a risk (§9).

---

## 7. MainActor blocking

- `LauncherStore` is `@MainActor` (53). The drain loop runs on MainActor but every heavy step is an `await` on an actor (`catalogActor`, `layoutStore`, `metadataStore`), which hops off MainActor. The synchronous parts (`rebuildCatalogIndex` 262–264, `rebuildSearchIndex` 266–277, `bumpRevision`, `notifyDataChange`) are O(n) over apps but bounded and non-blocking.
- `bootstrap()` (175–185) runs in a `Task` from `init` (170–172) and awaits actor calls; no MainActor stall.
- `flushMetadataForTermination()` (335–345) deliberately uses `Task.detached` + a semaphore and **never** `DispatchQueue.main.sync` — no MainActor deadlock.
- **Verdict**: no MainActor blocking in the catalog-refresh path.

---

## 8. Protocol / public API constraints

- `catalogDidChangeExternally()` is `public` on the concrete `LauncherStore` but not a protocol requirement; only `DependencyContainer` calls it (150, 168).
- The store's protocol conformances (`LauncherStoring`, `LayoutMutationCompleting`, `SettingsHandling`, `AppLibraryDataProviding`, `AppLibraryCategoryOverriding`) do not expose the catalog-refresh entry. LaunchUI depends only on those protocols and never touches the refresh path.
- Any coordinator extraction would change `DependencyContainer` call sites and add a public type; no protocol change is required or warranted.

---

## 9. Risks

1. **Duplicate notification on new-app discovery** (§6): two `onDataChange` emissions for one logical "new app" event. Minor; not a correctness defect. If addressed, the fix belongs in the drain's publish/`recordDiscovered` sequencing, not a new coordinator.
2. **`reconcileInBackground` un-checked `currentSnapshot()` read** (§5): benign today because `applySnapshot` only triggers a re-validating drain; a future direct assignment would reintroduce a stale window. Keep `applySnapshot` as a trigger-only method.
3. **No direct test of the drain loop** (§11): coalescing, generation re-check, retry/backoff, and the publish sequence are untested at the `LauncherStore` level. Bounded test debt; the underlying seams (actor generation, `RetryBackoff`, `LayoutStore.reconcileWithResult`) are tested.
4. **`applySnapshot` naming** (205–213): it does not apply; it triggers. A future reader may assume it assigns `catalogSnapshot`. Documentation-only concern.

---

## 10. Non-goals

- No new `CatalogRefreshCoordinator` type, no new package, no global/DI framework.
- No move of `catalogSnapshot`/`catalogIndex`/`layout`/`searchIndex`/`displayRevision`/`notifyDataChange` out of `LauncherStore` (Phase 3 invariant: current snapshots stay with LauncherStore).
- No change to `AppCatalogActor`, `LayoutStore`, `LayoutSnapshotStore`, `LayoutReconciler`, `DirectoryMonitor`, `AppLibraryMetadataStore`, or `RetryBackoff` semantics.
- No change to the `catalogDidChangeExternally()` public entry or `DependencyContainer` wiring.
- No implementation in this audit.

---

## 11. Focused test mapping (generation / retry / publication)

| Concern | Covered by | Evidence |
|---|---|---|
| Actor generation + stale rejection | `AppCatalogActorTests` | `StoreTests.swift:224–233` (`snapshotGeneration`, `currentSnapshot(ifGeneration:)` nil on old gen) |
| Actor reconcile persist/restore | `AppCatalogActorTests` | `StoreTests.swift:212–244` |
| Actor removed delta | `AppCatalogActorTests` | `StoreTests.swift:246–266` |
| Actor corruption recovery | `AppCatalogActorTests` | `StoreTests.swift:268–285` |
| Incremental `applyChangeSummary` | `FSEventsTests` | `FSEventsTests.swift:310–381` |
| Stale/current `applyChangeSummary` + `updateSources` | `CustomSourceTests` | `CustomSourceTests.swift:240–253`, `26–39`, `189–193` |
| Layout reconcile commit | `LayoutStoreTests` | `LayoutStoreTests.swift:146–170` (`reconcileWithResult.committed`) |
| Stale `expectedLayout` rejection | `LayoutStoreTests` | `LayoutStoreTests.swift:198–226` |
| Layout persistence failure rollback | `LayoutStoreTests` | `LayoutStoreTests.swift:172–196`, `267–291` |
| Backoff sequence/cap/reset | `RetryBackoffTests` | `Packages/LaunchCore/Tests/LaunchCoreTests/RetryBackoffTests.swift` |
| **Drain loop coalescing / generation re-check / retry / publish** | **NOT directly tested** | no test references `catalogDidChangeExternally`/`drainExternalCatalogRefreshes` (grep: zero) |

**Gap**: the `LauncherStore`-level orchestration (drain coalescing, generation re-check, retry/backoff loop, publish sequence, duplicate-notification path) has no direct test. The seams it composes are individually tested.

---

## 12. [DEFER BASIS]

- **Independent `CatalogRefreshCoordinator`**: **deferred / rejected**. Not justified because its output is LauncherStore's own `@MainActor` snapshot/index/layout/publication state; extraction would violate the "current snapshots stay with LauncherStore" invariant or create a non-independent callback helper. The current private `drainExternalCatalogRefreshes()` is the correct owner.
- **Pure decision-helper extraction** (optional, §3.4): deferred. The current loop is correct and ~57 lines; extraction is a refactor for testability only, not a correctness need. Revisit only if direct drain-loop test coverage is required.
- **Duplicate-notification fix** (§6): deferred. Minor inefficiency on the new-app path; not a correctness defect. Revisit if a measured double-refresh cost appears.
- **`reconcileInBackground` un-checked read** (§5): deferred. Benign today; keep `applySnapshot` trigger-only as the guard.
- **Drain-loop direct tests** (§11): deferred bounded test debt; underlying seams are tested.

---

## 13. Evidence index (exact file:line)

- `LaunchBetterApp/LauncherStore.swift:69–86` — store state fields (snapshot/index/layout/config/search/metadata/library/coordination flags).
- `LaunchBetterApp/LauncherStore.swift:104,110–121` — `displayRevision`, `bumpRevision`, `notifyDataChange` (publication).
- `LaunchBetterApp/LauncherStore.swift:175–185` — `bootstrap()` startup orchestration.
- `LaunchBetterApp/LauncherStore.swift:198–203` — `reconcileInBackground()`.
- `LaunchBetterApp/LauncherStore.swift:205–213` — `applySnapshot()` trigger-only short-circuit.
- `LaunchBetterApp/LauncherStore.swift:217–231,233–260` — layout commit + mutation serialization.
- `LaunchBetterApp/LauncherStore.swift:262–277,310–318,400–412` — derived indexes.
- `LaunchBetterApp/LauncherStore.swift:322–330` — `applyMetadataSnapshot` (coordination + publication).
- `LaunchBetterApp/LauncherStore.swift:335–345` — termination flush bridge (no `main.sync`).
- `LaunchBetterApp/LauncherStore.swift:600–606` — `catalogDidChangeExternally()` coalescing entry.
- `LaunchBetterApp/LauncherStore.swift:608–665` — `drainExternalCatalogRefreshes()` orchestration.
- `LaunchBetterApp/LauncherStore.swift:641–646` — publish (snapshot/index/layout/search/revision/notify).
- `LaunchBetterApp/LauncherStore.swift:649–657` — `recordDiscovered` task (duplicate-notification source).
- `Packages/LaunchPlatform/Sources/LaunchPlatform/AppCatalogActor.swift:42–43,136–143` — authoritative snapshot + generation contract.
- `Packages/LaunchPlatform/Sources/LaunchPlatform/AppCatalogActor.swift:152–185,195–213,271–289` — reconcile/updateSources/applyChangeSummary.
- `Packages/LaunchPlatform/Sources/LaunchPlatform/LayoutStore.swift:32,74–90,150–194` — authoritative layout + reconcile + durability.
- `Packages/LaunchCore/Sources/LaunchCore/LayoutReconciler.swift:117–186` — pure reconciliation.
- `Packages/LaunchCore/Sources/LaunchCore/RetryBackoff.swift:8–39` — pure backoff scheduling.
- `Packages/LaunchPlatform/Sources/LaunchPlatform/AppLibraryMetadataStore.swift:20,97–115,169–176` — metadata authoritative state + idempotent `recordDiscovered`.
- `LaunchBetterApp/DependencyContainer.swift:145–152,158–171` — FSEvents + custom-source wiring to `catalogDidChangeExternally`.
- `Packages/LaunchUI/Sources/LaunchUI/LauncherStoring.swift:25,128,163,173` — protocols (refresh not exposed).
- Tests: `StoreTests.swift:199–286`, `LayoutStoreTests.swift:17–321`, `FSEventsTests.swift:310–381`, `CustomSourceTests.swift:240–253`, `RetryBackoffTests.swift`.
- Invariant: `Docs/aegis/work/2026-08-25-launchbetter-convergence-phase3/10-intent.md:21` ("current snapshots stay with LauncherStore").

---

## 14. DONE

Read-only audit complete. No production source or Git changes. Only this file was created. Verdict: **no independent `CatalogRefreshCoordinator`**; the private `drainExternalCatalogRefreshes()` is the correct owner, with a smaller optional pure-decision helper deferred. Risks, non-goals, test mapping, and defer basis recorded above.
