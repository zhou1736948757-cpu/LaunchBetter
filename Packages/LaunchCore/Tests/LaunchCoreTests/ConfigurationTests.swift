import Foundation
import Testing
@testable import LaunchCore

@Suite("配置模型: AppConfiguration / Hotkey / HotCorner")
struct ConfigurationTests {
    @Test("默认配置: 网格 7 列, 图标 80, 显示标签, 语言 system")
    func defaults() {
        let config = AppConfiguration()
        #expect(config.schemaVersion == AppConfiguration.currentSchemaVersion)
        #expect(config.gridColumns == 7)
        #expect(config.iconSize == 80)
        #expect(config.showIconLabels)
        #expect(config.customSourceDirectories.isEmpty)
        #expect(config.hiddenAppIDs.isEmpty)
        #expect(config.customDisplayNames.isEmpty)
        #expect(config.language == .system)
        #expect(!config.hotkey.enabled)
        #expect(!config.launchAtLogin)
        #expect(config.hotCorner.topLeft == .none)
    }

    @Test("AppConfiguration Codable 往返")
    func roundTrip() throws {
        let appID = try #require(AppID("/Applications/Secret.app"))
        var config = AppConfiguration()
        config.gridColumns = 5
        config.iconSize = 64
        config.showIconLabels = false
        config.customSourceDirectories = ["/Volumes/Dev"]
        config.hiddenAppIDs = [appID]
        config.customDisplayNames = [appID: "MySecret"]
        config.language = .simplifiedChinese
        config.launchAtLogin = true
        config.hotkey = HotkeyConfig(enabled: true, keyCode: 37, modifiers: [.command, .shift])
        config.hotCorner = HotCornerConfig(
            topLeft: .showLauncher,
            bottomRight: .toggleLauncher
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)
        #expect(decoded.gridColumns == 5)
        #expect(decoded.iconSize == 64)
        #expect(!decoded.showIconLabels)
        #expect(decoded.customSourceDirectories == ["/Volumes/Dev"])
        #expect(decoded.hiddenAppIDs == [appID])
        #expect(decoded.customDisplayNames == [appID: "MySecret"])
        #expect(decoded.language == .simplifiedChinese)
        #expect(decoded.launchAtLogin)
        #expect(decoded.hotkey.keyCode == 37)
        #expect(decoded.hotkey.modifiers == [.command, .shift])
        #expect(decoded.hotkey.enabled)
        #expect(decoded.hotCorner.topLeft == .showLauncher)
        #expect(decoded.hotCorner.bottomRight == .toggleLauncher)
        #expect(decoded.hotCorner.topRight == .none)
    }

    @Test("缺失字段解码回退默认值(前向兼容)")
    func decodeMissingFieldsFallsBack() throws {
        let data = Data(#"{"schemaVersion":1,"gridColumns":4}"#.utf8)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)
        #expect(decoded.gridColumns == 4)
        #expect(decoded.iconSize == 80)
        #expect(decoded.showIconLabels)
        #expect(decoded.language == .system)
        #expect(!decoded.launchAtLogin)
    }

    @Test("旧配置文件缺省 launchAtLogin 时回退 false")
    func oldFileMissingLaunchAtLoginDefaultsFalse() throws {
        let data = Data(#"{"schemaVersion":1,"wallpaperBlurRadius":42,"searchBarWidth":512}"#.utf8)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)
        #expect(!decoded.launchAtLogin)
        #expect(decoded.wallpaperBlurRadius == 42)
        #expect(decoded.searchBarWidth == 512)
    }

    @Test("旧 searchBarWidth 持久值映射为百分比且保持宽高比例")
    func searchBarSizingCompatibility() throws {
        let data = Data(#"{"schemaVersion":1,"searchBarWidth":512}"#.utf8)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)
        let size = SearchBarSizing.size(forPersistedWidth: decoded.searchBarWidth)

        #expect(decoded.searchBarWidth == 512)
        #expect(SearchBarSizing.percent(forPersistedWidth: 320) == 100)
        #expect(SearchBarSizing.persistedWidth(forPercent: 160) == 512)
        #expect(size.width == 512)
        #expect(size.height == 35.2)
        #expect(abs(size.width / size.height - 320.0 / 22.0) < 0.000_001)
    }

    @Test("HotkeyModifiers OptionSet 组合")
    func modifiersCombination() {
        let combo = HotkeyModifiers([.command, .option])
        #expect(combo.contains(.command))
        #expect(combo.contains(.option))
        #expect(!combo.contains(.shift))
        #expect(combo == [.command, .option])
    }

    @Test("HotCornerAction Codable")
    func cornerActionCoding() throws {
        let actions: [HotCornerAction] = [.none, .showLauncher, .hideLauncher, .toggleLauncher]
        for action in actions {
            let data = try JSONEncoder().encode(action)
            #expect(try JSONDecoder().decode(HotCornerAction.self, from: data) == action)
        }
    }
}
