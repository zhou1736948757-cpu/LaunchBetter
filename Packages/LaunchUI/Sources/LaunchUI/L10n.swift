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
        case launchApp
        case folderLabel
        case folderContentsHelp
        case renameFolderHelp
        case dropIntoFolder
        case createFolderWith
        case rename
        case renameApp
        case dissolveFolder
        case hideApp
        case unhideApp
        case moveToTrash
        case revealInFinder
        case getInfo
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
        case hiddenAppNoCandidates
        case hiddenAppNoResults
        case settingsTitle
        case permissionSection
        case permissionStatus
        case permissionOpenSettings
        case permissionTitle
        case permissionMessage
        case later
        case none
        case cornerShow
        case cornerHide
        case cornerToggle
        case pageOf
        case generalSection
        case launchAtLogin
        case aboutLabel
        case blurIntensityLabel
        case searchBarSection
        case searchBarSizeLabel
        case appLibrary
        case suggestions
        case recentlyAdded
        case libraryCardsHelp
        case categoryDetailHelp
        case viewMoreApps
        case categoryProductivity
        case categorySocial
        case categoryDeveloper
        case categoryEntertainment
        case categoryGames
        case categoryCreativity
        case categoryUtilities
        case categoryEducation
        case categoryBusiness
        case categoryFinance
        case categoryOther
        case moveToCategory
        case automaticClassification
    }

    nonisolated(unsafe) private static let zhHans: [Key: String] = [
        .searchPlaceholder: "搜索应用", .back: "返回", .settings: "设置",
        .quit: "退出 LaunchBetter", .addToFolder: "加入文件夹", .newFolder: "新建文件夹",
        .launchApp: "点击启动 %@", .folderLabel: "文件夹 %@",
        .folderContentsHelp: "文件夹内容和操作", .renameFolderHelp: "重命名文件夹",
        .dropIntoFolder: "放入 %@", .createFolderWith: "与 %@ 建立文件夹",
        .rename: "重命名…", .renameApp: "重命名…", .dissolveFolder: "解散文件夹",
        .hideApp: "隐藏应用", .unhideApp: "取消隐藏", .moveToTrash: "移到废纸篓…",
        .revealInFinder: "在访达中显示", .getInfo: "显示简介",
        .ok: "确定", .cancel: "取消", .noFolders: "(无文件夹)",
        .gridSection: "网格", .columnsLabel: "列数", .rowsLabel: "行数",
        .iconSizeLabel: "图标尺寸", .showLabelsLabel: "显示标签", .languageLabel: "语言",
        .hotkeyLabel: "全局热键", .hotkeyEnabled: "启用", .hotCornerLabel: "热角",
        .wallpaperLabel: "壁纸模糊背景", .customSourcesLabel: "自定义应用源目录",
        .addSource: "添加目录…", .remove: "移除", .hiddenAppsLabel: "隐藏应用",
        .addHiddenApp: "添加…", .settingsTitle: "LaunchBetter 设置",
        .hiddenAppNoCandidates: "没有可隐藏的应用",
        .hiddenAppNoResults: "没有匹配的应用",
        .permissionSection: "手势", .permissionStatus: "输入监控权限",
        .permissionOpenSettings: "打开系统设置", .permissionTitle: "需要输入监控权限",
        .permissionMessage: "四指捏合手势需要“输入监控”权限才能工作。\n请点击“打开系统设置”，在“隐私与安全性” → “输入监控”中启用 LaunchBetter，然后回到应用。",
        .later: "稍后", .none: "无",
        .cornerShow: "显示启动器", .cornerHide: "隐藏启动器", .cornerToggle: "切换启动器",
        .pageOf: "第 %@ 页，共 %@ 页",
        .generalSection: "通用",
        .launchAtLogin: "开机自动启动",
        .aboutLabel: "关于",
        .blurIntensityLabel: "模糊强度",
        .searchBarSection: "搜索栏",
        .searchBarSizeLabel: "尺寸百分比",
        .appLibrary: "App 资料库",
        .suggestions: "建议",
        .recentlyAdded: "最近添加",
        .libraryCardsHelp: "App 资料库分区卡片",
        .categoryDetailHelp: "浏览此分类中的应用",
        .viewMoreApps: "查看更多应用",
        .categoryProductivity: "效率",
        .categorySocial: "社交",
        .categoryDeveloper: "开发工具",
        .categoryEntertainment: "娱乐",
        .categoryGames: "游戏",
        .categoryCreativity: "创意",
        .categoryUtilities: "实用工具",
        .categoryEducation: "教育",
        .categoryBusiness: "商务",
        .categoryFinance: "财务",
        .categoryOther: "其他",
        .moveToCategory: "移到分类",
        .automaticClassification: "自动分类",
    ]

    nonisolated(unsafe) private static let zhHant: [Key: String] = [
        .searchPlaceholder: "搜尋應用程式", .back: "返回", .settings: "設定",
        .quit: "結束 LaunchBetter", .addToFolder: "加入檔案夾", .newFolder: "新增檔案夾",
        .launchApp: "點擊啟動 %@", .folderLabel: "檔案夾 %@",
        .folderContentsHelp: "檔案夾內容與操作", .renameFolderHelp: "重新命名檔案夾",
        .dropIntoFolder: "放入 %@", .createFolderWith: "與 %@ 建立檔案夾",
        .rename: "重新命名…", .renameApp: "重新命名…", .dissolveFolder: "解散檔案夾",
        .hideApp: "隱藏應用程式", .unhideApp: "取消隱藏", .moveToTrash: "移到垃圾桶…",
        .revealInFinder: "在 Finder 中顯示", .getInfo: "顯示簡介",
        .ok: "確定", .cancel: "取消", .noFolders: "(沒有檔案夾)",
        .gridSection: "網格", .columnsLabel: "欄數", .rowsLabel: "列數",
        .iconSizeLabel: "圖示大小", .showLabelsLabel: "顯示標籤", .languageLabel: "語言",
        .hotkeyLabel: "全域快速鍵", .hotkeyEnabled: "啟用", .hotCornerLabel: "熱角",
        .wallpaperLabel: "模糊桌布", .customSourcesLabel: "自訂應用程式來源",
        .addSource: "加入目錄…", .remove: "移除", .hiddenAppsLabel: "隱藏應用程式",
        .addHiddenApp: "加入…", .settingsTitle: "LaunchBetter 設定",
        .hiddenAppNoCandidates: "沒有可隱藏的應用程式",
        .hiddenAppNoResults: "沒有符合的應用程式",
        .permissionSection: "手勢", .permissionStatus: "輸入監控權限",
        .permissionOpenSettings: "開啟系統設定", .permissionTitle: "需要輸入監控權限",
        .permissionMessage: "四指捏合手勢需要「輸入監控」權限才能運作。\n請點擊「開啟系統設定」，在「隱私權與安全性」→「輸入監控」中啟用 LaunchBetter，然後返回應用程式。",
        .later: "稍後", .none: "無",
        .cornerShow: "顯示啟動器", .cornerHide: "隱藏啟動器", .cornerToggle: "切換啟動器",
        .pageOf: "第 %@ 頁，共 %@ 頁",
        .generalSection: "通用",
        .launchAtLogin: "開機自動啟動",
        .aboutLabel: "關於",
        .blurIntensityLabel: "模糊強度",
        .searchBarSection: "搜尋列",
        .searchBarSizeLabel: "尺寸百分比",
        .appLibrary: "App 資料庫",
        .suggestions: "建議",
        .recentlyAdded: "最近加入",
        .libraryCardsHelp: "App 資料庫分區卡片",
        .categoryDetailHelp: "瀏覽此分類中的應用程式",
        .viewMoreApps: "查看更多應用程式",
        .categoryProductivity: "效率",
        .categorySocial: "社交",
        .categoryDeveloper: "開發工具",
        .categoryEntertainment: "娛樂",
        .categoryGames: "遊戲",
        .categoryCreativity: "創意",
        .categoryUtilities: "工具程式",
        .categoryEducation: "教育",
        .categoryBusiness: "商務",
        .categoryFinance: "財務",
        .categoryOther: "其他",
        .moveToCategory: "移到分類",
        .automaticClassification: "自動分類",
    ]

    nonisolated(unsafe) private static let english: [Key: String] = [
        .searchPlaceholder: "Search apps", .back: "Back", .settings: "Settings",
        .quit: "Quit LaunchBetter", .addToFolder: "Add to Folder", .newFolder: "New Folder",
        .launchApp: "Click to launch %@", .folderLabel: "Folder %@",
        .folderContentsHelp: "Folder contents and actions", .renameFolderHelp: "Rename folder",
        .dropIntoFolder: "Drop into %@", .createFolderWith: "Create a folder with %@",
        .rename: "Rename…", .renameApp: "Rename…", .dissolveFolder: "Dissolve Folder",
        .hideApp: "Hide App", .unhideApp: "Unhide", .moveToTrash: "Move to Trash…",
        .revealInFinder: "Reveal in Finder", .getInfo: "Get Info",
        .ok: "OK", .cancel: "Cancel", .noFolders: "(No folders)",
        .gridSection: "Grid", .columnsLabel: "Columns", .rowsLabel: "Rows",
        .iconSizeLabel: "Icon Size", .showLabelsLabel: "Show Labels", .languageLabel: "Language",
        .hotkeyLabel: "Global Hotkey", .hotkeyEnabled: "Enabled", .hotCornerLabel: "Hot Corners",
        .wallpaperLabel: "Blurred Wallpaper", .customSourcesLabel: "Custom App Sources",
        .addSource: "Add Folder…", .remove: "Remove", .hiddenAppsLabel: "Hidden Apps",
        .addHiddenApp: "Add…", .settingsTitle: "LaunchBetter Settings",
        .hiddenAppNoCandidates: "No applications are available to hide",
        .hiddenAppNoResults: "No matching applications",
        .permissionSection: "Gestures", .permissionStatus: "Input Monitoring",
        .permissionOpenSettings: "Open System Settings", .permissionTitle: "Input Monitoring Permission Required",
        .permissionMessage: "The four-finger pinch gesture requires Input Monitoring permission.\nClick “Open System Settings”, then enable LaunchBetter in Privacy & Security → Input Monitoring and return to the app.",
        .later: "Later", .none: "None",
        .cornerShow: "Show Launcher", .cornerHide: "Hide Launcher", .cornerToggle: "Toggle Launcher",
        .pageOf: "Page %@ of %@",
        .generalSection: "General",
        .launchAtLogin: "Launch at Login",
        .aboutLabel: "About",
        .blurIntensityLabel: "Blur Intensity",
        .searchBarSection: "Search Bar",
        .searchBarSizeLabel: "Size Percentage",
        .appLibrary: "App Library",
        .suggestions: "Suggestions",
        .recentlyAdded: "Recently Added",
        .libraryCardsHelp: "App Library section card",
        .categoryDetailHelp: "Browse apps in this category",
        .viewMoreApps: "View more apps",
        .categoryProductivity: "Productivity",
        .categorySocial: "Social",
        .categoryDeveloper: "Developer Tools",
        .categoryEntertainment: "Entertainment",
        .categoryGames: "Games",
        .categoryCreativity: "Creativity",
        .categoryUtilities: "Utilities",
        .categoryEducation: "Education",
        .categoryBusiness: "Business",
        .categoryFinance: "Finance",
        .categoryOther: "Other",
        .moveToCategory: "Move to Category",
        .automaticClassification: "Automatic Classification",
    ]

    /// L10n 全部可变状态的锁隔离容器(F8)。
    ///
    /// L10n 的公开 API 保持 nonisolated(t()/configure/currentLanguage 任意线程
    /// 可调); 所有可变状态收进此类, 由 NSLock 保护, 消除原先
    /// `nonisolated(unsafe)` 可变静态的后台线程竞态。观察者 token 也在锁内
    /// 双检, 保证只注册一次。回调只清缓存(无 UI / 无 MainActor 依赖),
    /// 锁内操作, 不需要 assumeIsolated。
    private static let state = L10nState()

    /// 应用层在配置加载后设置。
    public static func configure(language: AppLanguage) {
        state.setLanguage(language)
        state.clearSystemLanguageCache()
        ensureLocaleObserverRegistered()
    }

    /// 当前语言。
    public static var currentLanguage: AppLanguage { state.language() }

    /// 惰性注册系统语言变更观察者(F8: 锁内双检 token, 只注册一次)。
    /// 系统语言变化 → 失效缓存, 下一次 `t(_:)` 重新解析。
    private static func ensureLocaleObserverRegistered() {
        state.ensureObserver {
            NotificationCenter.default.addObserver(
                forName: NSLocale.currentLocaleDidChangeNotification,
                object: nil,
                queue: .main
            ) { _ in
                L10n.state.clearSystemLanguageCache()
            }
        }
    }

    /// 测试 seam(F11): 手动失效系统语言推断缓存。
    /// 系统首选语言无法在测试中变更, 断言缓存被清空后 `.system` 重新解析
    /// 即可(结果应与重解析前一致)。
    static func invalidateSystemLanguageCacheForTesting() {
        state.clearSystemLanguageCache()
    }

    /// 系统首选语言 → AppLanguage(与旧 `t(_:)` 内联逻辑逐字等价)。
    private static func resolveSystemLanguage() -> AppLanguage {
        let preferred = Locale.preferredLanguages.first ?? ""
        if preferred.hasPrefix("zh-Hant") || preferred.hasPrefix("zh-TW") || preferred.hasPrefix("zh-HK") {
            return .traditionalChinese
        } else if preferred.hasPrefix("zh") {
            return .simplifiedChinese
        } else {
            return .english
        }
    }

    /// 取翻译; 未翻译的 key 回退简体中文。
    public static func t(_ key: Key) -> String {
        ensureLocaleObserverRegistered()
        let effective: AppLanguage
        switch state.language() {
        case .system:
            // F8: 锁内双检——读缓存, miss 则解析并写回, 全程持锁无竞态。
            effective = state.resolvedSystemLanguage { resolveSystemLanguage() }
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

    /// 取带参数翻译。格式字符串统一使用 Foundation 的 %@ 占位符。
    public static func format(_ key: Key, _ arguments: CVarArg...) -> String {
        String(format: t(key), arguments: arguments)
    }

    /// App Library 分类显示名(固定优先级, 见 AppLibraryCategory)。
    public static func categoryTitle(for category: AppLibraryCategory) -> String {
        switch category {
        case .productivity: return t(.categoryProductivity)
        case .social: return t(.categorySocial)
        case .developer: return t(.categoryDeveloper)
        case .entertainment: return t(.categoryEntertainment)
        case .games: return t(.categoryGames)
        case .creativity: return t(.categoryCreativity)
        case .utilities: return t(.categoryUtilities)
        case .education: return t(.categoryEducation)
        case .business: return t(.categoryBusiness)
        case .finance: return t(.categoryFinance)
        case .other: return t(.categoryOther)
        }
    }
}

/// L10n 可变状态的锁隔离容器(F8)。
///
/// 全部可变状态(language / 系统语言推断缓存 / 观察者 token)收进此类,
/// 每个访问点都在 NSLock 临界区内, 后台线程调 t()/configure 不再竞态。
/// `@unchecked Sendable`: 可变性完全由内部锁串行化, 状态不跨临界区暴露
/// (getter 返回值是值类型/只读 token 引用)。
private final class L10nState: @unchecked Sendable {
    private let lock = NSLock()

    private var _language: AppLanguage = .system
    private var _systemLanguageCache: AppLanguage?
    private var _localeChangeObserverToken: NSObjectProtocol?

    func language() -> AppLanguage {
        lock.lock()
        defer { lock.unlock() }
        return _language
    }

    func setLanguage(_ language: AppLanguage) {
        lock.lock()
        defer { lock.unlock() }
        _language = language
    }

    /// 锁内双检的系统语言解析: 命中缓存直接返回; miss 时执行 resolver
    /// 并写回缓存(全程持锁, 无竞态窗口)。
    func resolvedSystemLanguage(resolving resolve: () -> AppLanguage) -> AppLanguage {
        lock.lock()
        defer { lock.unlock() }
        if let cached = _systemLanguageCache {
            return cached
        }
        let resolved = resolve()
        _systemLanguageCache = resolved
        return resolved
    }

    func clearSystemLanguageCache() {
        lock.lock()
        defer { lock.unlock() }
        _systemLanguageCache = nil
    }

    /// 观察者注册双检(锁内): 已注册则 no-op; 否则在锁内执行 factory
    /// 注册并保存 token, 并发调用也只会注册一次。
    func ensureObserver(register factory: () -> NSObjectProtocol) {
        lock.lock()
        defer { lock.unlock() }
        guard _localeChangeObserverToken == nil else { return }
        _localeChangeObserverToken = factory()
    }
}
