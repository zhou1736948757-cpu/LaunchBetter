import AppKit
import Darwin
import LaunchCore
import LaunchUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var container: DependencyContainer!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        container = DependencyContainer()
        // Phase 3 激活方式: 启动即显示 + Dock 图标点击重开(toggle)。
        // 全局热键/手势/热角属 Phase 8。
        container.windowController.show()

        if let setLang = CommandLine.arguments.firstIndex(of: "--setlang") {
            // 测试辅助: 用应用自身编码路径保存配置(验证真实持久化往返)
            let value = CommandLine.arguments[setLang + 1]
            var config = container?.store.config ?? AppConfiguration()
            switch value {
            case "english": config.language = .english
            case "hans": config.language = .simplifiedChinese
            case "hant": config.language = .traditionalChinese
            default: config.language = .system
            }
            container?.store.save(config)
            print("CONFIG saved lang=\(value)")
        }
        if let screenshotPath = screenshotArgument() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.captureScreenshot(to: screenshotPath)
            }
        } else if CommandLine.arguments.contains("--touchdebug") {
            // 触点调试: 打印引擎状态 + 原始触点帧(GESTURE_DEBUG env), 15s 后退出
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self else { return }
                print("TOUCHDEBUG status=\(self.container?.activationCoordinator.diagnostics() ?? "?")")
                print("TOUCHDEBUG 请在触控板上做四指捏合, 观察 GESTURE_DEBUG 输出")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) {
                print("TOUCHDEBUG done")
                NSApp.terminate(nil)
            }
        } else if CommandLine.arguments.contains("--touchwatch") {
            // 持续触点监听(配合 GESTURE_DEBUG 日志), 手动终止
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self else { return }
                print("TOUCHWATCH status=\(self.container?.activationCoordinator.diagnostics() ?? "?")")
                print("TOUCHWATCH 持续监听中, 请做四指捏合; Ctrl+C 或 kill 结束")
                fflush(stdout)
            }
        } else if CommandLine.arguments.contains("--perf") {
            // 性能基线: 10 次 show/hide 循环(真实事件循环时序)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self, let controller = self.container?.windowController else {
                    print("PERF FAIL")
                    NSApp.terminate(nil)
                    return
                }
                var cycle = 0
                @MainActor func next() {
                    guard cycle < 10 else {
                        print("PERF done")
                        NSApp.terminate(nil)
                        return
                    }
                    cycle += 1
                    controller.show()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak controller] in
                        MainActor.assumeIsolated {
                            controller?.hide()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            MainActor.assumeIsolated {
                                next()
                            }
                        }
                    }
                }
                MainActor.assumeIsolated {
                    next()
                }
            }
        } else if CommandLine.arguments.contains("--pagetest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.runPageTest()
            }
        } else if CommandLine.arguments.contains("--smoke") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.runSmokeDiagnostics()
            }
        } else if CommandLine.arguments.contains("--iconbench") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.runIconBenchmark()
            }
        } else if CommandLine.arguments.contains("--searchprobe") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.runSearchProbe()
            }
        } else if CommandLine.arguments.contains("--threefingerdiag") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let container = self?.container else {
                    print("3FDIAG FAIL")
                    NSApp.terminate(nil)
                    return
                }
                print("3FDIAG engine=\(container.activationCoordinator.diagnostics())")
                print("3FDIAG coordinator=\(container.threeFingerCoordinator.diagnostics())")
                print("3FDIAG windowVisible=\(container.windowController.isVisible)")
                print("3FDIAG OK")
                NSApp.terminate(nil)
            }
        } else if CommandLine.arguments.contains("--dragcacheprobe") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.runDragCacheProbe()
            }
        } else if CommandLine.arguments.contains("--pagingprobe") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.runPagingProbe()
            }
        } else if CommandLine.arguments.contains("--gridtest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.runGridSettingsTest()
            }
        }
    }

    /// 搜索溢出运行时验证: 宽查询(> pageCapacity 结果) → 全部结果可滚动访问。
    private func runSearchProbe() {
        guard let store = container?.store, let windowController = container?.windowController else {
            print("SEARCHPROBE FAIL")
            NSApp.terminate(nil)
            return
        }
        let capacity = store.displayModel().pageCapacity
        let query = "com"
        // 搜索前截图(同壁纸基线)
        windowController.captureContentScreenshot(to: "/tmp/lb-search-before.png")
        store.searchQuery = query
        // 等搜索布局 + 图标异步加载完成后再测量/截图
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            MainActor.assumeIsolated {
                guard let store = self?.container?.store, let windowController = self?.container?.windowController else {
                    NSApp.terminate(nil)
                    return
                }
                let results = store.searchResults() ?? []
                let diag = windowController.pageTestScrollDiagnostics()
                print("SEARCHPROBE query=\(query) results=\(results.count) capacity=\(capacity) overflow=\(results.count > capacity)")
                print("SEARCHPROBE \(diag)")
                print("SEARCHPROBE realIcons=\(windowController.realIconCount())/\(windowController.visibleItemCountForDiag())")
                if let screenshotPath = CommandLine.arguments.last, !screenshotPath.hasPrefix("--") {
                    windowController.captureContentScreenshot(to: screenshotPath)
                }
                // §71: customDisplayName 变化应触发搜索索引重建
                let rb0 = store.searchIndexRebuildCount
                let target = store.displayModel().visibleAppIDs.first
                if let target {
                    store.setCustomName(target, name: "SearchInvProbeName")
                    let rb1 = store.searchIndexRebuildCount
                    store.setCustomName(target, name: nil)
                    let delta = rb1 - rb0
                    print("SEARCHPROBE searchRebuildOnCustomName=\(delta > 0 ? "OK (+\(delta))" : "FAIL (0)")")
                }
                store.searchQuery = ""
                windowController.refreshGrid()
                print("SEARCHPROBE restored search=\(store.searchResults() == nil)")
                print("SEARCHPROBE OK")
                NSApp.terminate(nil)
            }
        }
    }

    /// 拖拽缓存探针(v0.1.6 §69): 同 destination 停留 20 帧, preview/transform 写应≈1。
    private func runDragCacheProbe() {
        guard let controller = container?.windowController else {
            finishProbe("DRAGCACHE", ok: false, detail: "container not ready")
        }
        guard let first = controller.dragTestItems().first else {
            finishProbe("DRAGCACHE", ok: false, detail: "empty drag-test items")
        }
        let p = NSPoint(x: 900, y: 400)
        controller.dragTestBegin(item: first, at: p)
        guard controller.hasActiveDrag() else {
            finishProbe("DRAGCACHE", ok: false, detail: "drag begin rejected")
        }
        // 停留同一位置 20 帧(手动驱动, 无 display link 环境)
        for _ in 0..<20 {
            controller.dragProbeTick(p)
        }
        let c1 = controller.dragCacheDiagnostics()
        // 再停留 30 帧
        for _ in 0..<30 {
            controller.dragProbeTick(p)
        }
        let c2 = controller.dragCacheDiagnostics()
        print("DRAGCACHE after20: \(c1)")
        print("DRAGCACHE after50: \(c2)")
        let exercised = ["previews", "transformWrites"].allSatisfy { key in
            (diagnosticCounter(key, in: c1) ?? 0) > 0
        }
        let stable = ["previews", "transformWrites"].allSatisfy { key in
            guard let before = diagnosticCounter(key, in: c1),
                  let after = diagnosticCounter(key, in: c2) else {
                return false
            }
            return before == after
        }
        controller.dragTestEnd(at: p)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let ok = exercised && stable && !controller.hasActiveDrag()
                self.finishProbe("DRAGCACHE", ok: ok, detail: "exercised=\(exercised) stableCounters=\(stable) activeDrag=\(controller.hasActiveDrag())")
            }
        }
    }

    private func diagnosticCounter(_ key: String, in diagnostics: String) -> Int? {
        for token in diagnostics.split(separator: " ") {
            let parts = token.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, String(parts[0]) == key else { continue }
            return Int(parts[1])
        }
        return nil
    }

    private func finishProbe(_ name: String, ok: Bool, detail: String? = nil) -> Never {
        if let detail {
            print("\(name) \(ok ? "OK" : "FAIL") \(detail)")
        } else {
            print("\(name) \(ok ? "OK" : "FAIL")")
        }
        terminateDiagnostic(success: ok)
    }

    private func terminateDiagnostic(success: Bool) -> Never {
        fflush(stdout)
        fflush(stderr)
        exit(success ? 0 : 1)
    }

    /// 分页性能探针(v0.1.6 §63/§82): 合成触控板 swipe + momentum, 测量计数器。
    private func runPagingProbe() {
        guard let controller = container?.windowController else {
            print("PAGINGPROBE FAIL")
            NSApp.terminate(nil)
            return
        }
        func makeScroll(dx: CGFloat, phase: Int, momentum: Int) -> NSEvent? {
            guard let src = CGEventSource(stateID: .hidSystemState),
                  let cg = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: Int32(dx), wheel3: 0) else { return nil }
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
            cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
            // 相位经 rawValue 设置(kCGScrollWheelEventPhase=99 / MomentumPhase=123)
            cg.setIntegerValueField(CGEventField(rawValue: 99)!, value: Int64(phase))
            cg.setIntegerValueField(CGEventField(rawValue: 123)!, value: Int64(momentum))
            return NSEvent(cgEvent: cg)
        }
        print("PAGINGPROBE before: \(controller.pagingProbeDiagnostics())")
        // 1. 手势: began + changed×8(累计 -460pt > 30%×1470=441 → 下一页)
        controller.pagingProbeFeed(makeScroll(dx: 0, phase: 1, momentum: 0)!)
        for _ in 0..<4 { controller.pagingProbeFeed(makeScroll(dx: -60, phase: 2, momentum: 0)!) }
        for _ in 0..<4 { controller.pagingProbeFeed(makeScroll(dx: -55, phase: 2, momentum: 0)!) }
        controller.pagingProbeFeed(makeScroll(dx: 0, phase: 4, momentum: 0)!)
        // 2. momentum 序列(应 0 位移 0 snap)
        controller.pagingProbeFeed(makeScroll(dx: -80, phase: 0, momentum: 1)!)
        controller.pagingProbeFeed(makeScroll(dx: -80, phase: 0, momentum: 2)!)
        controller.pagingProbeFeed(makeScroll(dx: 0, phase: 0, momentum: 4)!)
        // 等 settle 完成
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                let page = controller.pageTestCurrentPage()
                print("PAGINGPROBE after: \(controller.pagingProbeDiagnostics()) page=\(page) scrollX=\(Int(controller.pageTestScrollX()))")
                let ok = page == 1 && controller.pageTestScrollX() > 1400
                print("PAGINGPROBE \(ok ? "OK" : "FAIL")")
                NSApp.terminate(nil)
            }
        }
    }

    /// Settings 几何生效验证: 改 columns/rows/iconSize → 布局/容量/图标请求尺寸跟随; 完成后恢复。
    private func runGridSettingsTest() {
        guard let store = container?.store, let windowController = container?.windowController else {
            print("GRIDTEST FAIL")
            NSApp.terminate(nil)
            return
        }
        let rebuildBefore = store.searchIndexRebuildCount
        let original = store.config
        var test = original
        // 可选参数: --gridtest [columns] [rows] [iconSize] [截图路径]
        let args = CommandLine.arguments
        let base = args.firstIndex(of: "--gridtest") ?? args.endIndex
        func intArg(_ offset: Int, default d: Int) -> Int {
            let idx = args.index(base, offsetBy: offset)
            return (args.indices.contains(idx) ? Int(args[idx]) : nil) ?? d
        }
        let gColumns = intArg(1, default: 8)
        let gRows = intArg(2, default: 5)
        let gIconSize = intArg(3, default: 48)
        test.gridColumns = gColumns
        test.gridRows = gRows
        test.iconSize = gIconSize
        store.save(test)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            MainActor.assumeIsolated {
                windowController.refreshGrid()
                let display = store.displayModel()
                let diag = windowController.pageTestScrollDiagnostics()
                print("GRIDTEST columns=\(gColumns) rows=\(gRows) iconSize=\(gIconSize) pages=\(display.pages.count) capacity=\(display.pageCapacity) iconSize=\(store.iconSize)")
                print("GRIDTEST \(diag)")
                if let screenshotPath = CommandLine.arguments.last, !screenshotPath.hasPrefix("--") {
                    windowController.captureContentScreenshot(to: screenshotPath)
                }
                store.save(original)
                windowController.refreshGrid()
                print("GRIDTEST restored columns=\(store.config.gridColumns) rows=\(store.config.gridRows) iconSize=\(store.config.iconSize)")
                print("GRIDTEST searchRebuildDelta=\(store.searchIndexRebuildCount - rebuildBefore) (期望 0: UI-only config 不重建搜索索引, §71)")
                print("GRIDTEST OK")
                NSApp.terminate(nil)
            }
        }
    }

    private func runIconBenchmark() {
        guard let store = container?.store, let iconAdapter = container?.iconAdapter else {
            print("ICONBENCH FAIL container not ready")
            NSApp.terminate(nil)
            return
        }
        Task { @MainActor in
            // 冷路径: 磁盘 + 实时提取
            let cold = await iconAdapter.benchmarkVisibleIcons(scale: 2)
            print("ICONBENCH cold resolved=\(cold.resolved) totalMs=\(String(format: "%.1f", cold.milliseconds)) perIconMs=\(String(format: "%.2f", cold.milliseconds / Double(max(1, cold.resolved)))) live=\(cold.live) disk=\(cold.disk) mem=\(cold.memoryHits) catalog=\(store.diagnosticCatalogAppCount())")
            // 热路径: 内存命中
            let warm = await iconAdapter.benchmarkVisibleIcons(scale: 2)
            print("ICONBENCH warm resolved=\(warm.resolved) totalMs=\(String(format: "%.1f", warm.milliseconds)) perIconMs=\(String(format: "%.2f", warm.milliseconds / Double(max(1, warm.resolved)))) live=\(warm.live) disk=\(warm.disk) mem=\(warm.memoryHits)")
            print("ICONBENCH OK")
            NSApp.terminate(nil)
        }
    }

    private func runSmokeDiagnostics() {
        guard let store = container?.store, let windowController = container?.windowController else {
            print("SMOKE FAIL container not ready")
            terminateDiagnostic(success: false)
        }
        let display = store.displayModel()
        print("SMOKE catalogApps=\(store.diagnosticCatalogAppCount())")
        print("SMOKE layoutPages=\(display.pages.count) flatSlots=\(display.flatSlots.count) capacity=\(display.pageCapacity)")

        store.searchQuery = "chrome"
        let results = store.searchResults() ?? []
        print("SMOKE searchQuery=chrome results=\(results.count)")
        store.searchQuery = ""

        print("SMOKE window [\(windowController.diagnostics())]")

        // 拖拽引擎: 程序化驱动 beginDrag → updateDrag ×N → endDrag(真实代码路径)
        if CommandLine.arguments.contains("--dragtest") {
            let items = windowController.dragTestItems()
            guard let first = items.first else {
                finishSmoke(store: store, ok: false, detail: "dragtest has no visible items")
            }
            let orderBefore = store.displayModel().flatSlots
            guard Set(orderBefore).count == orderBefore.count else {
                finishSmoke(store: store, ok: false, detail: "dragtest baseline contains duplicate display items")
            }
            let previousOnDataChange = store.onDataChange
            var completed = false
            func finishDrag(_ ok: Bool, detail: String) {
                guard !completed else { return }
                completed = true
                store.onDataChange = previousOnDataChange
                print("SMOKE dragtest \(ok ? "OK" : "FAIL") \(detail)")
                finishSmoke(store: store, ok: ok, detail: detail)
            }
            store.onDataChange = { [weak store] in
                previousOnDataChange?()
                guard let store, !completed else { return }
                let orderAfter = store.displayModel().flatSlots
                guard orderAfter != orderBefore else { return }
                let unique = Set(orderAfter).count == orderAfter.count
                let activeDrag = windowController.hasActiveDrag()
                finishDrag(
                    unique && !activeDrag,
                    detail: "changed=true unique=\(unique) activeDrag=\(activeDrag) items=\(orderAfter.count)"
                )
            }
            // 目标点: 窗口中心偏右(模拟拖到末尾)
            let targetPoint = NSPoint(x: 900, y: 400)
            windowController.dragTestBegin(item: first, at: targetPoint)
            guard windowController.hasActiveDrag() else {
                finishDrag(false, detail: "drag begin rejected")
                return
            }
            var lastPoint = targetPoint
            for i in 0..<20 {
                lastPoint = NSPoint(x: 700 + CGFloat(i) * 15, y: 400)
                windowController.dragTestUpdate(at: lastPoint)
                windowController.dragProbeTick(lastPoint)
            }
            windowController.dragTestEnd(at: lastPoint)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                MainActor.assumeIsolated {
                    guard !completed else { return }
                    finishDrag(false, detail: "timeout waiting for a changed, unique layout")
                }
            }
            return
        }

        if CommandLine.arguments.contains("--folders") {
            let visible = display.flatSlots
            let apps = visible.compactMap { item -> AppID? in
                if case .app(let id) = item { return id }
                return nil
            }
            guard apps.count >= 3 else {
                finishSmoke(store: store, ok: false, detail: "folder probe requires at least 3 visible app slots; found \(apps.count)")
            }
            let baselineFlatSlots = visible
            guard Set(baselineFlatSlots).count == baselineFlatSlots.count else {
                finishSmoke(store: store, ok: false, detail: "folder probe baseline contains duplicate display items")
            }
            let baselineFolderIDs = Set(store.folderNames().keys)
            let previousOnDataChange = store.onDataChange
            var stage = 0
            var folderID: FolderID?
            var completed = false
            let stepNames = ["create", "rename", "add", "dissolve"]

            func finishFolder(_ ok: Bool, detail: String) {
                guard !completed else { return }
                completed = true
                store.onDataChange = previousOnDataChange
                print("SMOKE folderOps=\(ok ? "OK" : "FAIL") \(detail)")
                finishSmoke(store: store, ok: ok, detail: detail)
            }

            store.onDataChange = { [weak store] in
                previousOnDataChange?()
                guard let store, !completed else { return }
                switch stage {
                case 0: // 创建完成
                    let newIDs = Set(store.folderNames().keys).subtracting(baselineFolderIDs)
                    if newIDs.count > 1 {
                        finishFolder(false, detail: "create produced \(newIDs.count) new folders")
                        return
                    }
                    guard let id = newIDs.first else { return }
                    guard store.folderNames()[id] == "冒烟文件夹",
                          store.folderChildren(id) == [apps[0], apps[1]] else { return }
                    let current = store.displayModel().flatSlots
                    guard current.count == baselineFlatSlots.count - 1,
                          Set(current).count == current.count,
                          current.contains(.folder(id, visibleChildren: [apps[0], apps[1]])) else {
                        finishFolder(false, detail: "create state did not match expected folder and flat-slot count")
                        return
                    }
                    folderID = id
                    print("SMOKE folder step=create OK")
                    stage = 1
                    store.renameFolder(id, to: "冒烟改名")
                case 1: // 重命名完成
                    guard let id = folderID,
                          store.folderNames()[id] == "冒烟改名",
                          store.folderChildren(id) == [apps[0], apps[1]] else { return }
                    print("SMOKE folder step=rename OK")
                    stage = 2
                    store.addToFolder(app: apps[2], folder: id)
                case 2: // 加入完成
                    guard let id = folderID,
                          store.folderChildren(id) == [apps[0], apps[1], apps[2]] else { return }
                    let current = store.displayModel().flatSlots
                    guard current.count == baselineFlatSlots.count - 2,
                          Set(current).count == current.count,
                          !current.contains(.app(apps[2])),
                          current.contains(.folder(id, visibleChildren: [apps[0], apps[1], apps[2]])) else {
                        finishFolder(false, detail: "add state did not contain all three folder children")
                        return
                    }
                    print("SMOKE folder step=add OK")
                    stage = 3
                    store.dissolveFolder(id)
                case 3: // 解散完成
                    guard let id = folderID,
                          store.folderNames()[id] == nil,
                          store.folderChildren(id) == nil else { return }
                    let current = store.displayModel().flatSlots
                    guard current == baselineFlatSlots,
                          Set(current).count == current.count else {
                        finishFolder(false, detail: "dissolve state did not restore the baseline display")
                        return
                    }
                    print("SMOKE folder step=dissolve OK")
                    finishFolder(true, detail: "all async folder steps verified")
                default:
                    break
                }
            }
            store.createFolder(name: "冒烟文件夹", appIDs: [apps[0], apps[1]])
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
                MainActor.assumeIsolated {
                    guard !completed else { return }
                    let step = stepNames[min(stage, stepNames.count - 1)]
                    finishFolder(false, detail: "timeout during \(step) step")
                }
            }
            return
        }

        finishSmoke(store: store)
    }

    private func runPageTest() {
        guard let controller = container?.windowController else {
            print("PAGETEST FAIL")
            NSApp.terminate(nil)
            return
        }
        // 翻页为动画(0.35s), 每步等待动画完成再读数
        func step(_ action: () -> Void) {
            action()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        // Stage 1 §36: 0→1→2→1→0 序列 + 诊断字段
        func report(_ label: String) {
            let scrollX = controller.pageTestScrollX()
            let page = controller.pageTestCurrentPage()
            let count = controller.pageTestPageCount()
            let pageW = controller.pageTestPageWidth()
            let docW = controller.pageTestDocumentWidth()
            print("PAGETEST \(label) scrollX=\(Int(scrollX)) currentPage=\(page) pageCount=\(count) pageWidth=\(Int(pageW)) documentWidth=\(Int(docW))")
        }
        print("PAGETEST before: \(controller.pageTestScrollDiagnostics())")
        report("p0")
        step { _ = controller.pageTestGoTo(1) }
        report("p1")
        step { _ = controller.pageTestGoTo(2) }
        report("p2")
        step { _ = controller.pageTestGoTo(1) }
        report("p3")
        step { _ = controller.pageTestGoTo(0) }
        report("p4")
        print("PAGETEST after: \(controller.pageTestScrollDiagnostics())")
        let ok = controller.pageTestCurrentPage() == 0
        let moved = controller.pageTestScrollX() < controller.pageTestPageWidth()
        // v0.1.4: 重开面板回到第一页
        _ = controller.pageTestGoTo(2)
        step {}
        let reset = controller.pageTestHideShowReset()
        step {}
        print("PAGETEST hideShowReset=\(reset ? "OK" : "FAIL") page=\(controller.pageTestCurrentPage())")
        print("PAGETEST \(ok && moved && reset ? "OK" : "FAIL")")
        NSApp.terminate(nil)
    }

    private func finishSmoke(store: LauncherStore, ok: Bool = true, detail: String? = nil) -> Never {
        // 启动路径验证仅在显式 --launchtest 时真实拉起应用(避免测试副作用)
        if CommandLine.arguments.contains("--launchtest") {
            let chrome = store.displayModel().visibleAppIDs.first { $0.rawValue.contains("Chrome") }
            if let chrome {
                store.launch(chrome)
                print("SMOKE launch=OK \(chrome.rawValue)")
            } else {
                print("SMOKE launch=SKIPPED no chrome")
            }
        } else {
            print("SMOKE launch=SKIPPED (no --launchtest)")
        }

        if let detail {
            print("SMOKE \(ok ? "OK" : "FAIL") \(detail)")
        } else {
            print("SMOKE \(ok ? "OK" : "FAIL")")
        }
        terminateDiagnostic(success: ok)
    }

    private func screenshotArgument() -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--screenshot"),
              args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }

    /// 调试截图: 应用自渲染窗口内容(cacheDisplay, 无需屏幕录制权限)。
    private func captureScreenshot(to path: String) {
        guard let window = container?.windowController.window,
              let contentView = window.contentView else { return }
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
            return
        }
        contentView.cacheDisplay(in: contentView.bounds, to: rep)
        let image = NSImage(size: contentView.bounds.size)
        image.addRepresentation(rep)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("SCREENSHOT_WRITTEN \(path)")
        NSApp.terminate(nil)
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: L10n.t(.settings),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: L10n.t(.quit),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettings() {
        container?.settingsController.show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        container.windowController.toggle()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        container.windowController.hide()
    }
}
