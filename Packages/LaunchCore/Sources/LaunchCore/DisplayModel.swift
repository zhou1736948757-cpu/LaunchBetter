import Foundation

/// 显示模型: 从 Catalog + Layout + Configuration 派生的实际分页 UI 结构。
///
/// 派生规则(确定性):
/// - 隐藏应用(hiddenAppIDs)与缺失应用(missingApps 墓碑)从显示中过滤
/// - 文件夹显示其可见子项;无可见子项的文件夹从显示中隐藏(布局保留,
///   是否解散由 LayoutReconciler 决定)
/// - 过滤后为空的页被丢弃
/// - 页面结构按布局原样保留(不重新分块);拖拽 drop 会按 pageCapacity 归一化
///
/// NSCollectionView 不得假设 Catalog 顺序 == 显示顺序。
/// DisplayModel 是派生值,不作为持久状态。
public struct DisplayModel: Sendable, Equatable {
    public enum DisplayItem: Sendable, Equatable, Hashable {
        case app(AppID)
        case folder(FolderID, visibleChildren: [AppID])
    }

    /// 分页显示结构。
    public let pages: [[DisplayItem]]

    /// 每页槽位容量(列 × 行),用于拖拽索引数学。
    public let pageCapacity: Int

    /// 从 Catalog + Layout + Configuration 派生。
    public init(catalog: CatalogSnapshot, layout: LayoutSnapshot, config: AppConfiguration) {
        let capacity = config.gridColumns * config.gridRows
        self.pageCapacity = max(1, capacity)

        let missing = Set(layout.missingApps.keys)
        let hidden = Set(config.hiddenAppIDs)
        let isInvisible: (AppID) -> Bool = { missing.contains($0) || hidden.contains($0) }

        var derived: [[DisplayItem]] = []
        for page in layout.pages {
            var pageItems: [DisplayItem] = []
            for item in page {
                switch item {
                case .app(let id):
                    if !isInvisible(id) {
                        pageItems.append(.app(id))
                    }
                case .folder(let folderID):
                    guard let folder = layout.folders[folderID] else { continue }
                    let visible = folder.children.filter { !isInvisible($0) }
                    if !visible.isEmpty {
                        pageItems.append(.folder(folderID, visibleChildren: visible))
                    }
                }
            }
            if !pageItems.isEmpty {
                derived.append(pageItems)
            }
        }
        pages = derived
    }

    /// 直构已分页结构(引擎重分块 / 布局恢复 / 测试用)。
    public init(pages: [[DisplayItem]], pageCapacity: Int) {
        self.pages = pages
        self.pageCapacity = max(1, pageCapacity)
    }

    /// 扁平显示槽位。
    public var flatSlots: [DisplayItem] {
        pages.flatMap { $0 }
    }

    /// 可见应用 ID(扁平、显示顺序)。
    public var visibleAppIDs: [AppID] {
        flatSlots.compactMap { slot in
            if case .app(let id) = slot {
                return id
            }
            return nil
        }
    }

    /// 文件夹的可见子项;文件夹不在显示中时返回 nil。
    public func folderVisibleChildren(_ id: FolderID) -> [AppID]? {
        for page in pages {
            for item in page {
                if case .folder(let fid, let children) = item, fid == id {
                    return children
                }
            }
        }
        return nil
    }
}
