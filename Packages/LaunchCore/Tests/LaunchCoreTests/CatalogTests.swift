import Foundation
import Testing
@testable import LaunchCore

@Suite("CatalogSnapshot / CatalogDelta")
struct CatalogTests {
    private func record(_ path: String) throws -> AppRecord {
        let id = try #require(AppID(path))
        return AppRecord(
            id: id,
            url: URL(fileURLWithPath: path),
            bundleIdentifier: nil,
            displayName: "App",
            infoPlistModificationDate: nil,
            iconContentVersion: .empty
        )
    }

    @Test("apps 保持按 AppID 排序的不变式")
    func sortedInvariant() throws {
        let b = try record("/Applications/B.app")
        let a = try record("/Applications/A.app")
        let c = try record("/Applications/C.app")
        let snapshot = CatalogSnapshot(apps: [b, a, c])
        #expect(snapshot.apps.map(\.id.rawValue) == [
            "/Applications/A.app",
            "/Applications/B.app",
            "/Applications/C.app",
        ])
    }

    @Test("Codable 往返后保持排序不变式")
    func codableSortedInvariant() throws {
        let snapshot = CatalogSnapshot(apps: [try record("/Z.app"), try record("/A.app")])
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(CatalogSnapshot.self, from: data)
        #expect(decoded.apps.map(\.id.rawValue) == ["/A.app", "/Z.app"])
    }

    @Test("schemaVersion 与查询方法正确")
    func lookups() throws {
        let a = try record("/Applications/A.app")
        let snapshot = CatalogSnapshot(apps: [a])
        #expect(snapshot.schemaVersion == CatalogSnapshot.currentSchemaVersion)
        #expect(snapshot.contains(a.id))
        #expect(snapshot.app(with: a.id) == a)
        #expect(!snapshot.contains(try #require(AppID("/Applications/Nope.app"))))
    }

    @Test("旧版 v1 快照解码迁移(无 localizedNames 字段)")
    func decodesLegacyV1Snapshot() throws {
        let json = """
        {
          "schemaVersion": 1,
          "apps": [
            {
              "id": "/Applications/A.app",
              "url": "file:///Applications/A.app",
              "bundleIdentifier": null,
              "displayName": "A",
              "infoPlistModificationDate": null,
              "iconContentVersion": {}
            }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(CatalogSnapshot.self, from: Data(json.utf8))
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.apps.count == 1)
        #expect(decoded.apps[0].localizedNames.isEmpty)
        #expect(decoded.apps[0].displayName == "A")
    }

    @Test("空 CatalogDelta 判定与字段")
    func deltaEmpty() throws {
        let delta = CatalogDelta()
        #expect(delta.isEmpty)
        #expect(delta.inserted.isEmpty)
        #expect(delta.updated.isEmpty)
        #expect(delta.removed.isEmpty)
    }

    @Test("CatalogDelta Codable 往返")
    func deltaRoundTrip() throws {
        let record = try record("/Applications/A.app")
        let removed = try #require(AppID("/Applications/Removed.app"))
        let delta = CatalogDelta(inserted: [record], removed: [removed])
        let data = try JSONEncoder().encode(delta)
        let decoded = try JSONDecoder().decode(CatalogDelta.self, from: data)
        #expect(decoded == delta)
        #expect(!decoded.isEmpty)
    }
}
