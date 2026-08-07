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

    public init(
        id: AppID,
        url: URL,
        bundleIdentifier: String?,
        displayName: String,
        infoPlistModificationDate: Date?,
        iconContentVersion: IconContentVersion
    ) {
        self.id = id
        self.url = url
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.infoPlistModificationDate = infoPlistModificationDate
        self.iconContentVersion = iconContentVersion
    }
}
