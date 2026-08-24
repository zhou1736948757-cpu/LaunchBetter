# LaunchBetter Convergence Phase 2 - Retirement Record

## Anti-Entropy Declaration

- Deletion class: `code-retirement` (internal source code and stale internal bridges).
- Old paths: `DragVisualRepresentation.legacy(image:)`; `DragController.beginFolderExitDrag(... sourceImage:)`; `DragOverlayLayer.configure(... sourceImage:)`; dead `GridViewController.pagedPageBeforeSearch`.
- New canonical owners: value-semantic `DragVisualRepresentation` producers/consumers; `surfaceBeforeSearch` for search restoration.
- Preserved behavior: drag image ownership/lifetime, nil placeholder behavior, session/generation/threshold guards, paging motion ownership, and search surface restoration.
- Retired behavior: bare-CGImage drag bridge overloads, zero-caller compatibility factory, and unused raw page state.
- External boundary touched: no.
- Source-of-truth data risk: none.
- User confirmation required: no.

## Retirement Decision

- Path: `delete-first`.
- Why: all retired paths were internal; repo-wide call-site evidence showed zero active consumers, while semantic representation and `surfaceBeforeSearch` were already live canonical owners.
- Non-edits: no public API, persistent data, schema, external contract, or compatibility boundary was deleted.

## Verification Plan and Results

- Main path: drag focused tests **10/10** passed; full LaunchUI suite **410/62** passed; search restore tests remained green.
- Lingering references: repo-wide Swift grep found zero `sourceImage:` and `.legacy(` references after retirement; `pagedPageBeforeSearch` has no live source reference.
- Negative check: legacy bridge symbols are absent from source while `DragVisualRepresentation` producers/consumers remain active.
- Boundary check: Swift 6.3 Debug/Release builds passed; Release was warning-free; `PagingInteractionController.swift` was untouched.

## Gap Closure

- Gap found: P2-G initially retained the AppCell legacy factory because AppCell was a concurrent single-writer boundary.
- Gap type: `expected-retirement` with a temporary ownership defer.
- Repair action: after P2-A committed, a dedicated follow-up Worker deleted the factory and reviewers reconfirmed zero callers and unchanged AppCell behavior.
- Reintroduced compatibility: no.
- Retirement trigger: AppCell ownership became free and zero-caller evidence was reconfirmed.

## Deferred non-retirement debt

Retained scale fallback, same-size-monitor wallpaper ambiguity, disk-cache parity/eviction, live detail accessibility refresh, brittle source-shape tests, and direct cell stale-result test gaps are not retired paths. Each has a bounded defer basis in `90-evidence.md` and an explicit future trigger; none was expanded into a speculative abstraction.
