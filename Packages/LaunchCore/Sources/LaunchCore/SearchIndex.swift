import Foundation

/// 内存搜索索引(纯逻辑,无文件系统访问)。
///
/// 索引字段: displayName / bundleIdentifier / customName。
/// 查询只碰内存,0 文件系统扫描 / 0 Info.plist IO / 0 图标重扫。
///
/// 匹配规则: 任一字段大小写不敏感、变音符不敏感地包含查询词。
/// 结果按 AppID 排序,保证确定性。
public struct SearchIndex: Sendable {
    private var entries: [AppID: [String]]

    public init() {
        entries = [:]
    }

    /// 为应用建立索引。customName 非 nil 时作为额外字段。
    public mutating func index(
        _ app: AppID,
        displayName: String,
        bundleIdentifier: String?,
        customName: String?
    ) {
        var fields = [displayName]
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            fields.append(bundleIdentifier)
        }
        if let customName, !customName.isEmpty {
            fields.append(customName)
        }
        entries[app] = fields
    }

    /// 移除应用索引。
    public mutating func remove(_ app: AppID) {
        entries.removeValue(forKey: app)
    }

    /// 清空索引。
    public mutating func removeAll() {
        entries.removeAll()
    }

    /// 查询。空查询返回全部已索引 AppID(排序)。
    public func query(_ text: String) -> [AppID] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return entries.keys.sorted { $0.rawValue < $1.rawValue }
        }
        return entries
            .filter { _, fields in
                fields.contains { field in
                    field.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }
            }
            .keys
            .sorted { $0.rawValue < $1.rawValue }
    }

    /// 已索引应用数。
    public var count: Int {
        entries.count
    }
}
