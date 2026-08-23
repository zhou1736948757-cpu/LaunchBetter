import Foundation
import LaunchCore

/// 应用目录服务(actor)。
///
/// 职责: 启动恢复磁盘快照 → 后台全量对账 → 产出 CatalogDelta → 持久化。
///
/// 启动契约(主提示 §65):
/// 进程启动 → 读 CatalogSnapshot → 构建 DisplayModel → 可用 → 后台 reconcile。
/// 禁止: 启动时递归扫全盘再显示 UI。
///
/// 陈旧结果防护(§64): `snapshotGeneration()` + `currentSnapshot(ifGeneration:)`
/// 供 UI 消费方校验,防止旧对账结果覆盖新状态。
public actor AppCatalogActor {
    public struct StartResult: Sendable, Equatable {
        /// 是否成功从磁盘恢复快照
        public let loadedFromDisk: Bool
        /// 磁盘快照损坏且已备份(不静默清除)
        public let recoveredFromCorruption: Bool
        /// 恢复的快照(损坏时为空快照)
        public let snapshot: CatalogSnapshot

        public init(
            loadedFromDisk: Bool,
            recoveredFromCorruption: Bool,
            snapshot: CatalogSnapshot
        ) {
            self.loadedFromDisk = loadedFromDisk
            self.recoveredFromCorruption = recoveredFromCorruption
            self.snapshot = snapshot
        }
    }

    private let store: CatalogSnapshotStore
    /// 当前源集合(规范化 + 去重)。设置中自定义源增删后经 `updateSources` 动态更新。
    private var sources: [URL]
    /// 发现闭包: 第二参数为上次快照的 knownRecords(按 AppID 索引),
    /// 供 AppDiscoveryService 在 Info.plist 未变时复用本地化名(跳过 lproj 重读)。
    private let discoverSources: @Sendable ([URL], [AppID: AppRecord]) -> [AppRecord]
    private let discoverAppRoot: @Sendable (URL) -> AppRecord?

    private var snapshot: CatalogSnapshot
    private var generation: Int = 0
    /// 源集合代数: 每次 sources 实际变更(即使无应用 delta)递增。
    /// 独立于 snapshot generation: 防旧源集合的并发全量扫描在重配后提交(M3)。
    private var sourceGeneration: UInt64 = 0
    /// Incremental scans are globally ordered. Actor reentrancy around detached
    /// filesystem work must not allow an older event to commit after a newer one.
    private var incrementalTail: Task<CatalogDelta, Never>?
    private var incrementalRequestSequence: UInt64 = 0

    /// 最近一次持久化失败描述(nil = 正常)。持久化失败不阻断对账流程。
    public private(set) var lastPersistErrorDescription: String?

    public init(
        store: CatalogSnapshotStore,
        sources: [URL],
        discoverSources: @escaping @Sendable ([URL], [AppID: AppRecord]) -> [AppRecord] = { urls, known in
            AppDiscoveryService.discover(sources: urls, knownRecords: known)
        },
        discoverAppRoot: @escaping @Sendable (URL) -> AppRecord? = {
            AppDiscoveryService.makeRecord(from: $0)
        }
    ) {
        self.store = store
        self.sources = Self.normalizedSources(sources)
        self.discoverSources = discoverSources
        self.discoverAppRoot = discoverAppRoot
        self.snapshot = CatalogSnapshot(apps: [])
    }

    /// 兼容重载(FX-C F6): 旧调用方传一参 discoverSources。内部包装为二参形式,
    /// 第二参数(knownRecords)恒空 —— 旧调用方不参与 plist-unchanged 复用优化。
    /// 注意: 本重载的 discoverSources 不给默认值,避免与上方新签名 init 的默认参数歧义。
    public init(
        store: CatalogSnapshotStore,
        sources: [URL],
        discoverSources: @escaping @Sendable ([URL]) -> [AppRecord],
        discoverAppRoot: @escaping @Sendable (URL) -> AppRecord? = {
            AppDiscoveryService.makeRecord(from: $0)
        }
    ) {
        let legacy = discoverSources
        self.store = store
        self.sources = Self.normalizedSources(sources)
        self.discoverSources = { urls, _ in legacy(urls) }
        self.discoverAppRoot = discoverAppRoot
        self.snapshot = CatalogSnapshot(apps: [])
    }

    /// 启动: 加载磁盘快照。损坏时备份并继续(空快照),绝不静默清除。
    ///
    /// `seed` 非 nil 时直接采纳(调用方已同步读过同一磁盘文件, PA1 去重);
    /// nil = 保留原读盘/损坏恢复路径。
    public func start(seed: CatalogSnapshot? = nil) async -> StartResult {
        if let seed {
            snapshot = seed
            generation += 1
            return StartResult(
                loadedFromDisk: true,
                recoveredFromCorruption: false,
                snapshot: seed
            )
        }
        do {
            if let loaded = try store.load() {
                snapshot = loaded
                generation += 1
                return StartResult(
                    loadedFromDisk: true,
                    recoveredFromCorruption: false,
                    snapshot: loaded
                )
            }
        } catch {
            let backupError = try? store.backupCorruptedFile()
            lastPersistErrorDescription = backupError == nil
                ? "corruption backup failed"
                : "corrupted snapshot backed up"
        }
        snapshot = CatalogSnapshot(apps: [])
        generation += 1
        return StartResult(
            loadedFromDisk: false,
            recoveredFromCorruption: lastPersistErrorDescription != nil,
            snapshot: snapshot
        )
    }

    /// 当前快照。
    public func currentSnapshot() async -> CatalogSnapshot {
        snapshot
    }

    /// 当前代数;消费方缓存此值以检测陈旧结果。
    public func snapshotGeneration() async -> Int {
        generation
    }

    /// 仅当代数匹配时返回快照,否则 nil(陈旧防护契约)。
    public func currentSnapshot(ifGeneration expected: Int) async -> CatalogSnapshot? {
        generation == expected ? snapshot : nil
    }

    /// 当前源集合(规范化 + 去重后)。
    public func currentSources() async -> [URL] {
        sources
    }

    /// 后台全量对账: 枚举磁盘 → 计算增量 → 更新快照 → 原子持久化。
    /// 枚举在后台执行器进行,不阻塞 actor。
    public func reconcileFromDisk() async throws -> CatalogDelta {
        while true {
            let capturedSources = sources
            let capturedGeneration = generation
            let capturedSourceGeneration = sourceGeneration
            let known = Dictionary(uniqueKeysWithValues: snapshot.apps.map { ($0.id, $0) })
            let discoverSources = discoverSources
            let discovered = Self.deduplicated(
                await Task.detached(priority: .utility) {
                    discoverSources(capturedSources, known)
                }.value
            )

            // Actor may process an incremental FSEvent or a source update while
            // detached discovery is running. Rescan against that newer state
            // instead of dropping the full reconciliation and permanently
            // missing changes. Source-only updates bump sourceGeneration even
            // when they carry no app delta, so a stale-source scan cannot commit.
            guard generation == capturedGeneration,
                  sourceGeneration == capturedSourceGeneration else { continue }

            let delta = ReconcileEngine.delta(from: snapshot, to: discovered)
            snapshot = CatalogSnapshot(apps: discovered)
            generation += 1

            do {
                try store.save(snapshot)
                lastPersistErrorDescription = nil
            } catch {
                lastPersistErrorDescription = String(describing: error)
            }
            return delta
        }
    }

    // MARK: - 动态源集合(Stage B §B2)

    /// 更新源集合(设置中自定义源增删后调用)。
    ///
    /// 生命周期契约(§B2): 保留 generation 防陈旧 + durable-before-publish。
    /// - 新增源: 增量枚举该目录(不覆盖其余源应用状态)
    /// - 移除源: 移除该源直接枚举的应用(嵌套/其余源仍枚举的应用保留, 防重叠误删与幽灵项)
    /// - 规范化 + 去重(与默认源、自定义源互相去重; 重叠不产生重复 AppID)
    public func updateSources(_ newSources: [URL]) async -> CatalogDelta {
        let normalized = Self.normalizedSources(newSources)
        guard normalized != sources else { return CatalogDelta() }

        incrementalRequestSequence &+= 1
        let request = incrementalRequestSequence
        let previous = incrementalTail
        let task = Task { [weak self] () -> CatalogDelta in
            _ = await previous?.value
            guard let self else { return CatalogDelta() }
            return await self.performUpdateSources(newSources: normalized)
        }
        incrementalTail = task
        let result = await task.value
        if request == incrementalRequestSequence {
            incrementalTail = nil
        }
        return result
    }

    private func performUpdateSources(newSources: [URL]) async -> CatalogDelta {
        while true {
            let current = sources
            let added = newSources.filter { !current.contains($0) }
            let removed = current.filter { !newSources.contains($0) }
            let capturedGeneration = generation
            let known = Dictionary(uniqueKeysWithValues: snapshot.apps.map { ($0.id, $0) })
            var discoveredAdded: [AppRecord] = []
            for scope in added {
                let discoverSources = discoverSources
                let found = await Task.detached(priority: .utility) {
                    discoverSources([scope], known)
                }.value
                discoveredAdded.append(contentsOf: found)
            }
            // 扫描期间若有其他对账提交, 以最新状态重算(陈旧防护)。
            guard generation == capturedGeneration else { continue }

            let deduped = Self.deduplicated(discoveredAdded)

            var apps = snapshot.apps
            apps = apps.filter { record in
                let ownedByRemoved = removed.contains { sourceDirectlyOwns(record.id.rawValue, $0.path) }
                return !ownedByRemoved
            }
            for record in deduped {
                apps.removeAll { $0.id == record.id }
                apps.append(record)
            }

            let newSnapshot = CatalogSnapshot(apps: apps)
            let delta = ReconcileEngine.delta(from: snapshot, to: newSnapshot.apps)
            guard !delta.isEmpty else {
                sources = newSources
                sourceGeneration &+= 1
                return delta
            }
            sources = newSources
            sourceGeneration &+= 1
            snapshot = newSnapshot
            generation += 1

            do {
                try store.save(snapshot)
                lastPersistErrorDescription = nil
            } catch {
                lastPersistErrorDescription = String(describing: error)
            }
            return delta
        }
    }

    // MARK: - 增量对账(FSEvents, §71-72)

    /// 处理目录监控变更摘要: scoped reconcile(仅受影响应用/目录), 不触发全量扫描。
    /// 摘要中的路径必须属于当前配置源(重配/停止后旧源路径被丢弃, 防御防幽灵)。
    public func applyChangeSummary(_ summary: DirectoryMonitor.ChangeSummary) async -> CatalogDelta {
        var delta = CatalogDelta()
        // Event loss invalidates the summarized paths, including summaries that
        // contain only app roots. Recover from every configured source.
        if summary.eventLossDetected {
            return await recoverAllScopes()
        }
        for scope in summary.dirtyScopes {
            guard isConfiguredSource(scope) else { continue }
            let scoped = await reconcileScope(URL(fileURLWithPath: scope))
            delta = delta.merged(with: scoped)
        }
        for appRoot in summary.dirtyAppRoots {
            guard isUnderConfiguredSource(appRoot) else { continue }
            let scoped = await reconcileAppRoot(URL(fileURLWithPath: appRoot))
            delta = delta.merged(with: scoped)
        }
        return delta
    }

    /// 仅重扫单个应用(§71 .app root 折叠后)。
    public func reconcileAppRoot(_ appRootURL: URL) async -> CatalogDelta {
        incrementalRequestSequence &+= 1
        let request = incrementalRequestSequence
        let previous = incrementalTail
        let task = Task { [weak self] () -> CatalogDelta in
            _ = await previous?.value
            guard let self else { return CatalogDelta() }
            return await self.performReconcileAppRoot(appRootURL)
        }
        incrementalTail = task
        let result = await task.value
        if request == incrementalRequestSequence {
            incrementalTail = nil
        }
        return result
    }

    private func performReconcileAppRoot(_ appRootURL: URL) async -> CatalogDelta {
        while true {
            let capturedGeneration = generation
            let capturedSourceGeneration = sourceGeneration
            guard isUnderConfiguredSource(appRootURL.path) else { return CatalogDelta() }
            let discoverAppRoot = discoverAppRoot
            let record = await Task.detached(priority: .utility) {
                discoverAppRoot(appRootURL)
            }.value
            // Another incremental/full scan committed or the source set changed
            // while this actor was reentrant. Rescan so an older result cannot win.
            guard generation == capturedGeneration,
                  sourceGeneration == capturedSourceGeneration else { continue }
            let discovered = record.map { [$0] } ?? []
            return applyIncremental(discovered, appRootPath: appRootURL.path)
        }
    }

    /// 仅枚举单个 scope 目录(§71 目录脏)。
    public func reconcileScope(_ scopeURL: URL) async -> CatalogDelta {
        incrementalRequestSequence &+= 1
        let request = incrementalRequestSequence
        let previous = incrementalTail
        let task = Task { [weak self] () -> CatalogDelta in
            _ = await previous?.value
            guard let self else { return CatalogDelta() }
            return await self.performReconcileScope(scopeURL)
        }
        incrementalTail = task
        let result = await task.value
        if request == incrementalRequestSequence {
            incrementalTail = nil
        }
        return result
    }

    private func performReconcileScope(_ scopeURL: URL) async -> CatalogDelta {
        while true {
            let capturedGeneration = generation
            let capturedSourceGeneration = sourceGeneration
            // scope 已不再是配置源(重配/移除): 禁止对非当前 source 执行 reconcile。
            guard isConfiguredSource(scopeURL.path) else { return CatalogDelta() }
            let known = Dictionary(uniqueKeysWithValues: snapshot.apps.map { ($0.id, $0) })
            let discoverSources = discoverSources
            let discovered = await Task.detached(priority: .utility) {
                discoverSources([scopeURL], known)
            }.value
            // Preserve disjoint updates too: retry this scope against the latest
            // generation instead of merely dropping a result when any scan wins.
            guard generation == capturedGeneration,
                  sourceGeneration == capturedSourceGeneration else { continue }
            return applyIncremental(discovered, scopePrefix: scopeURL.path + "/")
        }
    }

    /// 事件丢失时对全部 scope 执行恢复性重扫。
    public func recoverAllScopes() async -> CatalogDelta {
        (try? await reconcileFromDisk()) ?? CatalogDelta()
    }

    /// 应用根匹配: 容忍 /var 与 /private/var 表示差异(应用删除后 realpath 失效)。
    private func matchesAppRoot(_ id: AppID, _ appRootPath: String) -> Bool {
        let idPath = id.rawValue
        return idPath == appRootPath
            || idPath == "/private" + appRootPath
            || appRootPath == "/private" + idPath
    }

    /// scope 路径是否仍是当前配置源(规范化比较, 容忍 /var 与 /private/var)。
    private func isConfiguredSource(_ scopePath: String) -> Bool {
        let canonical = PathCanonicalizer.canonicalPath(from: URL(fileURLWithPath: scopePath))
        return sources.contains { $0.path == canonical }
    }

    /// .app 根是否位于任一当前配置源之下(容忍 /var 与 /private/var 表示差异)。
    private func isUnderConfiguredSource(_ appPath: String) -> Bool {
        let path = PathCanonicalizer.canonicalPath(from: URL(fileURLWithPath: appPath))
        return sources.contains { source in
            let sourcePath = source.path
            if path.hasPrefix(sourcePath + "/") { return true }
            // 源是 /private 形式而应用路径未解析(realpath 回退纯文本), 或反之。
            let plain = sourcePath.hasPrefix("/private")
                ? String(sourcePath.dropFirst("/private".count))
                : "/private" + sourcePath
            return path.hasPrefix(plain + "/")
        }
    }

    /// 源目录直接归属判断: 应用是该源目录的顶层 .app(容忍 /var 与 /private/var 差异)。
    /// 仅移除被移除源"直接枚举"的应用(嵌套应用属更深层源, 不误删)。
    private func sourceDirectlyOwns(_ appPath: String, _ sourcePath: String) -> Bool {
        let prefix = sourcePath + "/"
        if appPath.hasPrefix(prefix) {
            return !appPath.dropFirst(prefix.count).contains("/")
        }
        let privatePrefix = "/private" + prefix
        if appPath.hasPrefix(privatePrefix) {
            return !appPath.dropFirst(privatePrefix.count).contains("/")
        }
        return false
    }

    /// 按 AppID 去重发现记录(重叠源对同一 .app 枚举多次, 保证不产生重复 AppID)。
    private static func deduplicated(_ records: [AppRecord]) -> [AppRecord] {
        var seen = Set<AppID>()
        var result: [AppRecord] = []
        for record in records.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            if seen.insert(record.id).inserted {
                result.append(record)
            }
        }
        return result
    }

    /// 源集合规范化 + 去重: realpath 收敛(不存在路径回退纯文本), 重复路径仅保留一次。
    private static func normalizedSources(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let canonical = PathCanonicalizer.canonicalPath(from: url)
            guard seen.insert(canonical).inserted else { continue }
            result.append(URL(fileURLWithPath: canonical, isDirectory: true))
        }
        return result.sorted { $0.path < $1.path }
    }

    private func applyIncremental(
        _ rawDiscovered: [AppRecord],
        scopePrefix: String? = nil,
        appRootPath: String? = nil
    ) -> CatalogDelta {
        let discovered = Self.deduplicated(rawDiscovered)
        let currentByID = Dictionary(uniqueKeysWithValues: snapshot.apps.map { ($0.id, $0) })
        var inserted: [AppRecord] = []
        var updated: [AppRecord] = []
        for record in discovered {
            guard let previous = currentByID[record.id] else {
                inserted.append(record)
                continue
            }
            if previous != record {
                updated.append(record)
            }
        }
        let discoveredIDs = Set(discovered.map(\.id))
        var removed: [AppID] = []
        for record in snapshot.apps {
            let inScope: Bool
            if let appRootPath {
                inScope = matchesAppRoot(record.id, appRootPath)
            } else if let scopePrefix {
                inScope = record.id.rawValue.hasPrefix(scopePrefix)
            } else {
                inScope = false
            }
            if inScope && !discoveredIDs.contains(record.id) {
                removed.append(record.id)
            }
        }
        let delta = CatalogDelta(
            inserted: inserted,
            updated: updated,
            removed: removed.sorted { $0.rawValue < $1.rawValue }
        )
        guard !delta.isEmpty else { return delta }

        var apps = snapshot.apps.filter { !removed.contains($0.id) }
        for record in inserted + updated {
            apps.removeAll { $0.id == record.id }
            apps.append(record)
        }
        snapshot = CatalogSnapshot(apps: apps)
        generation += 1

        do {
            try store.save(snapshot)
            lastPersistErrorDescription = nil
        } catch {
            lastPersistErrorDescription = String(describing: error)
        }
        return delta
    }
}
