import Foundation
import LaunchCore

/// 轻量本地化: 运行时切换, 无需重启。
///
/// 避免旧版 AppleLanguages 重启式切换; 语言存于 AppConfiguration.language,
/// 设置变更即时生效。跟随系统时按系统首选语言自动选择。
public enum L10n {
    public enum Key: String, CaseIterable {
        case searchPlaceholder
        case back
        case settings
        case quit
        case addToFolder
        case newFolder
        case rename
        case renameApp
        case dissolveFolder
        case hideApp
        case unhideApp
        case moveToTrash
        case ok
        case cancel
        case noFolders
        case gridSection
        case columnsLabel
        case rowsLabel
        case iconSizeLabel
        case showLabelsLabel
        case languageLabel
        case hotkeyLabel
        case hotkeyEnabled
        case hotCornerLabel
        case wallpaperLabel
        case customSourcesLabel
        case addSource
        case remove
        case hiddenAppsLabel
        case addHiddenApp
        case settingsTitle
        case permissionSection
        case permissionStatus
        case permissionOpenSettings
        case none
        case cornerShow
        case cornerHide
        case cornerToggle
    }

    nonisolated(unsafe) private static let zhHans: [Key: String] = [
        .searchPlaceholder: "搜索应用", .back: "返回", .settings: "设置",
        .quit: "退出 LaunchBetter", .addToFolder: "加入文件夹", .newFolder: "新建文件夹",
        .rename: "重命名…", .renameApp: "重命名…", .dissolveFolder: "解散文件夹",
        .hideApp: "隐藏应用", .unhideApp: "取消隐藏", .moveToTrash: "移到废纸篓…",
        .ok: "确定", .cancel: "取消", .noFolders: "(无文件夹)",
        .gridSection: "网格", .columnsLabel: "列数", .rowsLabel: "行数",
        .iconSizeLabel: "图标尺寸", .showLabelsLabel: "显示标签", .languageLabel: "语言",
        .hotkeyLabel: "全局热键", .hotkeyEnabled: "启用", .hotCornerLabel: "热角",
        .wallpaperLabel: "壁纸模糊背景", .customSourcesLabel: "自定义应用源目录",
        .addSource: "添加目录…", .remove: "移除", .hiddenAppsLabel: "隐藏应用",
        .addHiddenApp: "添加…", .settingsTitle: "LaunchBetter 设置",
        .permissionSection: "手势", .permissionStatus: "输入监控权限",
        .permissionOpenSettings: "打开系统设置", .none: "无",
        .cornerShow: "显示启动器", .cornerHide: "隐藏启动器", .cornerToggle: "切换启动器",
    ]

    nonisolated(unsafe) private static let zhHant: [Key: String] = [
        .searchPlaceholder: "搜尋應用程式", .back: "返回", .settings: "設定",
        .quit: "結束 LaunchBetter", .addToFolder: "加入檔案夾", .newFolder: "新增檔案夾",
        .rename: "重新命名…", .renameApp: "重新命名…", .dissolveFolder: "解散檔案夾",
        .hideApp: "隱藏應用程式", .unhideApp: "取消隱藏", .moveToTrash: "移到垃圾桶…",
        .ok: "確定", .cancel: "取消", .noFolders: "(沒有檔案夾)",
        .gridSection: "網格", .columnsLabel: "欄數", .rowsLabel: "列數",
        .iconSizeLabel: "圖示大小", .showLabelsLabel: "顯示標籤", .languageLabel: "語言",
        .hotkeyLabel: "全域快速鍵", .hotkeyEnabled: "啟用", .hotCornerLabel: "熱角",
        .wallpaperLabel: "模糊桌布", .customSourcesLabel: "自訂應用程式來源",
        .addSource: "加入目錄…", .remove: "移除", .hiddenAppsLabel: "隱藏應用程式",
        .addHiddenApp: "加入…", .settingsTitle: "LaunchBetter 設定",
        .permissionSection: "手勢", .permissionStatus: "輸入監控權限",
        .permissionOpenSettings: "開啟系統設定", .none: "無",
        .cornerShow: "顯示啟動器", .cornerHide: "隱藏啟動器", .cornerToggle: "切換啟動器",
    ]

    nonisolated(unsafe) private static let english: [Key: String] = [
        .searchPlaceholder: "Search apps", .back: "Back", .settings: "Settings",
        .quit: "Quit LaunchBetter", .addToFolder: "Add to Folder", .newFolder: "New Folder",
        .rename: "Rename…", .renameApp: "Rename…", .dissolveFolder: "Dissolve Folder",
        .hideApp: "Hide App", .unhideApp: "Unhide", .moveToTrash: "Move to Trash…",
        .ok: "OK", .cancel: "Cancel", .noFolders: "(No folders)",
        .gridSection: "Grid", .columnsLabel: "Columns", .rowsLabel: "Rows",
        .iconSizeLabel: "Icon Size", .showLabelsLabel: "Show Labels", .languageLabel: "Language",
        .hotkeyLabel: "Global Hotkey", .hotkeyEnabled: "Enabled", .hotCornerLabel: "Hot Corners",
        .wallpaperLabel: "Blurred Wallpaper", .customSourcesLabel: "Custom App Sources",
        .addSource: "Add Folder…", .remove: "Remove", .hiddenAppsLabel: "Hidden Apps",
        .addHiddenApp: "Add…", .settingsTitle: "LaunchBetter Settings",
        .permissionSection: "Gestures", .permissionStatus: "Input Monitoring",
        .permissionOpenSettings: "Open System Settings", .none: "None",
        .cornerShow: "Show Launcher", .cornerHide: "Hide Launcher", .cornerToggle: "Toggle Launcher",
    ]

    nonisolated(unsafe) private static var language: AppLanguage = .system

    /// 应用层在配置加载后设置。
    public static func configure(language: AppLanguage) {
        self.language = language
    }

    /// 当前语言。
    public static var currentLanguage: AppLanguage { language }

    /// 取翻译; 未翻译的 key 回退简体中文。
    public static func t(_ key: Key) -> String {
        let effective: AppLanguage
        switch language {
        case .system:
            let preferred = Locale.preferredLanguages.first ?? ""
            if preferred.hasPrefix("zh-Hant") || preferred.hasPrefix("zh-TW") || preferred.hasPrefix("zh-HK") {
                effective = .traditionalChinese
            } else if preferred.hasPrefix("zh") {
                effective = .simplifiedChinese
            } else {
                effective = .english
            }
        case let other:
            effective = other
        }
        switch effective {
        case .system, .simplifiedChinese:
            return zhHans[key] ?? key.rawValue
        case .traditionalChinese:
            return zhHant[key] ?? zhHans[key] ?? key.rawValue
        case .english:
            return english[key] ?? zhHans[key] ?? key.rawValue
        }
    }
}
