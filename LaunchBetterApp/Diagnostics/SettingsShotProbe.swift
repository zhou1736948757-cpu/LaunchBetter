import AppKit

/// 设置窗口截图探针: 打开设置并层渲染其窗口(检查红绿灯位置/布局)。
enum SettingsShotProbe {
    static func run(container: DependencyContainer) {
        MainActor.assumeIsolated {
            let controller = container.settingsController
            guard let sw = controller.window else {
                print("SETTINGSSHOT FAIL no window")
                exit(1)
            }
            sw.makeKeyAndOrderFront(nil)
            sw.displayIfNeeded()
            Self.capture(sw: sw)
        }
    }

    @MainActor
    private static func capture(sw: NSWindow) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let contentView = sw.contentView, let layer = contentView.layer else {
                print("SETTINGSSHOT FAIL no content")
                exit(1)
            }
            let scale = sw.backingScaleFactor
            let width = Int(contentView.bounds.width * scale)
            let height = Int(contentView.bounds.height * scale)
            guard let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                print("SETTINGSSHOT FAIL ctx")
                exit(1)
            }
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: 0, y: contentView.bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            layer.render(in: ctx)
            guard let img = ctx.makeImage() else { print("SETTINGSSHOT FAIL render"); exit(1) }
            let rep = NSBitmapImageRep(cgImage: img)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                print("SETTINGSSHOT FAIL png")
                exit(1)
            }
            let path = CommandLine.arguments.last ?? "/tmp/lb-settings.png"
            try? png.write(to: URL(fileURLWithPath: path))
            print("SETTINGSSHOT_WRITTEN \(path) \(width)x\(height)")
            exit(0)
        }
    }
}
