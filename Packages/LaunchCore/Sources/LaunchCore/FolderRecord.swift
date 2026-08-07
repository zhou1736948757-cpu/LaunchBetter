/// 文件夹记录(布局的一部分)。
///
/// 文件夹是纯布局概念: 不持有 AppRecord 对象,只持有 AppID。
/// `children` 保持插入顺序。
public struct FolderRecord: Codable, Sendable, Hashable {
    public let id: FolderID
    public var name: String
    public var children: [AppID]

    public init(id: FolderID, name: String, children: [AppID] = []) {
        self.id = id
        self.name = name
        self.children = children
    }
}
