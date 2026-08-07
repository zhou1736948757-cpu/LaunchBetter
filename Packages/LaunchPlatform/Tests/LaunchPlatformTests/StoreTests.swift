import Foundation
import Testing
import LaunchCore
@testable import LaunchPlatform

@Suite("持久存储: CatalogSnapshotStore / SettingsStore / DurableFile")
struct StoreTests {
    @Test("CatalogSnapshot 往返")
    func catalogRoundTrip() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogSnapshotStore(directory: dir)
        let snapshot = CatalogSnapshot(apps: [
            AppRecord(
                id: AppID("/Applications/A.app")!,
                url: URL(fileURLWithPath: "/Applications/A.app"),
                bundleIdentifier: "com.test.A",
                displayName: "A",
                infoPlistModificationDate: Date(timeIntervalSince1970: 100),
                iconContentVersion: IconContentVersion(bundleVersion: "1.0")
            )
        ])

        try store.save(snapshot)
        let loaded = try #require(try store.load())
        #expect(loaded == snapshot)
        #expect(loaded.schemaVersion == CatalogSnapshot.currentSchemaVersion)
    }

    @Test("文件不存在 → nil")
    func loadMissing() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogSnapshotStore(directory: dir)
        #expect(try store.load() == nil)
    }

    @Test("损坏文件 → 抛错,不静默清除")
    func corruptedThrows() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogSnapshotStore(directory: dir)
        try DurableFile.save(Data("garbage-not-json".utf8), to: store.fileURL)

        #expect(throws: Swift.Error.self) {
            _ = try store.load()
        }
        // 文件仍在
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test("损坏备份: 文件被重命名保留")
    func backupCorrupted() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogSnapshotStore(directory: dir)
        try DurableFile.save(Data("garbage".utf8), to: store.fileURL)

        let backup = try store.backupCorruptedFile()
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(backup.lastPathComponent.hasPrefix("CatalogSnapshot.json.corrupt-"))
    }

    @Test("Settings 往返与默认字段")
    func settingsRoundTrip() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        var config = AppConfiguration()
        config.gridColumns = 6
        config.language = .simplifiedChinese

        try store.save(config)
        let loaded = try #require(try store.load())
        #expect(loaded.gridColumns == 6)
        #expect(loaded.language == .simplifiedChinese)
        #expect(loaded.iconSize == 80)
        #expect(loaded.schemaVersion == AppConfiguration.currentSchemaVersion)
    }

    @Test("Settings 缺失与损坏")
    func settingsMissingAndCorrupted() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        #expect(try store.load() == nil)

        try DurableFile.save(Data("junk".utf8), to: store.fileURL)
        #expect(throws: Swift.Error.self) {
            _ = try store.load()
        }
    }

    @Test("DurableFile 自动创建目录")
    func durableFileCreatesDirectories() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let nested = dir.appendingPathComponent("a/b/c")
        let file = nested.appendingPathComponent("state.json")
        try DurableFile.save(Data("{}".utf8), to: file)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try DurableFile.loadData(at: file) != nil)
    }
}

@Suite("StateMigrationService 迁移框架")
struct StateMigrationTests {
    private struct FakeV1: Codable, Equatable {
        let schemaVersion: Int
        let name: String
    }

    private struct FakeV2: Codable, Equatable {
        let schemaVersion: Int
        let name: String
        let added: Int
    }

    private struct FakeV3: Codable, Equatable {
        let schemaVersion: Int
        let name: String
        let added: Int
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    @Test("版本相同直接透传")
    func passthrough() throws {
        let data = try encode(FakeV1(schemaVersion: 1, name: "x"))
        let migrated = try StateMigrationService.migrateData(
            data, currentVersion: 1, toVersion: 1, steps: [:]
        )
        #expect(migrated == data)
    }

    @Test("单步迁移 1 → 2")
    func singleStep() throws {
        let v1 = try encode(FakeV1(schemaVersion: 1, name: "x"))
        let step: @Sendable (Data) throws -> Data = { data in
            let decoded = try JSONDecoder().decode(FakeV1.self, from: data)
            return try JSONEncoder().encode(FakeV2(schemaVersion: 2, name: decoded.name, added: 42))
        }
        let migrated = try StateMigrationService.migrateData(
            v1, currentVersion: 1, toVersion: 2, steps: [1: step]
        )
        let v2 = try decode(FakeV2.self, from: migrated)
        #expect(v2.schemaVersion == 2)
        #expect(v2.name == "x")
        #expect(v2.added == 42)
    }

    @Test("链式迁移 1 → 2 → 3")
    func chained() throws {
        let v1 = try encode(FakeV1(schemaVersion: 1, name: "x"))
        let step1: @Sendable (Data) throws -> Data = { data in
            let decoded = try JSONDecoder().decode(FakeV1.self, from: data)
            return try JSONEncoder().encode(FakeV2(schemaVersion: 2, name: decoded.name, added: 1))
        }
        let step2: @Sendable (Data) throws -> Data = { data in
            let decoded = try JSONDecoder().decode(FakeV2.self, from: data)
            return try JSONEncoder().encode(FakeV3(schemaVersion: 3, name: decoded.name, added: decoded.added + 1))
        }
        let migrated = try StateMigrationService.migrateData(
            v1, currentVersion: 1, toVersion: 3, steps: [1: step1, 2: step2]
        )
        let v3 = try decode(FakeV3.self, from: migrated)
        #expect(v3.schemaVersion == 3)
        #expect(v3.added == 2)
    }

    @Test("缺失迁移路径抛错")
    func noPathThrows() throws {
        let v1 = try encode(FakeV1(schemaVersion: 1, name: "x"))
        #expect(throws: StateMigrationService.MigrationError.noMigrationPath(from: 1)) {
            _ = try StateMigrationService.migrateData(
                v1, currentVersion: 1, toVersion: 2, steps: [:]
            )
        }
    }

    @Test("状态版本高于目标 → 抛错")
    func newerVersionThrows() throws {
        let v2 = try encode(FakeV2(schemaVersion: 2, name: "x", added: 0))
        #expect(throws: StateMigrationService.MigrationError.versionNewerThanSupported(2)) {
            _ = try StateMigrationService.migrateData(
                v2, currentVersion: 2, toVersion: 1, steps: [:]
            )
        }
    }
}

@Suite("AppCatalogActor 目录服务")
struct AppCatalogActorTests {
    @Test("空目录启动: 无磁盘快照, 空目录")
    func emptyStart() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let actor = AppCatalogActor(store: CatalogSnapshotStore(directory: dir), sources: [])
        let result = await actor.start()
        #expect(!result.loadedFromDisk)
        #expect(!result.recoveredFromCorruption)
        #expect(await actor.currentSnapshot().apps.isEmpty)
    }

    @Test("对账发现应用 → 增量插入; 持久化; 重启恢复")
    func reconcilePersistRestore() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceDir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        try makeFakeApp(in: sourceDir, name: "Foo", bundleID: "com.test.Foo")
        try makeFakeApp(in: sourceDir, name: "Bar", bundleID: "com.test.Bar")

        let store = CatalogSnapshotStore(directory: dir)
        let actor = AppCatalogActor(store: store, sources: [sourceDir])
        _ = await actor.start()
        let gen0 = await actor.snapshotGeneration()

        let delta = try await actor.reconcileFromDisk()
        #expect(delta.inserted.count == 2)
        #expect(delta.removed.isEmpty)
        #expect(await actor.currentSnapshot().apps.count == 2)
        // 陈旧防护: 旧代数取不到新快照
        #expect(await actor.currentSnapshot(ifGeneration: gen0) == nil)
        let gen1 = await actor.snapshotGeneration()
        #expect(await actor.currentSnapshot(ifGeneration: gen1) != nil)

        // 再次对账: 无变化
        let delta2 = try await actor.reconcileFromDisk()
        #expect(delta2.isEmpty)

        // 重启恢复
        let actor2 = AppCatalogActor(store: store, sources: [sourceDir])
        let start2 = await actor2.start()
        #expect(start2.loadedFromDisk)
        #expect(start2.snapshot.apps.count == 2)
    }

    @Test("对账增量: 删除应用产生 removed")
    func reconcileRemoved() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceDir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        try makeFakeApp(in: sourceDir, name: "Foo", bundleID: "com.test.Foo")

        let store = CatalogSnapshotStore(directory: dir)
        let actor = AppCatalogActor(store: store, sources: [sourceDir])
        _ = await actor.start()
        _ = try await actor.reconcileFromDisk()

        try FileManager.default.removeItem(at: sourceDir.appendingPathComponent("Foo.app"))
        let delta = try await actor.reconcileFromDisk()
        #expect(delta.removed == [AppID(
            sourceDir.appendingPathComponent("Foo.app").resolvingSymlinksInPath().standardizedFileURL.path
        )!])
        #expect(delta.inserted.isEmpty)
    }

    @Test("损坏快照: 备份并恢复为空, 不静默清除")
    func corruptedSnapshotRecovery() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogSnapshotStore(directory: dir)
        try DurableFile.save(Data("garbage".utf8), to: store.fileURL)

        let actor = AppCatalogActor(store: store, sources: [])
        let result = await actor.start()
        #expect(!result.loadedFromDisk)
        #expect(result.recoveredFromCorruption)
        #expect(result.snapshot.apps.isEmpty)

        // 备份文件保留
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("CatalogSnapshot.json.corrupt-") }
        #expect(backups.count == 1)
    }
}
