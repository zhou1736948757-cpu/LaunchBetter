# LaunchBetter — Performance & Architecture Convergence

> Source: user-approved convergence prompt, current `main` / `v0.5.4`.
> Scope: behavior-compatible performance, ownership, reuse, and legacy convergence.

## Non-negotiable constraints

- Preserve LaunchCore → LaunchPlatform/LaunchUI → LaunchBetterApp dependency direction.
- LaunchCore remains pure/Sendable and contains no AppKit, SwiftUI, Combine, FileManager, or platform IO.
- Keep the four runtime pipelines separate: catalog data, UI structure, icon resources, and per-frame interaction.
- No new giant Manager/Actor/Generic Framework, global event bus, global ObservableObject, SwiftUI grid rewrite, or whole-Store actorization.
- Preserve existing launcher, Library, Search restore, Folder/drag, Settings, accessibility, motion, context menu, custom names, hidden apps, launch, and PageVisual behavior.
- MainActor hot paths must avoid frame snapshots, disk IO, Info.plist IO, and O(n) AppID lookup when an index exists.
- Every performance claim needs a test, counter, signpost, trace, benchmark, or explicit `MANUAL_PHYSICAL_GATE`.
- Single writer for overlapping production files; implementer does not mutate Git lifecycle; Chef verifies, stages, commits.
- Each task must report files, behavior, performance, invariants, tests, deviations, and risks.

## Execution order

1. **P0 baseline/evidence**: fresh tests/builds and measurable counters where available.
2. **P0 immediate wins**: catalog O(1), settings lookup, shared folder geometry and child sizing, lazy folder hierarchy, typed change domains/revisions, settings no-grid refresh.
3. **P1 runtime convergence**: icon request lifecycle/budget/cache only when evidence supports it; PageVisual/background/settings coordinators; wallpaper platform boundary/key/CIContext only with evidence.
4. **P2 architecture consistency**: drag representation, backing scale, accessibility snapshot, press lifecycle, placeholder/threshold helpers, Store façade/consumer boundaries, actor queue helper, file organization, diagnostics/comments.
5. **P3 deletion/audit**: dead/legacy paths only with read-only evidence, full tests/builds, before/after report, manual gates, remaining debt.

## P0 dependency graph

```text
P0-01 baseline
├─ P0-02 Catalog O(1)
├─ P0-03 Settings hidden lookup
├─ P0-04 FolderThumbnailMetrics
│  └─ P0-05 child icon request sizing
│     └─ P0-06 lazy FolderThumbnailView
├─ P0-08 Search query ownership
└─ P0-09 typed change domains
   └─ P0-10 narrow revisions
      └─ P0-11 settings slider/no unrelated grid refresh
```

## Review gates

Architecture review before change-domain/revision/PageVisual/icon-concurrency/wallpaper/Store/drag tasks. Every implementation slice receives spec review, then code-quality review, then fresh coordinator verification and one scoped commit. Reviewer must challenge ownership, stale-result protection, single writer, cache identity, MainActor hops, actor reentrancy, behavior regression, and overengineering.

## Completion gates

All package tests and Debug/Release builds green; no fabricated physical metrics; performance table reports measured deltas or `MANUAL_PHYSICAL_GATE`; final report includes architecture changes, removed work, complexity, correctness, manual gates, remaining debt, and commit SHAs.
