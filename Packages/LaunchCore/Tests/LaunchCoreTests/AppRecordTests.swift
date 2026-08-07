import Foundation
import Testing
@testable import LaunchCore

@Suite("AppRecord 序列化")
struct AppRecordTests {
    private func makeRecord(
        path: String = "/Applications/Safari.app",
        bundleID: String? = "com.apple.Safari"
    ) throws -> AppRecord {
        let id = try #require(AppID(path))
        return AppRecord(
            id: id,
            url: URL(fileURLWithPath: path),
            bundleIdentifier: bundleID,
            displayName: "Safari",
            infoPlistModificationDate: Date(timeIntervalSince1970: 1_000),
            iconContentVersion: IconContentVersion(
                iconResourceModificationNanoseconds: 123,
                iconResourceSizeBytes: 456
            )
        )
    }

    @Test("Codable 往返保持全部字段")
    func codableRoundTrip() throws {
        let record = try makeRecord()
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(AppRecord.self, from: data)
        #expect(decoded == record)
        #expect(decoded.id == record.id)
        #expect(decoded.bundleIdentifier == "com.apple.Safari")
        #expect(decoded.iconContentVersion == record.iconContentVersion)
    }

    @Test("bundleIdentifier 可为 nil")
    func optionalBundleID() throws {
        let record = try makeRecord(bundleID: nil)
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(AppRecord.self, from: data)
        #expect(decoded.bundleIdentifier == nil)
    }

    @Test("Identifiable: id 即身份")
    func identifiable() throws {
        let record = try makeRecord()
        #expect(record.id == AppID("/Applications/Safari.app"))
    }

    @Test("相同内容哈希相等")
    func hashEquality() throws {
        #expect(try makeRecord() == makeRecord())
    }
}
