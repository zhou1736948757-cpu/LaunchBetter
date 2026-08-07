import AppKit
import CoreGraphics
import Foundation
import LaunchCore

/// 图标提取协议: 提供应用的实时图标提取。
/// 实现必须 Sendable;测试可注入假实现。
public protocol AppIconProviding: Sendable {
    /// 提取应用图标,渲染到指定像素尺寸。
    func liveIcon(for url: URL, pixelSize: Int) async -> CGImage?
}

/// AppKit 实时图标提供者(§80)。
///
/// 全应用唯一的 NSWorkspace.icon 调用点;禁止其他服务/单元格直接调用。
public struct AppIconProvider: AppIconProviding {
    public init() {}

    public func liveIcon(for url: URL, pixelSize: Int) async -> CGImage? {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        return Self.render(icon, pixelSize: pixelSize)
    }

    /// 渲染为指定像素尺寸的显示就绪位图(32-bit BGRA premultiplied)。
    static func render(_ image: NSImage, pixelSize: Int) -> CGImage? {
        let size = max(16, pixelSize)
        let bitmap = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let bitmap else { return nil }
        bitmap.interpolationQuality = .high

        var proposed = NSRect(x: 0, y: 0, width: size, height: size)
        guard let cgImage = image.cgImage(
            forProposedRect: &proposed,
            context: NSGraphicsContext(cgContext: bitmap, flipped: false),
            hints: [.interpolation: NSImageInterpolation.high]
        ) else {
            return nil
        }
        bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        return bitmap.makeImage()
    }
}
