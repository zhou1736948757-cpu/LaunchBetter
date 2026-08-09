import AppKit
import Foundation
import LaunchCore
import LaunchPlatform
import LaunchUI

@MainActor
private final class LayoutMutationCompletionGate {
    private let completion: ((Bool) -> Void)?
    private var didComplete = false

    init(_ completion: ((Bool) -> Void)?) {
        self.completion = completion
    }

    func finish(_ result: Bool) {
        guard !didComplete else { return }
        didComplete = true
        completion?(result)
    }
}

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
public final class LauncherStore: LauncherStoring, SettingsHandling {
    public var onDataChange: (() -> Void)?
    private var dataObservers: [UUID: () -> Void] = [:]

    /// 配置变更回调(热键/语言/热角即时生效接线)。
    public var onConfigChange: ((AppConfiguration) -> Void)?

    private let catalogActor: AppCatalogActor
    private let layoutStore: LayoutStore
    private let settingsStore: SettingsStore
    private var catalogSnapshot: CatalogSnapshot
    private var layout: LayoutSnapshot
    public private(set) var config: AppConfiguration
    private var searchIndex = SearchIndex()
    /// 结构变更一次只允许一个 in-flight，避免旧 display 索引应用到更新后的 actor layout。
    private var layoutMutationInFlight = false

    public var searchQuery = "" {
        didSet {
            // 搜索只碰内存索引(§95); 值未变化不 bump(避免 hide/show 无意义刷新, 评审 M8)
            if searchQuery != oldValue {
                bumpRevision()
            }
        }
    }

    public var gridColumns: Int { config.gridColumns }
    public var gridRows: Int { config.gridRows }
    public var iconSize: Int { config.iconSize }

    /// 显示修订号: 目录/布局/配置/搜索任一变化即递增(Stage 1 §30)。
    public private(set) var displayRevision: UInt64 = 0

    /// 诊断(§65-66): 搜索索引重建次数 / onDataChange 通知次数。
    public private(set) var searchIndexRebuildCount = 0
    public private(set) var notifyCount = 0

    private func bumpRevision() {
        displayRevision &+= 1
    }

    private func notifyDataChange() {
        notifyCount += 1
        onDataChange?()
        // 允许文件夹覆盖层订阅而不覆盖 LauncherWindowController 的主网格回调。
        for observer in Array(dataObservers.values) {
            observer()
        }
    }

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
        do {
            self.config = try settingsStore.load() ?? AppConfiguration()
        } catch {
            print("CONFIG load error: \(error)")
            self.config = AppConfiguration()
        }
        self.settingsStore = settingsStore

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
            await self.commitLayoutChange()
        }
        // catalog 变化 → 重建搜索索引(progressive: 首帧即用已恢复快照可搜, §51)
        rebuildSearchIndex()
        bumpRevision()
        notifyDataChange()
    }

    /// 布局变更统一提交(v0.1.6 §49): 一次 currentLayout + 按需 rebuild + revision + notify。
    /// 普通布局变更(reorder/文件夹)不重建 SearchIndex(§47-48)。
    private func commitLayoutChange(
        searchMetadataChanged: Bool = false,
        releaseMutationLock: Bool = false
    ) async {
        layout = await layoutStore.currentLayout()
        if searchMetadataChanged {
            rebuildSearchIndex()
        }
        bumpRevision()
        if releaseMutationLock {
            // 缓存已同步到 actor 最新布局；通知回调现在可以安全提交下一次 mutation。
            layoutMutationInFlight = false
        }
        notifyDataChange()
    }

    /// 执行一次布局变更: 经 LayoutStore 应用并持久化, 同步缓存。
    private func performLayoutMutation(
        _ mutation: LayoutTransaction.LayoutMutation
    ) {
        performSerializedLayoutChange { [layoutStore] display in
            await layoutStore.apply(mutation, display: display)
        }
    }

    private func performSerializedLayoutChange(
        _ operation: @escaping @MainActor (DisplayModel) async -> Bool,
        completion: ((Bool) -> Void)? = nil
    ) {
        let completionGate = LayoutMutationCompletionGate(completion)
        guard !layoutMutationInFlight else {
            completionGate.finish(false)
            return
        }
        layoutMutationInFlight = true
        let display = displayModel()
        Task { [weak self] in
            guard let self else {
                completionGate.finish(false)
                return
            }
            let changed = await operation(display)
            if changed {
                await self.commitLayoutChange(releaseMutationLock: true)
                // commitLayoutChange 已同步缓存、修订号及所有数据观察者。
                completionGate.finish(true)
            } else {
                self.layoutMutationInFlight = false
                completionGate.finish(false)
            }
        }
    }

    private func rebuildSearchIndex() {
        searchIndexRebuildCount += 1
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

    @discardableResult
    public func addDataObserver(_ observer: @escaping () -> Void) -> UUID {
        let token = UUID()
        dataObservers[token] = observer
        return token
    }

    public func removeDataObserver(_ token: UUID) {
        dataObservers.removeValue(forKey: token)
    }

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
        performSerializedLayoutChange { [layoutStore] display in
            await layoutStore.createFolder(
                display: display, name: name, appIDs: appIDs
            ) != nil
        }
    }

    public func renameFolder(_ id: FolderID, to name: String) {
        performSerializedLayoutChange { [layoutStore] _ in
            await layoutStore.renameFolder(id, to: name)
        }
    }

    public func dissolveFolder(_ id: FolderID) {
        performSerializedLayoutChange { [layoutStore] display in
            await layoutStore.dissolveFolder(display: display, id: id)
        }
    }

    public func addToFolder(app: AppID, folder: FolderID) {
        performLayoutMutation(.addToFolder(app: app, folder: folder, at: Int.max))
    }

    public func moveOutOfFolder(
        app: AppID,
        from folder: FolderID,
        toDisplayIndex: Int,
        completion: @escaping (Bool) -> Void
    ) {
        performSerializedLayoutChange(
            { [layoutStore] display in
                await layoutStore.apply(
                    .moveOutOfFolder(app: app, from: folder, toDisplayIndex: toDisplayIndex),
                    display: display
                )
            },
            completion: completion
        )
    }

    public func reorderFolderApp(app: AppID, in folder: FolderID, toIndex: Int) {
        performLayoutMutation(
            .reorderInFolder(app: app, folder: folder, toIndex: toIndex)
        )
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

    public func applyDragDrop(_ mutation: LayoutTransaction.LayoutMutation) {
        performLayoutMutation(mutation)
    }

    /// 外部目录变化(FSEvents)后调用: 拉取最新目录快照 → 布局对账(新应用/墓碑)→ 刷新。
    public func catalogDidChangeExternally() {
        Task { [weak self] in
            guard let self else { return }
            catalogSnapshot = await catalogActor.currentSnapshot()
            layout = await layoutStore.reconcile(catalog: catalogSnapshot, now: Date())
            rebuildSearchIndex()
            bumpRevision()
            notifyDataChange()
        }
    }

    // MARK: - SettingsHandling

    public func save(_ config: AppConfiguration) {
        // 仅自定义显示名变化时重建搜索索引(§47-48);
        // gridRows/columns/iconSize/wallpaper/hotkey/hotcorner/hidden 等不重建。
        let searchMetadataChanged = config.customDisplayNames != self.config.customDisplayNames
        self.config = config
        L10n.configure(language: config.language)
        try? settingsStore.save(config)
        if searchMetadataChanged {
            rebuildSearchIndex()
        }
        bumpRevision()
        onConfigChange?(config)
        notifyDataChange()
    }

    public var allApps: [(id: AppID, name: String)] {
        catalogSnapshot.apps.map { ($0.id, displayName(for: $0.id)) }
    }

    // MARK: - Phase 9 功能

    public func setHidden(_ appID: AppID, hidden: Bool) {
        var newConfig = config
        if hidden {
            if !newConfig.hiddenAppIDs.contains(appID) {
                newConfig.hiddenAppIDs.append(appID)
            }
        } else {
            newConfig.hiddenAppIDs.removeAll { $0 == appID }
        }
        save(newConfig)
    }

    public func setCustomName(_ appID: AppID, name: String?) {
        var newConfig = config
        if let name, !name.isEmpty {
            newConfig.customDisplayNames[appID] = name
        } else {
            newConfig.customDisplayNames.removeValue(forKey: appID)
        }
        save(newConfig)
    }

    public func moveToTrash(_ appID: AppID) {
        guard let record = catalogSnapshot.app(with: appID) else { return }
        NSWorkspace.shared.recycle([record.url]) { _, error in
            if let error {
                print("TRASH failed \(error)")
            }
        }
        // 目录监控(FSEvents)会自动移除; 布局墓碑宽限期保护
    }

    public func isHidden(_ appID: AppID) -> Bool {
        config.hiddenAppIDs.contains(appID)
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
