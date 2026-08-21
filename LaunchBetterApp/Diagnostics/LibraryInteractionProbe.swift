import AppKit
import LaunchCore
import LaunchUI

/// X2: `--libraryinteracttrace` 首次交互探针(非交互)。
///
/// 目标: 取证/验证"进入 App Library 后首个事件不被激活消耗"。
/// - 环境可置 key(真实桌面): show() 后窗口应为 key;首个 mouseDown 经
///   `window.sendEvent`(真实 AppKit 路径, 含激活逻辑)必须立即打开 detail/
///   命中卡片 —— 修复前首击被窗口激活吞掉(detail=0), 修复后立即生效。
/// - 环境不可置 key(无头 CI): 窗口永远非 key(已有环境限制, 同"无头 alpha 卡 0"),
///   首击必然被吞; 探针只报告诊断, 不硬失败。
/// 两种环境都打印: surface/卡片命中链/卡片热区 frame 数/窗口 key 态。
///
/// 退出: `--libraryinteracttrace`; 退出码 0/1。
@MainActor
enum LibraryInteractionProbe {
    private static let frameInterval = 1.0 / 120.0
    private static let settleTimeoutFrames = 300

    static func run(container: DependencyContainer) {
        let controller = container.windowController
        controller.show()
        print(
            "X2TRACE show key=\(controller.window?.isKeyWindow == true ? 1 : 0) "
                + "active=\(NSApp.isActive ? 1 : 0) visible=\(controller.isActuallyVisible ? 1 : 0)"
        )
        guard controller.libraryShotNavigateToLibrary() else {
            DiagnosticRunner.finishProbe(
                "LIBRARYINTERACTTRACE", ok: false,
                detail: "library navigation unavailable (leading surface disabled)"
            )
        }
        waitSettle(controller) { settled in
            guard settled else {
                DiagnosticRunner.finishProbe("LIBRARYINTERACTTRACE", ok: false, detail: "initial settle timeout")
            }
            controller.window?.displayIfNeeded()
            print(
                "X2TRACE settled surface=\(controller.libraryShotState()) "
                    + "key=\(controller.window?.isKeyWindow == true ? 1 : 0) "
                    + "firstResponder=\(String(describing: controller.window?.firstResponder))"
            )
            runSequence(container: container)
        }
    }

    /// 首击对比 + 首滚诊断; 环境 key 能力决定断言强度。
    private static func runSequence(container: DependencyContainer) {
        let controller = container.windowController
        guard let library = controller.appLibraryControllerForDiag else {
            DiagnosticRunner.finishProbe("LIBRARYINTERACTTRACE", ok: false, detail: "library not mounted")
        }
        guard let point = library.libraryBlankTracePoints()["cardWhitespace"],
              let window = controller.window else {
            DiagnosticRunner.finishProbe("LIBRARYINTERACTTRACE", ok: false, detail: "no cardWhitespace point")
        }
        print("X2TRACE target point=\(fmt(point)) detailBefore=\(library.libraryShotCounts().contains("detail=1") ? 1 : 0)")

        // 第一次点击(零前置输入): 真实 sendEvent 路径。
        clickViaSendEvent(window, at: point, name: "first", library: library)
        later(0.4) {
            let firstOpened = library.libraryShotCounts().contains("detail=1")
            print(
                "X2TRACE first detailOpened=\(firstOpened ? 1 : 0) "
                    + "key=\(window.isKeyWindow == true ? 1 : 0) surface=\(controller.libraryShotState())"
            )
            // 第二次点击(即使首击只是激活, 窗口应已 key)。
            closeDetailIfOpen(library)
            clickViaSendEvent(window, at: point, name: "second", library: library)
            later(0.4) {
                let secondOpened = library.libraryShotCounts().contains("detail=1")
                print(
                    "X2TRACE second detailOpened=\(secondOpened ? 1 : 0) "
                        + "key=\(window.isKeyWindow == true ? 1 : 0) surface=\(controller.libraryShotState())"
                )
                runScrollScenario(container: container, library: library) { scrollResult in
                    let keyable = window.isKeyWindow == true
                    // 可置 key 环境: 首击必须立即生效(根因断言)。
                    // 无头(不可置 key): 已知环境限制, 首击必然被激活逻辑吞掉,
                    // 只验证 Library 链路就绪(卡片可见/热区已布局)。
                    let chainReady = library.libraryShotCounts().contains("cards=")
                        && !library.libraryBlankTracePoints().isEmpty
                    let ok: Bool
                    let note: String
                    if keyable {
                        // scroll 仅在内容溢出时可断言; 内容不足一屏 → N/A(无位移是正确 no-op)。
                        let scrollOK = scrollResult == .moved || scrollResult == .noOverflow
                        ok = firstOpened && secondOpened && scrollOK
                        note = "key-capable first=\(firstOpened ? "OK" : "SWALLOWED") second=\(secondOpened ? "OK" : "SWALLOWED") scroll=\(scrollResult.rawValue)"
                    } else {
                        ok = chainReady
                        note = "headless key-unavailable (known env limit) chainReady=\(chainReady ? 1 : 0) first/second diagnostics only"
                    }
                    print("X2TRACE result \(note) key=\(window.isKeyWindow == true ? 1 : 0)")
                    DiagnosticRunner.finishProbe(
                        "LIBRARYINTERACTTRACE", ok: ok,
                        detail: note
                    )
                }
            }
        }
    }

    /// 首个垂直 precise 滚动(真实 Library 轴仲裁链路, `libraryProbeFeed` seam;
    /// 合成消息 phase 不可靠往返, 显式传 phase)。配合 `displayIfNeeded` 观察内部
    /// NSScrollView clip 是否在首个手势即滚动 —— 无前置输入时直接驱动。
    private enum ScrollResult: String {
        case moved = "MOVED"
        case noOverflow = "NOOVERFLOW"
        case nothing = "NOTHING"
    }

    private static func runScrollScenario(
        container: DependencyContainer,
        library: AppLibraryViewController,
        completion: @escaping @MainActor (ScrollResult) -> Void
    ) {
        let controller = container.windowController
        let clip = library.verticalScrollView.contentView
        let before = clip.bounds.origin.y
        let contentH = clip.documentView?.frame.height ?? 0
        let clipH = clip.bounds.height
        guard let began = makeScroll(dx: 0, dy: 4, phase: 1),
              let changed = makeScroll(dx: 0, dy: 24, phase: 2),
              let changed2 = makeScroll(dx: 0, dy: 24, phase: 2),
              let ended = makeScroll(dx: 0, dy: 0, phase: 4) else {
            print("X2TRACE scroll no-event")
            completion(.nothing)
            return
        }
        print(
            "X2TRACE scroll feed beforeY=\(String(format: "%.2f", before)) "
                + "contentH=\(String(format: "%.1f", contentH)) "
                + "clipH=\(String(format: "%.1f", clipH))"
        )
        if contentH <= clipH + 0.5 {
            // 内容不足一屏: 无溢出即无垂直位移; 正确 no-op, 不断言滚动。
            completion(.noOverflow)
            return
        }
        // 首个手势: began → changed → changed → ended, 零前置输入。
        _ = controller.libraryProbeFeed(phase: .began, event: began)
        _ = controller.libraryProbeFeed(phase: .changed, event: changed)
        _ = controller.libraryProbeFeed(phase: .changed, event: changed2)
        _ = controller.libraryProbeFeed(phase: .ended, event: ended)
        controller.window?.displayIfNeeded()
        later(0.2) {
            let after = library.verticalScrollView.contentView.bounds.origin.y
            let moved = abs(after - before) > 0.1
            print(
                "X2TRACE scroll afterY=\(String(format: "%.2f", after)) "
                    + "moved=\(moved ? "OK" : "NO")"
            )
            completion(moved ? .moved : .nothing)
        }
    }

    /// 合成 precise 滚动事件(与 PagingScrollProbe/PagingProbe 同一构造;
    /// phase 经 CGEventField 99, momentum 经 123)。
    private static func makeScroll(dx: CGFloat, dy: CGFloat, phase: Int) -> NSEvent? {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let cg = CGEvent(
                scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2,
                wheel1: 0, wheel2: Int32(dy), wheel3: 0
              ) else { return nil }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dx))
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dy))
        cg.setIntegerValueField(CGEventField(rawValue: 99)!, value: Int64(phase))
        cg.setIntegerValueField(CGEventField(rawValue: 123)!, value: 0)
        return NSEvent(cgEvent: cg)
    }

    private static func clickViaSendEvent(
        _ window: NSWindow,
        at point: NSPoint,
        name: String,
        library: AppLibraryViewController
    ) {
        guard let down = mouseEvent(.leftMouseDown, at: point, window: window),
              let up = mouseEvent(.leftMouseUp, at: point, window: window) else {
            print("X2TRACE \(name) no-event")
            return
        }
        let hit = window.contentView?.hitTest(point)
        print("X2TRACE \(name) hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil") key=\(window.isKeyWindow == true ? 1 : 0)")
        window.sendEvent(down)
        window.sendEvent(up)
    }

    private static func waitSettle(
        _ wc: LauncherWindowController,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        var remaining = settleTimeoutFrames
        @MainActor func poll() {
            remaining -= 1
            let settled = wc.libraryShotWaitSettled()
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

    private static func closeDetailIfOpen(_ library: AppLibraryViewController) {
        if library.libraryShotCounts().contains("detail=1") {
            library.dismissDetailIfPresent()
        }
    }

    private static func later(_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { body() }
        }
    }

    private static func mouseEvent(
        _ type: NSEvent.EventType,
        at point: NSPoint,
        window: NSWindow
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    }

    private static func fmt(_ point: NSPoint) -> String {
        String(format: "%.1f,%.1f", point.x, point.y)
    }
}