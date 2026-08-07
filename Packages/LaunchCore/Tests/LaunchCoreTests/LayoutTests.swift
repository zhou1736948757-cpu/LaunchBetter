import Foundation
import Testing
@testable import LaunchCore

@Suite("布局模型: LayoutItem / FolderRecord / LayoutSnapshot / MissingAppState")
struct LayoutTests {
    @Test("LayoutItem 编码: app 与 folder 两种形态")
    func layoutItemCoding() throws {
        let app = LayoutItem.app(try #require(AppID("/Applications/Safari.app")))
        let folder = LayoutItem.folder(try #require(FolderID("Tools")))
        let appData = try JSONEncoder().encode(app)
        let folderData = try JSONEncoder().encode(folder)
        #expect(try JSONDecoder().decode(LayoutItem.self, from: appData) == app)
        #expect(try JSONDecoder().decode(LayoutItem.self, from: folderData) == folder)
        #expect(app != folder)
    }

    @Test("FolderRecord 保持 children 插入顺序")
    func folderChildrenOrder() throws {
        let a = try #require(AppID("/Applications/A.app"))
        let b = try #require(AppID("/Applications/B.app"))
        let folder = FolderRecord(id: try #require(FolderID("F")), name: "Dev", children: [a, b])
        #expect(folder.children == [a, b])
        #expect(folder.children.first == a)
    }

    @Test("LayoutSnapshot 默认 schemaVersion = 1")
    func snapshotSchemaVersion() {
        let snapshot = LayoutSnapshot()
        #expect(snapshot.schemaVersion == LayoutSnapshot.currentSchemaVersion)
        #expect(snapshot.pages.isEmpty)
        #expect(snapshot.folders.isEmpty)
        #expect(snapshot.missingApps.isEmpty)
    }

    @Test("LayoutSnapshot Codable 往返")
    func snapshotCodableRoundTrip() throws {
        let appID = try #require(AppID("/Applications/Safari.app"))
        let folderID = try #require(FolderID("Tools"))
        let snapshot = LayoutSnapshot(
            pages: [[.app(appID), .folder(folderID)], []],
            folders: [
                folderID: FolderRecord(id: folderID, name: "Tools", children: [appID])
            ],
            missingApps: [
                appID: MissingAppState(missingSince: Date(timeIntervalSince1970: 5_000))
            ]
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(LayoutSnapshot.self, from: data)
        #expect(decoded.pages == snapshot.pages)
        #expect(decoded.folders == snapshot.folders)
        #expect(decoded.missingApps == snapshot.missingApps)
        #expect(decoded.schemaVersion == 1)
    }

    @Test("MissingAppState Codable 往返")
    func missingStateRoundTrip() throws {
        let state = MissingAppState(missingSince: Date(timeIntervalSince1970: 42))
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(MissingAppState.self, from: data)
        #expect(decoded == state)
    }

    @Test("referencedAppIDs 汇总页面与文件夹子项")
    func referencedAppIDs() throws {
        let a = try #require(AppID("/Applications/A.app"))
        let b = try #require(AppID("/Applications/B.app"))
        let c = try #require(AppID("/Applications/C.app"))
        let folderID = try #require(FolderID("F"))
        let snapshot = LayoutSnapshot(
            pages: [[.app(a), .folder(folderID)]],
            folders: [folderID: FolderRecord(id: folderID, name: "F", children: [b, c])]
        )
        #expect(snapshot.referencedAppIDs == [a, b, c])
    }
}
