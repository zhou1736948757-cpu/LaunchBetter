import CoreGraphics
import Foundation
import ImageIO
import LaunchCore
import UniformTypeIdentifiers

/// 图标磁盘缓存: 文件名含完整 IconKey 变体(§78)。
///
/// 结构:
/// ```
/// Icons/<hash(AppID)>/<pointSize>-<scale>-<contentVersionHash>.png
/// ```
/// 禁止仅以 hash(AppID) 命名。缓存可再生,损坏文件删除重建(§97)。
/// @unchecked Sendable: 仅持有不可变 rootURL,方法为无状态文件操作;供
/// IconRepository 后台 prune 任务(@Sendable 捕获)使用(与 GlobalHotkey 等同模式)。
public final class IconDiskCache: @unchecked Sendable {
    public let rootURL: URL

    /// 默认 prune 保留时长: 30 天内的文件视为新鲜,不清理(L4)。
    public static let defaultRetentionInterval: TimeInterval = 30 * 24 * 3600

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    /// 磁盘文件 URL(确定性)。
    public func fileURL(for key: IconKey) -> URL {
        let appDir = rootURL
            .appendingPathComponent(StableHash.fnv1a64(key.appID.rawValue), isDirectory: true)
        let name = "\(key.pointSize)-\(key.scale)-\(key.contentVersion.stableContentHash).png"
        return appDir.appendingPathComponent(name)
    }

    /// 读取并解码。文件不存在返回 nil;损坏删除并返回 nil(缓存可重建)。
    public func load(key: IconKey) -> CGImage? {
        let url = fileURL(for: key)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            // 损坏: 删除重建(可再生的缓存,§97)
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return image
    }

    /// 编码 PNG 并原子写入。
    public func store(key: IconKey, image: CGImage) throws {
        let url = fileURL(for: key)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = Self.pngData(of: image) else {
            throw Error.encodeFailed
        }
        try data.write(to: url, options: .atomic)
    }

    /// 清理过期缓存文件(L4): 枚举 rootURL 下全部常规文件(含子目录,跳过 .DS_Store),
    /// 删除 contentModificationDate 早于 cutoff 的文件并计数;清理后空的目录可选移除;
    /// 任何单个失败忽略(缓存可再生)。
    public func pruneStaleFiles(olderThan cutoff: Date) -> Int {
        var removed = 0
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey],
            options: []
        ) else {
            return 0
        }
        var directories: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey]
            )
            if values?.isRegularFile == true {
                guard url.lastPathComponent != ".DS_Store" else { continue }
                guard let modified = values?.contentModificationDate, modified < cutoff else { continue }
                if (try? FileManager.default.removeItem(at: url)) != nil {
                    removed += 1
                }
            } else if values?.isDirectory == true {
                directories.append(url)
            }
        }
        // 清理后空的目录可选移除(自底向上,避免子目录残留)
        for dir in directories.reversed() {
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
               contents.isEmpty {
                try? FileManager.default.removeItem(at: dir)
            }
        }
        return removed
    }

    public enum Error: Swift.Error {
        case encodeFailed
    }

    public static func pngData(of image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
