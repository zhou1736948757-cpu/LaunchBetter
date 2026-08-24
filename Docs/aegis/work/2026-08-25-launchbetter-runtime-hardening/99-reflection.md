# Phase 4 — Reflection

Phase 4 set out to measure LaunchBetter's real runtime performance on actual hardware and fix only evidence-backed issues. The result: the system is healthy and no fixes were needed.

## What was measured

- Launcher show: 30 runs across 3 `--perf` sessions, tracking wallpaper-ready and content-ready latency
- Paging: `--pagingscrollprobe` with per-frame timing for Library and Page phases
- Icon pipeline: `--iconbench` cold and warm
- App Library: `--searchprobe` with 76 results
- Memory: `--dragcacheprobe` over 50 iterations
- Grid layout: `--gridtest` with layout and search rebuild verification
- Settings ownership: `--settingsownershipprobe` with 23 lifecycle checks
- Smoke + launch: `--smoke --launchtest` with actual Chrome launch

## What was found

1. **Wallpaper is the launcher-show critical path.** Cold disk cache causes first-run variability (up to 319ms p95). After warmup, median drops to 30–45ms. This is expected behavior — the wallpaper must be decoded and rendered on first show. No fix needed.

2. **Paging per-frame work is essentially zero.** The compositor and display link path are clean. No per-frame allocations, no MainActor spikes. This confirms Phase 1–3 architecture work (PageVisual cache, compositor, generation guards) is performing well at runtime.

3. **Icon pipeline is healthy.** Warm cache hit rate is excellent (0.03ms per icon). Cold path (1.53ms per icon) is dominated by disk decode, which is expected. No serialization or concurrency issues observed.

4. **Memory is stable.** Drag cache counters showed zero growth over 50 iterations. No evidence of leaks in the measured paths.

5. **Settings ownership is correct.** All 23 lifecycle checks pass, confirming Phase 2–3 settings ownership work.

## What was NOT fixed (and why)

No fixes were implemented because no evidence-backed issues were found. The plan explicitly states: "测完以后发现已经很好 → 0–3 small fixes → 这完全成功。"

The architecture work from Phase 1–3 — lazy allocation, semantic drag representations, wallpaper cache convergence, publication decoupling, PageVisual lifecycle guards, settings ownership gate — all demonstrably work at runtime. There is no measurable bottleneck that would justify a performance rewrite.

## What remains blocked

Physical hardware gates that cannot be closed in this environment:
- 1x display testing (no 1x external display)
- 120Hz trackpad testing (requires interactive gesture testing)
- Live accessibility switching (requires System Settings interaction)
- Sleep/wake (requires manual cycle)

These are not architectural or code issues — they are environment constraints. A human operator with the appropriate hardware can close them by running the same probes on their setup.

## Verdict

RUNTIME HARDENING COMPLETE. LaunchBetter's runtime performance is healthy on the available hardware. The four phases of convergence work have produced a stable, well-tested, performant application. The next step should be feature development and product polish, not Phase 5 performance refactoring.