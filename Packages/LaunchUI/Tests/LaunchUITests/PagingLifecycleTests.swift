import AppKit
import Testing
@testable import LaunchUI

/// §C4 生命周期: PagingInteractionController 的 display link 停止路径。
///
/// 断言不依赖真实显示器帧: 无论 NSView.displayLink 在本环境能否创建 link,
/// "禁用分页必须回 idle、且不残留活动 link、不再产生滚动写" 的契约都要成立。
@Suite("Paging lifecycle: display link teardown", .serialized)
@MainActor
struct PagingLifecycleTests {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let view = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = view
        return window
    }

    private func makeController(window: NSWindow) -> PagingInteractionController {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = view
        let controller = PagingInteractionController()
        controller.linkView = view
        controller.onReadPageWidth = { 800 }
        controller.onReadPageCount = { 3 }
        return controller
    }

    private func makeHeadlessController(
        pageWidth: CGFloat = 1000,
        currentOffset: CGFloat = 1000
    ) -> PagingInteractionController {
        let controller = PagingInteractionController()
        controller.onReadCurrentOffset = { currentOffset }
        controller.onReadPageWidth = { pageWidth }
        controller.onReadPageCount = { 3 }
        return controller
    }

    @Test("禁用分页(搜索模式)中断在途 settle 并停止 display link")
    func disablingPagingStopsActiveSettle() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        let controller = makeController(window: window)
        var scrollWrites = 0
        controller.onScroll = { _ in scrollWrites += 1 }

        controller.startSettle(toPage: 1)
        #expect(controller.phase == .settling)

        controller.isEnabled = false
        #expect(controller.phase == .idle, "禁用分页必须回到 idle, 无残留状态")
        #expect(controller.isDisplayLinkActive == false, "禁用分页必须 invalidate display link")

        // 禁用后手动驱动帧: 不再产生滚动写, 且保持 idle。
        let writesAfterDisable = scrollWrites
        #expect(controller.probeDisplayFrame() == true)
        #expect(scrollWrites == writesAfterDisable)
    }

    @Test("重新启用后仍可启动新 settle")
    func reenablingAllowsNewSettle() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        let controller = makeController(window: window)

        controller.isEnabled = false
        #expect(controller.phase == .idle)
        #expect(controller.isDisplayLinkActive == false)

        controller.isEnabled = true
        controller.startSettle(toPage: 0)
        #expect(controller.phase == .settling)

        controller.isEnabled = false
        #expect(controller.phase == .idle)
        #expect(controller.isDisplayLinkActive == false)
    }

    @Test("5%-9%短距快速左/右 fling 使用与 resolver 一致的方向")
    func shortFastFlingUsesResolverDirectionBothWays() {
        var leftTarget: Int?
        let left = makeHeadlessController()
        left.onSettleTargetPage = { leftTarget = $0 }
        left.probeGesture(deltaXs: [-10, -50])
        #expect(leftTarget == 2)

        var rightTarget: Int?
        let right = makeHeadlessController()
        right.onSettleTargetPage = { rightTarget = $0 }
        right.probeGesture(deltaXs: [10, 50])
        #expect(rightTarget == 0)
    }

    @Test("零水平位移不启动无意义 settle 或 display link")
    func zeroHorizontalGestureDoesNotStartAnimation() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        let controller = makeController(window: window)

        controller.probeGesture(deltaXs: [0, 0])

        #expect(controller.phase == .idle)
        #expect(controller.settleCount == 0)
        #expect(controller.isDisplayLinkActive == false)
        #expect(controller.scrollWriteCount == 0)
    }

    @Test("未锁定的垂直手势不启动无意义 settle 或 display link")
    func verticalGestureWithoutHorizontalLockDoesNotStartAnimation() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        let controller = makeController(window: window)

        controller.probeGesture(deltaXs: [3, 2], deltaYs: [20, 30])

        #expect(controller.phase == .idle)
        #expect(controller.settleCount == 0)
        #expect(controller.isDisplayLinkActive == false)
        #expect(controller.scrollWriteCount == 0)
    }

    @Test("settle 收敛帧精确写入最终 target")
    func settleFinalFrameWritesExactTarget() {
        let controller = PagingInteractionController()
        let pageWidth: CGFloat = 800
        var currentOffset: CGFloat = 0
        var writes: [CGFloat] = []
        controller.onReadCurrentOffset = { currentOffset }
        controller.onReadPageWidth = { pageWidth }
        controller.onReadPageCount = { 3 }
        controller.onScroll = { offset in
            currentOffset = offset
            writes.append(offset)
        }

        controller.jumpTo(page: 1)
        // Simulate a residual offset that is inside the old 0.5pt skip window,
        // while the writer still remembers the previous exact page position.
        currentOffset = pageWidth + 0.25
        controller.startSettle(toPage: 1)

        #expect(controller.probeDisplayFrame() == true)
        #expect(controller.phase == .idle)
        #expect(currentOffset == pageWidth)
        #expect(writes.last == pageWidth)
        #expect(controller.settlingSkippedWriteCount == 0)
    }
}
