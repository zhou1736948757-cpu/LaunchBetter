import AppKit
import CoreImage
import Foundation

/// 壁纸提供者(§93): 发现桌面壁纸 → 解码 → cover 裁剪 → 模糊 → 缓存。
///
/// 职责单一: 输出背景图;UI 消费结果。文件 IO/CoreImage 不进入 WindowController。
/// 缓存到 Caches(可再生), 损坏/缺失回退纯色。
public final class WallpaperProvider: @unchecked Sendable {
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

    private let cachesURL: URL
    private let lock = NSLock()
    private var cache: [RenderRequest: CGImage] = [:]

    public init(cachesURL: URL) {
        self.cachesURL = cachesURL
    }

    /// 渲染模糊壁纸(同步, 后台线程调用)。
    public func blurredWallpaper(for request: RenderRequest) -> CGImage? {
        lock.lock()
        if let cached = cache[request] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let wallpaper = wallpaperSourceURL() else {
            return nil
        }
        guard let source = CGImageSourceCreateWithURL(wallpaper as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let rendered = Self.render(
            image,
            targetSize: request.screenFrame.size,
            scale: request.backingScale,
            blurRadius: request.blurRadius
        )
        if let rendered {
            lock.lock()
            cache[request] = rendered
            lock.unlock()
        }
        return rendered
    }

    /// 清缓存(屏幕/壁纸变化时)。
    public func invalidate() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
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
        let ciImage = CIImage(cgImage: scaled)
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
