import AppKit
import LaunchCore
import Testing
@testable import LaunchUI

/// X1: 滑杆修复 + 开机自动启动。
///
/// 覆盖:
/// - 滑杆在三种语言下都有可用宽度(> 阈值, 任意语言可拖动), 不再依赖 grid 的
///   偶然富余宽度坍缩到 0。
/// - setDoubleValue + sendAction → commit 读值正确(模糊半径 / 搜索栏宽度)。
/// - launchAtLogin 复选框绑定 config 且 toggle 触发 handler.save + fake
///   login item controller 的 register/unregister。
@Suite("Settings slider fix + launch at login", .serialized)
@MainActor
struct SettingsSliderLoginItemTests {
    @Test("blur and search bar sliders are draggable-width in all three languages")
    func slidersHaveUsableWidthInAllLanguages() throws {
        for language in [AppLanguage.english, .simplifiedChinese, .traditionalChinese] {
            let previousLanguage = L10n.currentLanguage
            defer { L10n.configure(language: previousLanguage) }

            let controller = SettingsWindowController(
                handler: SettingsHandlerStubX(config: AppConfiguration(language: language))
            )
            let window = try #require(controller.window)
            let contentView = try #require(window.contentView)
            window.layoutIfNeeded()
            contentView.layoutSubtreeIfNeeded()

            let blurSlider = try #require(descendantX(
                of: NSSlider.self,
                identifier: "settings.blur",
                in: contentView
            ))
            let searchSlider = try #require(descendantX(
                of: NSSlider.self,
                identifier: "settings.searchBarSize",
                in: contentView
            ))

            let threshold = SettingsWindowController.sliderWidthForTesting / 2
            #expect(
                blurSlider.frame.width >= threshold,
                "language=\(language) blurSlider width=\(blurSlider.frame.width)"
            )
            #expect(
                searchSlider.frame.width >= threshold,
                "language=\(language) searchBarSlider width=\(searchSlider.frame.width)"
            )
        }
    }

    @Test("blur slider value-to-commit roundtrip updates the persisted config immediately")
    func blurSliderCommitRoundtrip() throws {
        SettingsWindowController.sliderCommitInterval = 0
        defer { SettingsWindowController.sliderCommitInterval = 0.15 }
        let handler = SettingsHandlerStubX(config: AppConfiguration(wallpaperBlurRadius: 10))
        let controller = SettingsWindowController(handler: handler)
        let contentView = try #require(controller.window?.contentView)
        let slider = try #require(descendantX(
            of: NSSlider.self,
            identifier: "settings.blur",
            in: contentView
        ))

        slider.doubleValue = 45
        #expect(slider.sendAction(slider.action, to: slider.target))

        #expect(handler.config.wallpaperBlurRadius == 45)
    }

    @Test("search bar slider value-to-commit roundtrip updates the persisted width immediately")
    func searchBarSliderCommitRoundtrip() throws {
        SettingsWindowController.sliderCommitInterval = 0
        defer { SettingsWindowController.sliderCommitInterval = 0.15 }
        let handler = SettingsHandlerStubX(config: AppConfiguration(searchBarWidth: 320))
        let controller = SettingsWindowController(handler: handler)
        let contentView = try #require(controller.window?.contentView)
        let slider = try #require(descendantX(
            of: NSSlider.self,
            identifier: "settings.searchBarSize",
            in: contentView
        ))

        // “尺寸百分比”滑杆的中值 → 保留的持久宽度经 SearchBarSizing 映射。
        slider.doubleValue = 150
        #expect(slider.sendAction(slider.action, to: slider.target))

        #expect(handler.config.searchBarWidth == 480)
        #expect(SearchBarSizing.percent(forPersistedWidth: handler.config.searchBarWidth) > 0)
    }

    @Test("blur and search bar slider commits go through the injectable save handler")
    func sliderCommitUsesInjectableHandler() throws {
        let handler = SettingsHandlerStubX(config: AppConfiguration(
            wallpaperBlurRadius: 0,
            searchBarWidth: 200
        ))
        SettingsWindowController.sliderCommitInterval = 0
        defer { SettingsWindowController.sliderCommitInterval = 0.15 }
        let controller = SettingsWindowController(handler: handler)
        let contentView = try #require(controller.window?.contentView)
        let blur = try #require(descendantX(
            of: NSSlider.self,
            identifier: "settings.blur",
            in: contentView
        ))
        let search = try #require(descendantX(
            of: NSSlider.self,
            identifier: "settings.searchBarSize",
            in: contentView
        ))

        blur.doubleValue = 60
        #expect(blur.sendAction(blur.action, to: blur.target))
        search.doubleValue = 185
        #expect(search.sendAction(search.action, to: search.target))

        #expect(handler.config.wallpaperBlurRadius == 60)
        #expect(handler.config.searchBarWidth == 592)
    }

    @Test("continuous slider ticks coalesce into one deferred commit until flushed")
    func sliderCommitCoalescesUntilFlush() throws {
        SettingsWindowController.sliderCommitInterval = 0.15
        defer { SettingsWindowController.sliderCommitInterval = 0.15 }
        let handler = SettingsHandlerStubX(config: AppConfiguration(wallpaperBlurRadius: 10))
        let controller = SettingsWindowController(handler: handler)
        let contentView = try #require(controller.window?.contentView)
        let slider = try #require(descendantX(
            of: NSSlider.self,
            identifier: "settings.blur",
            in: contentView
        ))

        // 合并窗口内: 标签即时更新, 但配置尚未落盘。
        slider.doubleValue = 45
        #expect(slider.sendAction(slider.action, to: slider.target))
        #expect(handler.config.wallpaperBlurRadius == 10)

        // 冲刷(关闭路径同款)后一次性提交。
        controller.flushPendingSliderCommit()
        #expect(handler.config.wallpaperBlurRadius == 45)
    }

    @Test("launch-at-login checkbox binds to config and persists through save")
    func launchAtLoginCheckboxBindsToConfig() throws {
        let handler = SettingsHandlerStubX(config: AppConfiguration(language: .english))
        let controller = SettingsWindowController(
            handler: handler,
            iconProvider: nil,
            loginItem: FakeLoginItemController(),
            sourcePanelPresenter: { _, _ in },
            hiddenPanelPresenter: { _, _, _ in }
        )
        let contentView = try #require(controller.window?.contentView)
        let checkbox = try #require(descendantX(
            of: NSButton.self,
            identifier: "settings.launchAtLogin",
            in: contentView
        ))

        #expect(checkbox.state == .off)
        #expect(!handler.config.launchAtLogin)

        checkbox.state = .on
        #expect(checkbox.sendAction(checkbox.action, to: checkbox.target))
        #expect(handler.config.launchAtLogin)
    }

    @Test("toggling launch-at-login registers and unregisters via the injected login controller")
    func launchAtLoginToggleAppliesLoginItem() throws {
        let loginItem = FakeLoginItemController()
        let handler = SettingsHandlerStubX(config: AppConfiguration(language: .english))
        let controller = SettingsWindowController(
            handler: handler,
            iconProvider: nil,
            loginItem: loginItem,
            sourcePanelPresenter: { _, _ in },
            hiddenPanelPresenter: { _, _, _ in }
        )
        let contentView = try #require(controller.window?.contentView)
        let checkbox = try #require(descendantX(
            of: NSButton.self,
            identifier: "settings.launchAtLogin",
            in: contentView
        ))

        checkbox.state = .on
        #expect(checkbox.sendAction(checkbox.action, to: checkbox.target))
        #expect(loginItem.applications == [true])
        #expect(handler.config.launchAtLogin)

        checkbox.state = .off
        #expect(checkbox.sendAction(checkbox.action, to: checkbox.target))
        #expect(loginItem.applications == [true, false])
        #expect(!handler.config.launchAtLogin)
    }

    @Test("launch-at-login checkbox starts at the shared value column")
    func launchAtLoginCheckboxAlignsToValueColumn() throws {
        let previousLanguage = L10n.currentLanguage
        L10n.configure(language: .simplifiedChinese)
        defer { L10n.configure(language: previousLanguage) }

        let controller = SettingsWindowController(
            handler: SettingsHandlerStubX(config: AppConfiguration(language: .simplifiedChinese))
        )
        let window = try #require(controller.window)
        let contentView = try #require(window.contentView)
        window.layoutIfNeeded()
        contentView.layoutSubtreeIfNeeded()

        let sharedX = try sharedValueX(in: contentView)
        let checkbox = try #require(descendantX(
            of: NSButton.self,
            identifier: "settings.launchAtLogin",
            in: contentView
        ))
        #expect(abs(minX(of: checkbox, in: contentView) - sharedX) < 0.5)
    }
}

@MainActor
private final class SettingsHandlerStubX: SettingsHandling {
    private(set) var config: AppConfiguration
    let allApps: [(id: AppID, name: String)]

    init(config: AppConfiguration, allApps: [(id: AppID, name: String)] = []) {
        self.config = config
        self.allApps = allApps
    }

    func save(_ config: AppConfiguration) {
        self.config = config
        L10n.configure(language: config.language)
    }
}

@MainActor
private final class FakeLoginItemController: LoginItemApplying {
    private(set) var applications: [Bool] = []
    var registered = false

    var isRegistered: Bool { registered }

    @discardableResult
    func apply(_ enabled: Bool) -> Bool {
        applications.append(enabled)
        registered = enabled
        return registered == enabled
    }
}

private func descendantX<View: NSView>(
    of type: View.Type,
    identifier: String,
    in root: NSView
) -> View? {
    descendantsX(of: type, in: root).first { $0.identifier?.rawValue == identifier }
}

private func descendantsX<View: NSView>(of type: View.Type, in root: NSView) -> [View] {
    root.subviews.flatMap { view -> [View] in
        let current = (view as? View).map { [$0] } ?? []
        return current + descendantsX(of: type, in: view)
    }
}

private func sharedValueX(in contentView: NSView) throws -> CGFloat {
    let grids = descendantGridsX(in: contentView)
    let xs = grids.flatMap { grid in
        (0..<grid.numberOfRows).compactMap { row in
            grid.cell(atColumnIndex: 1, rowIndex: row).contentView.map {
                contentView.convert($0.bounds, from: $0).minX
            }
        }
    }
    return try #require(xs.first)
}

private func descendantGridsX(in root: NSView) -> [NSGridView] {
    root.subviews.flatMap { view -> [NSGridView] in
        let current = (view as? NSGridView).map { [$0] } ?? []
        return current + descendantGridsX(in: view)
    }
}

private func minX(of view: NSView, in contentView: NSView) -> CGFloat {
    contentView.convert(view.bounds, from: view).minX
}
