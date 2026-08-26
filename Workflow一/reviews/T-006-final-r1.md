PASS

# T-006 final independent review (R1-R4)

## Scope and verdict basis

Reviewed the original T-006 scope plus bounded repairs R1-R4, their worker results/reviews, T-005 result/review, R4 scope decision, current working-tree diff, production sources, and tests. No scope-expanding failure was found. The preserved `GridViewController` PageVisual prepare debounce/idle `Task.sleep(100ms)` is explicitly in the required production prepare path, not telemetry formatting or test timing proof, and is allowed/required by the original scope and `.workflow/decisions/T-006-R4-scope.md`.

## Findings by severity

- **BLOCKER:** None.
- **MAJOR:** None.
- **MINOR:** None affecting acceptance.
- **MANUAL:** Physical 60/120 Hz compositor/trackpad validation remains open; this is the explicitly retained `MANUAL_PHYSICAL_GATE`, not an automated-test failure.

## Required-behavior evidence

1. **Active interruption coverage:** `PageCompositor.covers(pages:)` is production coverage logic, independent of `pageIndicesForDiag`. Covered interruptions reuse the active compositor. Uncovered targets call `abort()` before the first new offset write; abort synchronizes the real clip to `currentOffset`, reveals live content, and removes compositor layers without cache preparation/rasterization. Integration and direction-callback tests cover third-page fallback, covered reverse reuse, boundaries, continuity, no stale layers, no blank state, and callback-before-write ordering.
2. **T-005 placement:** The placement document rect adds `leadingDocumentOffset`, page offset, and `gridOrigin.x/y` exactly once, then converts the complete rect. Real integration tests assert minX/minY/width/height through the actual collection-view/view hierarchy across page 0→1, middle, last, and leading-surface cases.
3. **Telemetry:** `GestureTelemetrySnapshot` is immutable and `Sendable`; mutable state is captured/reset on MainActor. Sorting, reduction, p95/max calculation, and `String` formatting run in the asynchronous formatter, outside the final DisplayLink callback. Interruption flushes happen before old settle state reset, and FIFO delivery buffers out-of-order formatter completion while preserving old/new sessions and completion reasons. R2's deterministic formatter gate explicitly releases gesture 1 before gesture 0; R3's show-session test uses gates/latches rather than sleep.
4. **Flag isolation:** The R3/R4 behavior test drives real `PageCompositor.activate/applyOffset` and real telemetry interval/flush behavior for `--pagecompositor` only, `--pagingfeeltelemetry` only, and both. It verifies events/metrics/summaries, not only enabled properties or source strings.
5. **Show lifecycle:** `beginShowSession()` is called from `LauncherWindowController.show()`, not refresh, settle, or search transitions; the deterministic test verifies the first-gesture marker.
6. **Activation classification:** Negative targets are `.targetIsLibrary` only when the leading surface is enabled; otherwise they are `.targetOutOfBounds`. Geometry, placements, finite document/view rects, host/live layers, and post-activation `isActive` are validated before `.activated` is recorded.
7. **Follow curve:** normalizedDamped evaluates gesture-total raw displacement, proving chunk invariance for positive, negative, mixed/reversal, and 60/120 Hz sequences. Default linear preserves the original sensitivity 1.3 accumulation path and required tuning/velocity/spring behavior.
8. **API boundary:** `PagingFollowCurve` is internal to LaunchUI; no LaunchCore source/test residual or new public API remains.
9. **Hot path/architecture:** `applyOffset` guards diagnostics metrics/event work. `advanceRealClipBehindCover()` remains. PagingSpring, fling threshold, rubber band, settle parameters, and other forbidden architecture changes are absent. No commit/push/tag/release was performed.

## Commands and results

- `swift test --package-path Packages/LaunchUI --filter PageCompositorActivationTelemetryTests` — PASS, 6 tests.
- `swift test --package-path Packages/LaunchUI --filter PageCompositorGridIntegrationTests/pagingDiagnosticFlagsAreIndependent` — PASS, 1 test.
- `swift test --package-path Packages/LaunchUI --filter PageCompositorGridIntegrationTests` — PASS, 25 tests.
- `swift test --package-path Packages/LaunchUI --filter PagingInterruptResumeTests` — PASS, 11 tests.
- `swift test --package-path Packages/LaunchCore` — PASS, 200 tests, 0 failures.
- `swift test --package-path Packages/LaunchUI` — PASS, 459 tests, 0 failures.
- `swift test --package-path Packages/LaunchPlatform` — PASS, 149 tests, 0 failures.
- `git diff --check` — PASS.
- Relevant timing-proof scan over `PageCompositorActivationTelemetryTests.swift`, `PageCompositorGridIntegrationTests.swift`, and `PagingInterruptResumeTests.swift` for `Task.sleep`, `Thread.sleep`, and `sleep(` — clean.

## 100ms debounce scope note

The existing `GridViewController` 100ms PageVisual prepare debounce/idle `Task.sleep` remains intentionally unchanged. It is production scheduling required by the original prompt, not telemetry formatting, final-frame work, or test timing proof; R4's no-sleep scope applies to the directly relevant tests only.

## MANUAL_PHYSICAL_GATE

REMAINING/OPEN: run the launcher on a real macOS display with dense pages and verify covered reverse interruption, uncovered third-page interruption, last-page/App Library boundaries, no blank frame, continuous clip/live handoff, and 60/120 Hz behavior. Automated tests do not prove subjective physical smoothness.
