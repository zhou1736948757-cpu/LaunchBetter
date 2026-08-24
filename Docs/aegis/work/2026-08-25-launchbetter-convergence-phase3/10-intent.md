# LaunchBetter Convergence Phase 3 - Intent

## TaskIntentDraft

- Requested outcome: converge long-lived ownership in `GridViewController`, `LauncherWindowController`, and `LauncherStore` without redesigning healthy pipelines.
- Plan order: P3-00 baseline; parallel ownership/publication audits; PageVisual ownership first; Grid convergence; Background and Settings ownership; Store catalog orchestration; publication/runtime/manual gates; retirement; final evidence.
- Goal: establish one owner for independent lifecycle, invalidation, resource ownership, and async workflow while preserving runtime behavior and Phase 1/2 baselines.
- Stop condition: stop for a product behavior decision, public/external contract uncertainty, persistence/source-of-truth risk, unrelated dirty work, new framework/package pressure, repeated verification failure, or an architecture review that proves a proposed owner is not independent enough.

## BaselineReadSetHint

- Phase 2 final HEAD: `79ad4abbda144344f520cac66aca25bda1c27f02`.
- Phase 2 evidence: `Docs/aegis/work/2026-08-24-launchbetter-convergence-phase2/90-evidence.md`, `95-retirement.md`, `99-reflection.md`, `proof-bundle.md`.
- Required source areas: `GridViewController`, `PageVisualCache`, `PageVisualRenderer`, `PageCompositor`, `PagingInteractionController`, `LauncherWindowController`, `WallpaperProvider`, settings ownership tests/controllers, `LauncherStore`, catalog/layout refresh paths.
- Required policy/baseline: `Docs/Tasks/performance-architecture-convergence.md`, `AGENTS.md`, `MEMORY.md`, module-boundary ADRs, Phase 1 evidence and runtime probes.

## ImpactStatementDraft

- Affected layers: LaunchUI, LaunchCore/LaunchPlatform store adapters if catalog audit proves an independent workflow, tests, and Aegis records.
- Owners: Chief coordinator; implementation Workers routed to Ollama `deepseek-v4-flash:0731`; Spec and Quality Reviewers routed to Ollama `minimax-m2.7`.
- Invariants: `PagingInteractionController` remains the only interactive paging motion writer; semantic page truth stays with Grid; current snapshots stay with LauncherStore; renderer receives immutable/frozen inputs; async generation/cancellation rejects stale results; window receives actual screen/geometry context rather than guessing with `NSScreen.main`.
- Non-goals: SwiftUI rewrite, Combine bus, global state/DI/runtime framework, whole-app actor/protocol migration, new package/persistence/cache architecture, icon pipeline redesign, DragController/LayoutStore/AppCatalogActor semantic changes unless a direct correctness defect is found.

## TDD Route

- Mode: off.
- Decision: skipped; the plan requires proportional focused lifecycle tests, not strict RED/GREEN authority.

## Baseline Evidence

- `git status --short --branch`: clean `main`, ahead 14 of origin.
- Phase 3 start HEAD: `79ad4abbda144344f520cac66aca25bda1c27f02`.
- `cd Packages/LaunchUI && swift test`: **410 tests / 62 suites passed**.
- `swift build -c debug`: passed.
- `swift build -c release`: passed, warning-free.
- Full test runtime probes included A4 measurement and localization/layout probes; A4 observed `flatIndex` 7.056833 µs, inverse 0.705375 µs, 3-page drag 3.16825 ms in this run. These are comparison evidence only, not a performance conclusion.

These records are evidence and planning boundaries; they do not grant completion authority.
