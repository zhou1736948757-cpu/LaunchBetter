import AppKit
import Foundation
import Testing
@testable import LaunchUI

/// T-001: 方向感知两页合成 — PagingInteractionController 的方向回调。
///
/// `onWillStartHorizontalTracking` 契约:
/// - 每次手势至多一次, 在水平轴锁定后、首个非零水平位移时触发。
/// - deltaX < 0 → `.next`, deltaX > 0 → `.previous`。
/// - 垂直 / 未定轴 / 零位移手势不触发。
/// - 不写 offset(回调只允许 Grid 切换 presentation surface)。
@Suite("Paging direction callback (T-001)", .serialized)
@MainActor
struct PagingDirectionCallbackTests {
    private static let pageWidth: CGFloat = 800

    private func makeController(
        pageCount: Int = 3
    ) -> (PagingInteractionController, NSView) {
        let controller = PagingInteractionController()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        controller.linkView = view
        controller.onReadPageWidth = { Self.pageWidth }
        controller.onReadPageCount = { pageCount }
        return (controller, view)
    }

    @Test("方向回调: 每次手势至多一次, 轴锁定后首个非零水平位移触发")
    func calledOncePerGesture() {
        let (controller, view) = makeController()
        var directions: [PagingDirection] = []
        controller.onWillStartHorizontalTracking = { directions.append($0) }
        withExtendedLifetime(view) {
            // 一次手势多个水平位移 → 只回调一次。
            controller.probeGesture(deltaXs: [-60, -80, -80])
            #expect(directions == [.next], "一次手势只回调一次")

            // 第二次手势重新计数。
            controller.probeGesture(deltaXs: [60, 80])
            #expect(directions == [.next, .previous], "每次手势独立回调一次")
        }
    }

    @Test("方向回调: deltaX < 0 → next")
    func negativeDeltaIsNext() {
        let (controller, view) = makeController()
        var directions: [PagingDirection] = []
        controller.onWillStartHorizontalTracking = { directions.append($0) }
        withExtendedLifetime(view) {
            controller.probeGesture(deltaXs: [-60])
            #expect(directions == [.next])
        }
    }

    @Test("方向回调: deltaX > 0 → previous")
    func positiveDeltaIsPrevious() {
        let (controller, view) = makeController()
        var directions: [PagingDirection] = []
        controller.onWillStartHorizontalTracking = { directions.append($0) }
        withExtendedLifetime(view) {
            controller.probeGesture(deltaXs: [60])
            #expect(directions == [.previous])
        }
    }

    @Test("方向回调: 垂直 / 未定轴 / 零位移不触发")
    func nonHorizontalGesturesDoNotCall() {
        let (controller, view) = makeController()
        var directions: [PagingDirection] = []
        controller.onWillStartHorizontalTracking = { directions.append($0) }
        withExtendedLifetime(view) {
            // 纯垂直: 从不锁定水平。
            controller.probeGesture(deltaXs: [3, 2], deltaYs: [20, 30])
            #expect(directions.isEmpty, "垂直手势不触发")

            // 零位移水平: deltaX 全 0, 轴不锁定。
            controller.probeGesture(deltaXs: [0, 0])
            #expect(directions.isEmpty, "零位移不触发")

            // 未定轴: 累计 X 未达阈值 / 未达水平主导。
            controller.probeGesture(deltaXs: [4, 4], deltaYs: [20, 30])
            #expect(directions.isEmpty, "未定轴不触发")
        }
    }

    @Test("方向回调: 轴在零位移帧锁定后, 首个非零位移帧才触发")
    func locksOnZeroFrameThenEmitsOnNextNonZero() {
        let (controller, view) = makeController()
        var directions: [PagingDirection] = []
        controller.onWillStartHorizontalTracking = { directions.append($0) }
        withExtendedLifetime(view) {
            // 帧 1: 累计 X=10, 但 Y 主导(20*1.2=24 > 10)→ 未锁定。
            // 帧 2: deltaX=0, deltaY=-20 → 累计 Y=0, X=10 > 0*1.2 → 锁定, 但 deltaX==0 → 不触发。
            // 帧 3: deltaX=-6 → 首个非零水平位移 → 触发 .next。
            controller.probeGesture(deltaXs: [-10, 0, -6], deltaYs: [20, -20, 0])
            #expect(directions == [.next], "锁定帧 deltaX==0 不触发, 下一非零帧触发")
        }
    }

}
