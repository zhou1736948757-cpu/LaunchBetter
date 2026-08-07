import Foundation
import LaunchCore

/// 目录快照持久存储(持久用户数据,非缓存)。
///
/// 位置: `~/Library/Application Support/<bundleID>/CatalogSnapshot.json`
/// 约定: schemaVersion、原子写入、损坏不静默清除(备份后抛错)。
public struct CatalogSnapshotStore: Sendable {
    public let directory: URL
    public let fileURL: URL

    public init(directory: URL) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("CatalogSnapshot.json")
    }

    /// 加载快照。文件不存在返回 nil;损坏抛错(不静默清除)。
    public func load() throws -> CatalogSnapshot? {
        try DurableFile.loadCodable(CatalogSnapshot.self, from: fileURL)
    }

    /// 原子保存快照。
    public func save(_ snapshot: CatalogSnapshot) throws {
        try DurableFile.saveCodable(snapshot, to: fileURL)
    }

    /// 备份损坏的快照文件(保留证据),返回备份 URL。
    @discardableResult
    public func backupCorruptedFile() throws -> URL {
        try DurableFile.backupCorruptedFile(at: fileURL)
    }
}

/// 设置持久存储。
public struct SettingsStore: Sendable {
    public let directory: URL
    public let fileURL: URL

    public init(directory: URL) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("Settings.json")
    }

    public func load() throws -> AppConfiguration? {
        try DurableFile.loadCodable(AppConfiguration.self, from: fileURL)
    }

    public func save(_ config: AppConfiguration) throws {
        try DurableFile.saveCodable(config, to: fileURL)
    }

    @discardableResult
    public func backupCorruptedFile() throws -> URL {
        try DurableFile.backupCorruptedFile(at: fileURL)
    }
}

/// Application Support 目录解析(宿主应用 bundle ID 注入)。
public enum ApplicationSupport {
    /// `~/Library/Application Support/<bundleIdentifier>/`
    public static func directory(bundleIdentifier: String) -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return base.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }
}
