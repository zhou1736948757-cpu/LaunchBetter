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
}
