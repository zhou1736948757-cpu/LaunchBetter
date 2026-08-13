/// 目录快照: 当前"存在哪些应用"。
///
/// 不变式: `apps` 按 `id.rawValue` 排序,保证确定性遍历。
/// 这是持久用户状态(Catalog),不是缓存;必须带 schemaVersion。
public struct CatalogSnapshot: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 3

    public let schemaVersion: Int
    public let apps: [AppRecord]

    public init(apps: [AppRecord]) {
        self.schemaVersion = CatalogSnapshot.currentSchemaVersion
        self.apps = apps.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let decoded = try container.decode([AppRecord].self, forKey: .apps)
        apps = decoded.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case apps
    }

    public func contains(_ id: AppID) -> Bool {
        apps.contains { $0.id == id }
    }

    public func app(with id: AppID) -> AppRecord? {
        apps.first { $0.id == id }
    }
}

/// 目录增量变化。
///
/// 禁止每次变化就替换整个应用全集;增量是默认路径,全量对账只是恢复手段。
public struct CatalogDelta: Codable, Sendable, Hashable {
    public let inserted: [AppRecord]
    public let updated: [AppRecord]
    public let removed: [AppID]

    public init(
        inserted: [AppRecord] = [],
        updated: [AppRecord] = [],
        removed: [AppID] = []
    ) {
        self.inserted = inserted
        self.updated = updated
        self.removed = removed
    }

    public var isEmpty: Bool {
        inserted.isEmpty && updated.isEmpty && removed.isEmpty
    }

    /// 合并两个增量(按 AppID 去重, 确定性排序)。
    public func merged(with other: CatalogDelta) -> CatalogDelta {
        var insertedIDs = Set(inserted.map(\.id))
        var mergedInserted = inserted
        for record in other.inserted where !insertedIDs.contains(record.id) {
            mergedInserted.append(record)
            insertedIDs.insert(record.id)
        }
        var updatedIDs = Set(updated.map(\.id))
        var mergedUpdated = updated
        for record in other.updated where !updatedIDs.contains(record.id) {
            mergedUpdated.append(record)
            updatedIDs.insert(record.id)
        }
        let mergedRemoved = Array(Set(removed).union(other.removed))
            .sorted { $0.rawValue < $1.rawValue }
        return CatalogDelta(
            inserted: mergedInserted.sorted { $0.id.rawValue < $1.id.rawValue },
            updated: mergedUpdated.sorted { $0.id.rawValue < $1.id.rawValue },
            removed: mergedRemoved
        )
    }
}
