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
        DiagnosticRunner.run(container: container)
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
        guard let container else { return }
        // 惰性构建(PA1 A6): 首次菜单/齿轮访问才创建 Settings 并注入 windowController。
        _ = container.settingsController
        container.windowController.openSettingsFromMenu()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        container.windowController.toggle()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        container.windowController.hide()
        // L3: 进程退出前冲刷 Library 元数据 pending 写(2s 上限, 退出路径阻塞可接受)。
        container.flushMetadataForTermination()
    }
}
