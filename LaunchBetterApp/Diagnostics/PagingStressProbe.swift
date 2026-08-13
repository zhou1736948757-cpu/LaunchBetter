import AppKit
import LaunchCore
import LaunchUI

/// PA4: `--pagingstressprobe` 压力探针(非交互)。
///
/// 500 轮 Library↔Page1 交替导航, 每轮轮流变化 7 种手势模式:
/// 慢位移 / 恰阈值位移 / 快速 flick / settle 中途反向 / diagonal→horizontal
/// 锁定 / horizontal→momentum / cancel。
///
/// 每轮 settle 完成后断言:
/// - Paging phase == idle
/// - display link 未激活
/// - |offset/pageWidth - 最近整数| <= 0.01(不休息在页中间)
/// - currentSurface 与物理 offset 一致(0 → appLibrary, n≥1 → layoutPage(n-1))
///
/// 失败即打印该轮 trace 摘要并退出 1。Library 表面手势走真实轴仲裁链路
/// (libraryProbeFeed), Page 表面走分页链路(pagingProbeFeed)。
@MainActor
enum PagingStressProbe {
    private static let totalRounds = 500
    private static let frameInterval = 1.0 / 120.0
    private static let settleTimeoutFrames = 300
    private static let boundaryEpsilon = 0.01

    /// 7 种手势模式循环。
    private enum Pattern: CaseIterable {
        case slow
        case threshold
        case flick
        case reverseMidSettle
        case diagonalToHorizontal
        case momentum
        case cancel

        var label: String {
            switch self {
            case .slow: return "slow"
            case .threshold: return "threshold"
            case .flick: return "flick"
            case .reverseMidSettle: return "reverse-mid-settle"
            case .diagonalToHorizontal: return "diagonal->horizontal"
            case .momentum: return "momentum"
            case .cancel: return "cancel"
            }
        }
    }

    /// 导航方向统计(验收: Library→Page1 / Page1→Library 各 ≥ 100)。
    private struct NavCounts {
        var libraryToPage1 = 0
        var page1ToLibrary = 0
        var pageNToLibrary = 0

        var summary: String {
            "library->page1=\(libraryToPage1) page1->library=\(page1ToLibrary) pageN->library=\(pageNToLibrary)"
        }
    }

    // MARK: - 入口

    static func run(container: DependencyContainer) {
        let controller = container.windowController
        controller.show()
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.orderFrontRegardless()
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.displayIfNeeded()

        guard controller.libraryShotNavigateToLibrary() else {
            DiagnosticRunner.finishProbe(
                "PAGINGSTRESSPROBE", ok: false,
                detail: "library navigation unavailable (leading surface disabled)"
            )
        }
        waitSettle(controller) { ok in
            guard ok else {
                DiagnosticRunner.finishProbe(
                    "PAGINGSTRESSPROBE", ok: false, detail: "initial settle timeout"
                )
            }
            runRounds(controller, round: 1, counts: NavCounts())
        }
    }

    // MARK: - 轮次循环

    private static func runRounds(
        _ controller: LauncherWindowController,
        round: Int,
        counts: NavCounts
    ) {
        if round == 1 || round % 100 == 1 || round > totalRounds {
            print("PAGINGSTRESSPROBE round=\(round - 1) progress=\(round - 1)/\(totalRounds)")
            fflush(stdout)
        }
        guard round <= totalRounds else {
            DiagnosticRunner.finishProbe(
                "PAGINGSTRESSPROBE", ok: true,
                detail: "rounds=\(totalRounds) all passed \(counts.summary)"
            )
        }

        let pattern = Pattern.allCases[(round - 1) % Pattern.allCases.count]

        // 1) 定向导航: Library → Page1; 否则 → Library(自身即一次 settle)。
        var navCounts = counts
        let startState = controller.libraryShotState()
        if startState.contains("surface=appLibrary") {
            _ = controller.pageTestNext()
            navCounts.libraryToPage1 += 1
        } else if startState.contains("surface=layoutPage(0)") {
            _ = controller.libraryShotNavigateToLibrary()
            navCounts.page1ToLibrary += 1
        } else {
            _ = controller.libraryShotNavigateToLibrary()
            navCounts.pageNToLibrary += 1
        }
        waitSettle(controller) { navOK in
            guard navOK else {
                fail(controller, round: round, pattern: pattern, reason: "navigation settle timeout")
            }
            // 2) 模式手势。
            runPattern(pattern, controller: controller) { patternOK in
                guard patternOK else {
                    fail(controller, round: round, pattern: pattern, reason: "pattern settle timeout")
                }
                // 3) 不变式断言。
                guard assertInvariants(controller, round: round, pattern: pattern) else {
                    fail(controller, round: round, pattern: pattern, reason: "invariant violated")
                }
                runRounds(controller, round: round + 1, counts: navCounts)
            }
        }
    }

    // MARK: - 模式手势

    private static func runPattern(
        _ pattern: Pattern,
        controller: LauncherWindowController,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        switch pattern {
        case .slow:
            feedHorizontal(deltas: [-8, -8, -8, -8, -8, -8, -8, -8, -8, -8], controller: controller) {
                waitSettle(controller, completion: completion)
            }
        case .threshold:
            feedHorizontal(deltas: [-4, -4, -4, -4], controller: controller) {
                waitSettle(controller, completion: completion)
            }
        case .flick:
            feedHorizontal(deltas: [-60, -90, -110], controller: controller) {
                waitSettle(controller, completion: completion)
            }
        case .reverseMidSettle:
            feedHorizontal(deltas: [-60, -90, -110], controller: controller) {
                // settle 中途: 反向 fling。
                driveFrames(controller, count: 12) {
                    feedHorizontal(deltas: [60, 90, 110], controller: controller) {
                        waitSettle(controller, completion: completion)
                    }
                }
            }
        case .diagonalToHorizontal:
            feedDiagonal(controller: controller) {
                waitSettle(controller, completion: completion)
            }
        case .momentum:
            feedHorizontal(deltas: [-60, -90, -110], controller: controller) {
                feedMomentum(controller: controller) {
                    waitSettle(controller, completion: completion)
                }
            }
        case .cancel:
            feedCancel(controller: controller) {
                waitSettle(controller, completion: completion)
            }
        }
    }

    /// 水平手势序列(began 携带首位移; 显式 phase 驱动)。
    private static func feedHorizontal(
        deltas: [CGFloat],
        controller: LauncherWindowController,
        completion: @escaping @MainActor () -> Void
    ) {
        let surface = controller.libraryShotState()
        guard let began = makeScroll(dx: deltas[0], dy: 0, phase: .began),
              let ended = makeScroll(dx: 0, dy: 0, phase: .ended) else {
            completion()
            return
        }
        let changed = deltas.compactMap { makeScroll(dx: $0, dy: 0, phase: .changed) }
        guard changed.count == deltas.count else {
            completion()
            return
        }
        var fed = 0
        @MainActor func feedNext() {
            let event: NSEvent
            let phase: NSEvent.Phase
            if fed == 0 {
                event = began
                phase = .began
            } else if fed <= changed.count {
                event = changed[fed - 1]
                phase = .changed
            } else {
                event = ended
                phase = .ended
                deliver(event, phase: phase, surface: surface, controller: controller)
                completion()
                return
            }
            deliver(event, phase: phase, surface: surface, controller: controller)
            fed += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + frameInterval) {
                MainActor.assumeIsolated { feedNext() }
            }
        }
        feedNext()
    }

    private static func deliver(
        _ event: NSEvent,
        phase: NSEvent.Phase,
        surface: String,
        controller: LauncherWindowController
    ) {
        if surface.contains("appLibrary") {
            _ = controller.libraryProbeFeed(phase: phase, event: event)
        } else {
            controller.pagingProbeFeed(event)
        }
    }

    /// diagonal→horizontal: began 对角微动(undecided) → changed 水平主导。
    private static func feedDiagonal(
        controller: LauncherWindowController,
        completion: @escaping @MainActor () -> Void
    ) {
        let surface = controller.libraryShotState()
        guard let began = makeScroll(dx: -4, dy: -4, phase: .began),
              let changed1 = makeScroll(dx: -40, dy: 6, phase: .changed),
              let changed2 = makeScroll(dx: -40, dy: 6, phase: .changed),
              let ended = makeScroll(dx: 0, dy: 0, phase: .ended) else {
            completion()
            return
        }
        deliver(began, phase: .began, surface: surface, controller: controller)
        deliver(changed1, phase: .changed, surface: surface, controller: controller)
        deliver(changed2, phase: .changed, surface: surface, controller: controller)
        deliver(ended, phase: .ended, surface: surface, controller: controller)
        completion()
    }

    /// horizontal→momentum: 手势结束后沿锁定轴注入 momentum(began/changed/ended)。
    private static func feedMomentum(
        controller: LauncherWindowController,
        completion: @escaping @MainActor () -> Void
    ) {
        let surface = controller.libraryShotState()
        guard let mBegan = makeScroll(dx: -60, dy: 0, momentum: .began),
              let mChanged = makeScroll(dx: -60, dy: 0, momentum: .changed),
              let mEnded = makeScroll(dx: 0, dy: 0, momentum: .ended) else {
            completion()
            return
        }
        if surface.contains("appLibrary") {
            controller.libraryProbeFeedMomentum(event: mBegan)
            controller.libraryProbeFeedMomentum(event: mChanged)
            controller.libraryProbeFeedMomentum(event: mEnded)
        } else {
            controller.pagingProbeFeed(mBegan)
            controller.pagingProbeFeed(mChanged)
            controller.pagingProbeFeed(mEnded)
        }
        completion()
    }

    /// cancel: 水平 fling 以 .cancelled 收尾。
    private static func feedCancel(
        controller: LauncherWindowController,
        completion: @escaping @MainActor () -> Void
    ) {
        let surface = controller.libraryShotState()
        guard let began = makeScroll(dx: -60, dy: 0, phase: .began),
              let changed = makeScroll(dx: -90, dy: 0, phase: .changed),
              let cancelled = makeScroll(dx: 0, dy: 0, phase: .cancelled) else {
            completion()
            return
        }
        deliver(began, phase: .began, surface: surface, controller: controller)
        deliver(changed, phase: .changed, surface: surface, controller: controller)
        deliver(cancelled, phase: .cancelled, surface: surface, controller: controller)
        completion()
    }

    // MARK: - 合成事件

    /// 合成 NSEvent。phase/momentum 用 AppKit 语义; CGEvent field 99/123 写入
    /// 的是 CGSEventScrollPhase(1/2/4/8 与 momentum 1/2/3, PagingProbe 验证过)。
    private static func makeScroll(
        dx: CGFloat,
        dy: CGFloat,
        phase: NSEvent.Phase = [],
        momentum: NSEvent.Phase = []
    ) -> NSEvent? {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let cg = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return nil }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
        if phase != [] {
            cg.setIntegerValueField(CGEventField(rawValue: 99)!, value: cgScrollPhase(phase))
        }
        if momentum != [] {
            cg.setIntegerValueField(CGEventField(rawValue: 123)!, value: cgMomentumPhase(momentum))
        }
        return NSEvent(cgEvent: cg)
    }

    /// NSEvent.Phase → CGSEventScrollPhase(99 字段): began 1 / changed 2 / ended 4 / cancelled 8。
    private static func cgScrollPhase(_ phase: NSEvent.Phase) -> Int64 {
        if phase.contains(.began) { return 1 }
        if phase.contains(.changed) { return 2 }
        if phase.contains(.ended) { return 4 }
        if phase.contains(.cancelled) { return 8 }
        return 0
    }

    /// NSEvent.Phase → CGSEventMomentumPhase(123 字段): began 1 / changed 2 / ended 3
    /// (3 与 PagingProbe 的历史取值一致, 该环境已验证往返)。
    private static func cgMomentumPhase(_ phase: NSEvent.Phase) -> Int64 {
        if phase.contains(.began) { return 1 }
        if phase.contains(.changed) { return 2 }
        if phase.contains(.ended) || phase.contains(.cancelled) { return 3 }
        return 0
    }

    // MARK: - 驱动

    private static func driveFrames(
        _ controller: LauncherWindowController,
        count: Int,
        after: @escaping @MainActor () -> Void
    ) {
        var remaining = count
        @MainActor func next() {
            _ = controller.pagingProbeDisplayFrame()
            remaining -= 1
            if remaining == 0 {
                after()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + frameInterval) {
                MainActor.assumeIsolated { next() }
            }
        }
        next()
    }

    private static func waitSettle(
        _ controller: LauncherWindowController,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        var remaining = settleTimeoutFrames
        @MainActor func poll() {
            remaining -= 1
            let settled = controller.pagingProbeDisplayFrame()
            if settled || remaining == 0 {
                completion(settled)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + frameInterval) {
                MainActor.assumeIsolated { poll() }
            }
        }
        poll()
    }

    // MARK: - 断言

    /// 每轮结束不变式: idle / 无 display link / 页边界 / surface 一致性。
    private static func assertInvariants(
        _ controller: LauncherWindowController,
        round: Int,
        pattern: Pattern
    ) -> Bool {
        let phase = controller.pagingProbePhase()
        let link = controller.pagingProbeDisplayLinkActive()
        let scrollX = controller.pageTestScrollX()
        let pageWidth = max(1, controller.pageTestPageWidth())
        let page = scrollX / pageWidth
        let nearest = page.rounded()
        let boundaryOK = abs(page - nearest) <= boundaryEpsilon
        let state = controller.libraryShotState()
        let surfaceOK = surfaceConsistent(state: state, physical: Int(nearest))
        let ok = phase == "idle" && !link && boundaryOK && surfaceOK
        if !ok {
            print(
                "PAGINGSTRESSPROBE round=\(round) pattern=\(pattern.label) FAIL "
                    + "phase=\(phase) link=\(link) scrollX=\(Int(scrollX)) page=\(page) "
                    + "boundaryOK=\(boundaryOK) surfaceOK=\(surfaceOK) state=\(state)"
            )
        }
        return ok
    }

    /// 物理 offset 与语义 surface 一致性: 物理 0 ↔ appLibrary; n≥1 ↔ layoutPage(n-1)。
    private static func surfaceConsistent(state: String, physical: Int) -> Bool {
        if physical == 0 {
            return state.contains("surface=appLibrary")
        }
        return state.contains("surface=layoutPage(\(physical - 1))")
    }

    private static func fail(
        _ controller: LauncherWindowController,
        round: Int,
        pattern: Pattern,
        reason: String
    ) -> Never {
        let diag = controller.pagingProbeDiagnostics()
        let state = controller.libraryShotState()
        print(
            "PAGINGSTRESSPROBE round=\(round) pattern=\(pattern.label) FAIL reason=\(reason) "
                + "scrollX=\(Int(controller.pageTestScrollX())) state=\(state) \(diag)"
        )
        DiagnosticRunner.finishProbe("PAGINGSTRESSPROBE", ok: false, detail: "round \(round) failed")
    }
}
