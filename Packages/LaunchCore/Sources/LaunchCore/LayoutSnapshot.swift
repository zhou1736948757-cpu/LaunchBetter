import Foundation

/// 布局中的一项: 一个应用或一个文件夹。
public enum LayoutItem: Codable, Sendable, Hashable {
    case app(AppID)
    case folder(FolderID)
}

/// 应用暂时缺失的状态(墓碑)。
///
/// 应用更新期间 bundle 可能短暂消失,禁止立即销毁布局引用。
/// 超过宽限期(默认 30 天)后由 LayoutReconciler 清理。
public struct MissingAppState: Codable, Sendable, Hashable {
    public let missingSince: Date

    public init(missingSince: Date) {
        self.missingSince = missingSince
    }
}

/// 持久化布局快照。
///
/// - `pages`: 分页网格,每页是 [LayoutItem]
/// - `folders`: 文件夹记录
/// - `missingApps`: 墓碑状态(与 Layout 关联的元数据,不是普通 LayoutItem)
///
/// 必须带 schemaVersion,为未来迁移设计。
/// 用户布局是持久用户数据,不是缓存。
public struct LayoutSnapshot: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public var pages: [[LayoutItem]]
    public var folders: [FolderID: FolderRecord]
    public var missingApps: [AppID: MissingAppState]

    public init(
        pages: [[LayoutItem]] = [],
        folders: [FolderID: FolderRecord] = [:],
        missingApps: [AppID: MissingAppState] = [:]
    ) {
        self.schemaVersion = LayoutSnapshot.currentSchemaVersion
        self.pages = pages
        self.folders = folders
        self.missingApps = missingApps
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        pages = try container.decode([[LayoutItem]].self, forKey: .pages)
        folders = try container.decode([FolderID: FolderRecord].self, forKey: .folders)
        missingApps = try container.decode([AppID: MissingAppState].self, forKey: .missingApps)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case pages
        case folders
        case missingApps
    }

    /// 布局中引用的所有 AppID(页面 + 文件夹子项),用于查询。
    public var referencedAppIDs: Set<AppID> {
        var ids = Set<AppID>()
        for page in pages {
            for item in page {
                if case .app(let id) = item {
                    ids.insert(id)
                }
            }
        }
        for folder in folders.values {
            ids.formUnion(folder.children)
        }
        return ids
    }
}
