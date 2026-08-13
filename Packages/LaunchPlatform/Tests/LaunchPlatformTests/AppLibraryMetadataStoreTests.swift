import Foundation
import Testing
import LaunchCore
@testable import LaunchPlatform

@Suite("AppLibraryMetadataStore 元数据持久化")
struct AppLibraryMetadataStoreTests {
    private let idA = AppID("/Applications/A.app")!
    private let idB = AppID("/Applications/B.app")!
    private let idC = AppID("/Applications/C.app")!
    private let idD = AppID("/Applications/D.app")!
    private let idE = AppID("/Applications/E.app")!
    private let t0 = Date(timeIntervalSince1970: 2_000_000_000)
    private let t1 = Date(timeIntervalSince1970: 2_000_003_600)
    private let t2 = Date(timeIntervalSince1970: 2_000_007_200)
    private let t3 = Date(timeIntervalSince1970: 2_000_010_800)

    @Test("缺失文件: start 返回初始快照 seed, 不落盘")
    func missingFileSeedsAndStarts() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seed = AppLibraryMetadataSnapshot(
            firstSeen: [idA: t0],
            isBootstrapped: true
        )
        let store = AppLibraryMetadataStore(directory: dir, initialSnapshot: seed)
        let snapshot = await store.start()
        #expect(snapshot == seed)
        #expect(await store.snapshot() == seed)
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("AppLibraryMetadata.json").path
        ))
    }

    @Test("schema round-trip: 写盘后重启加载一致")
    func schemaRoundTripAndRestart() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AppLibraryMetadataStore(directory: dir)
        _ = await store.start()
        _ = await store.bootstrap(existingAppIDs: [idA, idB], now: t0)
        _ = await store.recordDiscovered(appIDs: [idC], now: t1)
        _ = await store.recordLaunch(idA, at: t2)
        _ = await store.recordLaunch(idA, at: t3)
        await store.flush()

        let expected = await store.snapshot()
        #expect(expected.schemaVersion == AppLibraryMetadataSnapshot.currentSchemaVersion)

        let restored = AppLibraryMetadataStore(directory: dir)
        let loaded = await restored.start()
        #expect(loaded == expected)
        #expect(loaded.isBootstrapped)
        #expect(loaded.usage[idA] == AppLibraryUsageRecord(launchCount: 2, lastLaunchedAt: t3))
        #expect(loaded.firstSeen[idC] == t1)
    }

    @Test("bootstrap: 现有 App 全部 baseline, 不产生 Recently Added 候选, 幂等")
    func bootstrapBaselinesAndNoRecentlyAdded() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AppLibraryMetadataStore(directory: dir)
        _ = await store.start()
        let after = await store.bootstrap(existingAppIDs: [idA, idB], now: t0)
        #expect(after.isBootstrapped)
        #expect(after.firstSeen[idA] == t0.addingTimeInterval(-AppLibraryTuning.recentlyAddedWindow))
        #expect(after.firstSeen[idB] == after.firstSeen[idA])

        let catalog = CatalogSnapshot(apps: [makeRecord(idA), makeRecord(idB)])
        let model = AppLibraryModelBuilder.build(AppLibraryModelBuilder.Inputs(
            catalog: catalog,
            metadata: after,
            now: t0.addingTimeInterval(60)
        ))
        #expect(model.cards.allSatisfy { $0.id != .recentlyAdded })

        let again = await store.bootstrap(existingAppIDs: [idA, idB, idC], now: t1)
        #expect(again == after)
    }

    @Test("recordDiscovered 先于 bootstrap: baseline 化, 不产生 Recently Added 候选")
    func preBootstrapDiscoveryThenBootstrapNoRecentlyAdded() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AppLibraryMetadataStore(directory: dir)
        _ = await store.start()

        let baseline = t0.addingTimeInterval(-AppLibraryTuning.recentlyAddedWindow)
        let discovered = await store.recordDiscovered(appIDs: [idB], now: t0)
        #expect(!discovered.isBootstrapped)
        #expect(discovered.firstSeen[idB] == baseline)

        let after = await store.bootstrap(existingAppIDs: [idA, idB], now: t0)
        #expect(after.isBootstrapped)
        #expect(after.firstSeen[idB] == baseline)

        let catalog = CatalogSnapshot(apps: [makeRecord(idA), makeRecord(idB)])
        let model = AppLibraryModelBuilder.build(AppLibraryModelBuilder.Inputs(
            catalog: catalog,
            metadata: after,
            now: t0.addingTimeInterval(60)
        ))
        #expect(model.cards.allSatisfy { $0.id != .recentlyAdded })
    }

    @Test("recordDiscovered: 只写新 AppID; 重复发现与 remove/reappear 不重置")
    func recordDiscoveredOnlyNew() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AppLibraryMetadataStore(directory: dir)
        _ = await store.start()
        _ = await store.bootstrap(existingAppIDs: [idA], now: t0)

        var after = await store.recordDiscovered(appIDs: [idB, idA], now: t1)
        #expect(after.firstSeen[idB] == t1)
        #expect(after.firstSeen[idA] == t0.addingTimeInterval(-AppLibraryTuning.recentlyAddedWindow))

        after = await store.recordDiscovered(appIDs: [idB], now: t2)
        #expect(after.firstSeen[idB] == t1)

        await store.flush()
        let restored = AppLibraryMetadataStore(directory: dir)
        _ = await restored.start()
        after = await restored.recordDiscovered(appIDs: [idB], now: t3)
        #expect(after.firstSeen[idB] == t1)
    }

    @Test("recordLaunch: 顺序更新 count/lastLaunchedAt, 不触碰 firstSeen")
    func recordLaunchUpdatesUsage() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AppLibraryMetadataStore(directory: dir)
        _ = await store.start()
        _ = await store.bootstrap(existingAppIDs: [idA], now: t0)
        let baseline = await store.snapshot()

        var after = await store.recordLaunch(idA, at: t1)
        #expect(after.usage[idA] == AppLibraryUsageRecord(launchCount: 1, lastLaunchedAt: t1))
        after = await store.recordLaunch(idA, at: t2)
        #expect(after.usage[idA] == AppLibraryUsageRecord(launchCount: 2, lastLaunchedAt: t2))
        after = await store.recordLaunch(idB, at: t3)
        #expect(after.usage[idA] == AppLibraryUsageRecord(launchCount: 2, lastLaunchedAt: t2))
        #expect(after.usage[idB] == AppLibraryUsageRecord(launchCount: 1, lastLaunchedAt: t3))
        #expect(after.firstSeen == baseline.firstSeen)
    }

    @Test("多次快速更新 coalesced 后 flush 可读")
    func coalescedUpdatesFlushReadable() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AppLibraryMetadataStore(directory: dir)
        _ = await store.start()
        for id in [idA, idB, idC, idD, idE] {
            _ = await store.recordDiscovered(appIDs: [id], now: t0)
            _ = await store.recordLaunch(id, at: t1)
        }
        await store.flush()
        #expect(await store.snapshot().firstSeen.count == 5)
        #expect(await store.snapshot().usage.count == 5)

        let restored = AppLibraryMetadataStore(directory: dir)
        let loaded = await restored.start()
        #expect(loaded.firstSeen.count == 5)
        #expect(loaded.usage.count == 5)
        for id in [idA, idB, idC, idD, idE] {
            #expect(loaded.usage[id] == AppLibraryUsageRecord(launchCount: 1, lastLaunchedAt: t1))
        }
    }

    @Test("损坏 JSON: backup 保留, actor 回退 seed, 不 crash, 后续可写")
    func corruptedBackedUpAndSeeded() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("AppLibraryMetadata.json")
        try DurableFile.save(Data("garbage-{".utf8), to: file)

        let seed = AppLibraryMetadataSnapshot(firstSeen: [idA: t0], isBootstrapped: true)
        let store = AppLibraryMetadataStore(directory: dir, initialSnapshot: seed)
        let snapshot = await store.start()
        #expect(snapshot == seed)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("AppLibraryMetadata.json.corrupt-") }
        #expect(backups.count == 1)

        _ = await store.recordDiscovered(appIDs: [idB], now: t1)
        await store.flush()
        let restored = AppLibraryMetadataStore(directory: dir)
        let loaded = await restored.start()
        #expect(loaded.firstSeen[idA] == t0)
        #expect(loaded.firstSeen[idB] == t1)
    }

    @Test("start/shutdown/flush 幂等; shutdown 冲刷落盘")
    func lifecycleIdempotent() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AppLibraryMetadataStore(directory: dir)
        let first = await store.start()
        let second = await store.start()
        #expect(first == second)
        _ = await store.recordLaunch(idA, at: t0)
        await store.flush()
        await store.flush()
        await store.shutdown()
        await store.shutdown()

        let restored = AppLibraryMetadataStore(directory: dir)
        let loaded = await restored.start()
        #expect(loaded.usage[idA] == AppLibraryUsageRecord(launchCount: 1, lastLaunchedAt: t0))
    }

    private func makeRecord(_ id: AppID) -> AppRecord {
        AppRecord(
            id: id,
            url: URL(fileURLWithPath: id.rawValue),
            bundleIdentifier: "com.test.\(id.rawValue)",
            displayName: "App",
            infoPlistModificationDate: t0,
            iconContentVersion: IconContentVersion(bundleVersion: "1.0")
        )
    }
}
