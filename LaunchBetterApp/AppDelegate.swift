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
        print("PAGETEST \(ok && moved ? "OK" : "FAIL")")
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
