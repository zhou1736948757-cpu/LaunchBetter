# LaunchBetter — Post-v0.2.3 Architecture Consolidation + Feature Completion + RC Preparation

> OpenCode Mid-Stream Takeover Prompt(最新阶段)。
> 保存日期: 2026-08-10。来源: 用户提供。执行基线: main @ v0.2.3(Codex 阶段)。
> 说明: Prompt 内 "OpenCode Workflow" 章节(§6-8)按用户指示暂不执行,
> 遵循项目已有 Workflow(主对话总控 + 独立 implementer + Luna 评审 + Watchdog)。

---

## 0. MISSION

OpenCode resuming an EXISTING macOS project mid-development. NOT greenfield.

Codex completed v0.2.2 / v0.2.3. No reliable conversational context for all current code.

Tasks:
1. recover the real current project state
2. preserve the good architecture established through v0.2.3
3. Architecture + Invisible Performance Consolidation pass
4. selectively adopt useful findings from BuhoLaunchpad reverse analysis (no proprietary copying)
5. complete remaining meaningful LaunchBetter feature-parity gaps
6. regression / concurrency / performance / GUI validation
7. move LaunchBetter toward Release Candidate quality

Goal: a coherent, maintainable, performant, well-tested native macOS launcher whose remaining risks are known and documented. NOT zero theoretical bugs.

## 1. PROJECT LOCATIONS

- Project: /Users/mac/Projects/LaunchBetter
- GitHub: https://github.com/zhou1736948757-cpu/LaunchBetter
- Baseline: v0.2.3, main
- Legacy (READ ONLY): /Users/mac/Projects/Launchpad_Back
- Buho evidence (READ ONLY): /Users/mac/skills/reverse-skill/work/buholaunchpad-case/

## 2. RETURNING AFTER A CODEX PHASE

Codex completed v0.2.2 + v0.2.3. Do NOT interpret unfamiliar code as disposable. Do NOT restart Stage 1/2. Read handoff, inspect source/tests/git, establish current truth, continue from HEAD.

## 3. FIRST ACTION — RECOVER CURRENT TRUTH

Read MEMORY.md. Inspect git status/branch/log/tags, current v0.2.3 source, PhaseReports, test suites, diagnostics. Authority order: user real-device > runtime behavior > source > tests/diagnostics > git history > MEMORY > reports > assumptions. Runtime/source wins over docs.

## 4. MEMORY.md IS THE CROSS-AGENT HANDOFF

MEMORY is context; CURRENT SOURCE is truth. Update MEMORY at every major stage end (version/branch/commit/work/tests/measurements/manual gates/risks/next). Not a chronological dump.

## 5. CODEX HANDOFF — v0.2.2 / v0.2.3 WORK (PRESERVE)

v0.2.2: three-finger drag coords; blue insertion indicator; drag source visual ownership; duplicate icon behavior; functional folder create/open/add/reorder/drag-out/rename/dissolve; durable mutation completion.

v0.2.3: hidden/missing layout mapping; folder create/dissolve ordering; folder row-boundary/trailing-gap geometry; folder drag visual; localization/accessibility of drag/folder UI; LayoutReconciler normalization; LayoutStore persistence correctness; catalog scan ordering; actor-reentrancy stale protection; FSEvents recovery; diagnostics; regression tests.

Architecture principles (do NOT weaken):
- Layout structural mutations do NOT publish UI success until persistence succeeds
- LayoutStore expected-layout validation rejects stale structural mutations
- AppCatalogActor generation checking (actor isolation alone not atomic across awaits)
- Old scans must not overwrite newer catalog state
- LayoutEditor translates visible-display-space ops back to persistent layout-space, retaining hidden/missing refs
- LayoutReconciler deterministic
- DragController is the ONE root-grid drag engine
- Mouse vs three-finger drag differ only by input source
- Per-frame interaction state does not enter LauncherStore
- Drag/folder sessions use session identity to reject stale callbacks
- Root/folder structural drop waits for actual mutation result
- Cell drag-source visibility is identity-owned (not tied to recyclable NSCollectionViewItem)

## 6. OPENCODE WORKFLOW — (SKIP PER USER; follow existing workflow)

Main = deepseek-v4-flash; Implementer = deepseek-v4-flash variant:max (isolated); Reviewer = gpt-5.6-luna variant:max; Visual = mimo-v2.5; Arbitration = qwen3.8-max (rare); Watchdog = bash/zero-model. Standard cycle: read MEMORY → task package → implementer (when beneficial) → independent verify → Luna review → fix → atomic commits → push → MEMORY → Watchdog.

## 7. THREE HONEST FACTS (keep documented)

FACT 1: isolated implementer tested on simple tasks; major real work (v0.1.6/Stage2) done by main conversation (coupled interaction files; Orca TUI unstable). Implementer = READY, USE WHEN BENEFICIAL, not mandatory.
FACT 2: `opencode run -m` inherits opencode.json permissions, not implementer.md agent-file model (that applies only when Task/agent mechanism invokes the configured agent).
FACT 3: reliable backbone = Main controller, Luna reviewer, Watchdog, runtime probes, pixel-level verification.

## 8. AGENTS / ROUTING — (SKIP PER USER unless stale; update routing section only)

## 9. LUNA REVIEW POLICY

Reviewer gpt-5.6-luna variant:max. DESIGN GATES before high-risk work (persistent schema changes, DisplayItem identity redesign, LauncherStoring decomposition, custom-source architecture, vertical-layout architecture, major concurrency). Luna must inspect actual source + tests + proposed design. STAGE-END REVIEW inspects actual diff, classifies BLOCKER/MAJOR/MINOR/NOTE. Stage close gate: 0 BLOCKER 0 MAJOR. Main controller independently verifies findings; do not blindly obey.

## 10. VISUAL REVIEW POLICY

mimo-v2.5 only with actual evidence. Historical false positives → NEVER change production code solely on visual reviewer. Verify via pixel/dimensions/geometry/screenshots/source/second screenshot/runtime diagnostics. Good targets: clipping, spacing, folder panel, page dots, localization, search overflow, vertical layout, settings, context menus.

## 11. COMPUTER USE / GUI AUTOMATION

Investigate whether current env has trusted Computer-Use-equivalent capability (OpenCode skills, MCP, installed tools, Codex/Claude integrations). Do NOT install unknown third-party desktop-control. If available USE IT (launch, click icons, folders, page dots, context menu, Settings, language, grid, vertical mode, screenshots). Supplements XCTest/probes; must NOT replace real hardware validation. If unavailable: don't block, use existing probes/screenshots. Hardware-only remain MANUAL_VERIFICATION_REQUIRED.

## 12. BUHOLAUNCHPAD BOUNDARY

Reference ONLY. May answer: what behavior exists, what standard AppKit mechanism might help, what product ideas are worth evaluating. May NOT copy code/structures/constants/strings/resources/UI designs. Credible findings: AppKit-based; appears to use NSDraggingSession; interactive page indicators; standard AppKit content-scale inheritance; Scene/multiple-layout; system/Dock integration (high-risk). Do not infer unproven behavior (e.g., NSDraggingSession ≠ Finder/Dock export without runtime/pasteboard evidence).

## 13. PRODUCT DECISIONS

ADOPT/INVESTIGATE NOW: clickable page dots; standard AppKit contents-scale lifecycle if it improves code.
DO NOT COPY: CoreData architecture, search pagination, EditablePageView, low-level sendEvent takeover.
DEFER: external system drag / Finder-Dock export.
REJECT: Dock private database integration.
DEFER LATER POLISH: Scene/multiple layouts, automatic app classification, smart folders (not current priorities).

## 14. NON-NEGOTIABLE ARCHITECTURE

Swift 6 strict concurrency; AppKit + CoreAnimation; LaunchCore/LaunchPlatform/LaunchUI/LaunchBetterApp; AppID = canonical path; versioned persistent schemas; migration/persistence failure keeps previous file; LaunchCore NO AppKit/SwiftUI/Combine/FileManager; NO DispatchQueue.main.sync; NO full scan on show/launch; NO per-frame interaction state in store; main grid NSCollectionView+Diffable+CALayer; GridGeometry central; PagingInteractionController+PageSnapAnimator+display link; ONE DragController; one final layout mutation per drop; icon mem/disk cache + in-flight dedup + stale-gen protection; catalog FSEvents+dirty scope+debounce+recovery. Reject: main.sync, scan on show, giant SwiftUI grid, .id(layoutVersion) full rebuild, CGDisplaySetDisplayMode, giant Codable settings tree, restart-based AppleLanguages localization. Performance priorities: input latency > direct manipulation > animation stability > 60/120Hz consistency > no dropped frames > CPU/wakeups/energy > memory. Principle: optimize invisible duplicate work, NOT visible interaction quality.

## 15. OVERNIGHT EXECUTION MODE

Autonomous sprint; don't stop after small milestones; continue investigate/design/implement/test/review/fix/commit. Pause only for destructive ops, missing credentials, irreversible product decision, non-automatable hardware/manual test, genuine ambiguity. No repetitive summaries.

## 16. STAGE STRUCTURE

- STAGE A: Architecture + Invisible Performance Consolidation + selective Buho improvements
- STAGE B: Remaining Feature Completion / Parity Gaps
- STAGE C: Regression / Performance / GUI Hardening + RC Preparation

Not one giant commit.

---

# STAGE A — ARCHITECTURE + INVISIBLE PERFORMANCE

## A0. BASELINE
Capture baseline before perf changes (show/hide, --perf, --pagingprobe, --dragcacheprobe, --iconbench, --searchprobe, --gridtest, folder open, drag, cold/warm icons, CPU/allocations/wakeups; Instruments when available). Don't optimize purely from intuition.

## A1. FSEVENTS / PERSISTENCE RETRY BACKOFF
Audit LauncherStore.drainExternalCatalogRefreshes(). v0.2.3 may retry failed persistence at fixed ~250ms → replace with deterministic capped backoff (e.g. 250ms/1s/4s/15s/30s cap). Requirements: successful commit resets backoff; new FS activity may accelerate retry; cancellation/shutdown cleanly exits; no busy loop; no lost pending event; no stale publication; durable-before-publish stays. Backoff testable without real sleeps.

## A2. DRAG HOT PATH — REMOVE REDUNDANT SOURCE-HIDE
Audit whether DragController repeats setDragSourceHidden(true, for:) every display frame. If identity-owned source state + configure/reuse reapplication fully guarantees visual ownership, remove redundant per-frame source lookup/write. Tests: hidden immediately, reuse hidden, cross-page hidden, no duplicate source, cancel/drop restore, stale completion no touch.

## A3. DRAG HOT PATH — ONE HIT TEST PER FRAME
Audit separate hoveredFolder(at:) + itemAt(point:) per frame. Coalesce into DragHitTarget (.none/.app/.folder), derive folder target / App→App create-folder dwell / reorder. One hit-test per frame; no UX change; source app can't target itself; folder precedence; dwell preserved; insertion indicator preserved.

## A4. GRID SNAPSHOT INDEX CACHE
Audit repeated dataSource.snapshot() in flatIndex(of:)/indexPath(atFlatIndex:). Optional O(1) cache (identity→flat index, flat→IndexPath). Only if removes meaningful work. Invalidate on catalog/layout/search/folder/geometry changes. Tests: cache == actual Diffable snapshot.

## A5. ICON PIPELINE — VERIFY DOUBLE RASTERIZATION
Audit AppIconProvider.liveIcon + IconRepository.resolve + preDecode. If live provider already returns exact requested pixel size display-ready premultiplied bitmap, don't rasterize again. Keep disk-loaded predecode if useful. Zero degradation, same dims/1x-2x/content version/stale-gen protection. Measure cold icon CPU/latency.

## A6. ICON DISK WRITES OFF FIRST-PAINT CRITICAL PATH
Audit whether first live icon consumer waits for PNG encode + disk write. Disk cache is regenerable. Preferred: live → memory → return to UI; independently controlled DiskCacheWriter (actor or bounded serial worker) → encode → atomic write. No unbounded Task.detached writes, no dozens of concurrent encoders. Dedup by IconKey; bounded; errors don't block UI; clean shutdown; stale key can't overwrite newer; memory correct. Measure first-icon latency + full cold page.

## A7. RETINA CONTENT SCALE — EVALUATE STANDARD APPKIT CALLBACK
Buho evidence suggests standard AppKit content-scale inheritance callback. LaunchBetter uses per-cell NSWindow.didChangeScreenNotification. Verify actual SDK API (NSViewLayerContentsScaleDelegate, layer:shouldInheritContentsScale:fromWindow:) availability/behavior/firing. If sufficient: replace per-cell observers. Keep reRequestIconIfScaleChanged semantic. No unmeasured perf claim. Regression: 1x→2x, 2x→1x, same-scale display change, folder thumbnails, drag reps, no request storm. If insufficient: retain + document.

## A8. CLICKABLE PAGE DOTS
Interactive page indicators. Strongest low-cost UX improvement. MUST reuse PagingInteractionController + PageSnapAnimator (startSettle(toPage:)). NO second engine / manual NSClipView animation / second spring / direct currentPage mutation / separate NSAnimationContext. UX: visual dot ~current size, larger hit region. Accessibility: button semantics, localized "Page X of Y". Search mode: hidden. GUI verify: click first/middle/last/current, interrupt active settle.

## A9. FOLDER REFRESH — REMOVE UNNECESSARY FULL reloadData
Audit FolderViewController.refresh(): may do Diffable apply then reloadData → recreate cells, restart icon tasks. Separate structural update from metadata/localization reconfiguration; least expensive correct AppKit op. Verify reorder/add/remove/rename/localization/icon/missing-hidden; no stale UI.

## A10. APPDELEGATE DIAGNOSTIC EXTRACTION
Keep all diagnostics (smoke/pagetest/pagingprobe/dragcacheprobe/searchprobe/gridtest/iconbench/threefingerdiag/folders/perf). Extract into Diagnostics/ (DiagnosticRunner + per-probe files). AppDelegate = bootstrap + mode dispatch. Preserve pass/fail behavior; failure exits non-zero.

## A11. DRAGCONTROLLER SOURCE ORGANIZATION
ONE runtime drag owner; no MouseDrag/ThreeFinger/Folder drag controllers. May split helper types into focused files (DragSessionState, InputEndArbitration, CreateFolderHoverDecision, DragPreviewPlan, DragOverlayLayer, InsertionIndicatorLayer). No behavior rewrite.

## A12. REMOVE LayoutStore DISPLAY PLACEHOLDER SMELL
Audit renameFolder: if LayoutStore constructs fake/empty DisplayModel only because LayoutEditor.apply requires one, remove that artificial dependency (rename is pure persistent-state mutation). Narrow pure API.

## A13. LauncherStoring / LayoutMutationCompleting REVIEW (HIGH-RISK)
LauncherStoring grown large; LayoutMutationCompleting duplicates mutations with completion. Abstraction smell. LUNA DESIGN GATE before modifying. Evaluate bounded split (LauncherReadModelProviding / LauncherObserving / LayoutCommanding / AppCommanding) and typed mutation result (committed/noChange/rejected(.staleLayout|.invalidMutation|.busy)/failed(.persistence|.corruptionProtection)). Only if bounded + well-tested; otherwise design note + defer.

## A14. DISPLAY ITEM STABLE IDENTITY REVIEW (HIGH-RISK)
folder(FolderID, visibleChildren:) in Hashable identity → Folder F [A,B] vs [A,B,C] are different identities. Semantic: App=AppID, Folder=FolderID, children=payload. May improve Diffable stability/reuse/folder thumbnail/extensibility. LUNA DESIGN GATE. Verify no flicker/fake delete-insert/drag identity/source hiding/folder thumbnails/search/layout. If not strong enough: defer.

## A15. STAGE A GATE
All LaunchCore/Platform/UI tests; Debug+Release build; diagnostics (smoke/pagetest/pagingprobe/dragcacheprobe/searchprobe/gridtest/iconbench/folders/threefingerdiag); Computer Use page-dot/folder/settings if available; Luna Stage-A review 0B/0M. Record before/after, behavior-neutral optimizations, deferred work. Atomic commits. Update MEMORY.

---

# STAGE B — FEATURE COMPLETION / PARITY

## B0. RE-AUDIT
Read current source + parity matrix + old legacy source + user-visible behavior. Classify COMPLETE/PARTIAL/MISSING/UNPROVEN. Then implement.

## B1. LOCALIZED APPLICATION NAMES
Implement localized app metadata: CFBundleDisplayName/CFBundleName/InfoPlist.strings/.lproj resolution. Deterministic fallback; no per-frame IO; no per-show Info.plist IO; resolve during catalog metadata work; cache into snapshot/AppRecord; language change updates names without restart; search index updates; custom name highest override. Fallback: custom > localized display > localized bundle > base CFBundleDisplayName > CFBundleName > filename (check macOS semantics). Tests: en/zh-Hans/zh-Hant/missing/malformed/fallback/custom/search.

## B2. CUSTOM APPLICATION SOURCE DIRECTORIES
Complete end-to-end: settings add/remove, persistence, canonical paths, dedup default+overlapping, DirectoryMonitor updates, AppCatalogActor scanning, invalid/missing dirs gracefully, removal reconciles, no full scan on show, no duplicate AppID. Structural config changes (not random FileManager in Settings UI). Dynamic monitoring roots designed explicitly. High-risk lifecycle: Luna design gate. Computer Use: temp source dir add/remove.

## B3. CONTEXT MENU COMPLETION
App: Launch, Reveal in Finder, Get Info, Rename, Hide/Unhide, Move to Trash (safety). Folder: Rename, Dissolve. Standard APIs; no shell injection; canonical AppID URL; don't Trash system-protected. Localize. Computer Use: right-click/Reveal/Get Info/rename/folder menu. Don't claim Finder/Get Info success without observing.

## B4. GLOBAL HOTKEY COMPLETION
Presets may work. If custom recorder warranted: key+modifiers, persistence, conflict detection, registration failure handling, rollback (current stays until replacement succeeds), Escape/cancel, accessibility. Don't replace working Carbon infra unnecessarily. Disproportionate complexity → Luna review + document.

## B5. SETTINGS COMPLETENESS
Re-audit Settings as product surface: Layout (icon size/rows/columns/mode), Activation (hotkey/hot corner), Appearance (wallpaper), Language, Sources, Hidden Apps, About. Current design language (not legacy cargo-cult). Live application. No giant Codable structures.

## B6. VERTICAL LAYOUT (MAJOR; CONTINUOUS VERTICAL SCROLL, NOT paging)
LUNA MAX DESIGN GATE before implementation. Horizontal mode unchanged (paging+dots active). Vertical mode: continuous vertical scroll, horizontal paging disabled, no page-settle state, content height grows, search coherent, drag hit-testing/insertion/folder targeting/edge behavior adapt. Extend GridGeometry/PagingGridLayout/GridViewController with explicit mode semantics. Persistent config layoutMode, schema/version. Tests: content size, index→frame, point→destination, counts, search, drag destination, mode switching, persistence, horizontal regression. Computer Use: switch/scroll/launch/drag/switch back/screenshots.

## B7. PRODUCT POLISH (related only)
Long label truncation, localization overflow, page-dot accessibility, Settings clipping, folder name truncation, search safe area, context-menu wording, keyboard accessibility. No speculative redesign.

## B8. EXPLICITLY DEFER
Scene/multiple layouts, smart classification, function-based folders, ML categorization, Finder/Dock system drag export, Dock private database.

## B9. STAGE B GATE
Full suite + diagnostics + Computer Use visible verification (localized names, sources, context menus, Settings, hotkey UI, horizontal/vertical mode, language switching, folder regression, mouse drag regression). Hardware-only → MANUAL_VERIFICATION_REQUIRED. Luna 0B/0M. Update parity matrix with evidence. Update MEMORY. Atomic commits.

---

# STAGE C — REGRESSION / PERFORMANCE / RC HARDENING

## C1. FULL PERFORMANCE PROFILE
Instruments: cold start, warm show, hide, page interaction, mouse/folder drag, folder open, search, vertical scroll, custom source update. Look for main-thread IO, repeated snapshot, icon decode, allocation churn, retained controllers, observer/display-link leaks, task storms, repeated layout invalidation. Optimize only with measurement.

## C2. HOT-PATH INVARIANTS
Paging ≤1 offset write/frame; tracking direct latest-value; momentum ignored per design. Drag: no per-frame Diffable/LayoutStore/disk IO/Task; destination unchanged → skip preview; transforms only when changed. Icon: in-flight dedup, consumer cancel doesn't kill shared, stale gen can't publish. Catalog: incremental events don't lose disjoint updates; event loss → recovery; stale full scan can't overwrite newer incremental.

## C3. STRESS TEST
Synthetic fixtures 100/250/500+ apps: DisplayModel, SearchIndex, layout, reorder, folders, snapshot building, index cache, vertical mode, localized metadata. Deterministic; no 500 real apps.

## C4. LIFECYCLE / LEAK REVIEW
Cleanup: CADisplayLink, PagingInteractionController, FrameCoordinator, gesture callbacks, private Multitouch subscription, NotificationCenter observers, DirectoryMonitor, IconRepository memory pressure, FolderViewController observers, async disk writer. Show/hide repeated doesn't accumulate.

## C5. CONCURRENCY REVIEW
Luna dedicated: actor reentrancy, Task ownership, detached work, cancellation, stale-generation results, persistent commit boundaries, retry/backoff, FSEvents callbacks, MainActor isolation, @unchecked Sendable usage, NSLock usage. Every @unchecked Sendable defensible. Don't refactor safe lock-based code just for style.

## C6. GUI / COMPUTER USE ACCEPTANCE PASS
If trusted capability exists: launch, page dot 2/1, search, clear, open/rename/close folder, context menu, Reveal in Finder, Settings, language, icon size, vertical mode, scroll, horizontal, safe custom source, close/reopen. Screenshots at checkpoints. Main controller validates visual findings. Don't fake physical trackpad verification.

## C7. GITHUB CI
Audit macOS CI gate. If absent: add basic GitHub Actions (LaunchCore/Platform/UI tests, Debug+Release build). No hardware tests, no secrets, no signing credentials for ordinary CI.

## C8. DOCUMENTATION CONSISTENCY
Check MEMORY, parity matrix, PhaseReports, README, version/build metadata. Remove contradictions (e.g. "already released" vs "ready to release" for same state).

## C9. FINAL MULTI-LAYER REVIEW
Luna #1 architecture/abstraction; #2 concurrency/persistence; #3 drag/paging/UI lifecycle (as useful). Main verifies all findings. Mimo screenshot-only. Qwen only unresolved disagreement. Final gate 0B/0M. Fix low-risk valuable MINORs, else document.

## 17. RELEASE POLICY
No release merely for compiling. Likely v0.2.4 (architecture/perf) then v0.3.0 (feature/vertical). Inspect version policy. Before tag/release: tests green, diagnostics green, Luna 0B/0M, CI green, MEMORY current, parity current, manual/GUI gate recorded. Hardware-only not silently passed. Use existing signing/install workflow; no invented credentials.

## 18. GIT DISCIPLINE
Inspect dirty state; never destroy user changes; branches/worktrees per convention. Logical commits (e.g. "perf: reduce drag hot-path duplicate work", "perf: decouple icon disk writes", "refactor: extract diagnostic runner", "feat: add clickable page indicators", "feat: localized application metadata", "feat: complete custom source directories", "feat: add continuous vertical layout", "test: add vertical layout regression coverage"). No giant "finish everything" commit. Never modify Launchpad_Back or Buho reverse artifacts.

## 19. TESTING PHILOSOPHY
Test quality > count. Prefer regression tests that failed on the old bug ("would this test have failed before the fix?"). Cover success, rejection, stale state, persistence failure, cancellation, lifecycle teardown, hidden/missing, cross-page/row geometry, localization fallback, malformed filesystem state.

## 20. DIAGNOSTIC PHILOSOPHY
Every PASS validates a meaningful invariant; probe failure exits non-zero; don't print OK when not checked; fix false-positive diagnostics.

## 21. MANUAL VERIFICATION HONESTY
Manual-only gates: physical three-finger drag feel, four-finger pinch, 120Hz subjective smoothness, mixed-scale monitor hardware. Mark MANUAL_VERIFICATION_REQUIRED.

## 22. FINAL REPORT FORMAT
One concise engineering report: BASELINE (tag+commit), STAGE A/B/C summaries, MEASUREMENTS (before/after), TESTS (suites/counts/diagnostics/CI), COMPUTER USE (available/automated/screenshots/not automated), REVIEWS (Luna 0B/0M, visual, Qwen), GIT (branch/commits/pushes/tag), MEMORY (sync confirmed), MANUAL GATES, REMAINING RISKS.

## 23. SUCCESS CRITERIA
Architecture guarantees intact; invisible duplicate work reduced (evidence-based); no visible regressions; clickable page dots reuse existing paging engine; Retina lifecycle cleaner if standard API proven; feature parity (localized names, custom sources, context menu, settings, hotkey decided, vertical layout) completed; Scene/smart categorization/auto folders/external drag explicitly deferred; tests green; diagnostics green; Luna 0B/0M; MEMORY accurate; repo RC-quality.

## 24. FIRST EXECUTION SEQUENCE
Read MEMORY → inspect git/v0.2.3/Codex commits → reconstruct architecture → sync workflow docs → discover Computer Use → capture Stage-A baseline → package Stage-A tasks → isolated implementer where beneficial → main controller for tightly-coupled core work → independent verification → Luna design gates → Stage A complete → Luna 0B/0M → MEMORY+commit → Stage B (localized names, sources, context menu, settings/hotkey, vertical layout) → GUI/Computer Use verification → Luna 0B/0M → MEMORY+commit → Stage C hardening → Instruments/stress/lifecycle/concurrency → CI → final GUI acceptance → final Luna → fix verified B/M → final gate → RC/release per policy.

## 25. FINAL REMINDERS
Resuming after Codex; don't rely on old memory; source is truth; MEMORY is handoff; preserve v0.2.3 architecture; Buho selectively. Clickable page dots YES; standard Retina lifecycle INVESTIGATE/ADOPT IF PROVEN; CoreData migration NO; NSDraggingSession rewrite NO; Dock private DB NO; Scene LATER; smart classification LATER. Optimize invisible work, don't degrade direct manipulation. Use Computer Use when trustworthy; don't fake hardware validation. Main controller owns integration; implementer increases throughput; Luna challenges; Mimo not authoritative; Qwen rare; Watchdog protects. Every major stage ends: independent verification, 0 BLOCKER/0 MAJOR, atomic commit, push, MEMORY sync.
