import Foundation
import Testing
import LaunchCore
@testable import LaunchPlatform

private func appID(_ path: String) -> AppID { AppID(path)! }
private func folderID(_ raw: String) -> FolderID { FolderID(raw)! }

private func apps(_ count: Int) -> [AppID] {
    (0..<count).map { appID("/Applications/App\($0).app") }
}

private func config(columns: Int = 4, rows: Int = 3) -> AppConfiguration {
    AppConfiguration(gridColumns: columns, gridRows: rows)
}

@Suite("LayoutSnapshotStore / LayoutStore")
struct LayoutStoreTests {
    @Test("LayoutSnapshot 持久化往返")
    func persistenceRoundTrip() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutSnapshotStore(directory: dir)
        let ids = apps(3)
        let f = folderID("F")
        let snapshot = LayoutSnapshot(
            pages: [[.app(ids[0]), .folder(f)]],
            folders: [f: FolderRecord(id: f, name: "F", children: [ids[1]])],
            missingApps: [ids[2]: MissingAppState(missingSince: Date(timeIntervalSince1970: 100))]
        )
        try store.save(snapshot)
        let loaded = try #require(try store.load())
        #expect(loaded == snapshot)
    }

    @Test("损坏布局: 备份并空布局, 不静默清除")
    func corruptedLayout() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutSnapshotStore(directory: dir)
        try DurableFile.save(Data("garbage".utf8), to: store.fileURL)
        let actor = LayoutStore(seed: LayoutSnapshot(), persistence: store)
        let result = await actor.start()
        #expect(!result.loadedFromDisk)
        #expect(result.recoveredFromCorruption)
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("LayoutSnapshot.json.corrupt-") }
        #expect(backups.count == 1)
    }

    @Test("启动恢复 + 变更持久化 + 重启恢复")
    func restartPersistence() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutSnapshotStore(directory: dir)
        let ids = apps(6)

        let actor = LayoutStore(seed: LayoutSnapshot(), persistence: store)
        let start = await actor.start()
        #expect(!start.loadedFromDisk)
        // 对账后持久化
        let catalog = CatalogSnapshot(apps: ids.map {
            AppRecord(id: $0, url: URL(fileURLWithPath: $0.rawValue), bundleIdentifier: nil,
                      displayName: "A", infoPlistModificationDate: nil, iconContentVersion: .empty)
        })
        _ = await actor.reconcile(catalog: catalog, now: Date(timeIntervalSince1970: 1_000))
        #expect(await actor.currentLayout().pages[0].count == 6)

        // 重启: 新 actor 从磁盘恢复
        let actor2 = LayoutStore(seed: LayoutSnapshot(), persistence: store)
        let start2 = await actor2.start()
        #expect(start2.loadedFromDisk)
        #expect(start2.layout.pages[0].count == 6)
    }

    @Test("apply mutation 持久化并可恢复")
    func applyPersists() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutSnapshotStore(directory: dir)
        let ids = apps(5)
        let layout = LayoutSnapshot(pages: [ids.map(LayoutItem.app)])
        let actor = LayoutStore(seed: layout, persistence: store)
        _ = await actor.start()
        let display = DisplayModel(
            catalog: CatalogSnapshot(apps: []),
            layout: layout,
            config: config(columns: 4, rows: 3)
        )
        let ok = await actor.apply(
            .reorder(item: .app(ids[0]), toDisplayIndex: 4), display: display
        )
        #expect(ok)
        #expect(await actor.currentLayout().pages[0].last == .app(ids[0]))

        let actor2 = LayoutStore(seed: LayoutSnapshot(), persistence: store)
        let start2 = await actor2.start()
        #expect(start2.layout.pages[0].last == .app(ids[0]))
    }

    @Test("无效 mutation 返回 false 且不改变状态")
    func invalidMutation() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutSnapshotStore(directory: dir)
        let ids = apps(2)
        let layout = LayoutSnapshot(pages: [ids.map(LayoutItem.app)])
        let actor = LayoutStore(seed: layout, persistence: store)
        let display = DisplayModel(
            catalog: CatalogSnapshot(apps: []),
            layout: layout,
            config: config(columns: 4, rows: 3)
        )
        let ok = await actor.apply(
            .reorder(item: .app(appID("/Applications/Nope.app")), toDisplayIndex: 0),
            display: display
        )
        #expect(!ok)
        #expect(await actor.currentLayout() == layout)
    }

    @Test("无变化 mutation 不提交也不产生持久化错误")
    func unchangedMutationDoesNotCommit() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutSnapshotStore(directory: dir)
        let ids = apps(2)
        let layout = LayoutSnapshot(pages: [ids.map(LayoutItem.app)])
        let actor = LayoutStore(seed: layout, persistence: store)
        let display = DisplayModel(
            catalog: CatalogSnapshot(apps: []),
            layout: layout,
            config: config(columns: 4, rows: 3)
        )

        let changed = await actor.apply(
            .reorder(item: .app(ids[0]), toDisplayIndex: 0), display: display
        )

        #expect(!changed)
        #expect(await actor.currentLayout() == layout)
        #expect(await actor.lastPersistErrorDescription == nil)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test("缺失磁盘快照时,无变化对账仍持久化非空种子")
    func unchangedReconcilePersistsSeed() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistence = LayoutSnapshotStore(directory: dir)
        let ids = apps(2)
        let seed = LayoutSnapshot(pages: [ids.map(LayoutItem.app)])
        let actor = LayoutStore(seed: seed, persistence: persistence)
        _ = await actor.start()
        let catalog = CatalogSnapshot(apps: ids.map {
            AppRecord(
                id: $0, url: URL(fileURLWithPath: $0.rawValue),
                bundleIdentifier: nil, displayName: $0.rawValue,
                infoPlistModificationDate: nil,
                iconContentVersion: .empty
            )
        })

        let result = await actor.reconcileWithResult(catalog: catalog, now: Date())
        #expect(result.committed)
        #expect(FileManager.default.fileExists(atPath: persistence.fileURL.path))

        let restarted = LayoutStore(seed: LayoutSnapshot(), persistence: persistence)
        #expect(await restarted.start().layout == seed)
    }

    @Test("持久化失败: mutation 返回 false 且内存布局回滚")
    func persistenceFailureRollsBack() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 让 persistence 的“目录”实际指向普通文件，createDirectory/save 必然失败。
        let blocked = dir.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blocked)
        let persistence = LayoutSnapshotStore(directory: blocked)
        let ids = apps(3)
        let initial = LayoutSnapshot(pages: [ids.map(LayoutItem.app)])
        let actor = LayoutStore(seed: initial, persistence: persistence)
        let display = DisplayModel(
            catalog: CatalogSnapshot(apps: []),
            layout: initial,
            config: config(columns: 4, rows: 3)
        )

        let ok = await actor.apply(
            .reorder(item: .app(ids[0]), toDisplayIndex: 2), display: display
        )

        #expect(!ok)
        #expect(await actor.currentLayout() == initial)
        #expect(await actor.lastPersistErrorDescription != nil)
    }

    @Test("陈旧布局期望被拒绝且不覆盖较新状态")
    func staleExpectedLayoutIsRejected() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutSnapshotStore(directory: dir)
        let ids = apps(3)
        let initial = LayoutSnapshot(pages: [ids.map(LayoutItem.app)])
        let actor = LayoutStore(seed: initial, persistence: store)
        let initialDisplay = DisplayModel(
            catalog: CatalogSnapshot(apps: []),
            layout: initial,
            config: config(columns: 4, rows: 3)
        )
        #expect(await actor.apply(
            .reorder(item: .app(ids[0]), toDisplayIndex: 2),
            display: initialDisplay,
            expectedLayout: initial
        ))
        let newer = await actor.currentLayout()

        let staleResult = await actor.apply(
            .reorder(item: .app(ids[1]), toDisplayIndex: 0),
            display: initialDisplay,
            expectedLayout: initial
        )

        #expect(!staleResult)
        #expect(await actor.currentLayout() == newer)
    }

    @Test("文件夹操作: 创建/重命名/解散, 持久化")
    func folderOperations() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutSnapshotStore(directory: dir)
        let ids = apps(4)
        let layout = LayoutSnapshot(pages: [ids.map(LayoutItem.app)])
        let actor = LayoutStore(seed: layout, persistence: store)
        _ = await actor.start()
        let display = DisplayModel(
            catalog: CatalogSnapshot(apps: []),
            layout: layout,
            config: config(columns: 4, rows: 3)
        )

        let folderID = try #require(await actor.createFolder(
            display: display, name: "工具", appIDs: [ids[1], ids[2]]
        ))
        #expect(await actor.currentLayout().folders[folderID]?.name == "工具")

        #expect(await actor.renameFolder(folderID, to: "开发"))
        #expect(await actor.currentLayout().folders[folderID]?.name == "开发")

        let layoutWithFolder = await actor.currentLayout()
        let display2 = DisplayModel(
            catalog: CatalogSnapshot(apps: []),
            layout: layoutWithFolder,
            config: config(columns: 4, rows: 3)
        )
        #expect(await actor.dissolveFolder(display: display2, id: folderID))
        #expect(await actor.currentLayout().folders[folderID] == nil)

        // 重启恢复(解散后的状态)
        let actor2 = LayoutStore(seed: LayoutSnapshot(), persistence: store)
        _ = await actor2.start()
        #expect(await actor2.currentLayout().folders.isEmpty)
        #expect(await actor2.currentLayout().pages[0].count == 4)
    }
}
