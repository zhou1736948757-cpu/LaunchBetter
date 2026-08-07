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
    private let sources: [URL]

    private var snapshot: CatalogSnapshot
    private var generation: Int = 0

    /// 最近一次持久化失败描述(nil = 正常)。持久化失败不阻断对账流程。
    public private(set) var lastPersistErrorDescription: String?

    public init(store: CatalogSnapshotStore, sources: [URL]) {
        self.store = store
        self.sources = sources
        self.snapshot = CatalogSnapshot(apps: [])
    }

    /// 启动: 加载磁盘快照。损坏时备份并继续(空快照),绝不静默清除。
    public func start() -> StartResult {
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
    public func currentSnapshot() -> CatalogSnapshot {
        snapshot
    }

    /// 当前代数;消费方缓存此值以检测陈旧结果。
    public func snapshotGeneration() -> Int {
        generation
    }

    /// 仅当代数匹配时返回快照,否则 nil(陈旧防护契约)。
    public func currentSnapshot(ifGeneration expected: Int) -> CatalogSnapshot? {
        generation == expected ? snapshot : nil
    }

    /// 后台全量对账: 枚举磁盘 → 计算增量 → 更新快照 → 原子持久化。
    /// 枚举在后台执行器进行,不阻塞 actor。
    public func reconcileFromDisk() async throws -> CatalogDelta {
        let capturedSources = sources
        let discovered = await Task.detached(priority: .utility) {
            AppDiscoveryService.discover(sources: capturedSources)
        }.value

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
