import Foundation

/// 应用的不可变目录记录。
///
/// 只描述"存在"的事实: 身份、位置、元数据指纹。
/// 禁止放入: NSImage / NSView / CALayer / 页面号 / 选中状态 / 拖拽状态 / 动画进度。
public struct AppRecord: Codable, Sendable, Identifiable, Hashable {
    public let id: AppID
    public let url: URL
    public let bundleIdentifier: String?
    public let displayName: String
    public let infoPlistModificationDate: Date?
    public let iconContentVersion: IconContentVersion
    /// 本地化显示名: locale 标识符 → 名称(在 catalog 扫描/对账时解析,非每次显示)。
    /// 键为 .lproj 目录名(如 "en" / "zh-Hans"),空表示无本地化名。
    public let localizedNames: [String: String]

    public init(
        id: AppID,
        url: URL,
        bundleIdentifier: String?,
        displayName: String,
        infoPlistModificationDate: Date?,
        iconContentVersion: IconContentVersion,
        localizedNames: [String: String] = [:]
    ) {
        self.id = id
        self.url = url
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.infoPlistModificationDate = infoPlistModificationDate
        self.iconContentVersion = iconContentVersion
        self.localizedNames = localizedNames
    }

    /// 向后兼容解码: 旧文件(无 localizedNames 字段)迁移为空字典,不抛错、不销毁旧数据。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(AppID.self, forKey: .id)
        url = try container.decode(URL.self, forKey: .url)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        displayName = try container.decode(String.self, forKey: .displayName)
        infoPlistModificationDate = try container.decodeIfPresent(
            Date.self, forKey: .infoPlistModificationDate
        )
        iconContentVersion = try container.decode(
            IconContentVersion.self, forKey: .iconContentVersion
        )
        localizedNames = try container.decodeIfPresent(
            [String: String].self, forKey: .localizedNames
        ) ?? [:]
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case url
        case bundleIdentifier
        case displayName
        case infoPlistModificationDate
        case iconContentVersion
        case localizedNames
    }

    /// 按语言偏好解析本地化显示名(纯逻辑,无文件系统访问)。
    ///
    /// 匹配顺序(确定性): 候选 locale 精确匹配 → 前缀匹配(如 "zh-Hans" 命中 "zh-Hans-CN")
    /// → 按 key 排序取首个。无匹配返回 nil,调用方回退 `displayName`。
    /// `language` 为 `.system` 时按系统首选语言推断(与 L10n 一致的 zh-Hans/zh-Hant/en 划分)。
    ///
    /// 语言代码规范化(v0.3.3, 系统性): 不同 bundle 的 lproj 目录名可能用旧格式
    /// `zh_CN` / `zh_TW`(下划线)或区域后缀 `zh-CN` / `zh-Hans-CN`; 统一归一到
    /// `zh-Hans` / `zh-Hant` 族后匹配 —— 修复"百度网盘/微信等显示英文名"的系统性问题。
    public func localizedDisplayName(
        language: AppLanguage,
        systemPreferredLanguages: [String]
    ) -> String? {
        guard !localizedNames.isEmpty else { return nil }
        let candidates = Self.localizationCandidates(
            language: language,
            systemPreferredLanguages: systemPreferredLanguages
        )
        // 归一化字典: 旧格式/区域格式键 → 语言族(冲突时保留首个, 确定性)。
        var normalized: [String: String] = [:]
        for (key, name) in localizedNames {
            let nk = Self.normalizeLocale(key)
            if normalized[nk] == nil {
                normalized[nk] = name
            }
        }
        for candidate in candidates {
            let nc = Self.normalizeLocale(candidate)
            if let exact = normalized[nc] {
                return exact
            }
            if let prefixed = normalized.keys
                .filter({ $0.hasPrefix(nc + "-") })
                .sorted()
                .first,
                let name = normalized[prefixed] {
                return name
            }
        }
        return nil
    }

    /// 语言代码规范化: 把旧格式/区域格式归一到语言族。
    /// - `zh` / `zh_CN` / `zh-CN` / `zh-Hans*` → `zh-Hans`
    /// - `zh_TW` / `zh-TW` / `zh_HK` / `zh-HK` / `zh-Hant*` → `zh-Hant`
    /// - 其余原样(如 `en`、`ja`、`fr`)。
    static func normalizeLocale(_ key: String) -> String {
        let lower = key.lowercased()
        if lower == "zh" || lower.hasPrefix("zh_cn") || lower.hasPrefix("zh-cn")
            || lower.hasPrefix("zh-hans") || lower == "zhhans" {
            return "zh-Hans"
        }
        if lower.hasPrefix("zh_tw") || lower.hasPrefix("zh-tw") || lower.hasPrefix("zh_hk")
            || lower.hasPrefix("zh-hk") || lower.hasPrefix("zh-hant") || lower == "zhtw"
            || lower == "zhhk" || lower == "zhtw" {
            return "zh-Hant"
        }
        return key
    }

    /// 语言偏好的候选 locale 列表(按优先级)。
    private static func localizationCandidates(
        language: AppLanguage,
        systemPreferredLanguages: [String]
    ) -> [String] {
        let effective: AppLanguage
        switch language {
        case .system:
            let preferred = systemPreferredLanguages.first ?? ""
            if preferred.hasPrefix("zh-Hant")
                || preferred.hasPrefix("zh-TW")
                || preferred.hasPrefix("zh-HK") {
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
            return ["zh-Hans", "zh", "zh-CN"]
        case .traditionalChinese:
            return ["zh-Hant", "zh-TW", "zh-HK"]
        case .english:
            return ["en"]
        }
    }
}
