import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var container: DependencyContainer!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        container = DependencyContainer()
        // Phase 3 激活方式: 启动即显示 + Dock 图标点击重开(toggle)。
        // 全局热键/手势/热角属 Phase 8。
        container.windowController.show()

        if let screenshotPath = screenshotArgument() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.captureScreenshot(to: screenshotPath)
            }
        } else if CommandLine.arguments.contains("--smoke") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.runSmokeDiagnostics()
            }
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

        // 启动路径验证: 找 Chrome 并真实启动(无害)
        let chrome = store.displayModel().visibleAppIDs.first { $0.rawValue.contains("Chrome") }
        if let chrome {
            store.launch(chrome)
            print("SMOKE launch=OK \(chrome.rawValue)")
        } else {
            print("SMOKE launch=SKIPPED no chrome")
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
            withTitle: "退出 LaunchBetter",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        container.windowController.toggle()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        container.windowController.hide()
    }
}
