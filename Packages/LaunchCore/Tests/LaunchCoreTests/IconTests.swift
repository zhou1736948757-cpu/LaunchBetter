import Foundation
import Testing
@testable import LaunchCore

@Suite("IconContentVersion / IconKey")
struct IconTests {
    @Test("内容版本: 相同信号相等, 任一信号变化即不等")
    func contentVersionEquality() {
        let v1 = IconContentVersion(
            iconResourceModificationNanoseconds: 100,
            iconResourceSizeBytes: 200
        )
        let v1Again = IconContentVersion(
            iconResourceModificationNanoseconds: 100,
            iconResourceSizeBytes: 200
        )
        let v2 = IconContentVersion(
            iconResourceModificationNanoseconds: 101,
            iconResourceSizeBytes: 200
        )
        #expect(v1 == v1Again)
        #expect(v1 != v2)
    }

    @Test("内容版本 Codable 往返")
    func contentVersionRoundTrip() throws {
        let v = IconContentVersion(
            iconResourceModificationNanoseconds: 123_456,
            iconResourceSizeBytes: 9_999,
            infoPlistModificationNanoseconds: 77,
            bundleVersion: "1.2.3"
        )
        let data = try JSONEncoder().encode(v)
        let decoded = try JSONDecoder().decode(IconContentVersion.self, from: data)
        #expect(decoded == v)
    }

    @Test("空版本无信号; 含任一信号即有")
    func emptyVersion() {
        #expect(!IconContentVersion.empty.hasSignals)
        #expect(IconContentVersion(bundleVersion: "1").hasSignals)
    }

    @Test("IconKey 区分尺寸/缩放变体: 96@1x != 96@2x != 64@2x")
    func keyVariantsDistinct() throws {
        let app = try #require(AppID("/Applications/A.app"))
        let version = IconContentVersion(iconResourceSizeBytes: 1)
        let k96_1 = IconKey(appID: app, pointSize: 96, scale: 1, contentVersion: version)
        let k96_2 = IconKey(appID: app, pointSize: 96, scale: 2, contentVersion: version)
        let k64_2 = IconKey(appID: app, pointSize: 64, scale: 2, contentVersion: version)
        #expect(k96_1 != k96_2)
        #expect(k96_2 != k64_2)
        #expect(k96_1 != k64_2)
    }

    @Test("IconKey 区分内容版本: 图标更新前后必须不同键")
    func keyVersionDistinction() throws {
        let app = try #require(AppID("/Applications/A.app"))
        let before = IconKey(
            appID: app,
            pointSize: 96,
            scale: 2,
            contentVersion: IconContentVersion(iconResourceSizeBytes: 100)
        )
        let after = IconKey(
            appID: app,
            pointSize: 96,
            scale: 2,
            contentVersion: IconContentVersion(iconResourceSizeBytes: 101)
        )
        #expect(before != after)
    }

    @Test("pixelSize = pointSize × scale")
    func pixelSize() throws {
        let app = try #require(AppID("/Applications/A.app"))
        let key = IconKey(appID: app, pointSize: 96, scale: 2, contentVersion: .empty)
        #expect(key.pixelSize == 192)
    }

    @Test("IconKey Codable 往返")
    func keyRoundTrip() throws {
        let app = try #require(AppID("/Applications/A.app"))
        let key = IconKey(
            appID: app,
            pointSize: 96,
            scale: 2,
            contentVersion: IconContentVersion(
                iconResourceModificationNanoseconds: 1,
                iconResourceSizeBytes: 2
            )
        )
        let data = try JSONEncoder().encode(key)
        let decoded = try JSONDecoder().decode(IconKey.self, from: data)
        #expect(decoded == key)
    }
}
