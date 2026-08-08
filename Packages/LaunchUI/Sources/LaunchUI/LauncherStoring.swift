import AppKit
import LaunchCore

/// 图标图像提供协议(MainActor)。
///
/// 由应用层适配器实现(内部调用 LaunchPlatform.IconRepository)。
/// LaunchUI 不依赖 LaunchPlatform(架构约束),只依赖本协议。
@MainActor
public protocol IconImageProviding: AnyObject {
    /// 返回应用图标(按 IconKey 变体: 尺寸/缩放/内容版本)。
    /// nil = 暂无可用图标(单元格保留占位)。
    func icon(for appID: AppID, pointSize: Int, scale: Int) async -> CGImage?

    /// 启动器隐藏时裁剪低优先级图标(保留最近使用)。
    func trimMemoryForHidden()
}

/// 启动器数据存储协议(MainActor)。
///
/// 由应用层 LauncherStore 实现: 持有 Catalog/Layout/Config 组合出的显示状态。
/// UI 层只依赖此协议,不依赖具体存储实现。
@MainActor
public protocol LauncherStoring: AnyObject {
    /// 数据变化回调(UI 刷新入口)。
    var onDataChange: (() -> Void)? { get set }

    /// 当前搜索词(由 UI 写入)。
    var searchQuery: String { get set }

    /// 网格列数(布局几何)。
    var gridColumns: Int { get }

    /// 网格行数(布局几何)。
    var gridRows: Int { get }

    /// 当前分页显示模型。
    func displayModel() -> DisplayModel

    /// 搜索结果(搜索词非空时返回)。
    func searchResults() -> [DisplayModel.DisplayItem]?

    /// 应用显示名(占位图标与标签用)。
    func displayName(for appID: AppID) -> String

    /// 文件夹名称。
    func folderName(for folderID: FolderID) -> String

    /// 启动应用。
    func launch(_ appID: AppID)

    // MARK: - 文件夹/布局(Phase 5)

    /// 创建文件夹(合并给定应用), 完成后触发 onDataChange。
    func createFolder(name: String, appIDs: [AppID])

    /// 重命名文件夹。
    func renameFolder(_ id: FolderID, to name: String)

    /// 解散文件夹(children 回到页面)。
    func dissolveFolder(_ id: FolderID)

    /// 把应用加入文件夹。
    func addToFolder(app: AppID, folder: FolderID)

    /// 现有文件夹(名称表, 供上下文菜单)。
    func folderNames() -> [FolderID: String]

    /// 文件夹可见子项(供文件夹视图)。
    func folderChildren(_ id: FolderID) -> [AppID]?
}
