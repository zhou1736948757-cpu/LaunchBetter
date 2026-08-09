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
public final class LauncherStore: LauncherStoring, LayoutMutationCompleting, SettingsHandling {
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
    /// FSEvents callbacks are coalesced into one generation-checked drain so
    /// an older async callback cannot publish after a newer catalog snapshot.
    private var externalCatalogRefreshPending = false
    private var externalCatalogRefreshTask: Task<Void, Never>?

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
        // All catalog/layout publication goes through one generation-checked
        // persistence drain. The parameter documents the triggering snapshot;
        // the drain deliberately fetches the actor's newest authoritative value.
        _ = snapshot
        catalogDidChangeExternally()
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

    private func performSerializedLayoutChange(
        _ operation: @escaping @MainActor (DisplayModel, LayoutSnapshot) async -> Bool,
        completion: ((Bool) -> Void)? = nil
    ) {
        let completionGate = LayoutMutationCompletionGate(completion)
        guard !layoutMutationInFlight else {
            completionGate.finish(false)
            return
        }
        layoutMutationInFlight = true
        let display = displayModel()
        let expectedLayout = layout
        Task { [weak self] in
            guard let self else {
                completionGate.finish(false)
                return
            }
            let changed = await operation(display, expectedLayout)
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
        createFolder(name: name, appIDs: appIDs) { _ in }
    }

    public func createFolder(
        name: String,
        appIDs: [AppID],
        completion: @escaping (Bool) -> Void
    ) {
        guard !appIDs.isEmpty else {
            completion(false)
            return
        }
        performSerializedLayoutChange { [layoutStore] display, expectedLayout in
            await layoutStore.createFolder(
                display: display,
                name: name,
                appIDs: appIDs,
                expectedLayout: expectedLayout
            ) != nil
        } completion: { completion($0) }
    }

    public func renameFolder(_ id: FolderID, to name: String) {
        renameFolder(id, to: name) { _ in }
    }

    public func renameFolder(
        _ id: FolderID,
        to name: String,
        completion: @escaping (Bool) -> Void
    ) {
        performSerializedLayoutChange { [layoutStore] _, expectedLayout in
            await layoutStore.renameFolder(id, to: name, expectedLayout: expectedLayout)
        } completion: { completion($0) }
    }

    public func dissolveFolder(_ id: FolderID) {
        dissolveFolder(id) { _ in }
    }

    public func dissolveFolder(_ id: FolderID, completion: @escaping (Bool) -> Void) {
        performSerializedLayoutChange { [layoutStore] display, expectedLayout in
            await layoutStore.dissolveFolder(
                display: display,
                id: id,
                expectedLayout: expectedLayout
            )
        } completion: { completion($0) }
    }

    public func addToFolder(app: AppID, folder: FolderID) {
        addToFolder(app: app, folder: folder) { _ in }
    }

    public func addToFolder(
        app: AppID,
        folder: FolderID,
        completion: @escaping (Bool) -> Void
    ) {
        performSerializedLayoutChange(
            { [layoutStore] display, expectedLayout in
                await layoutStore.apply(
                    .addToFolder(app: app, folder: folder, at: Int.max),
                    display: display,
                    expectedLayout: expectedLayout
                )
            },
            completion: completion
        )
    }

    public func moveOutOfFolder(
        app: AppID,
        from folder: FolderID,
        toDisplayIndex: Int,
        completion: @escaping (Bool) -> Void
    ) {
        performSerializedLayoutChange(
            { [layoutStore] display, expectedLayout in
                await layoutStore.apply(
                    .moveOutOfFolder(app: app, from: folder, toDisplayIndex: toDisplayIndex),
                    display: display,
                    expectedLayout: expectedLayout
                )
            },
            completion: completion
        )
    }

    public func reorderFolderApp(app: AppID, in folder: FolderID, toIndex: Int) {
        reorderFolderApp(app: app, in: folder, toIndex: toIndex) { _ in }
    }

    public func reorderFolderApp(
        app: AppID,
        in folder: FolderID,
        toIndex: Int,
        completion: @escaping (Bool) -> Void
    ) {
        performSerializedLayoutChange(
            { [layoutStore] display, expectedLayout in
                await layoutStore.apply(
                    .reorderInFolder(app: app, folder: folder, toIndex: toIndex),
                    display: display,
                    expectedLayout: expectedLayout
                )
            },
            completion: completion
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
        applyDragDrop(mutation) { _ in }
    }

    public func applyDragDrop(
        _ mutation: LayoutTransaction.LayoutMutation,
        completion: @escaping (Bool) -> Void
    ) {
        performSerializedLayoutChange(
            { [layoutStore] display, expectedLayout in
                await layoutStore.apply(
                    mutation,
                    display: display,
                    expectedLayout: expectedLayout
                )
            },
            completion: completion
        )
    }

    /// 外部目录变化(FSEvents)后调用: 拉取最新目录快照 → 布局对账(新应用/墓碑)→ 刷新。
    public func catalogDidChangeExternally() {
        externalCatalogRefreshPending = true
        guard externalCatalogRefreshTask == nil else { return }
        externalCatalogRefreshTask = Task { [weak self] in
            await self?.drainExternalCatalogRefreshes()
        }
    }

    private func drainExternalCatalogRefreshes() async {
        while externalCatalogRefreshPending {
            externalCatalogRefreshPending = false
            let generation = await catalogActor.snapshotGeneration()
            guard let snapshot = await catalogActor.currentSnapshot(ifGeneration: generation) else {
                externalCatalogRefreshPending = true
                continue
            }
            let result = await layoutStore.reconcileWithResult(catalog: snapshot, now: Date())
            guard result.committed else {
                // Do not publish a catalog whose required tombstone/layout update
                // failed to persist. Keep a bounded-backoff retry alive even if
                // no later filesystem callback arrives.
                externalCatalogRefreshPending = true
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    break
                }
                continue
            }
            guard await catalogActor.currentSnapshot(ifGeneration: generation) != nil else {
                // A newer catalog arrived during layout persistence. Loop once more
                // before publishing so the final disk/UI state is current.
                externalCatalogRefreshPending = true
                continue
            }
            catalogSnapshot = snapshot
            layout = result.layout
            rebuildSearchIndex()
            bumpRevision()
            notifyDataChange()
        }
        externalCatalogRefreshTask = nil
        // No await occurs between the loop condition and clearing the task, but
        // keep this defensive restart if future code introduces one.
        if externalCatalogRefreshPending {
            catalogDidChangeExternally()
        }
    }

    // MARK: - SettingsHandling

    public func save(_ config: AppConfiguration) {
        // 仅自定义显示名变化时重建搜索索引(§47-48);
        // gridRows/columns/iconSize/wallpaper/hotkey/hotcorner/hidden 等不重建。
        let searchMetadataChanged = config.customDisplayNames != self.config.customDisplayNames
        do {
            try settingsStore.save(config)
        } catch {
            print("CONFIG save error: \(error)")
            return
        }
        self.config = config
        L10n.configure(language: config.language)
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
