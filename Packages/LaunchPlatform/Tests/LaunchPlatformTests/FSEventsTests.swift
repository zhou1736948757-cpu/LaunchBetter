import Foundation
import Testing
import LaunchCore
@testable import LaunchPlatform

@Suite("AppRootFolding 事件折叠")
struct AppRootFoldingTests {
    private let scopes = ["/Applications", "/Users/mac/Applications", "/Volumes/Dev"]

    @Test(".app 内部事件折叠到 .app 根")
    func foldsAppRoot() {
        #expect(AppRootFolding.fold("/Applications/Foo.app/Contents/Info.plist", scopes: scopes)
            == .appRoot("/Applications/Foo.app"))
        #expect(AppRootFolding.fold("/Applications/Foo.app", scopes: scopes)
            == .appRoot("/Applications/Foo.app"))
        #expect(AppRootFolding.fold("/Applications/Foo.app/Contents/MacOS/Foo", scopes: scopes)
            == .appRoot("/Applications/Foo.app"))
    }

    @Test("scope 目录自身变化 → scopeDirty")
    func scopeDirty() {
        #expect(AppRootFolding.fold("/Applications", scopes: scopes)
            == .scopeDirty("/Applications"))
        #expect(AppRootFolding.fold("/Applications/Installer.staging", scopes: scopes)
            == .scopeDirty("/Applications"))
    }

    @Test("非 .app 子项 → scopeDirty(最长匹配 scope)")
    func nonAppSubitem() {
        #expect(AppRootFolding.fold("/Applications/SomeFile", scopes: scopes)
            == .scopeDirty("/Applications"))
        // 嵌套目录
        #expect(AppRootFolding.fold("/Applications/Foo/bar/baz", scopes: scopes)
            == .scopeDirty("/Applications"))
    }

    @Test("多 scope 取最长匹配")
    func longestScopeMatch() {
        #expect(AppRootFolding.fold("/Users/mac/Applications/Tools.app/Contents", scopes: scopes)
            == .appRoot("/Users/mac/Applications/Tools.app"))
    }

    @Test("scope 前缀不误匹配(子串陷阱)")
    func noPartialPrefix() {
        // /Applications2 不应匹配 /Applications
        let scopes = ["/Applications"]
        #expect(AppRootFolding.fold("/Applications2/Foo.app", scopes: scopes) == .ignored)
        #expect(AppRootFolding.fold("/ApplicationsX", scopes: scopes) == .ignored)
    }

    @Test("scope 外的路径 → ignored")
    func ignored() {
        #expect(AppRootFolding.fold("/System/Library/Foo.app", scopes: scopes) == .ignored)
        #expect(AppRootFolding.fold("/tmp/x", scopes: scopes) == .ignored)
    }
}

@Suite("AppCatalogActor 增量对账(FSEvents)")
struct IncrementalReconcileTests {
    private func makeActor(
        dir: URL, source: URL
    ) -> AppCatalogActor {
        AppCatalogActor(store: CatalogSnapshotStore(directory: dir), sources: [source])
    }

    @Test("reconcileScope: 安装新应用 → inserted")
    func scopeInsert() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: source) }
        let actor = makeActor(dir: dir, source: source)
        _ = await actor.start()

        try makeFakeApp(in: source, name: "NewApp", bundleID: "com.test.NewApp")
        let delta = await actor.reconcileScope(source)
        #expect(delta.inserted.count == 1)
        #expect(delta.removed.isEmpty)
        #expect(await actor.currentSnapshot().apps.count == 1)
    }

    @Test("reconcileAppRoot: 元数据变化 → updated(图标内容版本信号)")
    func appRootUpdate() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: source) }
        let actor = makeActor(dir: dir, source: source)
        _ = await actor.start()
        let appURL = try makeFakeApp(in: source, name: "Foo", bundleID: "com.test.Foo", version: "1.0")

        _ = await actor.reconcileScope(source)
        // 修改版本 → 重扫该 .app
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.test.Foo",
                "CFBundleName": "Foo",
                "CFBundleVersion": "2.0",
            ],
            format: .xml, options: 0
        )
        try data.write(to: plistURL)
        let stamp = Date().addingTimeInterval(2)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: plistURL.path)

        let delta = await actor.reconcileAppRoot(appURL)
        #expect(delta.updated.count == 1)
        #expect(delta.updated[0].iconContentVersion.bundleVersion == "2.0")
    }

    @Test("reconcileAppRoot: 应用删除 → removed; 恢复 → inserted")
    func appRootRemovedAndRestored() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: source) }
        let actor = makeActor(dir: dir, source: source)
        _ = await actor.start()
        let appURL = try makeFakeApp(in: source, name: "Foo", bundleID: "com.test.Foo")

        _ = await actor.reconcileScope(source)
        let canonicalAppURL = URL(fileURLWithPath: PathCanonicalizer.canonicalPath(from: appURL))
        try FileManager.default.removeItem(at: appURL)
        let removed = await actor.reconcileAppRoot(appURL)
        #expect(removed.removed == [AppID(canonicalAppURL.path)!])

        // 恢复
        try makeFakeApp(in: source, name: "Foo", bundleID: "com.test.Foo")
        let restored = await actor.reconcileAppRoot(appURL)
        #expect(restored.inserted.count == 1)
    }

    @Test("reconcileScope 不影响 scope 外应用")
    func scopeIsolation() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceA = try tempDirectory()
        let sourceB = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceA)
            try? FileManager.default.removeItem(at: sourceB)
        }
        let actor = AppCatalogActor(
            store: CatalogSnapshotStore(directory: dir), sources: [sourceA, sourceB]
        )
        _ = await actor.start()
        try makeFakeApp(in: sourceA, name: "A", bundleID: "com.test.A")
        try makeFakeApp(in: sourceB, name: "B", bundleID: "com.test.B")
        _ = try await actor.reconcileFromDisk()

        // 只重扫 A: B 不受影响
        let delta = await actor.reconcileScope(sourceA)
        #expect(delta.isEmpty)
        let ids = await actor.currentSnapshot().apps.map(\.bundleIdentifier)
        #expect(ids.contains("com.test.A"))
        #expect(ids.contains("com.test.B"))
    }

    @Test("applyChangeSummary: appRoot + scope 组合增量")
    func changeSummaryMerge() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: source) }
        let actor = makeActor(dir: dir, source: source)
        _ = await actor.start()
        let appURL = try makeFakeApp(in: source, name: "Foo", bundleID: "com.test.Foo", version: "1.0")
        _ = await actor.reconcileScope(source)

        // 修改 Foo 版本 + 安装 Bar
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.test.Foo",
                "CFBundleName": "Foo",
                "CFBundleVersion": "3.0",
            ],
            format: .xml, options: 0
        )
        try data.write(to: plistURL)
        try makeFakeApp(in: source, name: "Bar", bundleID: "com.test.Bar")

        let summary = DirectoryMonitor.ChangeSummary(
            dirtyScopes: [source.path],
            dirtyAppRoots: [appURL.path],
            eventLossDetected: false
        )
        let delta = await actor.applyChangeSummary(summary)
        #expect(delta.inserted.count == 1)
        #expect(delta.updated.count == 1)
        #expect(await actor.currentSnapshot().apps.count == 2)
    }

    @Test("事件丢失 → 受影响 scope 恢复性重扫")
    func eventLossRecovery() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: source) }
        let actor = makeActor(dir: dir, source: source)
        _ = await actor.start()
        try makeFakeApp(in: source, name: "A", bundleID: "com.test.A")
        try makeFakeApp(in: source, name: "B", bundleID: "com.test.B")

        let summary = DirectoryMonitor.ChangeSummary(
            dirtyScopes: [source.path], dirtyAppRoots: [], eventLossDetected: true
        )
        let delta = await actor.applyChangeSummary(summary)
        #expect(delta.inserted.count == 2, "事件丢失应触发该 scope 全量重扫")
    }
}

@Suite("DirectoryMonitor 实时 FSEvents")
struct DirectoryMonitorTests {
    private actor MatchFlag {
        private(set) var matched = false
        func mark() { matched = true }
    }

    @Test("创建/删除 .app 产生折叠摘要")
    func realEvents() async throws {
        let source = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: source) }
        // 与 DirectoryMonitor 相同规范化(FSEvents 报告真实路径)
        let canonicalSource = PathCanonicalizer.canonicalPath(from: source)
        let monitor = DirectoryMonitor(scopes: [source.path], latency: 0.1)
        let flag = MatchFlag()
        monitor.onChange = { summary in
            if summary.dirtyScopes.contains(canonicalSource)
                || summary.dirtyAppRoots.contains(
                    canonicalSource + "/Real.app"
                ) {
                Task { await flag.mark() }
            }
        }
        monitor.start()
        try await Task.sleep(nanoseconds: 500_000_000)

        // 创建 .app 目录(触发目录级事件)
        let appURL = source.appendingPathComponent("Real.app")
        try FileManager.default.createDirectory(
            at: appURL.appendingPathComponent("Contents"), withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: appURL.appendingPathComponent("Contents/Info.plist"))

        // 有界轮询(最多 8s), 避免挂起
        var found = false
        for _ in 0..<80 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await flag.matched {
                found = true
                break
            }
        }
        monitor.stop()
        #expect(found, "应收到折叠摘要(scope 脏或 appRoot)")
    }
}
