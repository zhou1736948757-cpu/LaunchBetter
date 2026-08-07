import AppKit
import LaunchCore

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
}
