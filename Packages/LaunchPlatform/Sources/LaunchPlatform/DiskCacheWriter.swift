import CoreGraphics
import Foundation
import LaunchCore
import os

/// 图标磁盘写提交协议: 接收方负责异步、按 key 去重、有界地执行磁盘写入。
/// 独立于 IconRepository,避免首个 live icon 消费者等待 PNG encode + 原子写盘(§A6)。
public protocol IconDiskWriting: Sendable {
    /// 提交一次写;同 key 仅首次返回 true(成功写入后亦去重)。快速返回,磁盘 IO 不在入队路径。
    @discardableResult
    func enqueue(key: IconKey, image: CGImage) async -> Bool

    /// 等待所有已提交写入完成(干净 shutdown / 测试同步)。幂等。
    func flush() async
}

/// 受控磁盘写器(actor, 串行有界): 把 PNG encode + 原子写盘移出首屏关键路径(§A6)。
///
/// 特性:
/// - 按 IconKey 去重: 同 key 在其生命周期内仅执行一次写(writtenKeys 记录成功写过的 key,
///   失败可重试;容量封顶防无界增长)。新语义 key 由文件名中的 contentVersion 天然隔离,
///   陈旧内容不可能覆盖较新文件;代际校验由 IconRepository.resolve 在入队前完成
/// - 有界并发: 单飞行 drain 循环,不做无界 Task.detached 洪泛(最大并发 1)
/// - 写失败不阻断 UI: 仅记录日志(缓存可再生),且不记入 writtenKeys 允许重试
/// - 每次写之间让出(await Task.yield),保证 enqueue 调用不被长 drain 阻塞
public actor DiskCacheWriter: IconDiskWriting {
    private let diskCache: IconDiskCache
    private let log: OSLog
    private var pending: [IconKey: CGImage] = [:]
    private var writtenKeys: Set<IconKey> = []
    private var draining = false

    /// writtenKeys 容量上限: 超过即清空(罕见;仅防长期运行无界增长)。
    private static let writtenKeysCap = 4096

    /// 以缓存根目录构造;内部自建 IconDiskCache(无状态, 与读取端实例等价)。
    public init(rootURL: URL) {
        self.diskCache = IconDiskCache(rootURL: rootURL)
        self.log = OSLog(subsystem: "dev.launchbetter", category: "IconDiskWriter")
    }

    @discardableResult
    public func enqueue(key: IconKey, image: CGImage) async -> Bool {
        guard !writtenKeys.contains(key), pending[key] == nil else { return false }
        pending[key] = image
        if !draining {
            draining = true
            Task { await self.drain() }
        }
        return true
    }

    public func flush() async {
        while draining {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func drain() async {
        defer { draining = false }
        while let (key, image) = pending.popFirst() {
            do {
                try diskCache.store(key: key, image: image)
                writtenKeys.insert(key)
                if writtenKeys.count > Self.writtenKeysCap {
                    writtenKeys.removeAll(keepingCapacity: false)
                }
            } catch {
                os_log(
                    .error, log: log, "icon disk write failed for %{public}@: %{public}@",
                    key.appID.rawValue, String(describing: error)
                )
            }
            await Task.yield()
        }
    }
}
