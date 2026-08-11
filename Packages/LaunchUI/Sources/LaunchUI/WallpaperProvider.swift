import AppKit
import CoreImage
import CryptoKit
import Foundation

/// 壁纸提供者(§93): 发现桌面壁纸 → 解码 → cover 裁剪 → 模糊 → 缓存。
///
/// 职责单一: 输出背景图;UI 消费结果。文件 IO/CoreImage 不进入 WindowController。
/// 缓存到 Caches(可再生), 损坏/缺失回退纯色。
public final class WallpaperProvider: @unchecked Sendable {
    static let diskCacheAlgorithmVersion = 3

    public struct RenderRequest: Sendable, Equatable, Hashable {
        public let screenFrame: CGRect
        public let backingScale: CGFloat
        public let blurRadius: Double

        public init(screenFrame: CGRect, backingScale: CGFloat, blurRadius: Double) {
            self.screenFrame = screenFrame
            self.backingScale = backingScale
            self.blurRadius = blurRadius
        }
    }

    struct SourceIdentity: Sendable, Equatable, Hashable {
        let normalizedPath: String
        let modificationTimeBits: UInt64?
        let fileSize: Int?
        let fileResourceIdentifier: String?

        init(
            normalizedPath: String,
            modificationTimeBits: UInt64?,
            fileSize: Int?,
            fileResourceIdentifier: String?
        ) {
            self.normalizedPath = normalizedPath
            self.modificationTimeBits = modificationTimeBits
            self.fileSize = fileSize
            self.fileResourceIdentifier = fileResourceIdentifier
        }
    }

    private struct CacheKey: Sendable, Equatable, Hashable {
        let request: RenderRequest
        let sourceIdentity: SourceIdentity
    }

    private let cachesURL: URL
    private let lock = NSLock()
    private let condition = NSCondition()
    private var cache: [CacheKey: CGImage] = [:]
    private var renderingKeys: Set<CacheKey> = []
    /// 渲染分辨率系数(模糊背景低分辨率不可感知, 0.25x 减少 16 倍像素工作量)。
    private static let renderScaleFactor: CGFloat = 0.25

    public init(cachesURL: URL) {
        self.cachesURL = cachesURL
    }

    /// 渲染模糊壁纸(同步, 后台线程调用)。
    /// 路径: 内存缓存 → 磁盘缓存 → 渲染(半分辨率, in-flight 去重)+ 双缓存。
    public func blurredWallpaper(for request: RenderRequest) -> CGImage? {
        guard let wallpaper = wallpaperSourceURL() else {
            return nil
        }
        let sourceIdentity = Self.sourceIdentity(for: wallpaper)
        let cacheKey = CacheKey(request: request, sourceIdentity: sourceIdentity)

        condition.lock()
        // in-flight 去重: 同一 key 并发请求共享一次渲染(预渲染与首显竞争场景)
        while renderingKeys.contains(cacheKey) {
            condition.wait()
        }
        if let cached = cache[cacheKey] {
            condition.unlock()
            return cached
        }
        renderingKeys.insert(cacheKey)
        condition.unlock()

        defer {
            condition.lock()
            renderingKeys.remove(cacheKey)
            condition.signal()
            condition.unlock()
        }

        // 磁盘缓存(可再生): 首显渲染后落盘, 后续启动/显示直接解码
        let diskURL = diskURL(for: request, sourceIdentity: sourceIdentity)
        if let diskImage = Self.loadImage(url: diskURL) {
            condition.lock()
            cache[cacheKey] = diskImage
            condition.unlock()
            return diskImage
        }

        guard let source = CGImageSourceCreateWithURL(wallpaper as CFURL, nil) else {
            return nil
        }
        // 直接解码缩略图(源图常为数 MB 的 JPEG/HEIC, 全量解码是主要耗时;
        // 优先用内嵌缩略图(HEIC 常内嵌, 近零成本); 模糊背景 512px 足够)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let rendered = Self.render(
            image,
            targetSize: request.screenFrame.size,
            scale: request.backingScale * Self.renderScaleFactor,
            blurRadius: request.blurRadius * Double(Self.renderScaleFactor)
        )
        if let rendered {
            condition.lock()
            cache[cacheKey] = rendered
            condition.unlock()
            // 磁盘缓存(失败不阻断)
            if let data = Self.pngData(of: rendered) {
                try? FileManager.default.createDirectory(
                    at: diskURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? data.write(to: diskURL, options: .atomic)
            }
        }
        return rendered
    }

    /// 内存缓存命中(主线程安全; 未命中返回 nil)。
    public func cachedWallpaper(for request: RenderRequest) -> CGImage? {
        guard let wallpaper = wallpaperSourceURL() else { return nil }
        let cacheKey = CacheKey(
            request: request,
            sourceIdentity: Self.sourceIdentity(for: wallpaper)
        )
        condition.lock()
        defer { condition.unlock() }
        return cache[cacheKey]
    }

    /// 清缓存(屏幕/壁纸变化时)。
    public func invalidate() {
        condition.lock()
        cache.removeAll()
        condition.unlock()
    }

    // MARK: - 磁盘缓存

    private func diskURL(
        for request: RenderRequest,
        sourceIdentity: SourceIdentity
    ) -> URL {
        return cachesURL.appendingPathComponent("Wallpaper", isDirectory: true)
            .appendingPathComponent(Self.diskCacheFileName(
                for: request,
                sourceIdentity: sourceIdentity
            ))
    }

    static func diskCacheFileName(
        for request: RenderRequest,
        sourceIdentity: SourceIdentity
    ) -> String {
        let renderScale = request.backingScale * renderScaleFactor
        let pixelWidth = Int(request.screenFrame.width * renderScale)
        let pixelHeight = Int(request.screenFrame.height * renderScale)
        let sourceDigest = SHA256.hash(data: Data(sourceIdentity.cacheMaterial.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "v\(diskCacheAlgorithmVersion)-\(pixelWidth)x\(pixelHeight)-b\(request.blurRadius)-src\(sourceDigest).png"
    }

    private static func loadImage(url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
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

    // MARK: - 壁纸来源

    private func wallpaperSourceURL() -> URL? {
        for screen in NSScreen.screens {
            if let url = NSWorkspace.shared.desktopImageURL(for: screen) {
                return url
            }
        }
        return nil
    }

    static func sourceIdentity(for sourceURL: URL) -> SourceIdentity {
        let normalizedURL = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let values = try? normalizedURL.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileSizeKey,
            .fileResourceIdentifierKey,
        ])
        return SourceIdentity(
            normalizedPath: normalizedURL.path,
            modificationTimeBits: values?.contentModificationDate?
                .timeIntervalSince1970.bitPattern,
            fileSize: values?.fileSize,
            fileResourceIdentifier: values?.fileResourceIdentifier.map {
                String(reflecting: $0)
            }
        )
    }

    // MARK: - 渲染

    /// cover 缩放居中裁剪 + 高斯模糊。
    static func render(
        _ image: CGImage,
        targetSize: CGSize,
        scale: CGFloat,
        blurRadius: Double
    ) -> CGImage? {
        let pixelWidth = Int(targetSize.width * scale)
        let pixelHeight = Int(targetSize.height * scale)
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        // 缩放: 保持宽高比 cover
        let imageAspect = CGFloat(image.width) / CGFloat(image.height)
        let targetAspect = CGFloat(pixelWidth) / CGFloat(pixelHeight)
        var drawSize: CGSize
        if imageAspect > targetAspect {
            drawSize = CGSize(
                width: CGFloat(pixelHeight) * imageAspect,
                height: CGFloat(pixelHeight)
            )
        } else {
            drawSize = CGSize(
                width: CGFloat(pixelWidth),
                height: CGFloat(pixelWidth) / imageAspect
            )
        }

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        let origin = CGPoint(
            x: (CGFloat(pixelWidth) - drawSize.width) / 2,
            y: (CGFloat(pixelHeight) - drawSize.height) / 2
        )
        context.draw(image, in: CGRect(origin: origin, size: drawSize))
        guard let scaled = context.makeImage() else { return nil }

        // 模糊
        guard blurRadius > 0 else { return scaled }
        // Gaussian blur samples outside a finite image extent as transparent.
        // Extend edge pixels before filtering so the crop keeps opaque, stable edges.
        let ciImage = CIImage(cgImage: scaled).clampedToExtent()
        let filter = CIFilter(name: "CIGaussianBlur")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        filter?.setValue(blurRadius, forKey: kCIInputRadiusKey)
        guard let output = filter?.outputImage else { return scaled }

        // 裁剪回目标尺寸(模糊会扩展边缘)
        let context2 = CIContext(options: [.useSoftwareRenderer: false])
        let cropRect = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        let cropped = output.cropped(to: cropRect)
        return context2.createCGImage(cropped, from: cropRect)
    }
}

private extension WallpaperProvider.SourceIdentity {
    var cacheMaterial: String {
        [
            normalizedPath,
            modificationTimeBits.map(String.init) ?? "",
            fileSize.map(String.init) ?? "",
            fileResourceIdentifier ?? "",
        ].joined(separator: "\u{1F}")
    }
}
