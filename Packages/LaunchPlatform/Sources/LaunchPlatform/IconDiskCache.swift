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
public final class IconDiskCache {
    public let rootURL: URL

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
