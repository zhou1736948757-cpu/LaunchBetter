import AppKit
import Foundation
import LaunchCore
import LaunchPlatform
import LaunchUI

/// 启动器存储(MainActor): 组装 Catalog + Layout + Config → DisplayModel。
///
/// 职责(§65 启动契约):
/// 进程启动 → 读 CatalogSnapshot(同步,首帧可用)→ 后台 reconcile。
/// 启动器显示不触发任何扫描(§66)。
///
/// 后台服务(AppCatalogActor)返回 Sendable 快照,本存储(MainActor)应用(§62)。
/// 禁止: 每帧状态(拖拽/动画)进入本存储(§60)。
@MainActor
public final class LauncherStore: LauncherStoring {
    public var onDataChange: (() -> Void)?

    private let catalogActor: AppCatalogActor
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
        initialSnapshot: CatalogSnapshot,
        settingsStore: SettingsStore
    ) {
        self.catalogActor = catalogActor
        self.catalogSnapshot = initialSnapshot
        self.config = (try? settingsStore.load()) ?? AppConfiguration()
        self.layout = LayoutSnapshot()

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
        layout = LayoutReconciler.reconcile(
            catalog: snapshot,
            layout: layout,
            now: Date()
        )
        rebuildSearchIndex()
        onDataChange?()
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
