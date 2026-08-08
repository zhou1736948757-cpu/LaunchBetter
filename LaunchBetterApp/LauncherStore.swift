import AppKit
import Foundation
import LaunchCore
import LaunchPlatform
import LaunchUI

/// 启动器存储(MainActor): 组装 Catalog + Layout + Config → DisplayModel。
///
/// 职责(§65 启动契约):
/// 进程启动 → 读 CatalogSnapshot/LayoutSnapshot(同步,首帧可用)→ 后台 reconcile。
/// 启动器显示不触发任何扫描(§66)。
///
/// 布局: 权威状态在 LayoutStore(actor),本存储持有 MainActor 缓存(§62 模式),
/// 变更经 LayoutStore 应用并持久化,缓存同步后触发 onDataChange。
/// 禁止: 每帧状态(拖拽/动画)进入本存储(§60)。
@MainActor
public final class LauncherStore: LauncherStoring {
    public var onDataChange: (() -> Void)?

    private let catalogActor: AppCatalogActor
    private let layoutStore: LayoutStore
    private var catalogSnapshot: CatalogSnapshot
    private var layout: LayoutSnapshot
    private var config: AppConfiguration
    private var searchIndex = SearchIndex()

    public var searchQuery = "" {
        didSet {
            // 搜索只碰内存索引(§95)
        }
    }

    public var gridColumns: Int { config.gridColumns }
    public var gridRows: Int { config.gridRows }

    public init(
        catalogActor: AppCatalogActor,
        layoutStore: LayoutStore,
        initialSnapshot: CatalogSnapshot,
        initialLayout: LayoutSnapshot,
        settingsStore: SettingsStore
    ) {
        self.catalogActor = catalogActor
        self.layoutStore = layoutStore
        self.catalogSnapshot = initialSnapshot
        self.layout = initialLayout
        self.config = (try? settingsStore.load()) ?? AppConfiguration()

        // 首帧: 用已恢复的快照构建显示模型(同步, 快照加载 < 10ms 目标)
        layout = LayoutReconciler.reconcile(
            catalog: initialSnapshot,
            layout: layout,
            now: Date()
        )
        rebuildSearchIndex()

        // 后台: 正式启动(含损坏恢复)+ 全量对账
        Task { [weak self] in
            await self?.bootstrap()
        }
    }

    private func bootstrap() async {
        _ = await layoutStore.start()
        let result = await catalogActor.start()
        applySnapshot(result.snapshot)
        await reconcileInBackground()
    }

    private func reconcileInBackground() async {
        guard let delta = try? await catalogActor.reconcileFromDisk() else { return }
        if !delta.isEmpty {
            applySnapshot(await catalogActor.currentSnapshot())
        }
    }

    private func applySnapshot(_ snapshot: CatalogSnapshot) {
        catalogSnapshot = snapshot
        let reconciled = LayoutReconciler.reconcile(
            catalog: snapshot,
            layout: layout,
            now: Date()
        )
        if reconciled != layout {
            layout = reconciled
        }
        // 始终向 LayoutStore 同步(store 从自身状态对账, 幂等),
        // 否则 store 内部布局停留在初始种子, 文件夹操作会在空布局上执行
        Task { [weak self] in
            guard let self else { return }
            _ = await layoutStore.reconcile(catalog: snapshot, now: Date())
            refreshLayoutFromStore()
        }
        rebuildSearchIndex()
        onDataChange?()
    }

    private func refreshLayoutFromStore() {
        Task { [weak self] in
            guard let self else { return }
            layout = await layoutStore.currentLayout()
            rebuildSearchIndex()
            onDataChange?()
        }
    }

    /// 执行一次布局变更: 经 LayoutStore 应用并持久化, 同步缓存。
    private func performLayoutMutation(
        _ mutation: LayoutTransaction.LayoutMutation
    ) {
        let display = displayModel()
        Task { [weak self] in
            guard let self else { return }
            if await layoutStore.apply(mutation, display: display) {
                layout = await layoutStore.currentLayout()
                rebuildSearchIndex()
                onDataChange?()
            }
        }
    }

    private func rebuildSearchIndex() {
        searchIndex.removeAll()
        for record in catalogSnapshot.apps {
            searchIndex.index(
                record.id,
                displayName: record.displayName,
                bundleIdentifier: record.bundleIdentifier,
                customName: config.customDisplayNames[record.id]
            )
        }
    }

    // MARK: - LauncherStoring

    public func displayModel() -> DisplayModel {
        DisplayModel(
            catalog: catalogSnapshot,
            layout: layout,
            config: config
        )
    }

    public func searchResults() -> [DisplayModel.DisplayItem]? {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        return searchIndex.query(query).map(DisplayModel.DisplayItem.app)
    }

    public func displayName(for appID: AppID) -> String {
        if let custom = config.customDisplayNames[appID] {
            return custom
        }
        return catalogSnapshot.app(with: appID)?.displayName
            ?? appID.rawValue.lastPathComponent
    }

    public func folderName(for folderID: FolderID) -> String {
        layout.folders[folderID]?.name ?? folderID.rawValue
    }

    public func launch(_ appID: AppID) {
        guard let record = catalogSnapshot.app(with: appID) else { return }
        NSWorkspace.shared.open(record.url)
    }

    // MARK: - 文件夹/布局(Phase 5)

    public func createFolder(name: String, appIDs: [AppID]) {
        guard !appIDs.isEmpty else { return }
        let display = displayModel()
        Task { [weak self] in
            guard let self else { return }
            if await layoutStore.createFolder(display: display, name: name, appIDs: appIDs) != nil {
                layout = await layoutStore.currentLayout()
                rebuildSearchIndex()
                onDataChange?()
            }
        }
    }

    public func renameFolder(_ id: FolderID, to name: String) {
        Task { [weak self] in
            guard let self else { return }
            if await layoutStore.renameFolder(id, to: name) {
                layout = await layoutStore.currentLayout()
                onDataChange?()
            }
        }
    }

    public func dissolveFolder(_ id: FolderID) {
        let display = displayModel()
        Task { [weak self] in
            guard let self else { return }
            if await layoutStore.dissolveFolder(display: display, id: id) {
                layout = await layoutStore.currentLayout()
                rebuildSearchIndex()
                onDataChange?()
            }
        }
    }

    public func addToFolder(app: AppID, folder: FolderID) {
        performLayoutMutation(.addToFolder(app: app, folder: folder, at: Int.max))
    }

    public func folderNames() -> [FolderID: String] {
        Dictionary(uniqueKeysWithValues: layout.folders.map { ($0.key, $0.value.name) })
    }

    public func folderChildren(_ id: FolderID) -> [AppID]? {
        guard let folder = layout.folders[id] else { return nil }
        let missing = Set(layout.missingApps.keys)
        let hidden = Set(config.hiddenAppIDs)
        return folder.children.filter { !missing.contains($0) && !hidden.contains($0) }
    }

    // MARK: - 诊断

    /// 冒烟诊断辅助。
    public func diagnosticCatalogAppCount() -> Int {
        catalogSnapshot.apps.count
    }

    /// 应用图标内容版本(图标缓存身份信号源)。
    public func iconContentVersion(for appID: AppID) -> IconContentVersion {
        catalogSnapshot.app(with: appID)?.iconContentVersion ?? .empty
    }
}

private extension String {
    var lastPathComponent: String {
        (self as NSString).lastPathComponent
    }
}
