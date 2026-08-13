import Foundation

/// PA4: 分页逐事件 trace 共享写入器(生产默认关闭)。
///
/// `--pagingeventtrace` 时由诊断探针开启; PagingInteractionController 与
/// PausableLibraryScrollView 双方都调用 `record`, 事件序列按时间戳交错落在
/// `/tmp/lb-paging-eventtrace.log`。诊断用途, 非热路径(仅 traceEnabled 时开
/// 文件)。记录仅作诊断, 不参与任何行为决策。
@MainActor
enum PagingTraceLog {
    private static let path = "/tmp/lb-paging-eventtrace.log"

    static var enabled = false

    /// 记录一行 trace。enabled 关闭时零开销。
    static func record(_ line: String) {
        guard enabled else { return }
        let timestamp = ProcessInfo.processInfo.systemUptime
        let formatted = String(format: "[%10.4f]", timestamp)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((formatted + " " + line + "\n").utf8))
    }
}
