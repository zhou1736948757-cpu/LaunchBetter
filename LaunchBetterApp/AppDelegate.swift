import AppKit
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
                store.searchQuery = ""
                windowController.refreshGrid()
                print("SEARCHPROBE restored search=\(store.searchResults() == nil)")
                print("SEARCHPROBE OK")
                NSApp.terminate(nil)
            }
        }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
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
            NSApp.terminate(nil)
            return
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
            let semaphore = DispatchSemaphore(value: 0)
            store.onDataChange = { semaphore.signal() }
            let items = windowController.dragTestItems()
            guard let first = items.first else {
                print("SMOKE dragtest=SKIPPED empty")
                finishSmoke(store: store)
                return
            }
            let orderBefore = store.displayModel().flatSlots.map(String.init(describing:))
            // 目标点: 窗口中心偏右(模拟拖到末尾)
            let targetPoint = NSPoint(x: 900, y: 400)
            windowController.dragTestBegin(item: first, at: targetPoint)
            for i in 0..<20 {
                windowController.dragTestUpdate(at: NSPoint(x: 700 + CGFloat(i) * 15, y: 400))
            }
            windowController.dragTestEnd(at: targetPoint)
            DispatchQueue.global().async { [weak self, weak store] in
                _ = semaphore.wait(timeout: .now() + 5)
                DispatchQueue.main.async {
                    guard let store else { return }
                    let orderAfter = store.displayModel().flatSlots.map(String.init(describing:))
                    let changed = orderBefore != orderAfter
                    print("SMOKE dragtest=OK changed=\(changed) items=\(orderAfter.count)")
                    self?.finishSmoke(store: store)
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
            if apps.count >= 2 {
                var stage = 0
                var folderID: FolderID?
                let semaphore = DispatchSemaphore(value: 0)
                store.onDataChange = { [weak store] in
                    guard let store else { return }
                    switch stage {
                    case 0: // 创建完成
                        folderID = store.folderNames().keys.first
                        guard folderID != nil else { semaphore.signal(); return }
                        stage = 1
                        store.renameFolder(folderID!, to: "冒烟改名")
                    case 1: // 重命名完成
                        stage = 2
                        store.addToFolder(app: apps[2], folder: folderID!)
                    case 2: // 加入完成
                        stage = 3
                        store.dissolveFolder(folderID!)
                    case 3: // 解散完成
                        semaphore.signal()
                    default:
                        break
                    }
                }
                store.createFolder(name: "冒烟文件夹", appIDs: [apps[0], apps[1]])
                // 等待必须在后台队列(主线程 Task 需要跑, 不能阻塞主线程)
                DispatchQueue.global().async { [weak self, weak store] in
                    _ = semaphore.wait(timeout: .now() + 8)
                    DispatchQueue.main.async {
                        guard let store else { return }
                        print("SMOKE folderOps=OK foldersNow=\(store.folderNames().count) flatAfter=\(store.displayModel().flatSlots.count)")
                        self?.finishSmoke(store: store)
                    }
                }
                return
            } else {
                print("SMOKE folderOps=SKIPPED apps<2")
            }
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

    private func finishSmoke(store: LauncherStore) {
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

        print("SMOKE OK")
        NSApp.terminate(nil)
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
