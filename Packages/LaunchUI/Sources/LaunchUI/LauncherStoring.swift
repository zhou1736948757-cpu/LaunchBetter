import AppKit
import LaunchCore

/// 图标图像提供协议(MainActor)。
///
/// 由应用层适配器实现(内部调用 LaunchPlatform.IconRepository)。
/// LaunchUI 不依赖 LaunchPlatform(架构约束),只依赖本协议。
/// Sendable: 实现类均为 @MainActor final class(全局 actor 隔离类天然
/// Sendable),协议级声明让 withTaskGroup 发送闭包可强捕获该存在类型。
@MainActor
public protocol IconImageProviding: AnyObject, Sendable {
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

    /// 添加独立数据观察者,不覆盖主网格的 onDataChange 回调。
    @discardableResult
    func addDataObserver(_ observer: @escaping () -> Void) -> UUID

    /// 移除由 addDataObserver 返回的观察者。
    func removeDataObserver(_ token: UUID)

    /// 当前搜索词(由 UI 写入)。
    var searchQuery: String { get set }

    /// 网格列数(布局几何)。
    var gridColumns: Int { get }

    /// 网格行数(布局几何)。
    var gridRows: Int { get }

    /// 图标点尺寸(布局几何; IconKey 请求尺寸真值)。
    var iconSize: Int { get }

    /// 壁纸模糊强度(半径 pt, 0 = 关闭)。
    var wallpaperBlurRadius: Int { get }

    /// 搜索栏宽度(pt，兼容持久值；运行时宽高由 `SearchBarSizing` 统一映射)。
    var searchBarWidth: Int { get }

    /// 显示修订号: 目录/布局/配置/搜索任一变化即递增(无变化跳过 full snapshot)。
    var displayRevision: UInt64 { get }

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

    /// 从文件夹移到主页面显示空间。
    /// completion 在 mutation 被拒绝或持久化失败时回调 false;
    /// 仅在布局缓存与数据通知同步完成后回调 true。
    func moveOutOfFolder(
        app: AppID,
        from folder: FolderID,
        toDisplayIndex: Int,
        completion: @escaping (Bool) -> Void
    )

    /// 在文件夹可见子项中重排。toIndex 是移除源项后的可见 gap 索引。
    func reorderFolderApp(app: AppID, in folder: FolderID, toIndex: Int)

    /// 现有文件夹(名称表, 供上下文菜单)。
    func folderNames() -> [FolderID: String]

    /// 文件夹可见子项(供文件夹视图)。
    func folderChildren(_ id: FolderID) -> [AppID]?

    /// 应用一次拖拽 drop(单次布局变更 + 单次结构更新, §57)。
    func applyDragDrop(_ mutation: LayoutTransaction.LayoutMutation)

    // MARK: - Phase 9 功能

    /// 隐藏/取消隐藏应用(持久配置, 显示过滤)。
    func setHidden(_ appID: AppID, hidden: Bool)

    /// 自定义显示名(持久配置; nil 清除)。
    func setCustomName(_ appID: AppID, name: String?)

    /// 移到废纸篓(卸载)。
    func moveToTrash(_ appID: AppID)

    /// 是否已隐藏。
    func isHidden(_ appID: AppID) -> Bool
}

/// 可回报结构 mutation 最终持久化结果的存储能力。
///
/// 测试替身和只读宿主仍可只实现 `LauncherStoring`;正式存储通过此协议让 UI
/// 仅在磁盘提交成功后确认操作，失败时恢复原视觉而不发布假成功。
@MainActor
public protocol LayoutMutationCompleting: LauncherStoring {
    func createFolder(
        name: String,
        appIDs: [AppID],
        completion: @escaping (Bool) -> Void
    )
    func renameFolder(
        _ id: FolderID,
        to name: String,
        completion: @escaping (Bool) -> Void
    )
    func dissolveFolder(_ id: FolderID, completion: @escaping (Bool) -> Void)
    func addToFolder(
        app: AppID,
        folder: FolderID,
        completion: @escaping (Bool) -> Void
    )
    func reorderFolderApp(
        app: AppID,
        in folder: FolderID,
        toIndex: Int,
        completion: @escaping (Bool) -> Void
    )
    func applyDragDrop(
        _ mutation: LayoutTransaction.LayoutMutation,
        completion: @escaping (Bool) -> Void
    )
}

/// App Library 读模型提供能力(MainActor)。
///
/// 独立于 `LauncherStoring`: Library 表面按需向宿主查询最新模型,
/// 不要求既有 LauncherStoring 测试替身实现额外方法。
/// 由 LauncherStore 实现;LaunchUI 不依赖 LaunchPlatform。
@MainActor
public protocol AppLibraryDataProviding: AnyObject {
    /// 最新 App Library 模型(Store 内存 cache,构建纯内存)。
    func appLibraryModel() -> AppLibraryModel
}

/// App Library 手动分类覆盖能力(MainActor,PA2)。
///
/// 独立于 `AppLibraryDataProviding`(读模型): 写覆盖不触碰 LayoutStore /
/// AppRecord.categoryIdentifier;实现方为 LauncherStore。测试替身按需实现。
@MainActor
public protocol AppLibraryCategoryOverriding: AnyObject {
    /// 当前生效的手动覆盖表(menu 勾选态与"Automatic Classification"判定用)。
    var categoryOverrides: [AppID: AppLibraryCategory] { get }

    /// 设置手动分类覆盖(异步: 复用 metadata snapshot → rebuild model → notify 链路)。
    func setCategoryOverride(appID: AppID, category: AppLibraryCategory) async

    /// 移除手动分类覆盖, 恢复自动分类(异步)。
    func clearCategoryOverride(appID: AppID) async
}
