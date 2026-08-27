import CoreGraphics
import Foundation
import ImageIO
import os

/// 壁纸磁盘写器(T-026): 把 PNG encode + 原子写盘移出 render 返回路径。
///
/// 路径: render → 内存缓存 → return CGImage(UI 立即显示); 磁盘持久化由本写器
/// 在串行队列上异步执行, render 返回不等待写盘。
///
/// 特性:
/// - 串行队列: 写盘按入队顺序执行(单飞行, 无并发写同一目录)
/// - 同 URL 去重: 已排队或已成功写入的 URL 不再重复写(多次 cold render 幂等;
///   失败不记入 written, 允许后续重试)
/// - 写失败不阻断 UI: 仅记录日志(缓存可再生), 不抛出
final class WallpaperDiskWriter: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: Set<URL> = []
    private var written: Set<URL> = []
    private let log = OSLog(subsystem: "dev.launchbetter", category: "WallpaperDiskWriter")

    /// written 容量上限: 超过即清空(防长期运行无界增长; 清空后旧 URL 可重写, 幂等)。
    private static let writtenCap = 256

    /// 以串行队列构造; 测试可注入挂起队列验证"入队不等待写盘"。
    init(queue: DispatchQueue? = nil) {
        self.queue = queue ?? DispatchQueue(
            label: "dev.launchbetter.wallpaper-disk-writer",
            qos: .utility
        )
    }

    /// 提交一次写盘(快速返回; 磁盘 IO 不在入队路径)。
    /// 同 URL 已排队或已成功写入则跳过。
    func enqueue(image: CGImage, to url: URL) {
        lock.lock()
        if pending.contains(url) || written.contains(url) {
            lock.unlock()
            return
        }
        pending.insert(url)
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            self.write(image: image, to: url)
        }
    }

    /// 等待所有已提交写入完成(测试/收尾)。幂等。
    /// 契约: 不得在写队列内部调用(会死锁)。
    func flush() {
        queue.sync {}
    }

    private func write(image: CGImage, to url: URL) {
        defer {
            lock.lock()
            pending.remove(url)
            lock.unlock()
        }
        guard let data = Self.pngData(of: image) else {
            os_log(
                .error, log: log, "wallpaper PNG encode failed for %{public}@",
                url.lastPathComponent
            )
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            lock.lock()
            written.insert(url)
            if written.count > Self.writtenCap {
                written.removeAll(keepingCapacity: false)
            }
            lock.unlock()
        } catch {
            os_log(
                .error, log: log, "wallpaper disk write failed for %{public}@: %{public}@",
                url.lastPathComponent, String(describing: error)
            )
        }
    }

    private static func pngData(of image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, "public.png" as CFString, 1, nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
