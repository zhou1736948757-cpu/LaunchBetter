import Foundation

/// 持久文件读写: 原子写入 + 损坏保留。
///
/// 规则(AGENTS.md / 主提示 §97):
/// - 持久用户状态写入必须避免部分损坏: encode → temp → atomic replace
/// - 损坏的持久用户状态: 不静默清除,备份后由调用方决定
/// - 损坏的可再生缓存由缓存层自行删除重建(不在此处理)
public enum DurableFile: Sendable {
    public enum Error: Swift.Error, Equatable {
        case loadFailed(underlying: String)
    }

    /// 读取文件数据。文件不存在返回 nil;读取失败抛错。
    public static func loadData(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw Error.loadFailed(underlying: String(describing: error))
        }
    }

    /// 原子写入: 写临时文件后替换目标。
    public static func save(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    /// 备份损坏文件(重命名保留),返回备份 URL。
    /// 用于"损坏的持久状态不静默清除"策略。
    @discardableResult
    public static func backupCorruptedFile(at url: URL) throws -> URL {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = url
            .deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)")
        try FileManager.default.moveItem(at: url, to: backup)
        return backup
    }

    /// 编码并原子保存一个 Codable 状态。
    public static func saveCodable<State: Codable>(_ state: State, to url: URL) throws {
        let data = try JSONEncoder().encode(state)
        try save(data, to: url)
    }

    /// 解码读取一个 Codable 状态。文件不存在返回 nil;损坏抛错。
    public static func loadCodable<State: Codable>(_ type: State.Type, from url: URL) throws -> State? {
        guard let data = try loadData(at: url) else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }
}
