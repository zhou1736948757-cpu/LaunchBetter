import Foundation

/// 用户界面语言偏好。
public enum AppLanguage: String, Codable, Sendable, Hashable {
    case system
    case english
    case simplifiedChinese
    case traditionalChinese
}

/// 应用配置(持久用户数据,非缓存)。
///
/// 包含显示/行为偏好,与 Catalog(存在哪些应用)、Layout(如何排列)严格分离。
public struct AppConfiguration: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int

    /// 网格列数
    public var gridColumns: Int

    /// 网格行数(与列数共同决定每页容量)
    public var gridRows: Int

    /// 图标点尺寸
    public var iconSize: Int

    /// 是否显示图标标签
    public var showIconLabels: Bool

    /// 自定义应用源目录
    public var customSourceDirectories: [String]

    /// 隐藏应用(显示过滤器,不从 Catalog 删除)
    public var hiddenAppIDs: [AppID]

    /// 自定义显示名
    public var customDisplayNames: [AppID: String]

    /// 语言偏好
    public var language: AppLanguage

    /// 全局热键
    public var hotkey: HotkeyConfig

    /// 热角
    public var hotCorner: HotCornerConfig

    public init(
        gridColumns: Int = 7,
        gridRows: Int = 6,
        iconSize: Int = 80,
        showIconLabels: Bool = true,
        customSourceDirectories: [String] = [],
        hiddenAppIDs: [AppID] = [],
        customDisplayNames: [AppID: String] = [:],
        language: AppLanguage = .system,
        hotkey: HotkeyConfig = HotkeyConfig(),
        hotCorner: HotCornerConfig = HotCornerConfig()
    ) {
        self.schemaVersion = AppConfiguration.currentSchemaVersion
        self.gridColumns = gridColumns
        self.gridRows = gridRows
        self.iconSize = iconSize
        self.showIconLabels = showIconLabels
        self.customSourceDirectories = customSourceDirectories
        self.hiddenAppIDs = hiddenAppIDs
        self.customDisplayNames = customDisplayNames
        self.language = language
        self.hotkey = hotkey
        self.hotCorner = hotCorner
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        gridColumns = try container.decodeIfPresent(Int.self, forKey: .gridColumns) ?? 7
        gridRows = try container.decodeIfPresent(Int.self, forKey: .gridRows) ?? 6
        iconSize = try container.decodeIfPresent(Int.self, forKey: .iconSize) ?? 80
        showIconLabels = try container.decodeIfPresent(Bool.self, forKey: .showIconLabels) ?? true
        customSourceDirectories = try container.decodeIfPresent(
            [String].self, forKey: .customSourceDirectories
        ) ?? []
        hiddenAppIDs = try container.decodeIfPresent([AppID].self, forKey: .hiddenAppIDs) ?? []
        customDisplayNames = try container.decodeIfPresent(
            [AppID: String].self, forKey: .customDisplayNames
        ) ?? [:]
        language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        hotkey = try container.decodeIfPresent(HotkeyConfig.self, forKey: .hotkey) ?? HotkeyConfig()
        hotCorner = try container.decodeIfPresent(
            HotCornerConfig.self, forKey: .hotCorner
        ) ?? HotCornerConfig()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case gridColumns
        case gridRows
        case iconSize
        case showIconLabels
        case customSourceDirectories
        case hiddenAppIDs
        case customDisplayNames
        case language
        case hotkey
        case hotCorner
    }
}

/// 修饰键集合。
public struct HotkeyModifiers: Codable, Sendable, Hashable, OptionSet {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let command = HotkeyModifiers(rawValue: 1 << 0)
    public static let control = HotkeyModifiers(rawValue: 1 << 1)
    public static let option = HotkeyModifiers(rawValue: 1 << 2)
    public static let shift = HotkeyModifiers(rawValue: 1 << 3)
}

/// 全局热键配置。
public struct HotkeyConfig: Codable, Sendable, Hashable {
    public var enabled: Bool

    /// Carbon 键码(与旧版热键行为兼容的输入格式)
    public var keyCode: UInt32

    public var modifiers: HotkeyModifiers

    public init(
        enabled: Bool = false,
        keyCode: UInt32 = 37,
        modifiers: HotkeyModifiers = [.command]
    ) {
        self.enabled = enabled
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// 热角动作(String 编码, 可读持久化)。
public enum HotCornerAction: String, Codable, Sendable, Hashable {
    case none
    case showLauncher
    case hideLauncher
    case toggleLauncher
}

/// 四角热角配置。
public struct HotCornerConfig: Codable, Sendable, Hashable {
    public var topLeft: HotCornerAction
    public var topRight: HotCornerAction
    public var bottomLeft: HotCornerAction
    public var bottomRight: HotCornerAction

    public init(
        topLeft: HotCornerAction = .none,
        topRight: HotCornerAction = .none,
        bottomLeft: HotCornerAction = .none,
        bottomRight: HotCornerAction = .none
    ) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
    }
}
