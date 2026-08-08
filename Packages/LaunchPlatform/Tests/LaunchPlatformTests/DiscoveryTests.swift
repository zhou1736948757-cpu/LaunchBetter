import Foundation
import Testing
import LaunchCore
@testable import LaunchPlatform

func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("LaunchPlatformTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
func makeFakeApp(
    in parent: URL,
    name: String,
    bundleID: String,
    version: String = "1.0",
    displayName: String? = nil
) throws -> URL {
    let appURL = parent.appendingPathComponent("\(name).app")
    let contents = appURL.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    var plist: [String: Any] = [
        "CFBundleIdentifier": bundleID,
        "CFBundleName": name,
        "CFBundleVersion": version,
    ]
    if let displayName {
        plist["CFBundleDisplayName"] = displayName
    }
    let data = try PropertyListSerialization.data(
        fromPropertyList: plist, format: .xml, options: 0
    )
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    return appURL
}

@Suite("PathCanonicalizer 文件系统收敛")
struct PathCanonicalizerTests {
    @Test("相对组件标准化")
    func normalizesDotDot() {
        let path = PathCanonicalizer.canonicalPath(
            from: URL(fileURLWithPath: "/tmp/a/../b/c")
        )
        #expect(path == "/tmp/b/c")
    }

    @Test("symlink 收敛: 链接路径与目标路径得到同一 AppID")
    func symlinkConvergence() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("Real.app")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let viaLink = PathCanonicalizer.canonicalAppID(from: link)
        let viaReal = PathCanonicalizer.canonicalAppID(from: real)
        #expect(viaLink == viaReal)
    }

    @Test("/var 与 /private/var 收敛(系统 symlink)")
    func privateVarConvergence() {
        let varURL = URL(fileURLWithPath: "/var")
        let privateVarURL = URL(fileURLWithPath: "/private/var")
        guard FileManager.default.fileExists(atPath: privateVarURL.path) else {
            // 非常规系统,跳过
            return
        }
        #expect(
            PathCanonicalizer.canonicalAppID(from: varURL)
                == PathCanonicalizer.canonicalAppID(from: privateVarURL)
        )
    }

    @Test("不存在路径回退纯文本规范化")
    func nonexistentFallback() {
        let id = PathCanonicalizer.canonicalAppID(
            from: URL(fileURLWithPath: "/Applications/DefinitelyMissing.app")
        )
        #expect(id.rawValue == "/Applications/DefinitelyMissing.app")
    }
}

@Suite("AppDiscoveryService 应用发现")
struct AppDiscoveryServiceTests {
    @Test("发现真实 fake app: 名称/bundleID/内容版本信号")
    func discoversApps() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeFakeApp(in: dir, name: "Foo", bundleID: "com.test.Foo", displayName: "Foo App")
        try makeFakeApp(in: dir, name: "Bar", bundleID: "com.test.Bar", version: "2.3")

        let records = AppDiscoveryService.discover(sources: [dir])

        #expect(records.count == 2)
        let foo = try #require(records.first { $0.bundleIdentifier == "com.test.Foo" })
        #expect(foo.displayName == "Foo App")
        #expect(foo.iconContentVersion.bundleVersion == "1.0")
        #expect(foo.iconContentVersion.infoPlistModificationNanoseconds != nil)
        let bar = try #require(records.first { $0.bundleIdentifier == "com.test.Bar" })
        #expect(bar.displayName == "Bar")
        #expect(bar.iconContentVersion.bundleVersion == "2.3")
    }

    @Test("displayName 回退链: CFBundleDisplayName → CFBundleName → 文件名")
    func displayNameFallback() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeFakeApp(in: dir, name: "NoName", bundleID: "com.test.NoName")
        var plist: [String: Any] = ["CFBundleIdentifier": "com.test.OnlyFile"]
        let appURL = dir.appendingPathComponent("OnlyFile.app")
        let contents = appURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        let records = AppDiscoveryService.discover(sources: [dir])
        #expect(records.count == 2)
        #expect(records.first { $0.bundleIdentifier == "com.test.NoName" }?.displayName == "NoName")
        #expect(records.first { $0.bundleIdentifier == "com.test.OnlyFile" }?.displayName == "OnlyFile")
    }

    @Test("非 .app 目录与隐藏文件被忽略")
    func ignoresNonApps() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeFakeApp(in: dir, name: "Real", bundleID: "com.test.Real")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("NotAnApp"), withIntermediateDirectories: true
        )
        let records = AppDiscoveryService.discover(sources: [dir])
        #expect(records.count == 1)
        #expect(records[0].bundleIdentifier == "com.test.Real")
    }

    @Test("无 Info.plist 的 .app 目录被跳过")
    func skipsWithoutInfoPlist() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeFakeApp(in: dir, name: "Good", bundleID: "com.test.Good")
        let empty = dir.appendingPathComponent("Empty.app")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        let records = AppDiscoveryService.discover(sources: [dir])
        #expect(records.count == 1)
        #expect(records[0].bundleIdentifier == "com.test.Good")
    }

    @Test("不存在的源目录返回空")
    func missingSource() {
        let records = AppDiscoveryService.discover(
            sources: [URL(fileURLWithPath: "/nonexistent/dir/xyz")]
        )
        #expect(records.isEmpty)
    }

    @Test("AppID 规范化: 记录身份与 URL 一致")
    func recordIdentity() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appURL = try makeFakeApp(in: dir, name: "Foo", bundleID: "com.test.Foo")
        let record = try #require(AppDiscoveryService.makeRecord(from: appURL))
        let canonicalPath = PathCanonicalizer.canonicalPath(from: appURL)
        #expect(record.id.rawValue == canonicalPath)
        #expect(record.url == URL(fileURLWithPath: canonicalPath))
    }
}

@Suite("ReconcileEngine 增量对账")
struct ReconcileEngineTests {
    private func record(_ path: String, version: String = "1.0") -> AppRecord {
        AppRecord(
            id: AppID(path)!,
            url: URL(fileURLWithPath: path),
            bundleIdentifier: "com.test",
            displayName: "App",
            infoPlistModificationDate: nil,
            iconContentVersion: IconContentVersion(bundleVersion: version)
        )
    }

    @Test("全新增 → inserted(按 AppID 排序)")
    func allInserted() {
        let delta = ReconcileEngine.delta(
            from: CatalogSnapshot(apps: []),
            to: [record("/Applications/B.app"), record("/Applications/A.app")]
        )
        #expect(delta.inserted.map(\.id.rawValue) == [
            "/Applications/A.app",
            "/Applications/B.app",
        ])
        #expect(delta.updated.isEmpty)
        #expect(delta.removed.isEmpty)
    }

    @Test("完全相同 → 空增量")
    func identical() {
        let snapshot = CatalogSnapshot(apps: [record("/Applications/A.app")])
        let delta = ReconcileEngine.delta(
            from: snapshot, to: snapshot.apps
        )
        #expect(delta.isEmpty)
    }

    @Test("内容变化 → updated(版本/名称)")
    func updated() {
        let old = CatalogSnapshot(apps: [record("/Applications/A.app", version: "1.0")])
        let new = record("/Applications/A.app", version: "2.0")
        let delta = ReconcileEngine.delta(from: old, to: [new])
        #expect(delta.updated == [new])
        #expect(delta.inserted.isEmpty)
        #expect(delta.removed.isEmpty)
    }

    @Test("消失应用 → removed(排序)")
    func removed() {
        let old = CatalogSnapshot(apps: [
            record("/Applications/B.app"),
            record("/Applications/A.app"),
        ])
        let delta = ReconcileEngine.delta(from: old, to: [record("/Applications/A.app")])
        #expect(delta.removed == [AppID("/Applications/B.app")!])
    }

    @Test("混合场景")
    func mixed() {
        let old = CatalogSnapshot(apps: [
            record("/Applications/Keep.app"),
            record("/Applications/Update.app", version: "1.0"),
            record("/Applications/Gone.app"),
        ])
        let delta = ReconcileEngine.delta(from: old, to: [
            record("/Applications/New.app"),
            record("/Applications/Keep.app"),
            record("/Applications/Update.app", version: "1.1"),
        ])
        #expect(delta.inserted.map(\.id.rawValue) == ["/Applications/New.app"])
        #expect(delta.updated.map(\.id.rawValue) == ["/Applications/Update.app"])
        #expect(delta.removed == [AppID("/Applications/Gone.app")!])
    }
}
