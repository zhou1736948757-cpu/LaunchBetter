import Foundation
import LaunchCore

/// App Library 元数据持久存储(actor): usage / firstSeen / category overrides 内存聚合 + 异步原子持久化。
///
/// 职责:
/// - 启动加载 `AppLibraryMetadata.json`(损坏先备份后 seed,不静默清除证据)
/// - bootstrap 基线: 首次把现有 AppID 写入 firstSeen 作为 baseline,
///   基线时间戳落在 Recently Added 窗口边界之外,不产生候选
/// - 增量采集: recordDiscovered 只为不存在的 AppID 写 now;recordLaunch 只更新 count/lastLaunchedAt
/// - 手动覆盖: setCategoryOverride / clearCategoryOverride(PA2,与 Layout 完全独立)
/// - 持久化: 写盘在 detached 任务中执行(coalesced),不阻塞调用方;flush() 等待 pending write
///
/// 完全独立于 LayoutStore/LayoutSnapshot;无 AppKit/SwiftUI 依赖。
/// deinit 不承担业务生命周期: 析构前必须显式 shutdown()。
public actor AppLibraryMetadataStore {
    /// 磁盘文件位置(Application Support 目录下)。
    public let fileURL: URL

    private var memory: AppLibraryMetadataSnapshot
    private var started = false
    /// 损坏文件无法先备份时禁止后续覆盖,直到进程重启后再次成功加载。
    private var writesBlockedByUnpreservedCorruption = false

    /// 最近一次持久化失败描述(nil = 正常)。
    public private(set) var lastPersistErrorDescription: String?

    /// 有未落盘变更(内存聚合 → 磁盘的 coalesced 信号)。
    private var dirty = false
    /// 正在运行的持久化循环任务。
    private var persistTask: Task<Void, Never>?

    public init(directory: URL, initialSnapshot: AppLibraryMetadataSnapshot = .init()) {
        self.fileURL = directory.appendingPathComponent("AppLibraryMetadata.json")
        self.memory = initialSnapshot
    }

    /// 启动: 加载磁盘快照(存在则权威)。损坏时备份后保留 seed;缺失时保留 seed。幂等。
    ///
    /// `adoptingSeed` 非 nil 时直接采纳(调用方已同步读过同一磁盘文件, PA1 去重);
    /// nil = 保留原读盘/损坏恢复路径。
    public func start(adoptingSeed seed: AppLibraryMetadataSnapshot? = nil) async -> AppLibraryMetadataSnapshot {
        guard !started else { return memory }
        started = true
        if let seed {
            memory = seed
            writesBlockedByUnpreservedCorruption = false
            lastPersistErrorDescription = nil
            return seed
        }
        do {
            if let loaded = try DurableFile.loadCodable(
                AppLibraryMetadataSnapshot.self, from: fileURL
            ) {
                memory = loaded
                writesBlockedByUnpreservedCorruption = false
                lastPersistErrorDescription = nil
                return loaded
            }
        } catch {
            let backedUp = (try? DurableFile.backupCorruptedFile(at: fileURL)) != nil
            writesBlockedByUnpreservedCorruption = !backedUp
            lastPersistErrorDescription = backedUp
                ? "corrupted metadata backed up"
                : "corruption backup failed"
        }
        return memory
    }

    /// 当前内存聚合快照(最新已确认状态,可能尚未落盘)。
    public func snapshot() -> AppLibraryMetadataSnapshot {
        memory
    }

    /// 首次 bootstrap: 把现有 AppID 写入 firstSeen 基线并标记完成。
    /// 基线时间戳 = now - recentlyAddedWindow(窗口边界,Builder 排除);
    /// 已有 firstSeen 不重置;已 bootstrap 后调用为 no-op。返回最新快照。
    public func bootstrap(existingAppIDs: [AppID], now: Date) async -> AppLibraryMetadataSnapshot {
        guard !memory.isBootstrapped else { return memory }
        let baseline = now.addingTimeInterval(-AppLibraryTuning.recentlyAddedWindow)
        var firstSeen = memory.firstSeen
        for id in existingAppIDs where firstSeen[id] == nil {
            firstSeen[id] = baseline
        }
        memory = makeSnapshot(
            usage: memory.usage,
            firstSeen: firstSeen,
            isBootstrapped: true
        )
        noteMutation()
        return memory
    }

    /// 记录发现。只为不存在的 AppID 写入时间戳;重复发现与 remove/reappear 不重置。返回最新快照。
    /// bootstrap 前发现的 App 与存量 App 不可区分,时间戳 baseline 化到 Recently Added 窗口边界之外;
    /// bootstrap 之后才写入 now。
    public func recordDiscovered(appIDs: [AppID], now: Date) async -> AppLibraryMetadataSnapshot {
        let timestamp = memory.isBootstrapped
            ? now
            : now.addingTimeInterval(-AppLibraryTuning.recentlyAddedWindow)
        var changed = false
        var firstSeen = memory.firstSeen
        for id in appIDs where firstSeen[id] == nil {
            firstSeen[id] = timestamp
            changed = true
        }
        guard changed else { return memory }
        memory = makeSnapshot(
            usage: memory.usage,
            firstSeen: firstSeen,
            isBootstrapped: memory.isBootstrapped
        )
        noteMutation()
        return memory
    }

    /// 记录一次启动: 只更新 count 与 lastLaunchedAt,不保存搜索词/窗口内容/文件或用户输入。返回最新快照。
    public func recordLaunch(_ appID: AppID, at date: Date) async -> AppLibraryMetadataSnapshot {
        let previous = memory.usage[appID]
        var usage = memory.usage
        usage[appID] = AppLibraryUsageRecord(
            launchCount: (previous?.launchCount ?? 0) + 1,
            lastLaunchedAt: date
        )
        memory = makeSnapshot(
            usage: usage,
            firstSeen: memory.firstSeen,
            isBootstrapped: memory.isBootstrapped
        )
        noteMutation()
        return memory
    }

    /// 设置手动分类覆盖(用户显式指定)。更新内存并调度持久化;返回最新快照。
    /// 覆盖不进入 LayoutStore、不改 AppRecord.categoryIdentifier。
    public func setCategoryOverride(
        appID: AppID,
        category: AppLibraryCategory
    ) async -> AppLibraryMetadataSnapshot {
        guard memory.categoryOverrides[appID] != category else { return memory }
        var overrides = memory.categoryOverrides
        overrides[appID] = category
        memory = makeSnapshot(
            usage: memory.usage,
            firstSeen: memory.firstSeen,
            isBootstrapped: memory.isBootstrapped,
            categoryOverrides: overrides
        )
        noteMutation()
        return memory
    }

    /// 移除手动分类覆盖(恢复自动分类)。更新内存并调度持久化;返回最新快照。
    public func clearCategoryOverride(appID: AppID) async -> AppLibraryMetadataSnapshot {
        guard memory.categoryOverrides[appID] != nil else { return memory }
        var overrides = memory.categoryOverrides
        overrides.removeValue(forKey: appID)
        memory = makeSnapshot(
            usage: memory.usage,
            firstSeen: memory.firstSeen,
            isBootstrapped: memory.isBootstrapped,
            categoryOverrides: overrides
        )
        noteMutation()
        return memory
    }

    /// 等待全部 pending write 完成(含 coalesced 最新状态)。
    public func flush() async {
        if dirty, persistTask == nil {
            noteMutation()
        }
        while let task = persistTask {
            await task.value
        }
    }

    /// 冲刷并停止调度。幂等;deinit 不承担该职责。
    public func shutdown() async {
        await flush()
        persistTask?.cancel()
        started = false
    }

    // MARK: - Snapshot 构造

    /// 所有构造快照的唯一入口: 恒携带当前 `categoryOverrides`(PA2 保留约定)。
    private func makeSnapshot(
        usage: [AppID: AppLibraryUsageRecord],
        firstSeen: [AppID: Date],
        isBootstrapped: Bool,
        categoryOverrides: [AppID: AppLibraryCategory]? = nil
    ) -> AppLibraryMetadataSnapshot {
        AppLibraryMetadataSnapshot(
            usage: usage,
            firstSeen: firstSeen,
            isBootstrapped: isBootstrapped,
            categoryOverrides: categoryOverrides ?? memory.categoryOverrides
        )
    }

    // MARK: - Persistence (coalesced)

    /// 标记内存变更并调度一次持久化循环(已调度则仅置 dirty,合并写入)。
    private func noteMutation() {
        dirty = true
        guard persistTask == nil else { return }
        persistTask = Task.detached { [weak self] in
            guard let self else { return }
            let fileURL = self.fileURL
            while true {
                let payload = await self.takeNextPayload()
                guard let payload else { break }
                do {
                    try DurableFile.saveCodable(payload, to: fileURL)
                    await self.markWriteSucceeded()
                } catch {
                    await self.markWriteFailed(String(describing: error))
                }
            }
            await self.finishPersistLoop()
        }
    }

    /// 取走待写入快照;无变更或证据保护模式下返回 nil。
    private func takeNextPayload() -> AppLibraryMetadataSnapshot? {
        guard dirty else { return nil }
        dirty = false
        if writesBlockedByUnpreservedCorruption {
            lastPersistErrorDescription = "writes blocked: corrupted metadata could not be preserved"
            return nil
        }
        return memory
    }

    private func markWriteSucceeded() {
        lastPersistErrorDescription = nil
    }

    private func markWriteFailed(_ error: String) {
        lastPersistErrorDescription = error
    }

    /// 循环收尾: 清理任务引用;期间又有变更则重新调度。
    private func finishPersistLoop() {
        persistTask = nil
        if dirty {
            noteMutation()
        }
    }
}
