# Stage D Motion System — Execution Contract

## Objective

Make existing LaunchBetter interactions feel responsive, spatially coherent,
restrained, interruptible, and native on macOS. The primary visual deliverable
is source-anchored Folder open/close continuity; the primary technical
deliverable is newest-intent-wins motion without ownership or lifecycle races.

## Preserve

- Current dirty worktree and all post-v0.3.7 commits.
- Settings interaction ownership and full mouse-session shield.
- Folder inline rename, 2-to-1 dissolve, and drag handoff semantics.
- Grid geometry, search separation, page dots, icon caching, no scan on show.
- Paging's single offset writer, velocity handoff, one-page invariant, and
  existing rubber-band behavior unless runtime evidence justifies a change.
- Native Settings titlebar, move, resize, close, and child-window behavior.

## Prohibited

- App Library, categories, AI classification, vertical layout, scenes, hotkey
  recorder, Finder/Dock drag, or any other new launcher feature.
- Moving/reparenting real collection cells for Folder animation.
- Per-frame Auto Layout, snapshots, Store writes, icon IO, tasks, or scanning.
- Private AppKit APIs, titlebar internals, sound, haptics, giant zoom/bounce,
  per-icon choreography, or a universal animation framework.
- Resetting/checking out/stashing over local work; weakening tests.

## Architecture and behavior gates

- Keep semantic Motion specs small; feature-specific coordinators own lifecycle.
- Direct manipulation remains 1:1; press feedback starts on mouseDown.
- Reversal starts from current visible/presentation state and current velocity
  where applicable; generation guards reject stale completions.
- Temporary proxy/layer ownership and teardown are explicit.
- Folder source geometry uses real visible view conversion; invalid sources use
  a restrained central fallback.
- Reduce Motion removes large travel; Reduce Transparency and Increase Contrast
  alter material policy; official accessibility changes update live.
- Settings native movement immediately wins over presentation animation.
- Drag grab offset changes only if observable evidence shows a snap.
- Paging constants change only after actual evidence/A-B testing.

## Validation gates

- LaunchCore, LaunchPlatform, LaunchUI tests; Debug and Release builds.
- Existing diagnostics plus deterministic `--motionprobe` lifecycle invariants.
- Temporal evidence (recording or timed frames) for Launcher, Folder, Settings,
  press, and paging; static screenshots alone are insufficient.
- Trackpad velocity and 120 Hz feel are explicitly `MANUAL_PHYSICAL_GATE` when
  unavailable; never claim them as verified.
- Independent read-only review: zero BLOCKER and zero MAJOR before completion.
- Performance audit covers main-thread spikes, layout storms, proxy/display-link
  teardown, shadow/offscreen cost, and animation accumulation.

## Execution order

M0 baseline → M1 foundation → M2 Launcher → M3 Folder → M4 Settings → M5 press
→ M6 drag audit → M7 paging audit → M8 accessibility/material → M9 performance,
temporal validation, review, documentation, and Git checkpoint.

## Completion labels

Use only `AUTOMATED_VERIFIED`, `VISUAL_VERIFIED`, and
`MANUAL_PHYSICAL_GATE`. Source/tests never imply visual acceptance.
