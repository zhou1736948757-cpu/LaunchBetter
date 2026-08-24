# LaunchBetter Phase 4 — Real Runtime Validation & Performance Hardening

## TaskIntentDraft

- Requested outcome: measure real runtime performance on actual hardware, identify bottlenecks, and fix only evidence-backed issues.
- Plan order: P4-00 environment + harness; P4-01 baseline matrix; P4-02 instruments; P4-03 through P4-12 profiling scenarios; P4-13 findings-based fixes; P4-14 final gate.
- Goal: know where LaunchBetter is slow, where it leaks, where it drops frames, and where it's already good enough.
- Stop condition: common interactions smooth, no significant MainActor spike, no leak, idle healthy, multi-display correct — or hardware gate blocks remaining items.

## BaselineReadSetHint

- Phase 3 final HEAD: `1a4aa18`
- Phase 3 evidence: `Docs/aegis/work/2026-08-25-launchbetter-convergence-phase3/90-evidence.md`
- Test baseline: LaunchUI 417/64, LaunchCore 200/16, LaunchPlatform 149/23, Debug/Release warning-free
- App target: BUILD SUCCEEDED

## Runtime Environment (P4-00A)

- macOS 26.5.2 (Build 25F84)
- CPU: Apple M3
- RAM: 16 GB
- Display: Built-in Liquid Retina, 2560×1664, Retina (2x), Main Display
- Trackpad: Force Touch trackpad (built-in)
- No external display connected in this session
- Xcode: latest (SDK MacOSX26.5)

## ImpactStatementDraft

- Affected layers: potential production optimizations only with evidence; measurement hooks (signposts/counters) if needed; test probes.
- Invariants: PagingInteractionController sole motion writer; displayRevision only for grid-visible changes; PageVisual key-driven invalidation; no new coordinators; no new frameworks.
- Non-goals: SwiftUI rewrite, Combine, new DI, new runtime package, generic scheduler/cache, IconRepository rewrite without evidence, NSCollectionView replacement, paging motion writer duplication.