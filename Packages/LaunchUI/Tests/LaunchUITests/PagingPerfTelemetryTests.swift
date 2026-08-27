import AppKit
import CoreGraphics
import Foundation
import LaunchCore
import Testing
@testable import LaunchUI

/// T-027: `--paging-perf` 分页性能遥测(PagingPerfTelemetry)测试。
///
/// 覆盖(任务包 §6):
/// 1. 默认关闭 → 全生命周期零输出、零行为变化;
/// 2. 开启 → 确定性探针(手势→settle→打断→取消)输出完整 JSONL 字段;
/// 3. 生命周期闭合(settle / interrupted / cancelled / endedWithoutSettle 均
///    恰好一次摘要, 无丢失);
/// 4. 计数确定性(pre-lock / input / frame / latency);
/// 5. grid 级 live vs compositor 路由分桶 + teardown 归属;
/// 6. cell/icon 真实调用点归属(idle 桶 vs session 桶);
/// 7. layout metrics(prepare / query / invalidate 只记录不改行为);
/// 8. PageCompositor teardown 原因(finishSettle / abort / shutdown)。
///
/// 注意: 本 suite 整体 `.serialized`; 注册 `PagingPerfContext.recorder` 的用例
/// 必须 defer 清空, 避免跨 suite 并行污染(recorder 是全局弱引用)。
@Suite("PagingPerfTelemetry", .serialized)
@MainActor
struct PagingPerfTelemetryTests {
    // MARK: - 测试基础设施

    private func makeController(
        pageWidth: CGFloat = 640,
        pageCount: Int = 4
    ) -> (PagingInteractionController, NSView) {
        let controller = PagingInteractionController()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: pageWidth, height: 480))
        controller.linkView = view
        controller.onReadPageWidth = { pageWidth }
        controller.onReadPageCount = { pageCount }
        return (controller, view)
    }

    /// 引用型摘要收集器: 闭包内 append 必须对测试可见(值拷贝的数组不行)。
    private final class SummaryCollector {
        var lines: [String] = []
    }

    /// 接线 recorder 到 controller, 并把 onPhaseIdle 与 recorder 收口绑定
    /// (生产上由 GridViewController.onPhaseIdle 完成)。
    private func makeRecorder() -> (PagingPerfTelemetry, SummaryCollector) {
        let recorder = PagingPerfTelemetry()
        let collector = SummaryCollector()
        recorder.onSummary = { collector.lines.append($0) }
        return (recorder, collector)
    }

    private func parse(_ line: String) -> [String: Any] {
        let data = Data(line.utf8)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func nested(_ json: [String: Any], _ key: String) -> [String: Any] {
        json[key] as? [String: Any] ?? [:]
    }

    private func count(_ json: [String: Any], _ key: String) -> Int {
        json[key] as? Int ?? -1
    }

    /// 驱动 display frame 直到 paging idle(固定帧时钟)。
    private func driveUntilIdle(_ controller: PagingInteractionController, maxFrames: Int = 900) {
        var frames = 0
        while controller.phase != .idle, frames < maxFrames {
            _ = controller.probeDisplayFrame()
            frames += 1
        }
    }

    private func makeApp(_ page: Int, _ index: Int) -> AppID {
        AppID("/Applications/PerfA\(page)\(index).app")!
    }

    private func makeWindow(for controller: GridViewController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.view
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    /// 合成带 phase 的 precise 滚动事件(kCGScrollPhase: began=1 changed=2
    /// ended=4 cancelled=8)。
    private func makeScroll(dx: CGFloat, phase: NSEvent.Phase) -> NSEvent? {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let cg = CGEvent(
                  scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2,
                  wheel1: 0, wheel2: Int32(dx), wheel3: 0
              ) else { return nil }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
        let phaseField: Int64
        switch phase {
        case .began: phaseField = 1
        case .changed: phaseField = 2
        case .ended: phaseField = 4
        case .cancelled: phaseField = 8
        default: phaseField = 0
        }
        cg.setIntegerValueField(CGEventField(rawValue: 99)!, value: phaseField)
        return NSEvent(cgEvent: cg)
    }

    /// 非 precise(鼠标滚轮)离散输入: 不设 isContinuous, wheel1 即 deltaY。
    /// handleWheel → feedDiscrete → startSettle(与真实滚轮路径一致)。
    private func makeDiscreteScroll(deltaY: CGFloat) -> NSEvent? {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let cg = CGEvent(
                  scrollWheelEvent2Source: src, units: .line, wheelCount: 1,
                  wheel1: Int32(deltaY), wheel2: 0, wheel3: 0
              ) else { return nil }
        return NSEvent(cgEvent: cg)
    }

    private func makeGrid(_ store: PerfTelemetryStore) -> GridViewController {
        let grid = GridViewController(
            store: store, iconProvider: PerfTelemetryIconProvider()
        )
        grid.pageVisualCompositorEnabled = true
        grid.pageVisualMinItemsPerPage = 1
        grid.enableDeterministicPagingProbeClock()
        return grid
    }

    private func pagingControllerForDiag(_ grid: GridViewController) -> PagingInteractionController {
        guard let paging = Mirror(reflecting: grid).children
            .first(where: { $0.label == "paging" })?.value as? PagingInteractionController
        else {
            fatalError("GridViewController paging diagnostic seam unavailable")
        }
        return paging
    }

    private func driveUntilIdle(_ grid: GridViewController, maxFrames: Int = 900) {
        var frames = 0
        while grid.pagingProbePhase() != "idle", frames < maxFrames {
            _ = grid.pagingProbeDisplayFrame()
            frames += 1
        }
    }

    private func waitPrepared(_ grid: GridViewController, maxAttempts: Int = 8) async {
        for _ in 0..<maxAttempts {
            await grid.waitForPageVisualPrepareForDiag()
            if grid.pageVisualCacheCountForDiag >= 3 { return }
        }
    }

    /// 确定性放置(合成器测试用, 8x8 占位图像)。
    private func makeDiagnosticPlacement(page: Int) -> PageCompositor.Placement {
        let context = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let key = PageVisualKey(
            pageIndex: page, displayRevision: 1,
            geometry: PageVisualGeometrySignature(
                columns: 1, rows: 1, cellSize: 40, iconSize: 24,
                horizontalSpacing: 8, verticalSpacing: 8,
                pageWidth: 640, pageHeight: 480, topInset: 0, bottomInset: 0
            ),
            backingScale: 2, languageRevision: 0, iconEpoch: 0
        )
        let visual = PageVisual(
            key: key, image: context.makeImage()!,
            logicalBounds: CGRect(x: 20, y: 100, width: 40, height: 40),
            rasterScale: 2
        )
        return PageCompositor.Placement(
            page: page,
            baseFrame: CGRect(x: CGFloat(page) * 640 + 20, y: 100, width: 40, height: 40),
            visual: visual
        )
    }

    // MARK: - 1. 默认关闭: 零输出、零行为变化

    @Test("默认关闭: 全生命周期零输出, 无任何遥测副作用")
    func defaultOffNoOutput() {
        let (controller, linkView) = makeController()
        let (recorder, collector) = makeRecorder()
        controller.perfRecorder = recorder
        // recorder.enabled == false(默认)
        var currentOffset: CGFloat = 0
        controller.onReadCurrentOffset = { currentOffset }
        controller.onScroll = { currentOffset = $0 }

        withExtendedLifetime(linkView) {
            // 完整生命周期: 手势 → settle → 帧 → idle。
            controller.probeGesture(deltaXs: [100, 150])
            driveUntilIdle(controller)
            controller.startSettle(toPage: 2)
            driveUntilIdle(controller)
            controller.probeGesture(deltaXs: [50])
            driveUntilIdle(controller)
            controller.jumpTo(page: 0)
            controller.shutdown()

            #expect(collector.lines.isEmpty)
            // 行为零变化: 写计数来自既有计数器, 与遥测无关。
            #expect(controller.scrollWriteCount >= 1)
            #expect(currentOffset == 0)
            #expect(recorder.hasOpenSessionForDiag == false)
        }
    }

    @Test("默认关闭: configurePagingPerfTelemetry(false) 后 grid 不输出摘要")
    func gridDefaultOffNoOutput() {
        let grid = makeGrid(PerfTelemetryStore())
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }
        // 视图加载后接线(与生产 setupPagingController 时机一致)。
        var summaries: [String] = []
        grid.configurePagingPerfTelemetry(enabled: false)
        grid.setPagingPerfSummaryHandlerForDiag { summaries.append($0) }
        let paging = pagingControllerForDiag(grid)
        #expect(grid.pagingPerfEnabledForDiag == false)
        paging.probeGesture(deltaXs: [120, 80])
        driveUntilIdle(grid)
        #expect(summaries.isEmpty)
    }

    // MARK: - 2. 开启: 确定性探针完整生命周期

    @Test("开启: 确定性探针手势→settle→idle, 摘要字段完整且确定性")
    func deterministicProbeFullLifecycle() {
        let (controller, linkView) = makeController()
        let (recorder, collector) = makeRecorder()
        recorder.enabled = true
        controller.perfRecorder = recorder
        controller.onPhaseIdle = { recorder.flushOpenSession() }
        controller.enableDeterministicProbeClock()
        var currentOffset: CGFloat = 0
        var writes: [CGFloat] = []
        controller.onReadCurrentOffset = { currentOffset }
        controller.onScroll = { offset in
            currentOffset = offset
            writes.append(offset)
        }

        withExtendedLifetime(linkView) {
            // pre-lock 事件: |−3|+|−3| = 6 ≤ 阈值 6 → 前 2 个事件不锁定;
            // 第 3 个事件 −3 → 9 > 6 锁定。之后跟手 −30, −30(负 = 下一页)。
            // 注: 确定性探针时钟冻结 velocity 时间戳 → 松手速度 0, 目标页
            // 只由位移解析(0.14 页 ≥ 0.10 阈值 → 下一页)。
            controller.probeGesture(deltaXs: [-3, -3, -3, -30, -30])
            driveUntilIdle(controller)

            #expect(collector.lines.count == 1)
            let json = parse(collector.lines[0])
            #expect(json["event"] as? String == "pagingSessionSummary")
            #expect(json["reason"] as? String == "settled")
            let sessionId = json["sessionId"] as? String
            #expect(sessionId?.hasPrefix("S") == true)
            #expect((sessionId?.count ?? 0) == 7)

            // a: 确定性计数
            let a = nested(json, "a")
            #expect(count(a, "inputEvents") == 5)
            #expect(count(a, "preLockEvents") == 2)
            #expect(a["preLockDeltaX"] as? Double == -6.0)
            #expect(count(a, "trackingFrames") == 0)  // 探针期不驱动 display frame
            #expect(count(a, "settlingFrames") > 0)
            #expect(count(a, "totalFrames") == count(a, "settlingFrames"))
            #expect(count(a, "applyScrollCalls") >= count(a, "offsetWrites"))
            #expect(count(a, "offsetWrites") >= 1)
            #expect(count(a, "startPage") == 0)
            #expect(count(a, "targetPage") == 1)
            #expect(a["startOffset"] as? Double == 0)
            #expect(a["finalOffset"] as? Double == 640)
            #expect(a["compositorActive"] as? Bool == false)
            // 输入→首次 apply 延迟 = 固定帧时钟的整数倍步长(1/120s; 确定性)。
            #expect(count(a, "inputToApplyLatencyCount") == 1)
            let latencyMaxMs = a["inputToApplyLatencyMaxMs"] as? Double ?? 0
            let stepMs = 1000.0 / 120.0
            let steps = (latencyMaxMs / stepMs).rounded()
            #expect(abs(latencyMaxMs - steps * stepMs) < 0.5)
            #expect(steps >= 1 && steps <= 4)
            #expect(count(a, "settleSkipWrites") >= 0)
            #expect(a["beginAt"] as? Double != nil)
            #expect(a["axisLockAt"] as? Double != nil)
            #expect(a["gestureEndAt"] as? Double != nil)
            #expect(a["settleStartAt"] as? Double != nil)
            #expect(a["terminalAt"] as? Double != nil)

            // b: controller 层无路由/合成器 → 全零 + teardown 空。
            let b = nested(json, "b")
            let liveTracking = nested(b, "liveTracking")
            let liveSettling = nested(b, "liveSettling")
            let compositorTracking = nested(b, "compositorTracking")
            let compositorSettling = nested(b, "compositorSettling")
            #expect(count(liveTracking, "count") == 0)
            #expect(count(liveSettling, "count") == 0)
            #expect(count(compositorTracking, "applyOffsetCount") == 0)
            #expect(count(compositorSettling, "layerApplyCount") == 0)
            let teardown = nested(b, "teardown")
            #expect(teardown["reason"] as? NSNull == NSNull())
            #expect(count(teardown, "syncClipCount") == 0)

            // c/d: controller 层无布局/cell → 全零。
            let c = nested(json, "c")
            #expect(count(nested(c, "prepare"), "count") == 0)
            let d = nested(json, "d")
            #expect(count(nested(d, "cellProvider"), "tracking") == 0)

            // 收口后无残留 session。
            #expect(recorder.hasOpenSessionForDiag == false)
        }
    }

    // MARK: - 3. 生命周期闭合

    @Test("生命周期: settle 完成 → 恰好一次 settled 摘要")
    func lifecycleSettled() {
        let (controller, linkView) = makeController()
        let (recorder, collector) = makeRecorder()
        recorder.enabled = true
        controller.perfRecorder = recorder
        controller.onPhaseIdle = { recorder.flushOpenSession() }
        var currentOffset: CGFloat = 0
        controller.onReadCurrentOffset = { currentOffset }
        controller.onScroll = { currentOffset = $0 }

        withExtendedLifetime(linkView) {
            controller.probeGesture(deltaXs: [200])
            driveUntilIdle(controller)
            #expect(collector.lines.count == 1)
            #expect(parse(collector.lines[0])["reason"] as? String == "settled")
        }
    }

    @Test("生命周期: 新手势打断在途 settle → interrupted 摘要先出, settle 摘要随后")
    func lifecycleInterrupted() {
        let (controller, linkView) = makeController()
        let (recorder, collector) = makeRecorder()
        recorder.enabled = true
        controller.perfRecorder = recorder
        controller.onPhaseIdle = { recorder.flushOpenSession() }
        controller.enableDeterministicProbeClock()

        withExtendedLifetime(linkView) {
            controller.probeGesture(deltaXs: [-200])
            // 推进少量帧, settle 尚未收敛。
            for _ in 0..<5 { _ = controller.probeDisplayFrame() }
            #expect(controller.phase == .settling)
            #expect(recorder.hasOpenSessionForDiag)

            // 第二个手势打断第一个 settle。
            controller.probeGesture(deltaXs: [-100])
            #expect(collector.lines.count == 1)
            #expect(parse(collector.lines[0])["reason"] as? String == "interrupted")

            driveUntilIdle(controller)
            #expect(collector.lines.count == 2)
            #expect(parse(collector.lines[1])["reason"] as? String == "settled")
            let firstID = parse(collector.lines[0])["sessionId"] as? String
            let secondID = parse(collector.lines[1])["sessionId"] as? String
            #expect(firstID != secondID)
        }
    }

    @Test("生命周期: 取消(jumpTo)→ 恰一次 cancelled 摘要; 后续写入被拒(不再归属旧 session)")
    func lifecycleCancelled() {
        let (controller, linkView) = makeController()
        let (recorder, collector) = makeRecorder()
        recorder.enabled = true
        controller.perfRecorder = recorder
        controller.onPhaseIdle = { recorder.flushOpenSession() }

        withExtendedLifetime(linkView) {
            controller.probeGesture(deltaXs: [200])
            driveUntilIdle(controller)
            #expect(collector.lines.count == 1)
            #expect(parse(collector.lines[0])["reason"] as? String == "settled")

            // 第二次手势 → 帧中跳走 → cancelled。
            controller.probeGesture(deltaXs: [-200])
            for _ in 0..<3 { _ = controller.probeDisplayFrame() }
            controller.jumpTo(page: 0)
            #expect(collector.lines.count == 2)
            #expect(parse(collector.lines[1])["reason"] as? String == "cancelled")
            #expect(controller.phase == .idle)
        }
    }

    @Test("生命周期: 垂直手势(永不锁定)→ 恰一次 endedWithoutSettle 摘要")
    func lifecycleEndedWithoutSettle() {
        let (controller, linkView) = makeController()
        let (recorder, collector) = makeRecorder()
        recorder.enabled = true
        controller.perfRecorder = recorder
        controller.onPhaseIdle = { recorder.flushOpenSession() }

        withExtendedLifetime(linkView) {
            controller.probeGesture(deltaXs: [0, 0], deltaYs: [4, 4])
            #expect(controller.phase == .idle)
            #expect(collector.lines.count == 1)
            let json = parse(collector.lines[0])
            #expect(json["reason"] as? String == "endedWithoutSettle")
            #expect(count(nested(json, "a"), "preLockEvents") == 2)
            #expect(count(nested(json, "a"), "inputEvents") == 2)
        }
    }

    @Test("生命周期: 未显式收口的 open session 由 flushOpenSession 记为 endedWithoutSettle")
    func lifecycleFlushOpenCloses() {
        let (recorder, collector) = makeRecorder()
        recorder.enabled = true
        recorder.beginSession(startPage: 0, startOffset: 0, at: 100)
        recorder.recordInputEvent(at: 101)
        #expect(recorder.hasOpenSessionForDiag)
        #expect(collector.lines.isEmpty)
        recorder.flushOpenSession()
        #expect(collector.lines.count == 1)
        #expect(parse(collector.lines[0])["reason"] as? String == "endedWithoutSettle")
        #expect(recorder.hasOpenSessionForDiag == false)
    }

    // MARK: 4b. R2: 生命周期缺口 — 已收口未 emit 的 session 重建(interrupted/cancelled 变体)

    /// R2 主回归: settle 进行中收到 discrete 滚轮输入 → startSettle 记
    /// interrupted 收口 S1(未 emit) → beginSessionIfNeeded 必须重建 S2;
    /// 否则 S1 永不 emit、S2 指标全丢。修复前此测试断言 1 个摘要; 修复后
    /// S1(interrupted)+S2(settled) 双双存在。
    @Test("生命周期R2: settle 中 discrete 输入 → S1 interrupted + S2 settled 双摘要")
    func discreteDuringSettlingRebuildsSession() {
        let (controller, linkView) = makeController()
        let (recorder, collector) = makeRecorder()
        recorder.enabled = true
        controller.perfRecorder = recorder
        controller.onPhaseIdle = { recorder.flushOpenSession() }
        controller.enableDeterministicProbeClock()
        var currentOffset: CGFloat = 0
        controller.onReadCurrentOffset = { currentOffset }
        controller.onScroll = { currentOffset = $0 }

        withExtendedLifetime(linkView) {
            // S1: 左滑 → settle 0→640。
            controller.probeGesture(deltaXs: [-200])
            for _ in 0..<5 { _ = controller.probeDisplayFrame() }
            #expect(controller.phase == .settling)
            #expect(recorder.hasOpenSessionForDiag)

            // discrete 滚轮输入打断 settle → S1 interrupted, S2 重建开新 settle。
            let discrete = makeDiscreteScroll(deltaY: -1)!
            #expect(controller.handleWheel(discrete))
            driveUntilIdle(controller)
            #expect(collector.lines.count == 2)
            #expect(parse(collector.lines[0])["reason"] as? String == "interrupted")
            #expect(parse(collector.lines[1])["reason"] as? String == "settled")
            let firstID = parse(collector.lines[0])["sessionId"] as? String
            let secondID = parse(collector.lines[1])["sessionId"] as? String
            #expect(firstID != nil && secondID != nil && firstID != secondID)
            // discrete 输入到达时 S1 仍 open → 正确归属 S1: 探针手势 1 次
            // 输入 + discrete 1 次 = 2。
            let s1 = nested(parse(collector.lines[0]), "a")
            #expect(count(s1, "inputEvents") == 2)
            // S2 正常收口: 位移目标页已写。
            let a = nested(parse(collector.lines[1]), "a")
            #expect(a["finalOffset"] as? Double == 640)
            #expect(recorder.hasOpenSessionForDiag == false)
        }
    }

    /// R2 cancelled 变体(同根因): settle 中 jumpTo(取消)收口 S1(未 emit,
    /// 未接线 onPhaseIdle 时无 flush)→ 随后 discrete 输入触发 beginSessionIfNeeded
    /// → 修复后 S1(cancelled)+S2(settled) 双双存在。
    @Test("生命周期R2: settle 中取消后 discrete 输入 → S1 cancelled + S2 settled 双摘要")
    func cancelledThenDiscreteRebuildsSession() {
        let (controller, linkView) = makeController()
        let (recorder, collector) = makeRecorder()
        recorder.enabled = true
        controller.perfRecorder = recorder
        // 故意不接线 onPhaseIdle: jumpTo 收口后不立即 flush, 制造
        // "已收口未 emit" 状态, 让下一个 beginSessionIfNeeded 命中缺口。
        controller.enableDeterministicProbeClock()
        var currentOffset: CGFloat = 0
        controller.onReadCurrentOffset = { currentOffset }
        controller.onScroll = { currentOffset = $0 }

        withExtendedLifetime(linkView) {
            // S1: 左滑 → settle。
            controller.probeGesture(deltaXs: [-200])
            for _ in 0..<5 { _ = controller.probeDisplayFrame() }
            #expect(controller.phase == .settling)

            // jumpTo 取消 S1(cancelled, 未 emit)。
            controller.jumpTo(page: 0)
            #expect(controller.phase == .idle)
            #expect(collector.lines.isEmpty, "未接线 onPhaseIdle → S1 未 emit")

            // discrete 输入 → beginSessionIfNeeded 必须重建 S2。
            let discrete = makeDiscreteScroll(deltaY: -1)!
            #expect(controller.handleWheel(discrete))
            driveUntilIdle(controller)
            // 显式收口(生产由 onPhaseIdle 完成)。
            recorder.flushOpenSession()
            #expect(collector.lines.count == 2)
            #expect(parse(collector.lines[0])["reason"] as? String == "cancelled")
            #expect(parse(collector.lines[1])["reason"] as? String == "settled")
            let firstID = parse(collector.lines[0])["sessionId"] as? String
            let secondID = parse(collector.lines[1])["sessionId"] as? String
            #expect(firstID != nil && secondID != nil && firstID != secondID)
            #expect(recorder.hasOpenSessionForDiag == false)
        }
    }

    // MARK: - 4. 计数确定性(pre-lock 边界)

    @Test("计数: axis lock 阈值边界([3,3,3] → 2 个 pre-lock, 累计 6)")
    func preLockBoundaryDeterminism() {
        let (controller, linkView) = makeController()
        let (recorder, collector) = makeRecorder()
        recorder.enabled = true
        controller.perfRecorder = recorder
        controller.onPhaseIdle = { recorder.flushOpenSession() }
        controller.enableDeterministicProbeClock()

        withExtendedLifetime(linkView) {
            controller.probeGesture(deltaXs: [3, 3, 3, 60])
            driveUntilIdle(controller)
            #expect(collector.lines.count == 1)
            let a = nested(parse(collector.lines[0]), "a")
            #expect(count(a, "preLockEvents") == 2)
            #expect(a["preLockDeltaX"] as? Double == 6.0)
            #expect(count(a, "inputEvents") == 4)
            #expect(a["axisLockAt"] as? Double != nil)
        }
    }

    // MARK: - 5. grid 级路由分桶(live vs compositor)

    /// 经 NSEvent 驱动完整手势(含 tracking 帧): began → changed×2 →
    /// tracking 帧 → ended → settle → idle。
    private func driveFullGesture(
        _ grid: GridViewController,
        dx: CGFloat = 120
    ) {
        let paging = pagingControllerForDiag(grid)
        // 负 delta = 左滑 → 下一页方向(与既有 grid 测试约定一致)。
        let began = makeScroll(dx: -40, phase: .began)!
        let changed1 = makeScroll(dx: -dx, phase: .changed)!
        let changed2 = makeScroll(dx: -dx, phase: .changed)!
        let ended = makeScroll(dx: 0, phase: .ended)!
        #expect(paging.handleWheel(began))
        #expect(paging.handleWheel(changed1))
        #expect(paging.handleWheel(changed2))
        // tracking 阶段推进 2 帧(applyScroll → routeScroll 分桶)。
        _ = grid.pagingProbeDisplayFrame()
        _ = grid.pagingProbeDisplayFrame()
        #expect(paging.handleWheel(ended))
        driveUntilIdle(grid)
    }

    @Test("grid: live 路径 → liveTracking/liveSettling 分桶, 无合成器指标")
    func gridLiveRoutingBuckets() async {
        let grid = makeGrid(PerfTelemetryStore())
        grid.pageVisualCompositorEnabled = false  // 强制 live
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }
        grid.refresh()
        var summaries: [String] = []
        grid.configurePagingPerfTelemetry(enabled: true)
        // R2 隔离卫生: grid 级测试只断言 controller 级指标, cell 归属不在
        // 范围 → 立即清空全局 cell 记录器, 防跨 suite 并行 cell 事件污染。
        defer { PagingPerfContext.recorder = nil }
        grid.setPagingPerfSummaryHandlerForDiag { summaries.append($0) }
        driveFullGesture(grid)
        // R2: 只按 pagingSessionSummary 事件类型取数(idle 摘要独立事件, 过滤)。
        let sessionLines = summaries.filter { $0.contains("pagingSessionSummary") }
        #expect(sessionLines.count == 1)
        let json = parse(sessionLines[0])
        #expect(json["reason"] as? String == "settled")
        let b = nested(json, "b")
        #expect(count(nested(b, "liveTracking"), "count") >= 2)
        #expect(count(nested(b, "liveSettling"), "count") >= 1)
        #expect(count(nested(b, "compositorTracking"), "applyOffsetCount") == 0)
        #expect(nested(json, "a")["compositorActive"] as? Bool == false)
    }

    @Test("grid: compositor 路径 → tracking/settling/teardown 分桶, teardown=finishSettle")
    func gridCompositorRoutingBuckets() async {
        let grid = makeGrid(PerfTelemetryStore())
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }
        grid.refresh()
        var summaries: [String] = []
        grid.configurePagingPerfTelemetry(enabled: true)
        // R2 隔离卫生(见 gridLiveRoutingBuckets 注释)。
        defer { PagingPerfContext.recorder = nil }
        grid.setPagingPerfSummaryHandlerForDiag { summaries.append($0) }
        await waitPrepared(grid)
        driveFullGesture(grid)
        // R2: 只按 pagingSessionSummary 事件类型取数。
        let sessionLines = summaries.filter { $0.contains("pagingSessionSummary") }
        #expect(sessionLines.count == 1)
        let json = parse(sessionLines[0])
        #expect(json["reason"] as? String == "settled")
        #expect(nested(json, "a")["compositorActive"] as? Bool == true)
        let b = nested(json, "b")
        #expect(count(nested(b, "liveTracking"), "count") == 0)
        #expect(count(nested(b, "liveSettling"), "count") == 0)
        #expect(count(nested(b, "compositorTracking"), "applyOffsetCount") >= 2)
        #expect(count(nested(b, "compositorTracking"), "realClipWriteCount") == 0)
        let settling = nested(b, "compositorSettling")
        #expect(count(settling, "layerApplyCount") >= 1)
        // R2 ③: catch-up 真实路径断言 —— settle 首帧起 gap>0.5 → 真实 clip
        // 渐进写(advanceRealClipBehindCover, 35% 缺口/帧)。
        #expect(count(settling, "advanceRealClipCalls") >= 1)
        #expect(count(settling, "catchUpClipWriteCount") >= 1)
        // gapSkip 恒 0(实测 + 平衡态分析): 尾段弹簧每帧位移 ~0.62px,
        // 追赶平衡 gap ≈ 0.62×0.65/0.35 ≈ 1.15px > 0.5 → 收敛前永不
        // 进入 ≤0.5 跳过分支; skip 分支由 recorder 级单测(gapSkipCount==1)覆盖。
        #expect(count(settling, "gapSkipCount") == 0)
        #expect(settling["catchUpTotalMs"] as? Double ?? -1 >= 0)
        #expect(settling["catchUpGapMax"] as? Double ?? 0 >= 1)
        let teardown = nested(b, "teardown")
        #expect(teardown["reason"] as? String == "finishSettle")
        #expect(count(teardown, "syncClipCount") == 1)
        #expect(teardown["layoutSubtreeExecuted"] as? Bool == true)
        #expect(count(teardown, "totalCount") == 1)
    }

    @Test("grid: compositor settle 中显式 shutdown → teardown reason=shutdown")
    func gridCompositorShutdownTeardown() async {
        let grid = makeGrid(PerfTelemetryStore())
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }
        grid.refresh()
        var summaries: [String] = []
        grid.configurePagingPerfTelemetry(enabled: true)
        // R2 隔离卫生(见 gridLiveRoutingBuckets 注释)。
        defer { PagingPerfContext.recorder = nil }
        grid.setPagingPerfSummaryHandlerForDiag { summaries.append($0) }
        await waitPrepared(grid)
        let paging = pagingControllerForDiag(grid)
        let began = makeScroll(dx: -40, phase: .began)!
        let changed = makeScroll(dx: -140, phase: .changed)!
        let ended = makeScroll(dx: 0, phase: .ended)!
        #expect(paging.handleWheel(began))
        #expect(paging.handleWheel(changed))
        #expect(paging.handleWheel(ended))
        // settle 中 shutdown 合成器 → teardown reason=shutdown。
        for _ in 0..<3 { _ = grid.pagingProbeDisplayFrame() }
        grid.shutdownPageCompositor()
        driveUntilIdle(grid)
        // R2: 只按 pagingSessionSummary 事件类型取数。
        let sessionLines = summaries.filter { $0.contains("pagingSessionSummary") }
        #expect(sessionLines.count == 1)
        let b = nested(parse(sessionLines[0]), "b")
        #expect(nested(b, "teardown")["reason"] as? String == "shutdown")
    }

    // MARK: - 6. cell/icon 归属

    @Test("cell: idle 期事件归 idle 桶, pagingIdleSummary 输出 attribution=idle")
    func cellIdleAttribution() {
        let (recorder, collector) = makeRecorder()
        recorder.enabled = true
        PagingPerfContext.recorder = recorder
        defer { PagingPerfContext.recorder = nil }

        PagingPerfContext.recordCellEvent("cellProvider")
        PagingPerfContext.recordCellEvent("cellConfigure")
        PagingPerfContext.recordCellEvent("prepareForReuse")
        PagingPerfContext.recordCellEvent("iconRequest")
        PagingPerfContext.recordCellEvent("cellProvider")

        recorder.flushIdleSummaryIfAny()
        #expect(collector.lines.count == 1)
        let json = parse(collector.lines[0])
        #expect(json["event"] as? String == "pagingIdleSummary")
        #expect(json["attribution"] as? String == "idle")
        #expect(json["sessionId"] as? NSNull == NSNull())
        let d = nested(json, "d")
        #expect(count(nested(d, "cellProvider"), "idle") == 2)
        #expect(count(nested(d, "cellConfigure"), "idle") == 1)
        #expect(count(nested(d, "cellPrepareForReuse"), "idle") == 1)
        #expect(count(nested(d, "iconRequest"), "idle") == 1)

        // 二次 flush(无新数据)不重复输出。
        recorder.flushIdleSummaryIfAny()
        #expect(collector.lines.count == 1)
    }

    @Test("cell: session 内事件归 session 桶(tracking phase)")
    func cellSessionAttribution() {
        let (recorder, collector) = makeRecorder()
        recorder.enabled = true
        PagingPerfContext.recorder = recorder
        defer { PagingPerfContext.recorder = nil }

        recorder.beginSession(startPage: 0, startOffset: 0, at: 100)
        PagingPerfContext.recordCellEvent("cellProvider")
        PagingPerfContext.recordCellEvent("iconRequest")
        PagingPerfContext.recordCellEvent("prepareForReuse")
        recorder.recordSettleStart(targetPage: 1, at: 110)
        PagingPerfContext.recordCellEvent("cellProvider")
        recorder.recordSettleCompleted(finalOffset: 640, at: 120)
        recorder.flushOpenSession()

        #expect(collector.lines.count == 1)
        let d = nested(parse(collector.lines[0]), "d")
        #expect(count(nested(d, "cellProvider"), "tracking") == 1)
        #expect(count(nested(d, "cellProvider"), "settling") == 1)
        #expect(count(nested(d, "iconRequest"), "tracking") == 1)
        #expect(count(nested(d, "cellPrepareForReuse"), "tracking") == 1)
    }

    @Test("cell: AppCellView.prepareForReuse 真实调用点计入 idle 桶")
    func appCellPrepareForReuseCallSite() {
        let (recorder, collector) = makeRecorder()
        recorder.enabled = true
        PagingPerfContext.recorder = recorder
        defer { PagingPerfContext.recorder = nil }

        let cell = AppCellView()
        _ = cell.view  // 强制加载(与 configure 前一致)
        cell.prepareForReuse()
        cell.prepareForReuse()

        recorder.flushIdleSummaryIfAny()
        #expect(collector.lines.count == 1)
        let d = nested(parse(collector.lines[0]), "d")
        #expect(count(nested(d, "cellPrepareForReuse"), "idle") == 2)
    }

    @Test("cell: AppCellView.configure 真实调用点触发 iconRequest 计数(app 单图标)")
    func appCellIconRequestCallSite() {
        let (recorder, collector) = makeRecorder()
        recorder.enabled = true
        PagingPerfContext.recorder = recorder
        defer { PagingPerfContext.recorder = nil }

        let cell = AppCellView()
        cell.configure(
            displayName: "PerfApp",
            colorIndex: 3,
            accessibilityHint: "launch",
            appID: makeApp(0, 0),
            pointSize: 64,
            iconProvider: PerfTelemetryIconProvider()
        )

        recorder.flushIdleSummaryIfAny()
        #expect(collector.lines.count == 1)
        let d = nested(parse(collector.lines[0]), "d")
        // cellConfigure 计数在 GridViewController.configure(数据源闭包)层,
        // 这里直接调用 AppCellView.configure 只应触发 iconRequest。
        #expect(count(nested(d, "cellConfigure"), "idle") == 0)
        #expect(count(nested(d, "iconRequest"), "idle") == 1)
    }

    @Test("cell: 未注册 recorder 时调用点零副作用(默认路径)")
    func cellEventWithoutRecorder() {
        PagingPerfContext.recorder = nil
        PagingPerfContext.recordCellEvent("cellProvider")  // 不应崩溃/记录
        #expect(PagingPerfContext.recorder == nil)
    }

    // MARK: - 7. layout metrics(只记录, 不改行为)

    @Test("layout: 无 collection view 的 prepare/query/invalidate 全部记录")
    func layoutMetricsWithoutCollectionView() {
        let (recorder, collector) = makeRecorder()
        recorder.enabled = true
        let layout = PagingGridLayout(
            columns: 4, rows: 5, cellSize: 80, iconSize: 64,
            horizontalSpacing: 12, verticalSpacing: 12
        )
        layout.perfRecorder = recorder

        layout.prepare()
        _ = layout.layoutAttributesForElements(in: NSRect(x: 0, y: 0, width: 640, height: 480))
        let invalidate = layout.shouldInvalidateLayout(
            forBoundsChange: NSRect(x: 0, y: 0, width: 700, height: 500)
        )
        #expect(invalidate == false)  // 行为不变: 无 collection view → false

        recorder.flushOpenSession()
        recorder.flushIdleSummaryIfAny()
        #expect(collector.lines.count == 1)
        let json = parse(collector.lines[0])
        #expect(json["event"] as? String == "pagingIdleSummary")
        let c = nested(json, "c")
        #expect(count(nested(c, "prepare"), "count") == 1)
        #expect(count(nested(c, "query"), "count") == 1)
        #expect(count(nested(c, "query"), "candidatesTotal") == 0)
        #expect(count(nested(c, "query"), "returnedTotal") == 0)
        #expect(count(nested(c, "invalidate"), "calls") == 1)
        #expect(count(nested(c, "invalidate"), "true") == 0)
        #expect(count(nested(c, "invalidate"), "false") == 1)
    }

    @Test("layout: session 内 prepare/query 归 session 桶; 判定逻辑逐位保留")
    func layoutMetricsDuringSession() {
        let (recorder, collector) = makeRecorder()
        recorder.enabled = true
        let layout = PagingGridLayout(
            columns: 4, rows: 5, cellSize: 80, iconSize: 64,
            horizontalSpacing: 12, verticalSpacing: 12
        )
        layout.perfRecorder = recorder

        recorder.beginSession(startPage: 0, startOffset: 0, at: 100)
        layout.prepare()
        _ = layout.layoutAttributesForElements(in: NSRect(x: 0, y: 0, width: 640, height: 480))
        recorder.recordSettleCompleted(finalOffset: 0, at: 110)
        recorder.flushOpenSession()

        #expect(collector.lines.count == 1)
        let c = nested(parse(collector.lines[0]), "c")
        #expect(count(nested(c, "prepare"), "count") == 1)
        #expect(count(nested(c, "query"), "count") == 1)
    }

    // MARK: - 8. PageCompositor teardown 归属

    private func makeActiveCompositor(
        _ recorder: PagingPerfTelemetry
    ) -> PageCompositor {
        let compositor = PageCompositor()
        compositor.perfRecorder = recorder
        let host = CALayer()
        let live = CALayer()
        compositor.activate(
            placements: [makeDiagnosticPlacement(page: 0), makeDiagnosticPlacement(page: 1)],
            pageWidth: 640,
            startOffset: 0,
            hostLayer: host,
            liveLayer: live
        )
        #expect(compositor.isActive)
        return compositor
    }

    @Test("compositor: finishSettle teardown → idle 桶 reason=finishSettle, sync=1, layout 未执行")
    func compositorTeardownFinishSettleIdle() {
        let (recorder, collector) = makeRecorder()
        recorder.enabled = true
        let compositor = makeActiveCompositor(recorder)
        compositor.finishSettle()
        #expect(!compositor.isActive)

        recorder.flushIdleSummaryIfAny()
        #expect(collector.lines.count == 1)
        let teardown = nested(nested(parse(collector.lines[0]), "b"), "teardown")
        #expect(teardown["reason"] as? String == "finishSettle")
        #expect(count(teardown, "syncClipCount") == 1)
        #expect(teardown["layoutSubtreeExecuted"] as? Bool == false)
        #expect(count(teardown, "totalCount") == 1)
    }

    @Test("compositor: abort / shutdown teardown 原因正确")
    func compositorTeardownReasons() {
        let (recorder, collector) = makeRecorder()
        recorder.enabled = true

        let aborted = makeActiveCompositor(recorder)
        aborted.abort()
        recorder.flushIdleSummaryIfAny()
        #expect(collector.lines.count == 1)
        #expect(nested(nested(parse(collector.lines[0]), "b"), "teardown")["reason"] as? String == "abort")

        let shutdown = makeActiveCompositor(recorder)
        shutdown.shutdown()
        recorder.flushIdleSummaryIfAny()
        #expect(collector.lines.count == 2)
        #expect(nested(nested(parse(collector.lines[1]), "b"), "teardown")["reason"] as? String == "shutdown")

        // shutdown 幂等(未激活时只记录事件, 不再产生 teardown 指标)。
        shutdown.shutdown()
        recorder.flushIdleSummaryIfAny()
        #expect(collector.lines.count == 2)
    }

    @Test("compositor: open session 期间 teardown 归 session 桶")
    func compositorTeardownDuringSession() {
        let (recorder, collector) = makeRecorder()
        recorder.enabled = true
        let compositor = makeActiveCompositor(recorder)

        recorder.beginSession(startPage: 0, startOffset: 0, at: 100)
        compositor.shutdown()
        recorder.recordSettleCompleted(finalOffset: 0, at: 110)
        recorder.flushOpenSession()

        #expect(collector.lines.count == 1)
        let teardown = nested(nested(parse(collector.lines[0]), "b"), "teardown")
        #expect(teardown["reason"] as? String == "shutdown")
        #expect(count(teardown, "totalCount") == 1)
    }

    /// R2 ③: catch-up 指标 recorder 级单元断言 —— 与调用点(advanceRealClip
    /// BehindCover)同一方法, 覆盖 JSON 字段映射。真实路径(settling 中 gap>0.5
    /// 触发真实 clip 渐进写)由 gridCompositorRoutingBuckets 覆盖。
    @Test("catch-up: recordCatchUpWrite/GapSkip 聚合进 session 摘要")
    func catchUpMetricsRecordedInSession() {
        let (recorder, collector) = makeRecorder()
        recorder.enabled = true
        recorder.beginSession(startPage: 0, startOffset: 0, at: 100)
        recorder.recordSettleStart(targetPage: 1, at: 101)
        recorder.recordCatchUpWrite(durationMs: 0.5, gap: 300)
        recorder.recordCatchUpWrite(durationMs: 1.2, gap: 120)
        recorder.recordCatchUpWrite(durationMs: 0.8, gap: 0.4)  // 已低于阈值仍记录
        recorder.recordCatchUpGapSkip()
        recorder.recordAdvanceRealClipCall()
        recorder.recordSettleCompleted(finalOffset: 640, at: 200)
        recorder.flushOpenSession()

        #expect(collector.lines.count == 1)
        let settling = nested(nested(parse(collector.lines[0]), "b"), "compositorSettling")
        #expect(count(settling, "advanceRealClipCalls") == 1)
        #expect(count(settling, "catchUpClipWriteCount") == 3)
        #expect(count(settling, "gapSkipCount") == 1)
        #expect(settling["catchUpTotalMs"] as? Double == 2.5)  // 0.5+1.2+0.8
        #expect(settling["catchUpGapMax"] as? Double == 300)
    }

    // MARK: - 9. 与既有遥测隔离(独立存储, 不双重计数)

    @Test("隔离: recorder 计数与 PageCompositorMetrics(--pagecompositor) 互不干扰")
    func isolatedFromCompositorMetrics() {
        let (recorder, _) = makeRecorder()
        recorder.enabled = true
        let compositor = makeActiveCompositor(recorder)
        // 默认 diagnosticsEnabled == false: 现有 diag 事件环不记录。
        compositor.finishSettle()
        #expect(compositor.eventsForDiag.isEmpty)
        // recorder 侧已有 teardown 记录(idle 桶)。
        recorder.flushIdleSummaryIfAny()
        // 无崩溃即通过; 两个存储独立。
    }
}

// MARK: - 测试替身

@MainActor
private final class PerfTelemetryStore: LauncherStoring {
    var onDataChange: (() -> Void)?
    let gridColumns = 3
    let gridRows = 2
    let iconSize = 64
    let wallpaperBlurRadius = 30
    let searchBarWidth = 320
    var displayRevision: UInt64 { 1 }

    let pages: [[DisplayModel.DisplayItem]]

    init() {
        pages = (0..<4).map { page in
            (0..<3).map { index in
                .app(AppID("/Applications/PerfA\(page)\(index).app")!)
            }
        }
    }

    @discardableResult
    func addDataObserver(_ observer: @escaping () -> Void) -> UUID { UUID() }
    func removeDataObserver(_ token: UUID) {}

    func displayModel() -> DisplayModel {
        DisplayModel(pages: pages, pageCapacity: gridColumns * gridRows)
    }

    func searchResults(for query: String) -> [DisplayModel.DisplayItem]? { nil }
    func displayName(for appID: AppID) -> String { appID.rawValue }
    func folderName(for folderID: FolderID) -> String { folderID.rawValue }
    func launch(_ appID: AppID) {}
    func createFolder(name: String, appIDs: [AppID]) {}
    func renameFolder(_ id: FolderID, to name: String) {}
    func dissolveFolder(_ id: FolderID) {}
    func addToFolder(app: AppID, folder: FolderID) {}
    func moveOutOfFolder(
        app: AppID,
        from folder: FolderID,
        toDisplayIndex: Int,
        completion: @escaping (Bool) -> Void
    ) { completion(false) }
    func reorderFolderApp(app: AppID, in folder: FolderID, toIndex: Int) {}
    func folderNames() -> [FolderID: String] { [:] }
    func folderChildren(_ id: FolderID) -> [AppID]? { nil }
    func applyDragDrop(_ mutation: LayoutTransaction.LayoutMutation) {}
    func setHidden(_ appID: AppID, hidden: Bool) {}
    func setCustomName(_ appID: AppID, name: String?) {}
    func moveToTrash(_ appID: AppID) {}
    func isHidden(_ appID: AppID) -> Bool { false }
}

@MainActor
private final class PerfTelemetryIconProvider: IconImageProviding {
    func icon(for appID: AppID, pointSize: Int, scale: Int) async -> CGImage? {
        let context = CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(
            NSColor(hue: 0.5, saturation: 0.6, brightness: 0.7, alpha: 1).cgColor
        )
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        return context.makeImage()
    }

    func trimMemoryForHidden() {}
}
