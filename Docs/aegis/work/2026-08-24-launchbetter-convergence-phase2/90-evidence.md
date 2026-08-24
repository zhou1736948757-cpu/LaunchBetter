# LaunchBetter Convergence Phase 2 - Evidence

## Scope and baseline

- Baseline: Phase 1 verified HEAD `3116188a84f8dcb9f19394ee066046d91d90fd28` on `main`.
- Worktree boundary: `/Users/mac/Projects/LaunchBetter`; the separate `siren` worktree was not touched.
- Invariants held: one production writer per overlapping file; `PagingInteractionController` remains the sole motion writer; public `RenderRequest` and drag contracts remain compatible; stale-result, generation, cancellation, cache/source identity, and dependency-direction guards remain intact.

## Scoped implementation and review receipts

### P2-A — lazy FolderThumbnailView allocation

- `AppCellView.folderThumbnailView` is now optional and created only by `configureFolder`; ordinary app cells do not carry the folder hierarchy.
- Folder-to-folder configuration reuses the same instance; app configuration removes/releases it; the next folder configuration recreates it.
- Focused suite: `swift test --filter AppCellFolderThumbnailLazyAllocationTests` — **6/6 passed**.
- Spec Reviewer `e13d7fe9`: PASS. Code-quality Reviewer `0da44c8f`: PASS.
- Commit: `38145e9 perf(launchui): lazily allocate folder thumbnails`.

### P2-C — wallpaper cache/source convergence

- Memory cache identity normalizes away window-local frame origin while retaining render-affecting dimensions, scale, blur, and source identity.
- Source selection uses deterministic best matching request frame size with preserved wallpaper fallback behavior.
- `CIContext` is shared lazily within `WallpaperProvider`; final Swift 6.3 spelling is plain `private static let` because the compiler reports `CIContext` as Sendable.
- Focused suite: `swift test --filter WallpaperProviderTests` — **8/8 passed** after the final spelling correction.
- Spec Reviewer `36d91698`: PASS with bounded MINORs. Code-quality Reviewer `c530dfcc`: PASS after the compiler-driven correction.
- Debug and Release package builds passed; final Release build was warning-free.
- Commits: `27935db perf(launchui): converge wallpaper cache rendering`; `bbed916 fix(launchui): use sendable wallpaper context`.
- Deferred: same-size monitor identity ambiguity, disk-key scale/parity and eviction/LRU, non-finite public-input hardening, and unmeasured render-performance claims. No disk LRU or public API expansion was introduced.

### P2-G — semantic drag representation and accessibility/scale boundary

- Folder child overlay and folder-exit handoff now carry `DragVisualRepresentation?` end-to-end; bare `CGImage` bridge overloads were removed.
- The final zero-caller `DragVisualRepresentation.legacy(image:)` factory was retired only after repo-wide zero-caller evidence.
- Focused drag evidence: `DragRepresentationTests` **5/5**, `FolderExitMouseSessionTests` **3/3**, `DragFrameIsolationTests` **2/2** — **10/10 passed**.
- Repo-wide Swift grep confirmed zero `sourceImage:` and `.legacy(` references.
- Detail-row Reduce Motion is read once at load level and reused by all rows. The final falsifying test injects the opposite of the live setting and asserts both controller and row use the injected cached value.
- Chief detail suite: `swift test --filter AppLibraryViewTests` — **47/47 passed** after the falsification correction.
- Drag Spec Reviewer `54cf025e`: PASS; drag Code-quality Reviewer `ec6111e7`: PASS. Cache Spec re-review `1096bbee`: PASS; cache Code-quality Reviewer `ebe0542a`: PASS.
- Commits: `c771749 refactor(launchui): use semantic drag representations`; `d8b35b1 perf(launchui): cache detail motion snapshot`.
- Deferred: nil-representation `NSScreen.main` scale fallback, source-shape test brittleness, and live Reduce Motion changes while an already-presented detail remains on its load snapshot. The last defer has a named future owner/trigger: a detail reload entry point modeled on the parent F9 observer path.

### P2-H — semantic cleanup

- App Library placeholder color now uses the canonical sum-of-unicode-scalars modulo-12 index used by the main grid/folder paths.
- Detail-row far release always restores transform without dispatching selection; within-threshold click behavior, 6pt click threshold, 5pt drag threshold distinction, and preserved unpaired mouseUp semantics remain explicit and tested.
- Dead `pagedPageBeforeSearch` was removed; `surfaceBeforeSearch` remains the canonical search restore state.
- Spec Reviewer `e5409521`: PASS. Code-quality Reviewer `c54b945b`: PASS.
- Covered by the App Library focused suite above plus `AppIconPlaceholderCacheTests` **5/5**.
- Commit: `02e6f34 fix(launchui): align library semantics`.
- Deferred: cross-surface pixel-level placeholder parity harness, theoretical `abs(Int.min)` overflow, self-referential formula-strengthening, and product decision on synthetic/unpaired mouseUp selection semantics.

### P2-D — icon lifecycle decision

- Read-only audit confirmed generation/identity/cancellation guards, bounded fan-out, repository in-flight deduplication, and adapter content-version checks are correct across the four cell consumers.
- No shared helper or global decode budget was added: variation in identity/apply targets is high and no measured decode overload exists.
- Deferred triggers are measured decode overload, a correctness defect, or a fifth materially divergent consumer; missing direct AppCell/detail stale-result tests remain a bounded test debt.

## Final verification

- Full package test command: `cd Packages/LaunchUI && swift test` — **410 tests in 62 suites passed, exit 0** after all final code changes.
- Debug build: `swift build -c debug` — passed.
- Release build: `swift build -c release` — passed with no warnings after `bbed916`.
- Diff hygiene: `git diff --check` — clean at each slice and final code state.
- Existing package runtime probes emitted localization/layout and A4 measurement output during the full suite; no new runtime probe artifact or physical device claim was fabricated.

## Manual and remaining gates

- Not claimed as executed: physical 1x↔2x display switching, 120Hz trackpad interaction, and live accessibility-settings switching on hardware. These remain explicit manual gates from the Phase 1/Phase 2 plan.
- No top-level application runtime session was claimed from package tests alone.
- No persistence/schema, external contract, Launchpad_Back, new package, SwiftUI grid rewrite, global manager, disk LRU, or broad dependency upgrade was introduced.

## Commit receipt

Final Phase 2 code commits, in order:

1. `38145e9` — lazy folder thumbnails
2. `27935db` — wallpaper cache/source fixes
3. `02e6f34` — App Library semantic cleanup
4. `c771749` — semantic drag representation migration and legacy retirement
5. `d8b35b1` — detail motion snapshot cache
6. `bbed916` — warning-free Sendable CIContext spelling

The remaining uncommitted paths at evidence drafting time are Aegis workspace records only: `Docs/aegis/INDEX.md` and `Docs/aegis/work/2026-08-24-launchbetter-convergence-phase2/`.
