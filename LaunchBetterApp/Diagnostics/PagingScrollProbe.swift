import AppKit
import LaunchCore
import LaunchUI

/// E12: 分页滑动逐帧耗时测量(用户实机反馈: App 密集页左右滑卡顿)。
///
/// Phase L: App Library surface(7 张卡片); Phase P: 普通 Layout Page 1(~40
/// cells)。每 phase 先跑一次不打表的同尺寸手势预热图标/层缓存, 再测量第二次:
/// began + 74 个 changed(dx=-20, 总位移 ~1480pt ≈ 1 页宽 1470)以 120Hz 间隔
/// 驱动, 每 tick 记录 feed + displayFrame + displayIfNeeded 墙钟耗时; changed
/// 结束后 feed ended, 继续驱动 display frame 直到 settle(≤240 帧)。
///
/// 只读探针: 不写 Layout/Config/Usage, 不修改任何生产状态。
@MainActor
enum PagingScrollProbe {
    private static let frameInterval = 1.0 / 120.0
    private static let changedTickCount = 74
    private static let changedDeltaX: CGFloat = -20
    private static let settleTimeoutFrames = 240

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
                "PAGINGSCROLLPROBE", ok: false,
                detail: "library navigation unavailable (leading surface disabled)"
            )
        }
        waitForSettle(controller) { ok in
            guard ok else {
                DiagnosticRunner.finishProbe("PAGINGSCROLLPROBE", ok: false, detail: "initial settle timeout")
            }
            print("PAGINGSCROLLPROBE start \(controller.libraryShotState())")
            measurePhase(container, label: "L") { lOK in
                // 测量后已落在 Page 1: 退回 Library 再前进到 Page 1(任务包流程 4)。
                _ = controller.pageTestPrevious()
                waitForSettle(controller) { navBack in
                    _ = controller.pageTestNext()
                    waitForSettle(controller) { navNext in
                        guard lOK, navBack, navNext else {
                            DiagnosticRunner.finishProbe(
                                "PAGINGSCROLLPROBE", ok: false,
                                detail: "phase L or navigation failure l=\(lOK) back=\(navBack) next=\(navNext)"
                            )
                        }
                        measurePhase(container, label: "P") { pOK in
                            print("PAGINGSCROLLPROBE end \(controller.libraryShotState())")
                            DiagnosticRunner.finishProbe(
                                "PAGINGSCROLLPROBE", ok: pOK,
                                detail: "phases L and P measured"
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Phase 流程

    /// 预热(不打表) → 退回本 phase 起点 → 测量(打表)。
    private static func measurePhase(
        _ container: DependencyContainer,
        label: String,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        let controller = container.windowController
        driveGesture(container) { warmup in
            print(
                "PAGINGSCROLLPROBE phase=\(label) warmup ticks=\(warmup.tickDurations.count) "
                    + "settleFrames=\(warmup.settleFrames) settled=\(warmup.settled) "
                    + "page=\(controller.pageTestCurrentPage()) scrollX=\(Int(controller.pageTestScrollX()))"
            )
            guard warmup.settled else { completion(false); return }
            _ = controller.pageTestPrevious()
            waitForSettle(controller) { ok in
                guard ok else { completion(false); return }
                driveGesture(container) { measured in
                    printMeasured(container, label: label, stats: measured)
                    completion(measured.settled)
                }
            }
        }
    }

    // MARK: - 手势驱动

    private static func driveGesture(
        _ container: DependencyContainer,
        completion: @escaping @MainActor (GestureStats) -> Void
    ) {
        let controller = container.windowController
        guard let began = makeScroll(dx: 0, phase: 1, momentum: 0),
              let ended = makeScroll(dx: 0, phase: 4, momentum: 0) else {
            completion(GestureStats(settled: false))
            return
        }
        let changed = (0..<changedTickCount).map { _ in
            makeScroll(dx: changedDeltaX, phase: 2, momentum: 0)
        }.compactMap { $0 }
        guard changed.count == changedTickCount else {
            completion(GestureStats(settled: false))
            return
        }

        var tickIndex = 0
        var tickDurations: [Double] = []
        var settleDurations: [Double] = []
        var settleFrames = 0
        var endedFed = false

        @MainActor func settleTick() {
            let t0 = CACurrentMediaTime()
            if !endedFed {
                controller.pagingProbeFeed(ended)
                endedFed = true
            }
            let settled = controller.pagingProbeDisplayFrame()
            controller.window?.displayIfNeeded()
            settleDurations.append(CACurrentMediaTime() - t0)
            settleFrames += 1
            if settled || settleFrames >= settleTimeoutFrames {
                completion(GestureStats(
                    settled: settled,
                    tickDurations: tickDurations,
                    settleDurations: settleDurations,
                    settleFrames: settleFrames
                ))
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + frameInterval) {
                    MainActor.assumeIsolated { settleTick() }
                }
            }
        }

        @MainActor func gestureTick() {
            let t0 = CACurrentMediaTime()
            let event = tickIndex == 0 ? began : changed[tickIndex - 1]
            controller.pagingProbeFeed(event)
            tickIndex += 1
            _ = controller.pagingProbeDisplayFrame()
            controller.window?.displayIfNeeded()
            tickDurations.append(CACurrentMediaTime() - t0)
            if tickIndex < changed.count + 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + frameInterval) {
                    MainActor.assumeIsolated { gestureTick() }
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + frameInterval) {
                    MainActor.assumeIsolated { settleTick() }
                }
            }
        }
        gestureTick()
    }

    /// 合成 NSEvent(相位 rawValue 99/123, 与 PagingProbe 同一构造)。
    private static func makeScroll(dx: CGFloat, phase: Int, momentum: Int) -> NSEvent? {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let cg = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: Int32(dx), wheel3: 0) else { return nil }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
        cg.setIntegerValueField(CGEventField(rawValue: 99)!, value: Int64(phase))
        cg.setIntegerValueField(CGEventField(rawValue: 123)!, value: Int64(momentum))
        return NSEvent(cgEvent: cg)
    }

    // MARK: - 输出

    private static func printMeasured(
        _ container: DependencyContainer,
        label: String,
        stats: GestureStats
    ) {
        let controller = container.windowController
        let scale = controller.window?.backingScaleFactor ?? 0
        let combined = controller.pagingProbeDiagnostics()
        print(
            "PAGINGSCROLLPROBE phase=\(label) ticks=\(stats.tickDurations.count) "
                + "avgMs=\(fmt(stats.tickDurations.average)) p95Ms=\(fmt(stats.tickDurations.percentile(0.95))) "
                + "maxMs=\(fmt(stats.tickDurations.max())) "
                + "settleFrames=\(stats.settleFrames) settleMs=\(fmt(stats.settleDurations.reduce(0, +))) "
                + "settleAvgMs=\(fmt(stats.settleDurations.average)) settleMaxMs=\(fmt(stats.settleDurations.max())) "
                + "page=\(controller.pageTestCurrentPage()) scrollX=\(Int(controller.pageTestScrollX())) "
                + "backingScale=\(scale) \(combined) layout=\(layoutDiagnostics(from: combined))"
        )
        fflush(stdout)
    }

    private static func layoutDiagnostics(from combined: String) -> String {
        guard let start = combined.range(of: "layout[")?.lowerBound else {
            return "layout[missing]"
        }
        let tail = combined[start...]
        guard let end = tail.firstIndex(of: "]") else { return "layout[missing]" }
        return String(tail[...end])
    }

    private static func fmt(_ value: Double?) -> String {
        String(format: "%.2f", value ?? -1)
    }

    // MARK: - 等待

    private static func waitForSettle(
        _ controller: LauncherWindowController,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        var remaining = settleTimeoutFrames
        @MainActor func poll() {
            remaining -= 1
            let settled = controller.libraryShotWaitSettled()
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
}

/// 一次手势驱动的测量结果。
private struct GestureStats {
    var settled: Bool
    var tickDurations: [Double] = []
    var settleDurations: [Double] = []
    var settleFrames: Int = 0
}

private extension Array where Element == Double {
    var average: Double? {
        guard !isEmpty else { return nil }
        return reduce(0, +) / Double(count)
    }

    func percentile(_ p: Double) -> Double? {
        guard !isEmpty else { return nil }
        let sorted = self.sorted()
        let index = Swift.min(sorted.count - 1, Swift.max(0, Int((Double(sorted.count) * p).rounded(.up)) - 1))
        return sorted[index]
    }
}
