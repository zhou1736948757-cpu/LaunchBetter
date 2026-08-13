import AppKit
import Foundation
import Testing
@testable import LaunchUI

/// PA4: 分页半路卡住根因回归 —— beginGesture 打断在途 settle 后, 新手势未锁定
/// 水平位移(垂直/微动)结束时必须重启 settle 回到被打断目标页, 禁止停在页面
/// 中间(idle + display link 停止 + offset 不在页边界)。
@Suite("Paging interrupt resume (PA4)", .serialized)
@MainActor
struct PagingInterruptResumeTests {
    private static let pageWidth: CGFloat = 800

    /// 构造可观测 offset 的控制器(pageCount 3, 页宽 800)。
    private func makeController(
        pageCount: Int = 3,
        initialOffset: CGFloat = 0
    ) -> (PagingInteractionController, () -> CGFloat) {
        let controller = PagingInteractionController()
        var currentOffset = initialOffset
        controller.linkView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        controller.onReadPageWidth = { Self.pageWidth }
        controller.onReadPageCount = { pageCount }
        controller.onReadCurrentOffset = { currentOffset }
        controller.onScroll = { currentOffset = $0 }
        return (controller, { currentOffset })
    }

    /// 驱动帧直到 idle(弹簧按墙钟收敛, 必须让真实时间流逝)。
    @discardableResult
    private func settleToIdle(
        _ controller: PagingInteractionController,
        maxFrames: Int = 400
    ) -> Bool {
        for _ in 0..<maxFrames {
            if controller.probeDisplayFrame() { return true }
            Thread.sleep(forTimeInterval: 1.0 / 240.0)
        }
        return false
    }

    /// 驱动帧直到指定帧数(制造中间态)。
    private func driveFrames(_ controller: PagingInteractionController, count: Int) {
        for _ in 0..<count {
            _ = controller.probeDisplayFrame()
            Thread.sleep(forTimeInterval: 1.0 / 240.0)
        }
    }

    /// 驱动直到 offset 越过阈值(越过页 0.5 界, 使 round(offset/pageWidth)==1)。
    private func driveUntil(
        _ controller: PagingInteractionController,
        offsetExceeds threshold: CGFloat,
        offset: @escaping () -> CGFloat,
        maxFrames: Int = 400
    ) -> Bool {
        for _ in 0..<maxFrames {
            _ = controller.probeDisplayFrame()
            if offset() > threshold { return true }
            Thread.sleep(forTimeInterval: 1.0 / 240.0)
        }
        return false
    }

    /// 页边界断言: |offset/pageWidth - 最近整数| <= eps。
    private func assertPageBoundary(
        _ controller: PagingInteractionController,
        offset: CGFloat,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let pageWidth = max(1, Self.pageWidth)
        let page = offset / pageWidth
        let nearest = (page).rounded()
        #expect(
            abs(page - nearest) <= 0.001,
            "offset \(offset) 必须停在页边界(最近页 \(nearest))",
            sourceLocation: sourceLocation
        )
        #expect(controller.phase == .idle, sourceLocation: sourceLocation)
        #expect(!controller.isDisplayLinkActive, sourceLocation: sourceLocation)
    }

    // MARK: - 根因场景

    @Test("settle 中途被垂直手势打断 → 重启 settle 到原目标页")
    func verticalInterruptResumesToOriginalPage() {
        let (controller, offset) = makeController()
        // 左滑翻到页 1 → settle 进行中。
        controller.probeGesture(deltaXs: [-60, -80, -80])
        #expect(controller.phase == .settling)
        #expect(controller.settleTargetPageForTest == 1)
        driveFrames(controller, count: 10)
        let midOffset = offset()
        #expect(midOffset > 100 && midOffset < 700, "必须处于中间态, 实际 \(midOffset)")

        // 新手势纯垂直: 从不锁定水平 → finishTrackingWithoutSettle。
        controller.probeGesture(deltaXs: [3, 2], deltaYs: [20, 30])
        #expect(controller.interruptionCount == 1)
        #expect(controller.phase == .settling, "必须重启 settle 而不是停在中间")
        #expect(settleToIdle(controller))

        #expect(offset() == 800, "必须收敛到被打断的目标页(页 1)")
        assertPageBoundary(controller, offset: offset())
    }

    @Test("settle 中途被零位移水平手势打断 → 重启 settle 到原目标页")
    func zeroDisplacementHorizontalInterruptResumesToOriginalPage() {
        let (controller, offset) = makeController()
        controller.probeGesture(deltaXs: [-60, -80, -80])
        driveFrames(controller, count: 10)

        // 新手势锁定水平轴但累计位移为 0(-6+6): displacement == 0 分支。
        controller.probeGesture(deltaXs: [-6, 6])
        #expect(controller.interruptionCount == 1)
        #expect(controller.phase == .settling)
        #expect(settleToIdle(controller))

        #expect(offset() == 800)
        assertPageBoundary(controller, offset: offset())
    }

    @Test("settle 中途被反向水平手势打断 → 使用新手势的目标")
    func newHorizontalGestureUsesNewTarget() {
        let (controller, offset) = makeController()
        controller.probeGesture(deltaXs: [-60, -80, -80])
        #expect(controller.phase == .settling)
        // 驱动到中后段(round(offset/800) == 1)再打断。
        #expect(driveUntil(controller, offsetExceeds: 400, offset: offset))

        // 同一方向再来一记 fling: 从页 1 继续 → 翻到页 2。
        controller.probeGesture(deltaXs: [-80, -80, -80])
        #expect(controller.interruptionCount == 1)
        #expect(controller.phase == .settling)
        #expect(settleToIdle(controller))

        #expect(offset() == 1600, "新手势必须使用新目标(页 2)")
        assertPageBoundary(controller, offset: offset())
    }

    @Test("settle 中途被反向 fling 打断 → 翻回上一页")
    func reverseFlingDuringSettleGoesBack() {
        let (controller, offset) = makeController()
        controller.probeGesture(deltaXs: [-60, -80, -80])
        #expect(controller.phase == .settling)
        // 驱动到中后段(round(offset/800) == 1)再反向打断。
        #expect(driveUntil(controller, offsetExceeds: 400, offset: offset))

        // 反向(向右滑): 从页 1 回页 0。
        controller.probeGesture(deltaXs: [80, 80, 80])
        #expect(controller.interruptionCount == 1)
        #expect(settleToIdle(controller))

        #expect(offset() == 0, "反向手势应回到页 0")
        assertPageBoundary(controller, offset: offset())
    }

    @Test("重复打断: 每次重启的 settle 都可再次被安全打断")
    func repeatedInterruptsStayConsistent() {
        let (controller, offset) = makeController()
        controller.probeGesture(deltaXs: [-60, -80, -80])
        driveFrames(controller, count: 8)
        controller.probeGesture(deltaXs: [2, 2], deltaYs: [25, 25])
        #expect(controller.phase == .settling)
        driveFrames(controller, count: 8)
        // 第二次垂直打断: 仍在向页 1 收敛的中途。
        controller.probeGesture(deltaXs: [1, 1], deltaYs: [10, 10])
        // probeGesture 每次重置计数器: 每次打断手势各自计数为 1。
        #expect(controller.interruptionCount == 1)
        #expect(settleToIdle(controller))
        #expect(offset() == 800)
        assertPageBoundary(controller, offset: offset())
    }

    // MARK: - 目标清理与重 clamp

    @Test("jumpTo 清除被打断目标: 后续无水平手势不再重启旧 settle")
    func jumpToClearsInterruptedTarget() {
        let (controller, offset) = makeController()
        controller.probeGesture(deltaXs: [-60, -80, -80])
        driveFrames(controller, count: 10)

        controller.jumpTo(page: 2)
        #expect(controller.phase == .idle)
        #expect(offset() == 1600)

        // 垂直手势(无水平位移)结束时不得复活任何旧 settle。
        controller.probeGesture(deltaXs: [2, 2], deltaYs: [20, 30])
        #expect(controller.phase == .idle)
        #expect(offset() == 1600)
        #expect(settleToIdle(controller))
        assertPageBoundary(controller, offset: offset())

        // 之后新的打断仍正常捕获新目标(从页 2 右滑回页 1)。
        controller.probeGesture(deltaXs: [80, 80, 80])
        driveFrames(controller, count: 10)
        controller.probeGesture(deltaXs: [1, 1], deltaYs: [20, 20])
        #expect(controller.phase == .settling)
        #expect(settleToIdle(controller))
        #expect(offset() == 800)
    }

    @Test("disabled 清除 settle/被打断目标: 禁用期间无 settle 残留")
    func disablingClearsInterruptedTarget() {
        let (controller, _) = makeController()
        controller.probeGesture(deltaXs: [-60, -80, -80])
        driveFrames(controller, count: 10)
        #expect(controller.settleTargetPageForTest == 1)

        controller.isEnabled = false

        #expect(controller.phase == .idle)
        #expect(!controller.isDisplayLinkActive)
        #expect(controller.probeDisplayFrame())
        #expect(controller.interruptedSettleTargetForTest == nil)
        #expect(controller.settleTargetPageForTest == nil)
    }

    @Test("shutdown 清除被打断目标")
    func shutdownClearsInterruptedTarget() {
        let (controller, _) = makeController()
        controller.probeGesture(deltaXs: [-60, -80, -80])
        driveFrames(controller, count: 10)
        controller.shutdown()
        #expect(controller.phase == .idle)
        #expect(!controller.isDisplayLinkActive)
        #expect(controller.interruptedSettleTargetForTest == nil)
        #expect(controller.settleTargetPageForTest == nil)
    }

    @Test("重启 settle 时目标重新 clamp 到当前 pageCount")
    func resumeReclampsToCurrentPageCount() {
        var pageCount = 6
        let controller = PagingInteractionController()
        var currentOffset: CGFloat = 0
        controller.linkView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        controller.onReadPageWidth = { Self.pageWidth }
        controller.onReadPageCount = { pageCount }
        controller.onReadCurrentOffset = { currentOffset }
        controller.onScroll = { currentOffset = $0 }

        // 目标页 5(页数 6 时合法)。
        controller.startSettle(toPage: 5)
        #expect(controller.settleTargetPageForTest == 5)
        driveFrames(controller, count: 10)

        // 页数缩到 3 → 被打断目标必须在重启时重 clamp 到 2。
        pageCount = 3
        controller.probeGesture(deltaXs: [2, 2], deltaYs: [20, 30])
        #expect(controller.phase == .settling)
        #expect(settleToIdle(controller))
        #expect(currentOffset == 1600, "重 clamp 后必须停在页 2")
        assertPageBoundary(controller, offset: currentOffset)
    }

    // MARK: - 页边界不变式

    @Test("各类手势结束后 offset 恒在页边界(不变式)")
    func idleOffsetAlwaysAtPageBoundary() {
        let scenarios: [(label: String, deltas: [CGFloat], ys: [CGFloat], expectOffset: CGFloat)] = [
            ("fling left", [-60, -80, -80], [], 800),
            ("slow left", [-8, -8, -8, -8, -8, -8, -8, -8, -8, -8], [], 800),
            ("fling right", [80, 80], [], 0),
            ("vertical only", [2, 2], [20, 30], 0),
            ("zero horizontal", [-6, 6], [], 0),
            ("below threshold", [-4, -4], [], 0),
        ]
        for scenario in scenarios {
            let (controller, offset) = makeController()
            controller.probeGesture(deltaXs: scenario.deltas, deltaYs: scenario.ys)
            #expect(settleToIdle(controller), "\(scenario.label) 必须收敛")
            #expect(
                offset() == scenario.expectOffset,
                "\(scenario.label): 期望 \(scenario.expectOffset), 实际 \(offset())"
            )
            assertPageBoundary(controller, offset: offset())
        }
    }

    @Test("settle 目标页经 clamp(超界请求收敛到最后一页)")
    func settleTargetClampsOutOfRange() {
        let (controller, offset) = makeController()
        controller.startSettle(toPage: 99)
        #expect(controller.settleTargetPageForTest == 2)
        #expect(settleToIdle(controller))
        #expect(offset() == 1600)
        assertPageBoundary(controller, offset: offset())
    }
}
