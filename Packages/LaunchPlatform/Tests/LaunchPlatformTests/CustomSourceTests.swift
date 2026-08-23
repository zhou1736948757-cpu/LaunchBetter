import Foundation
import Testing
import LaunchCore
@testable import LaunchPlatform

@Suite("AppCatalogActor 动态源集合(Stage B §B2)")
struct CustomSourceActorTests {
    private func makeActor(
        dir: URL, source: URL
    ) -> AppCatalogActor {
        AppCatalogActor(store: CatalogSnapshotStore(directory: dir), sources: [source])
    }

    @Test("新增源: 增量枚举, 不覆盖既有应用状态")
    func addSourceIncremental() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceA = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: sourceA) }
        let sourceB = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: sourceB) }
        let actor = makeActor(dir: dir, source: sourceA)
        _ = await actor.start()
        try makeFakeApp(in: sourceA, name: "Keep", bundleID: "com.test.Keep", version: "1.0")
        _ = try await actor.reconcileFromDisk()
        let genBefore = await actor.snapshotGeneration()

        try makeFakeApp(in: sourceB, name: "New", bundleID: "com.test.New")
        let delta = await actor.updateSources([sourceA, sourceB])

        #expect(delta.inserted.count == 1)
        #expect(delta.inserted[0].bundleIdentifier == "com.test.New")
        #expect(delta.removed.isEmpty)
        let snapshot = await actor.currentSnapshot()
        #expect(snapshot.apps.count == 2)
        // 既有 Keep 未被覆盖(状态保留)
        let keepID = PathCanonicalizer.canonicalAppID(from: sourceA.appendingPathComponent("Keep.app"))
        #expect(snapshot.app(with: keepID)?.bundleIdentifier == "com.test.Keep")
        #expect(await actor.snapshotGeneration() != genBefore)
    }

    @Test("移除源: 该源直接应用消失, 其余源应用保留")
    func removeSource() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceA = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: sourceA) }
        let sourceB = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: sourceB) }
        let actor = AppCatalogActor(store: CatalogSnapshotStore(directory: dir), sources: [sourceA, sourceB])
        _ = await actor.start()
        try makeFakeApp(in: sourceA, name: "AA", bundleID: "com.test.AA")
        try makeFakeApp(in: sourceB, name: "BB", bundleID: "com.test.BB")
        _ = try await actor.reconcileFromDisk()

        let delta = await actor.updateSources([sourceA])

        #expect(delta.removed.map(\.rawValue) == [PathCanonicalizer.canonicalPath(from: sourceB.appendingPathComponent("BB.app"))])
        let ids = await actor.currentSnapshot().apps.map(\.bundleIdentifier)
        #expect(ids == ["com.test.AA"])
    }

    @Test("移除父源保留子源应用(直接归属语义, 不产生幽灵项)")
    func removeParentKeepsChildSourceApps() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let parent = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let child = parent.appendingPathComponent("Sub", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let actor = AppCatalogActor(store: CatalogSnapshotStore(directory: dir), sources: [parent, child])
        _ = await actor.start()
        try makeFakeApp(in: parent, name: "Top", bundleID: "com.test.Top")
        try makeFakeApp(in: child, name: "Nested", bundleID: "com.test.Nested")
        _ = try await actor.reconcileFromDisk()
        let before = await actor.currentSnapshot().apps.map(\.bundleIdentifier)
        #expect(Set(before) == Set(["com.test.Nested", "com.test.Top"]))

        // 移除父源: Top(直接属于 parent)移除, Nested(直接属于 child)保留
        let delta = await actor.updateSources([child])

        let removedPaths = delta.removed.map(\.rawValue)
        #expect(removedPaths == [PathCanonicalizer.canonicalPath(from: parent.appendingPathComponent("Top.app"))])
        let ids = await actor.currentSnapshot().apps.map(\.bundleIdentifier)
        #expect(ids == ["com.test.Nested"])
    }

    @Test("移除子源移除其直接应用(避免父前缀误保留幽灵项)")
    func removeChildRemovesItsApps() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let parent = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let child = parent.appendingPathComponent("Sub", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let actor = AppCatalogActor(store: CatalogSnapshotStore(directory: dir), sources: [parent, child])
        _ = await actor.start()
        try makeFakeApp(in: parent, name: "Top", bundleID: "com.test.Top")
        try makeFakeApp(in: child, name: "Nested", bundleID: "com.test.Nested")
        _ = try await actor.reconcileFromDisk()

        // 移除子源: Nested 移除(父源不枚举嵌套应用)
        let delta = await actor.updateSources([parent])

        #expect(delta.removed.map(\.rawValue) == [PathCanonicalizer.canonicalPath(from: child.appendingPathComponent("Nested.app"))])
        let ids = await actor.currentSnapshot().apps.map(\.bundleIdentifier)
        #expect(ids == ["com.test.Top"])
    }

    @Test("源去重: 相同路径/符号链接别名只保留一个; 重叠不产生重复 AppID")
    func sourceDeduplication() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: real) }
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchPlatformTests-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: link) }

        let actor = AppCatalogActor(
            store: CatalogSnapshotStore(directory: dir), sources: [real, real, link]
        )
        _ = await actor.start()
        try makeFakeApp(in: real, name: "Foo", bundleID: "com.test.Foo")
        _ = try await actor.reconcileFromDisk()

        let sources = await actor.currentSources()
        #expect(sources.count == 1, "重复路径与符号链接别名必须去重")
        let snapshot = await actor.currentSnapshot()
        #expect(snapshot.apps.count == 1, "重叠源不产生重复 AppID")
        #expect(snapshot.apps[0].bundleIdentifier == "com.test.Foo")
    }

    @Test("发现记录去重: discover 返回重复记录不崩溃、不产生重复 AppID")
    func discoveredRecordsDeduplicated() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: source) }
        let appURL = try makeFakeApp(in: source, name: "Dup", bundleID: "com.test.Dup")
        let record = try #require(AppDiscoveryService.makeRecord(from: appURL))
        // 模拟重叠源对同一 .app 枚举两次
        let actor = AppCatalogActor(
            store: CatalogSnapshotStore(directory: dir),
            sources: [source],
            discoverSources: { _ in [record, record] }
        )
        _ = await actor.start()
        let delta = try await actor.reconcileFromDisk()
        #expect(delta.inserted.count == 1, "重复发现记录只插入一次")
        let snapshot = await actor.currentSnapshot()
        #expect(snapshot.apps.count == 1)
        let unique = Set(snapshot.apps.map(\.id)).count
        #expect(unique == snapshot.apps.count)
    }

    @Test("无效/缺失源目录: 不崩溃, 增量扫描跳过")
    func missingSourceGraceful() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceA = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: sourceA) }
        let actor = makeActor(dir: dir, source: sourceA)
        _ = await actor.start()
        try makeFakeApp(in: sourceA, name: "Keep", bundleID: "com.test.Keep")
        _ = try await actor.reconcileFromDisk()

        let missing = URL(fileURLWithPath: "/nonexistent/custom/source/\(UUID().uuidString)", isDirectory: true)
        let delta = await actor.updateSources([sourceA, missing])

        #expect(delta.isEmpty, "缺失源无应用, 不产生增量也不崩溃")
        let snapshot = await actor.currentSnapshot()
        #expect(snapshot.apps.count == 1)
        let sources = await actor.currentSources()
        #expect(sources.map(\.path).contains(missing.path))
    }

    @Test("相同源集合: 无操作, 代数不变")
    func noopUpdate() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceA = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: sourceA) }
        let actor = makeActor(dir: dir, source: sourceA)
        _ = await actor.start()
        try makeFakeApp(in: sourceA, name: "Keep", bundleID: "com.test.Keep")
        _ = try await actor.reconcileFromDisk()
        let gen = await actor.snapshotGeneration()

        let delta = await actor.updateSources([sourceA])
        #expect(delta.isEmpty)
        #expect(await actor.snapshotGeneration() == gen)
    }

    @Test("更新源后重启: 从磁盘恢复新源应用; 移除源应用不残留")
    func updatePersistsAcrossRestart() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceA = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: sourceA) }
        let sourceB = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: sourceB) }
        let store = CatalogSnapshotStore(directory: dir)

        let actor = AppCatalogActor(store: store, sources: [sourceA])
        _ = await actor.start()
        try makeFakeApp(in: sourceA, name: "AA", bundleID: "com.test.AA")
        try makeFakeApp(in: sourceB, name: "BB", bundleID: "com.test.BB")
        _ = try await actor.reconcileFromDisk()
        _ = await actor.updateSources([sourceA, sourceB])
        _ = await actor.updateSources([sourceA])

        let actor2 = AppCatalogActor(store: store, sources: [sourceA])
        let result = await actor2.start()
        #expect(result.loadedFromDisk)
        let ids = result.snapshot.apps.map(\.bundleIdentifier)
        #expect(ids == ["com.test.AA"], "移除源应用不得在重启后残留")
    }

    @Test("移除源后: 旧源 scope 摘要不执行 reconcile(防幽灵, M2)")
    func removedSourceSummaryNotReconciled() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceA = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: sourceA) }
        let sourceB = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: sourceB) }
        let actor = AppCatalogActor(
            store: CatalogSnapshotStore(directory: dir), sources: [sourceA, sourceB]
        )
        _ = await actor.start()
        try makeFakeApp(in: sourceA, name: "AA", bundleID: "com.test.AA")
        try makeFakeApp(in: sourceB, name: "BB", bundleID: "com.test.BB")
        _ = try await actor.reconcileFromDisk()
        _ = await actor.updateSources([sourceA])
        #expect((await actor.currentSnapshot().apps.map(\.bundleIdentifier)) == ["com.test.AA"])

        // 旧源 B 的 scope 摘要: 禁止 reconcile, 不得把 BB 重新插回
        let stale = DirectoryMonitor.ChangeSummary(
            dirtyScopes: [PathCanonicalizer.canonicalPath(from: sourceB)],
            dirtyAppRoots: [], eventLossDetected: false
        )
        let delta = await actor.applyChangeSummary(stale)
        #expect(delta.isEmpty)
        #expect((await actor.currentSnapshot().apps.map(\.bundleIdentifier)) == ["com.test.AA"])

        // 正控制: 当前源 A 的 scope 摘要仍被处理(幂等无变化)
        let current = DirectoryMonitor.ChangeSummary(
            dirtyScopes: [PathCanonicalizer.canonicalPath(from: sourceA)],
            dirtyAppRoots: [], eventLossDetected: false
        )
        let delta2 = await actor.applyChangeSummary(current)
        #expect(delta2.isEmpty, "当前源重扫幂等无变化")
        #expect((await actor.currentSnapshot().apps.map(\.bundleIdentifier)) == ["com.test.AA"])
    }
}

private final class SourceRemovalInterleaveProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let firstStarted = DispatchSemaphore(value: 0)
    private let releaseFirst = DispatchSemaphore(value: 0)
    private var calls = 0
    private let recordA: AppRecord
    private let recordB: AppRecord

    init(sourceA: URL, sourceB: URL) {
        recordA = Self.makeRecord(sourceA, "A")
        recordB = Self.makeRecord(sourceB, "B")
    }

    private static func makeRecord(_ source: URL, _ name: String) -> AppRecord {
        let url = source.appendingPathComponent("\(name).app")
        return AppRecord(
            id: AppID(url.path)!, url: url,
            bundleIdentifier: "com.test.\(name)", displayName: name,
            infoPlistModificationDate: nil,
            iconContentVersion: IconContentVersion(bundleVersion: "1")
        )
    }

    func discover(_ sources: [URL]) -> [AppRecord] {
        lock.lock()
        calls += 1
        let call = calls
        lock.unlock()
        if call == 1 {
            firstStarted.signal()
            releaseFirst.wait()
            return [recordA, recordB]
        }
        return [recordA]
    }

    func waitUntilFirstStarted() -> Bool {
        firstStarted.wait(timeout: .now() + 2) == .success
    }

    func releaseFirstScan() { releaseFirst.signal() }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

@Suite("AppCatalogActor 源集合变更并发安全(Stage C C5)")
struct SourceGenerationSafetyTests {
    @Test("阻塞全量扫描期间移除无 delta 源: 释放后旧源应用不提交(M3)")
    func fullScanStaleSourceNotCommitted() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceA = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: sourceA) }
        let sourceB = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: sourceB) }
        let probe = SourceRemovalInterleaveProbe(sourceA: sourceA, sourceB: sourceB)
        let actor = AppCatalogActor(
            store: CatalogSnapshotStore(directory: dir),
            sources: [sourceA, sourceB],
            discoverSources: { urls in probe.discover(urls) }
        )
        _ = await actor.start()

        let full = Task { try await actor.reconcileFromDisk() }
        #expect(probe.waitUntilFirstStarted())

        // 扫描期间移除 sourceB(B 下无应用 → delta 为空, 走无增量路径)
        let delta = await actor.updateSources([sourceA])
        #expect(delta.isEmpty)

        probe.releaseFirstScan()
        _ = try await full.value

        #expect(probe.callCount == 2, "旧源集合扫描必须重扫, 不得用旧源提交")
        let names = await actor.currentSnapshot().apps.map(\.displayName)
        #expect(names == ["A"], "重配后提交结果不得包含已移除源的 B")
    }
}

@Suite("DirectoryMonitor 动态 scope 重配(Stage B §B2)")
struct DirectoryMonitorReconfigureTests {
    private actor MatchFlag {
        private(set) var matched = false
        func mark() { matched = true }
    }

    private final class SummaryRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var summaries: [DirectoryMonitor.ChangeSummary] = []
        func record(_ summary: DirectoryMonitor.ChangeSummary) {
            lock.lock()
            summaries.append(summary)
            lock.unlock()
        }
        func drain() -> [DirectoryMonitor.ChangeSummary] {
            lock.lock()
            defer { lock.unlock() }
            let captured = summaries
            summaries = []
            return captured
        }
    }

    @Test("reconfigure 增加监控根后, 新源事件被折叠")
    func reconfigureAddsScope() async throws {
        let sourceA = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: sourceA) }
        let sourceB = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: sourceB) }
        let canonicalB = PathCanonicalizer.canonicalPath(from: sourceB)
        let monitor = DirectoryMonitor(scopes: [sourceA.path], latency: 0.1)
        let flag = MatchFlag()
        monitor.onChange = { summary in
            if summary.dirtyScopes.contains(canonicalB)
                || summary.dirtyAppRoots.contains(canonicalB + "/RealB.app") {
                Task { await flag.mark() }
            }
        }
        monitor.start()
        try await Task.sleep(nanoseconds: 300_000_000)

        // 重配: 新增 sourceB
        monitor.reconfigure(scopes: [sourceA.path, sourceB.path])
        try await Task.sleep(nanoseconds: 500_000_000)

        let appURL = sourceB.appendingPathComponent("RealB.app")
        try FileManager.default.createDirectory(
            at: appURL.appendingPathComponent("Contents"), withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: appURL.appendingPathComponent("Contents/Info.plist"))

        var found = false
        for _ in 0..<80 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await flag.matched {
                found = true
                break
            }
        }
        monitor.stop()
        #expect(found, "reconfigure 后新源目录变化应被监控并折叠")
    }

    @Test("reconfigure 相同 scope: 无操作(不重建流)")
    func reconfigureNoopDoesNotStopStream() async throws {
        let source = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: source) }
        let canonical = PathCanonicalizer.canonicalPath(from: source)
        let monitor = DirectoryMonitor(scopes: [source.path], latency: 0.1)
        let flag = MatchFlag()
        monitor.onChange = { summary in
            if summary.dirtyScopes.contains(canonical)
                || summary.dirtyAppRoots.contains(canonical + "/Noop.app") {
                Task { await flag.mark() }
            }
        }
        monitor.start()
        try await Task.sleep(nanoseconds: 300_000_000)

        // 相同集合 → no-op
        monitor.reconfigure(scopes: [source.path])
        try await Task.sleep(nanoseconds: 300_000_000)

        let appURL = source.appendingPathComponent("Noop.app")
        try FileManager.default.createDirectory(
            at: appURL.appendingPathComponent("Contents"), withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: appURL.appendingPathComponent("Contents/Info.plist"))

        var found = false
        for _ in 0..<80 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await flag.matched {
                found = true
                break
            }
        }
        monitor.stop()
        #expect(found, "相同 scope 重配不应停止监控")
    }

    @Test("重配移除源: 旧源 pending 被丢弃, 新事件不含旧源(M2)")
    func reconfigureDropsRemovedSourcePending() async throws {
        let sourceA = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: sourceA) }
        let sourceB = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: sourceB) }
        let canonicalA = PathCanonicalizer.canonicalPath(from: sourceA)
        let canonicalB = PathCanonicalizer.canonicalPath(from: sourceB)

        let monitor = DirectoryMonitor(scopes: [sourceA.path, sourceB.path], latency: 0.1)
        let recorder = SummaryRecorder()
        monitor.onChange = { recorder.record($0) }

        // 重配前已积累的旧源 B pending(模拟旧流回调)
        monitor.process(paths: [canonicalB + "/Old.app"], flags: [0])
        // 重配: 移除 B → stop 递增代数并丢弃旧代数 pending
        monitor.reconfigure(scopes: [sourceA.path])
        // 新流事件
        monitor.process(paths: [canonicalA + "/New.app"], flags: [0])

        // 等待去抖(0.5s)+ 余量
        try await Task.sleep(for: .milliseconds(1200))
        monitor.stop()

        let appRoots = recorder.drain().flatMap { Array($0.dirtyAppRoots) }
        #expect(appRoots.contains(canonicalA + "/New.app"), "新源事件应交付")
        #expect(!appRoots.contains(canonicalB + "/Old.app"), "旧源 pending 不得随新摘要交付")
    }

    @Test("重配后批次含旧源路径: 折叠忽略, 摘要不含旧源(M2)")
    func postReconfigureBatchIgnoresRemovedSource() async throws {
        let sourceA = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: sourceA) }
        let sourceB = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: sourceB) }
        let canonicalA = PathCanonicalizer.canonicalPath(from: sourceA)
        let canonicalB = PathCanonicalizer.canonicalPath(from: sourceB)

        let monitor = DirectoryMonitor(scopes: [sourceA.path], latency: 0.1)
        let recorder = SummaryRecorder()
        monitor.onChange = { recorder.record($0) }

        // 单一批次混合: 已移除源 B 路径 + 当前源 A 路径(按当前 scope 折叠)
        monitor.process(
            paths: [canonicalB + "/Ghost.app", canonicalA + "/Live.app"],
            flags: [0, 0]
        )

        try await Task.sleep(for: .milliseconds(1200))
        monitor.stop()

        let summaries = recorder.drain()
        let appRoots = summaries.flatMap { Array($0.dirtyAppRoots) }
        let scopes = summaries.flatMap { Array($0.dirtyScopes) }
        #expect(appRoots.contains(canonicalA + "/Live.app"))
        #expect(!appRoots.contains(canonicalB + "/Ghost.app"))
        #expect(!scopes.contains(canonicalB), "已移除源不得作为 scopeDirty 交付")
    }
}
