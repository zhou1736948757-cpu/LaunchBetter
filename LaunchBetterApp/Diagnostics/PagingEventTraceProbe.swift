import AppKit
import LaunchCore
import LaunchUI

/// PA4: `--pagingeventtrace` 逐事件 trace 探针(非交互)。
///
/// 场景 1(干净手势): Library 表面经真实轴仲裁链路的水平 fling。
/// 场景 2(打断修复): Page 表面 fling 后 settle 中途被垂直手势打断 → 重启 settle
/// 回到原目标(根因修复证据, 修复前该场景停在页中间)。
///
/// 输出: 全部事件写 `/tmp/lb-paging-eventtrace.log`(paging/library 两侧交错),
/// stdout 打印证据摘要与断言结果。退出码 0/1。
@MainActor
enum PagingEventTraceProbe {
    private static let frameInterval = 1.0 / 120.0
    private static let settleTimeoutFrames = 300

    static func run(container: DependencyContainer) {
        let controller = container.windowController
        controller.show()
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.orderFrontRegardless()
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.displayIfNeeded()

        // 起点: App Library 表面。
        guard controller.libraryShotNavigateToLibrary() else {
            DiagnosticRunner.finishProbe(
                "PAGINGEVENTTRACE", ok: false,
                detail: "library navigation unavailable (leading surface disabled)"
            )
        }
        waitSettle(controller) { navOK in
            guard navOK else {
                DiagnosticRunner.finishProbe("PAGINGEVENTTRACE", ok: false, detail: "initial settle timeout")
            }
            print("PAGINGEVENTTRACE start surface=\(controller.libraryShotState())")
            traceCleanLibraryFling(controller) { cleanOK in
                guard cleanOK else {
                    DiagnosticRunner.finishProbe(
                        "PAGINGEVENTTRACE", ok: false, detail: "clean library fling failed"
                    )
                }
                traceInterruptFix(controller) { fixOK in
                    print("PAGINGEVENTTRACE evidence:\n\(logEvidence())")
                    DiagnosticRunner.finishProbe(
                        "PAGINGEVENTTRACE", ok: fixOK,
                        detail: "clean+interrupt traces written to /tmp/lb-paging-eventtrace.log"
                    )
                }
            }
        }
    }

    // MARK: - 场景 1: Library 表面干净水平 fling(真实仲裁链路)

    private static func traceCleanLibraryFling(
        _ controller: LauncherWindowController,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        print("PAGINGEVENTTRACE clean-fling surface=\(controller.libraryShotState())")
        guard let began = makeScroll(dx: -40, dy: 0, phase: .began),
              let changed1 = makeScroll(dx: -80, dy: 0, phase: .changed),
              let changed2 = makeScroll(dx: -80, dy: 0, phase: .changed),
              let ended = makeScroll(dx: 0, dy: 0, phase: .ended) else {
            completion(false)
            return
        }
        // began 即锁定 horizontal → 立即种子外层分页手势(真实仲裁路径)。
        let delivered = controller.libraryProbeFeed(phase: .began, event: began)
        print("PAGINGEVENTTRACE clean beganDelivered=\(delivered)")
        _ = controller.libraryProbeFeed(phase: .changed, event: changed1)
        _ = controller.libraryProbeFeed(phase: .changed, event: changed2)
        _ = controller.libraryProbeFeed(phase: .ended, event: ended)
        waitSettle(controller) { settled in
            let pageWidth = max(1, controller.pageTestPageWidth())
            let atBoundary = abs(controller.pageTestScrollX() - pageWidth) <= 1
            let ok = settled
                && controller.pagingProbePhase() == "idle"
                && !controller.pagingProbeDisplayLinkActive()
                && atBoundary
            print(
                "PAGINGEVENTTRACE clean settled=\(settled) phase=\(controller.pagingProbePhase()) "
                    + "link=\(controller.pagingProbeDisplayLinkActive()) "
                    + "scrollX=\(Int(controller.pageTestScrollX())) boundary=\(atBoundary) "
                    + "page=\(controller.pageTestCurrentPage()) surface=\(controller.libraryShotState())"
            )
            completion(ok)
        }
    }

    // MARK: - 场景 2: settle 中途垂直打断 → 修复后重启 settle(根因证据)

    private static func traceInterruptFix(
        _ controller: LauncherWindowController,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        print("PAGINGEVENTTRACE interrupt-fix surface=\(controller.libraryShotState())")
        guard let began = makeScroll(dx: -40, dy: 0, phase: .began),
              let changed1 = makeScroll(dx: -80, dy: 0, phase: .changed),
              let changed2 = makeScroll(dx: -80, dy: 0, phase: .changed),
              let changed3 = makeScroll(dx: -80, dy: 0, phase: .changed),
              let ended = makeScroll(dx: 0, dy: 0, phase: .ended),
              let vBegan = makeScroll(dx: 0, dy: 30, phase: .began),
              let vChanged = makeScroll(dx: 0, dy: 30, phase: .changed),
              let vEnded = makeScroll(dx: 0, dy: 0, phase: .ended) else {
            completion(false)
            return
        }
        // Page 表面: fling → settle 到下一页进行中。
        controller.pagingProbeFeed(began)
        controller.pagingProbeFeed(changed1)
        controller.pagingProbeFeed(changed2)
        controller.pagingProbeFeed(changed3)
        controller.pagingProbeFeed(ended)
        driveFrames(controller, count: 12) {
            // settle 中途: 纯垂直手势(永不锁定水平)。
            controller.pagingProbeFeed(vBegan)
            controller.pagingProbeFeed(vChanged)
            controller.pagingProbeFeed(vEnded)
            waitSettle(controller) { settled in
                let pageWidth = max(1, controller.pageTestPageWidth())
                // 修复行为: 重启 settle 到被打断目标(页 2, 即物理 offset 2×页宽)。
                let atBoundary = abs(controller.pageTestScrollX() - 2 * pageWidth) <= 1
                let ok = settled
                    && controller.pagingProbePhase() == "idle"
                    && !controller.pagingProbeDisplayLinkActive()
                    && atBoundary
                print(
                    "PAGINGEVENTTRACE interrupt settled=\(settled) phase=\(controller.pagingProbePhase()) "
                        + "link=\(controller.pagingProbeDisplayLinkActive()) "
                        + "scrollX=\(Int(controller.pageTestScrollX())) boundary=\(atBoundary) "
                        + "page=\(controller.pageTestCurrentPage()) surface=\(controller.libraryShotState())"
                )
                completion(ok)
            }
        }
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

    /// 合成 NSEvent(与 PagingProbe 同一构造)。phase 经 CGEvent field 99 写入
    /// CGSEventScrollPhase 值(1/2/4/8), momentum 经 field 123(1/2/3);
    /// 该映射在本 SDK 已验证往返(与 PagingScrollProbe 同构)。
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

    /// NSEvent.Phase → CGSEventMomentumPhase(123 字段): began 1 / changed 2 / ended 3。
    private static func cgMomentumPhase(_ phase: NSEvent.Phase) -> Int64 {
        if phase.contains(.began) { return 1 }
        if phase.contains(.changed) { return 2 }
        if phase.contains(.ended) || phase.contains(.cancelled) { return 3 }
        return 0
    }

    // MARK: - 证据摘要

    /// 读取 trace 日志, 输出关键事件计数 + 最后 N 行(诊断证据)。
    private static func logEvidence() -> String {
        let path = "/tmp/lb-paging-eventtrace.log"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "trace log missing: \(path)"
        }
        let lines = content.split(separator: "\n").map(String.init)
        func count(_ needle: String) -> Int {
            lines.filter { $0.contains(needle) }.count
        }
        var summary = "traceLog lines=\(lines.count) "
            + "interrupt=\(count("interrupt")) resumeSettle=\(count("resumeSettle")) "
            + "settleStart=\(count("settleStart")) settleEnd=\(count("settleEnd")) "
            + "linkStart=\(count("linkStart")) linkStop=\(count("linkStop"))\n"
        for line in lines.suffix(30) {
            summary += "  \(line)\n"
        }
        return summary
    }
}
