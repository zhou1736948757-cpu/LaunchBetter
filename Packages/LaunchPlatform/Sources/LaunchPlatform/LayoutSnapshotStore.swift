import Foundation
import LaunchCore

/// 布局快照持久存储(持久用户数据,非缓存)。
///
/// 位置: `~/Library/Application Support/<bundleID>/LayoutSnapshot.json`
/// 约定: schemaVersion、原子写入、损坏不静默清除(备份后抛错)。
public struct LayoutSnapshotStore: Sendable {
    public let directory: URL
    public let fileURL: URL

    public init(directory: URL) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("LayoutSnapshot.json")
    }

    public func load() throws -> LayoutSnapshot? {
        try DurableFile.loadCodable(LayoutSnapshot.self, from: fileURL)
    }

    public func save(_ snapshot: LayoutSnapshot) throws {
        try DurableFile.saveCodable(snapshot, to: fileURL)
    }

    @discardableResult
    public func backupCorruptedFile() throws -> URL {
        try DurableFile.backupCorruptedFile(at: fileURL)
    }
}
