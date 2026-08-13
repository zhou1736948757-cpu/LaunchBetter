import AppKit
import LaunchCore
import LaunchUI

/// V1: `--libraryblanktrace` 空白点击逐会话 trace 探针(非交互)。
///
/// 场景全部经真实窗口事件路径(`window.sendEvent` → AppKit hitTest 路由),
/// 命中视图类名由探针直接对 `verticalScrollView.hitTest` 采样记录:
/// - bottomBlank: 文档外 clip 空白(修复前 hitTest=NSClipView 吞点击; 修复后
///   =PausableLibraryScrollView 空白会话接管)
/// - gap: 卡片间隙(文档内网格背景 → BlankClickLibraryCollectionView)
/// - title / mini / cardWhitespace: 卡片热区路由(detail, 不隐藏)
/// - detailOutsideClick: detail 根覆盖层消费, 关 detail 不隐藏
/// - dragOut: mouseDown 空白后拖出 mouseUp → 不触发
/// - unpairedMouseUp: 无配对 mouseDown 的 mouseUp → 不触发
/// - twoBlanks: 两次独立空白 → 各触发一次
/// - settingsOwnership: Settings 打开时点击 → 只关设置, 不隐藏, ownership 恢复
///
/// 输出: 视图侧 + 探针侧全部写入 `/tmp/lb-library-blank-trace.log`(时间戳交错),
/// stdout 打印每场景 chain/hide 断言与证据摘要。退出码 0/1。
@MainActor
enum LibraryBlankTraceProbe {
    private static let logPath = "/tmp/lb-library-blank-trace.log"
    private static let frameInterval = 1.0 / 120.0
    private static let settleTimeoutFrames = 300

    private struct Scenario {
        let name: String
        let run: (DependencyContainer, @escaping @MainActor (Bool) -> Void) -> Void
    }

    static func run(container: DependencyContainer) {
        // 每次运行清空 trace 日志, 保证修复前后证据可对比。
        try? FileManager.default.removeItem(atPath: logPath)
        let controller = container.windowController
        controller.show()
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.orderFrontRegardless()
        controller.window?.makeKeyAndOrderFront(nil)
        // 保证底部空白存在: 文档(几行卡)高度 < 视口。默认全屏窗口高度可能
        // 不足(真实数据 3 行卡 ≈ 1101pt vs 视口 ≈ 956pt), 先拉高窗口。
        controller.window?.setFrame(
            NSRect(x: 0, y: 0, width: 1200, height: 1600),
            display: true
        )
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.window?.displayIfNeeded()
        guard controller.libraryShotNavigateToLibrary() else {
            DiagnosticRunner.finishProbe(
                "LIBRARYBLANKTRACE", ok: false,
                detail: "library navigation unavailable (leading surface disabled)"
            )
        }
        waitSettle(controller) { settled in
            guard settled else {
                DiagnosticRunner.finishProbe("LIBRARYBLANKTRACE", ok: false, detail: "initial settle timeout")
            }
            probeTrace("probe start \(controller.libraryShotState())")
            runStep(container, steps: makeSteps(), index: 0, results: [:])
        }
    }

    // MARK: - 步骤驱动

    private static func runStep(
        _ container: DependencyContainer,
        steps: [Scenario],
        index: Int,
        results: [String: Bool]
    ) {
        guard index < steps.count else {
            let summary = results.map { "\($0.key)=\($0.value ? "OK" : "FAIL")" }.joined(separator: " ")
            let failures = results.values.filter { !$0 }.count
            print("LIBRARYBLANKTRACE results \(summary)")
            print("LIBRARYBLANKTRACE evidence:\n\(logEvidence())")
            DiagnosticRunner.finishProbe(
                "LIBRARYBLANKTRACE", ok: failures == 0,
                detail: "\(results.count) scenarios, \(failures) failed — \(summary)"
            )
        }
        let scenario = steps[index]
        scenario.run(container) { ok in
            var updated = results
            updated[scenario.name] = ok
            runStep(container, steps: steps, index: index + 1, results: updated)
        }
    }

    private static func makeSteps() -> [Scenario] {
        [
            Scenario(name: "bottomBlank", run: { container, done in
                runBlankScenario(
                    container, pointKey: "bottomBlank", expectedHit: "PausableLibraryScrollView",
                    expectedFire: 1, expectHide: true, done: done
                )
            }),
            Scenario(name: "gap", run: { container, done in
                runBlankScenario(
                    container, pointKey: "gap", expectedHit: "BlankClickLibraryCollectionView",
                    expectedFire: 1, expectHide: true, done: done
                )
            }),
            Scenario(name: "title", run: { container, done in
                runCardScenario(container, pointKey: "title", expectedHitArea: "title", done: done)
            }),
            Scenario(name: "mini", run: { container, done in
                runCardScenario(container, pointKey: "mini", expectedHitArea: "mini", done: done)
            }),
            Scenario(name: "cardWhitespace", run: { container, done in
                runCardScenario(container, pointKey: "cardWhitespace", expectedHitArea: "cardWhitespace", done: done)
            }),
            Scenario(name: "detailOutsideClick", run: { container, done in
                runDetailOutsideClick(container, done: done)
            }),
            Scenario(name: "dragOut", run: { container, done in
                runDragOut(container, done: done)
            }),
            Scenario(name: "unpairedMouseUp", run: { container, done in
                runUnpairedMouseUp(container, done: done)
            }),
            Scenario(name: "twoBlanks", run: { container, done in
                runTwoBlanks(container, done: done)
            }),
            Scenario(name: "settingsOwnership", run: { container, done in
                runSettingsOwnership(container, done: done)
            }),
        ]
    }

    // MARK: - 场景

    /// 页面空白(hide)场景: 底部 clip 空白 / 卡间隙。
    private static func runBlankScenario(
        _ container: DependencyContainer,
        pointKey: String,
        expectedHit: String,
        expectedFire: Int,
        expectHide: Bool,
        done: @escaping @MainActor (Bool) -> Void
    ) {
        let wc = container.windowController
        ensureLibrarySurface(wc) { ready in
            guard ready else { done(false); return }
            guard let library = wc.appLibraryControllerForDiag,
                  let point = library.libraryBlankTracePoints()[pointKey] else {
                print("LIBRARYBLANKTRACE \(pointKey) SKIP (no such blank in current geometry)")
                probeTrace("probe scenario=\(pointKey) SKIP no-point")
                done(true)
                return
            }
            beginMarker(pointKey)
            let hitClass = recordHitTest(library, point)
            let visibleBefore = wc.isActuallyVisible
            click(wc.window, at: point)
            later(0.25) {
                let lines = logBetween(markers: pointKey)
                let fire = count("fire=1", in: lines)
                let forwarded = count("onBlankClick layer=libraryController forwarded", in: lines)
                let hidden = wc.isActuallyVisible == false
                let surface = wc.libraryShotState()
                let chainOK = hitClass == expectedHit && fire == expectedFire && forwarded == expectedFire
                let hideOK = hidden == expectHide
                print(
                    "LIBRARYBLANKTRACE \(pointKey) hit=\(hitClass) fire=\(fire) "
                        + "forwarded=\(forwarded) visibleBefore=\(visibleBefore) "
                        + "hidden=\(hidden ? 1 : 0) expectHide=\(expectHide ? 1 : 0) "
                        + "chain=\(chainOK ? "OK" : "FAIL") hide=\(hideOK ? "OK" : "FAIL")"
                )
                probeTrace(
                    "probe scenario=\(pointKey) result chain=\(chainOK ? "OK" : "FAIL") "
                        + "hide=\(hideOK ? "OK" : "FAIL") surface=\(surface)"
                )
                endMarker(pointKey)
                done(chainOK && hideOK)
            }
        }
    }

    /// 卡片热区场景: 点击 → detail 打开(不隐藏、不空白)。
    private static func runCardScenario(
        _ container: DependencyContainer,
        pointKey: String,
        expectedHitArea: String,
        done: @escaping @MainActor (Bool) -> Void
    ) {
        let wc = container.windowController
        ensureLibrarySurface(wc) { ready in
            guard ready else { done(false); return }
            guard let library = wc.appLibraryControllerForDiag,
                  let point = library.libraryBlankTracePoints()[pointKey] else {
                done(false)
                return
            }
            beginMarker(pointKey)
            _ = recordHitTest(library, point)
            let visibleBefore = wc.isActuallyVisible
            click(wc.window, at: point)
            later(0.3) {
                let lines = logBetween(markers: pointKey)
                let hitArea = lines.compactMap { line -> String? in
                    guard let range = line.range(of: "cardHit=") else { return nil }
                    let tail = line[range.upperBound...]
                    return String(tail.prefix(while: { $0 != " " }))
                }.first ?? "none"
                let fire = count("fire=1", in: lines)
                let detailOpen = library.libraryShotCounts().contains("detail=1")
                let stillVisible = wc.isActuallyVisible
                let chainOK = hitArea == expectedHitArea && fire == 0 && detailOpen
                let hideOK = stillVisible == visibleBefore
                print(
                    "LIBRARYBLANKTRACE \(pointKey) hitArea=\(hitArea) fire=\(fire) "
                        + "detail=\(detailOpen ? 1 : 0) visible=\(stillVisible ? 1 : 0) "
                        + "chain=\(chainOK ? "OK" : "FAIL") hide=\(hideOK ? "OK" : "FAIL")"
                )
                probeTrace(
                    "probe scenario=\(pointKey) result chain=\(chainOK ? "OK" : "FAIL") "
                        + "hide=\(hideOK ? "OK" : "FAIL") surface=\(wc.libraryShotState())"
                )
                endMarker(pointKey)
                // 收尾: 关闭 detail(外点/Escape), 供下一场景使用。
                closeDetailIfOpen(library)
                later(0.2) { done(chainOK && hideOK) }
            }
        }
    }

    /// detail 打开时外点: 关 detail, 不隐藏, 无空白。
    private static func runDetailOutsideClick(
        _ container: DependencyContainer,
        done: @escaping @MainActor (Bool) -> Void
    ) {
        let wc = container.windowController
        ensureLibrarySurface(wc) { ready in
            guard ready else { done(false); return }
            guard let library = wc.appLibraryControllerForDiag,
                  let point = library.libraryBlankTracePoints()["bottomBlank"]
                      ?? library.libraryBlankTracePoints()["gap"],
                  library.openFirstCategoryDetailForDiagnostic() else {
                done(false)
                return
            }
            later(0.25) {
                beginMarker("detailOutsideClick")
                recordHitTest(library, point)
                let visibleBefore = wc.isActuallyVisible
                click(wc.window, at: point)
                later(0.3) {
                let lines = logBetween(markers: "detailOutsideClick")
                let fire = count("fire=1", in: lines)
                let detailClosed = !library.libraryShotCounts().contains("detail=1")
                let stillVisible = wc.isActuallyVisible
                let chainOK = fire == 0 && detailClosed
                let hideOK = stillVisible == visibleBefore
                print(
                    "LIBRARYBLANKTRACE detailOutsideClick fire=\(fire) "
                        + "detailClosed=\(detailClosed ? 1 : 0) visible=\(stillVisible ? 1 : 0) "
                        + "key=\(wc.window?.isKeyWindow == true ? 1 : 0) "
                        + "chain=\(chainOK ? "OK" : "FAIL") hide=\(hideOK ? "OK" : "FAIL")"
                )
                    probeTrace(
                        "probe scenario=detailOutsideClick result chain=\(chainOK ? "OK" : "FAIL") "
                            + "hide=\(hideOK ? "OK" : "FAIL") surface=\(wc.libraryShotState())"
                    )
                    endMarker("detailOutsideClick")
                    done(chainOK && hideOK)
                }
            }
        }
    }

    /// mouseDown 空白后拖出 mouseUp(>6pt): 不触发。
    private static func runDragOut(
        _ container: DependencyContainer,
        done: @escaping @MainActor (Bool) -> Void
    ) {
        let wc = container.windowController
        ensureLibrarySurface(wc) { ready in
            guard ready else { done(false); return }
            guard let library = wc.appLibraryControllerForDiag,
                  let point = library.libraryBlankTracePoints()["bottomBlank"]
                      ?? library.libraryBlankTracePoints()["gap"] else {
                done(false)
                return
            }
            beginMarker("dragOut")
            let upPoint = CGPoint(x: point.x + 100, y: point.y)
            click(wc.window, at: point, upAt: upPoint)
            later(0.25) {
                let lines = logBetween(markers: "dragOut")
                let fire = count("fire=1", in: lines)
                let forwarded = count("onBlankClick layer=libraryController forwarded", in: lines)
                let stillVisible = wc.isActuallyVisible
                let ok = fire == 0 && forwarded == 0 && stillVisible
                print(
                    "LIBRARYBLANKTRACE dragOut fire=\(fire) forwarded=\(forwarded) "
                        + "visible=\(stillVisible ? 1 : 0) result=\(ok ? "OK" : "FAIL")"
                )
                probeTrace("probe scenario=dragOut result=\(ok ? "OK" : "FAIL") surface=\(wc.libraryShotState())")
                endMarker("dragOut")
                done(ok)
            }
        }
    }

    /// 无配对 mouseDown 的 mouseUp: 不触发。
    private static func runUnpairedMouseUp(
        _ container: DependencyContainer,
        done: @escaping @MainActor (Bool) -> Void
    ) {
        let wc = container.windowController
        ensureLibrarySurface(wc) { ready in
            guard ready else { done(false); return }
            guard let library = wc.appLibraryControllerForDiag,
                  let point = library.libraryBlankTracePoints()["bottomBlank"]
                      ?? library.libraryBlankTracePoints()["gap"] else {
                done(false)
                return
            }
            beginMarker("unpairedMouseUp")
            deliverMouseUpOnly(wc.window, at: point)
            later(0.25) {
                let lines = logBetween(markers: "unpairedMouseUp")
                let fire = count("fire=1", in: lines)
                let ok = fire == 0 && wc.isActuallyVisible
                print("LIBRARYBLANKTRACE unpairedMouseUp fire=\(fire) result=\(ok ? "OK" : "FAIL")")
                probeTrace("probe scenario=unpairedMouseUp result=\(ok ? "OK" : "FAIL") surface=\(wc.libraryShotState())")
                endMarker("unpairedMouseUp")
                done(ok)
            }
        }
    }

    /// 两次独立空白点击: 各触发一次(每次会话独立)。
    private static func runTwoBlanks(
        _ container: DependencyContainer,
        done: @escaping @MainActor (Bool) -> Void
    ) {
        let wc = container.windowController
        ensureLibrarySurface(wc) { ready in
            guard ready else { done(false); return }
            guard let library = wc.appLibraryControllerForDiag,
                  let point = library.libraryBlankTracePoints()["bottomBlank"]
                      ?? library.libraryBlankTracePoints()["gap"] else {
                done(false)
                return
            }
            beginMarker("twoBlanks")
            click(wc.window, at: point)
            later(0.25) {
                let firstVisible = wc.isActuallyVisible
                // 再次显示并回到 Library, 第二次空白。
                wc.show()
                wc.window?.orderFrontRegardless()
                wc.window?.makeKeyAndOrderFront(nil)
                wc.window?.displayIfNeeded()
                wc.libraryShotNavigateToLibrary()
                waitSettle(wc) { _ in
                    guard let point2 = library.libraryBlankTracePoints()["bottomBlank"]
                        ?? library.libraryBlankTracePoints()["gap"] else {
                        endMarker("twoBlanks")
                        done(false)
                        return
                    }
                    click(wc.window, at: point2)
                    later(0.25) {
                        let lines = logBetween(markers: "twoBlanks")
                        let fire = count("fire=1", in: lines)
                        let forwarded = count("onBlankClick layer=libraryController forwarded", in: lines)
                        let hidden = wc.isActuallyVisible == false
                        let ok = fire == 2 && forwarded == 2 && hidden && !firstVisible
                        print(
                            "LIBRARYBLANKTRACE twoBlanks fire=\(fire) forwarded=\(forwarded) "
                                + "hiddenAfterSecond=\(hidden ? 1 : 0) result=\(ok ? "OK" : "FAIL")"
                        )
                        probeTrace("probe scenario=twoBlanks result=\(ok ? "OK" : "FAIL") surface=\(wc.libraryShotState())")
                        endMarker("twoBlanks")
                        done(ok)
                    }
                }
            }
        }
    }

    /// Settings 覆盖: 点击只关设置, 不隐藏; ownership 恢复。
    private static func runSettingsOwnership(
        _ container: DependencyContainer,
        done: @escaping @MainActor (Bool) -> Void
    ) {
        let wc = container.windowController
        ensureLibrarySurface(wc) { ready in
            guard ready else { done(false); return }
            guard let library = wc.appLibraryControllerForDiag,
                  let point = library.libraryBlankTracePoints()["bottomBlank"]
                      ?? library.libraryBlankTracePoints()["gap"] else {
                done(false)
                return
            }
            wc.openSettingsFromMenu()
            later(0.6) {
                beginMarker("settingsOwnership")
                let settingsVisible = container.settingsController.window?.isVisible == true
                recordHitTest(library, point)
                let visibleBefore = wc.isActuallyVisible
                click(wc.window, at: point)
                later(0.6) {
                    let lines = logBetween(markers: "settingsOwnership")
                    let fire = count("fire=1", in: lines)
                    let settingsClosed = container.settingsController.window?.isVisible == false
                    let launcherVisible = wc.isActuallyVisible == visibleBefore
                    let surfaceRestored = wc.libraryShotState().hasPrefix("interaction=appLibrary")
                    let ok = settingsVisible && settingsClosed && launcherVisible && fire == 0 && surfaceRestored
                    print(
                        "LIBRARYBLANKTRACE settingsOwnership settingsWasOpen=\(settingsVisible ? 1 : 0) "
                            + "settingsClosed=\(settingsClosed ? 1 : 0) fire=\(fire) "
                            + "launcherStayed=\(launcherVisible ? 1 : 0) "
                            + "key=\(wc.window?.isKeyWindow == true ? 1 : 0) "
                            + "surface=\(wc.libraryShotState()) result=\(ok ? "OK" : "FAIL")"
                    )
                    probeTrace("probe scenario=settingsOwnership result=\(ok ? "OK" : "FAIL") surface=\(wc.libraryShotState())")
                    endMarker("settingsOwnership")
                    done(ok)
                }
            }
        }
    }

    // MARK: - 辅助

    /// 确保窗口可见 + 位于 Library surface + settle 完成。
    private static func ensureLibrarySurface(
        _ wc: LauncherWindowController,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        if !wc.isActuallyVisible {
            wc.show()
            wc.window?.orderFrontRegardless()
            wc.window?.makeKeyAndOrderFront(nil)
            wc.window?.displayIfNeeded()
        }
        wc.libraryShotNavigateToLibrary()
        waitSettle(wc) { settled in
            completion(settled)
        }
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

    /// 探针侧 trace 行(追加到同一日志; 含 surface 快照)。
    private static func probeTrace(_ line: String) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        let formatted = String(format: "[%10.4f]", timestamp)
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: logPath) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((formatted + " " + line + "\n").utf8))
    }

    private static func beginMarker(_ name: String) {
        probeTrace("probe begin \(name)")
    }

    private static func endMarker(_ name: String) {
        probeTrace("probe end \(name)")
    }

    /// 记录真实 hitTest 命中类(探针侧采样)。
    ///
    /// 坐标规则(V1 实证): AppKit 派发把事件点按窗口基坐标传给滚动视图的
    /// hitTest 覆盖(不先做 convert 翻转), 因此直接用事件窗口点调用
    /// `scroll.hitTest(W)` 与派发一致; 先 `convert(from: nil)` 会翻转 y 导致
    /// 采样命中错误区域(修复前底部空白被采样成卡片, 实证)。
    private static func recordHitTest(_ library: AppLibraryViewController, _ windowPoint: NSPoint) -> String {
        let scroll = library.verticalScrollView
        let hit = scroll.hitTest(windowPoint)
        let className = hit.map { String(describing: type(of: $0)) } ?? "nil"
        probeTrace(
            "probe hitTest win=\(fmt(windowPoint)) hit=\(className)"
        )
        return className
    }

    /// 真实 AppKit 事件路径。
    ///
    /// 命中视图经 `contentView.hitTest(事件窗口点)` 定位 —— 与 AppKit 派发链
    /// 一致(窗口基坐标直通各层 hitTest, 与探针实测的 `scroll.hitTest(W)`
    /// 派发行为一致; 屏蔽层/Settings 等滚动子树外视图也能命中)。
    ///
    /// 投递方式: 直接向命中视图发 mouseDown/mouseUp。无头环境窗口无法成为
    /// key(实测 key=0), `window.sendEvent` 会把"激活点击"吞掉(只有
    /// acceptsFirstMouse 的控件才收到事件); 直接投递与单元测试同构, 跳过
    /// 激活逻辑, 保留真实 hitTest 链证据(视图侧 trace 记录会话与各层调用)。
    private static func click(_ window: NSWindow?, at point: NSPoint, upAt: NSPoint? = nil) {
        guard let window, let contentView = window.contentView else { return }
        let up = upAt ?? point
        window.makeKeyAndOrderFront(nil)
        guard let hit = contentView.hitTest(point) else {
            probeTrace("probe deliver mouseDown win=\(fmt(point)) hit=nil")
            return
        }
        let hitClass = String(describing: type(of: hit))
        probeTrace("probe deliver mouseDown win=\(fmt(point)) to=\(hitClass)")
        mouseEvent(.leftMouseDown, at: point, window: window).map { hit.mouseDown(with: $0) }
        probeTrace("probe deliver mouseUp win=\(fmt(up)) to=\(hitClass)")
        mouseEvent(.leftMouseUp, at: up, window: window).map { hit.mouseUp(with: $0) }
    }

    /// 无配对 mouseDown 的 mouseUp: 投递到命中视图(与 click 同一命中链)。
    private static func deliverMouseUpOnly(_ window: NSWindow?, at point: NSPoint) {
        guard let window, let contentView = window.contentView else { return }
        guard let hit = contentView.hitTest(point) else {
            probeTrace("probe deliver mouseUp-only win=\(fmt(point)) hit=nil")
            return
        }
        let hitClass = String(describing: type(of: hit))
        probeTrace("probe deliver mouseUp-only win=\(fmt(point)) to=\(hitClass)")
        mouseEvent(.leftMouseUp, at: point, window: window).map { hit.mouseUp(with: $0) }
    }

    private static func mouseEvent(
        _ type: NSEvent.EventType,
        at point: NSPoint,
        window: NSWindow?
    ) -> NSEvent? {
        guard let window else { return nil }
        return NSEvent.mouseEvent(
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

    private static func closeDetailIfOpen(_ library: AppLibraryViewController) {
        if library.libraryShotCounts().contains("detail=1") {
            library.dismissDetailIfPresent()
        }
    }

    private static func later(_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                body()
            }
        }
    }

    private static func fmt(_ point: NSPoint) -> String {
        String(format: "%.1f,%.1f", point.x, point.y)
    }

    // MARK: - 日志解析

    private static func logBetween(markers name: String) -> [String] {
        guard let content = try? String(contentsOfFile: logPath, encoding: .utf8) else {
            return []
        }
        let lines = content.split(separator: "\n").map(String.init)
        var collecting = false
        var collected: [String] = []
        for line in lines {
            if line.contains("probe begin \(name)") {
                collecting = true
                continue
            }
            if line.contains("probe end \(name)") {
                break
            }
            if collecting {
                collected.append(line)
            }
        }
        return collected
    }

    private static func count(_ needle: String, in lines: [String]) -> Int {
        lines.filter { $0.contains(needle) }.count
    }

    private static func logEvidence() -> String {
        guard let content = try? String(contentsOfFile: logPath, encoding: .utf8) else {
            return "trace log missing: \(logPath)"
        }
        let lines = content.split(separator: "\n").map(String.init)
        func count(_ needle: String) -> Int {
            lines.filter { $0.contains(needle) }.count
        }
        var summary = "traceLog lines=\(lines.count) "
            + "intercept=\(count("intercept=self")) "
            + "scrollArm=\(count("scroll mouseDown")) gridArm=\(count("grid mouseDown")) "
            + "fire=\(count("fire=1")) forwarded=\(count("onBlankClick layer=libraryController forwarded"))\n"
        for line in lines.suffix(60) {
            summary += "  \(line)\n"
        }
        return summary
    }
}
