import Foundation
import LaunchCore

/// 布局存储(actor): 持有 LayoutSnapshot 状态,应用布局变更并持久化。
///
/// 职责:
/// - 启动: 加载磁盘快照(损坏备份后空布局,不静默清除)
/// - 变更: 应用 LayoutMutation / 文件夹操作(经 LayoutEditor 纯逻辑),
///   每次变更原子持久化
/// - 对账: 与 Catalog 对账(新应用追加/墓碑/回归),持久化结果
///
/// 禁止: 每帧状态进入本存储(§60);本 actor 只承载结构变更。
public actor LayoutStore {
    public struct StartResult: Sendable, Equatable {
        public let loadedFromDisk: Bool
        public let recoveredFromCorruption: Bool
        public let layout: LayoutSnapshot

        public init(loadedFromDisk: Bool, recoveredFromCorruption: Bool, layout: LayoutSnapshot) {
            self.loadedFromDisk = loadedFromDisk
            self.recoveredFromCorruption = recoveredFromCorruption
            self.layout = layout
        }
    }

    private let persistence: LayoutSnapshotStore
    private var layout: LayoutSnapshot
    /// 最近一次持久化失败描述(nil = 正常);持久化失败不阻断内存操作。
    public private(set) var lastPersistErrorDescription: String?

    public init(seed: LayoutSnapshot = LayoutSnapshot(), persistence: LayoutSnapshotStore) {
        self.layout = seed
        self.persistence = persistence
    }

    /// 启动: 加载磁盘快照(磁盘存在则权威)。损坏时备份并保留种子布局;缺失时保留种子布局。
    public func start() -> StartResult {
        do {
            if let loaded = try persistence.load() {
                layout = loaded
                return StartResult(loadedFromDisk: true, recoveredFromCorruption: false, layout: loaded)
            }
        } catch {
            let backedUp = (try? persistence.backupCorruptedFile()) != nil
            lastPersistErrorDescription = backedUp ? "corrupted layout backed up" : "corruption backup failed"
            return StartResult(loadedFromDisk: false, recoveredFromCorruption: backedUp, layout: layout)
        }
        return StartResult(loadedFromDisk: false, recoveredFromCorruption: false, layout: layout)
    }

    /// 当前布局。
    public func currentLayout() -> LayoutSnapshot {
        layout
    }

    /// 与 Catalog 对账(新应用/墓碑/回归),并持久化。
    public func reconcile(catalog: CatalogSnapshot, now: Date) -> LayoutSnapshot {
        layout = LayoutReconciler.reconcile(catalog: catalog, layout: layout, now: now)
        persist()
        return layout
    }

    /// 应用一个布局变更(显示空间 → 布局空间)。无效返回 false,状态不变。
    public func apply(
        _ mutation: LayoutTransaction.LayoutMutation,
        display: DisplayModel
    ) -> Bool {
        guard let result = LayoutEditor.apply(mutation, to: layout, display: display) else {
            return false
        }
        layout = result
        persist()
        return true
    }

    /// 创建文件夹(合并 ≥1 个应用)。返回新 FolderID,nil = 无效。
    public func createFolder(
        display: DisplayModel,
        name: String,
        appIDs: [AppID]
    ) -> FolderID? {
        guard let result = LayoutEditor.createFolder(
            in: layout, display: display, name: name, appIDs: appIDs
        ) else {
            return nil
        }
        layout = result.layout
        persist()
        return result.folderID
    }

    /// 解散文件夹(children 插回原显示位置)。
    public func dissolveFolder(display: DisplayModel, id: FolderID) -> Bool {
        guard let result = LayoutEditor.dissolveFolder(in: layout, display: display, id: id) else {
            return false
        }
        layout = result
        persist()
        return true
    }

    /// 重命名文件夹。
    public func renameFolder(_ id: FolderID, to newName: String) -> Bool {
        guard let result = LayoutEditor.apply(
            .renameFolder(id, newName: newName), to: layout, display: currentDisplayPlaceholder()
        ) else {
            return false
        }
        layout = result
        persist()
        return true
    }

    private func currentDisplayPlaceholder() -> DisplayModel {
        DisplayModel(pages: [], pageCapacity: 42)
    }

    private func persist() {
        do {
            try persistence.save(layout)
            lastPersistErrorDescription = nil
        } catch {
            lastPersistErrorDescription = String(describing: error)
        }
    }
}
