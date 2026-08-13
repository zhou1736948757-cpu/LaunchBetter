import AppKit
import LaunchCore
import LaunchUI

/// E10: fresh App Library 视觉证据探针。
///
/// 非交互: 只导航/读取, 不写 Layout/Config/Usage。截图统一走既有
/// `LauncherWindowController.captureContentScreenshot(to:)` 的 layer render
/// (禁止 cacheDisplay / screencapture)。settings 状态额外输出 Settings 窗口
/// 的独立 layer render PNG(与 parent Library 同 backing scale)。
///
/// 状态:
/// - `top`: Library 顶部
/// - `mid`: Library 垂直滚动到内容约 45%-60%(内容不足 → stable no-op)
/// - `detail`: 打开第一个 category detail
/// - `search`: 设置 query 刷新现有 Search UI
/// - `settings`: 从 Library 打开 Settings, 输出 parent + settings 两张 PNG
@MainActor
enum AppLibraryShotProbe {
    private static let settleFramesPerSecond = 120.0
    private static let settleTimeoutFrames = 300

    static func run(container: DependencyContainer, outputPath: String, state: String) {
        let controller = container.windowController
        controller.show()
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.orderFrontRegardless()
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.displayIfNeeded()

        guard controller.libraryShotNavigateToLibrary() else {
            DiagnosticRunner.finishProbe(
                "LIBRARYSHOT", ok: false,
                detail: "library navigation unavailable (leading surface disabled)"
            )
        }
        waitForSettle(container) { settled in
            guard settled else {
                DiagnosticRunner.finishProbe("LIBRARYSHOT", ok: false, detail: "paging settle timeout")
            }
            runState(container: container, outputPath: outputPath, state: state)
        }
    }

    // MARK: - 状态分派

    private static func runState(container: DependencyContainer, outputPath: String, state: String) {
        let controller = container.windowController
        switch state {
        case "mid":
            let result = controller.libraryShotScrollMid()
            print("LIBRARYSHOT mid scroll=\(result.scrolled ? "OK" : "STABLE_NOOP") fraction=\(String(format: "%.2f", result.fraction))")
            waitThenCapture(container, outputPath: outputPath, state: state, delay: 0.25)
        case "detail":
            guard controller.libraryShotOpenFirstCategoryDetail() else {
                DiagnosticRunner.finishProbe("LIBRARYSHOT", ok: false, detail: "no category card to open")
            }
            waitThenCapture(container, outputPath: outputPath, state: state, delay: 0.4)
        case "search":
            container.store.searchQuery = "com"
            controller.refreshGrid()
            waitThenCapture(container, outputPath: outputPath, state: state, delay: 0.3)
        case "settings":
            controller.openSettingsFromMenu()
            waitThenCaptureSettings(container, outputPath: outputPath, delay: 0.6)
        default:
            waitThenCapture(container, outputPath: outputPath, state: state, delay: 5.0)
        }
    }

    // MARK: - 等待与捕获

    /// 等待分页 settle 完成(120Hz 轮询驱动帧, 与 PagingProbe 同一模式)。
    private static func waitForSettle(
        _ container: DependencyContainer,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        let controller = container.windowController
        var remaining = settleTimeoutFrames
        @MainActor func poll() {
            remaining -= 1
            let settled = controller.libraryShotWaitSettled()
            if settled || remaining == 0 {
                completion(settled)
                return
            }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 1.0 / settleFramesPerSecond
            ) {
                MainActor.assumeIsolated { poll() }
            }
        }
        poll()
    }

    private static func waitThenCapture(
        _ container: DependencyContainer,
        outputPath: String,
        state: String,
        delay: TimeInterval
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                captureAndFinish(container, outputPath: outputPath, state: state, settingsPair: false)
            }
        }
    }

    private static func waitThenCaptureSettings(
        _ container: DependencyContainer,
        outputPath: String,
        delay: TimeInterval
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                captureAndFinish(container, outputPath: outputPath, state: "settings", settingsPair: true)
            }
        }
    }

    private static func captureAndFinish(
        _ container: DependencyContainer,
        outputPath: String,
        state: String,
        settingsPair: Bool
    ) {
        let controller = container.windowController
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.window?.displayIfNeeded()

        var written: [String] = []
        var failed = false

        if settingsPair {
            // parent Library(启动器窗口 layer render; Settings child 窗口独立捕获)
            captureLibraryContent(controller, to: outputPath)
            if FileManager.default.fileExists(atPath: outputPath) {
                written.append(outputPath)
            } else {
                failed = true
            }
            let settingsPath = derivedPath(outputPath, suffix: "settings")
            captureSettingsWindow(container.settingsController, to: settingsPath)
            if FileManager.default.fileExists(atPath: settingsPath) {
                written.append(settingsPath)
            } else {
                failed = true
            }
        } else {
            captureLibraryContent(controller, to: outputPath)
            if FileManager.default.fileExists(atPath: outputPath) {
                written.append(outputPath)
            } else {
                failed = true
            }
        }

        let size = controller.window?.contentView?.bounds.size ?? .zero
        let scale = controller.window?.backingScaleFactor ?? 0
        print(
            "LIBRARYSHOT state=\(state) \(controller.libraryShotState()) "
                + "size=\(Int(size.width))x\(Int(size.height)) backingScale=\(scale) "
                + "pngs=\(written.joined(separator: ","))"
        )
        fflush(stdout)
        DiagnosticRunner.finishProbe(
            "LIBRARYSHOT", ok: !failed && !written.isEmpty,
            detail: "state=\(state) pngs=\(written.joined(separator: ","))"
        )
    }

    /// Settings 窗口 layer render(与 SettingsShotProbe 同一方式, 路径参数化)。
    private static func captureSettingsWindow(_ settings: SettingsWindowController, to path: String) {
        guard let window = settings.window,
              let contentView = window.contentView,
              let layer = contentView.layer else { return }
        let scale = window.backingScaleFactor
        let width = Int(contentView.bounds.width * scale)
        let height = Int(contentView.bounds.height * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.scaleBy(x: scale, y: scale)
        // AppKit y 向上 → 位图 y 向下
        context.translateBy(x: 0, y: contentView.bounds.height)
        context.scaleBy(x: 1, y: -1)
        withTextLayerGeometryCorrection(in: contentView) {
            layer.render(in: context)
        }
        guard let image = context.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    private static func captureLibraryContent(
        _ controller: LauncherWindowController,
        to path: String
    ) {
        // launcher contentView 为 flipped, captureContentScreenshot 不再做 y-flip,
        // layer.render 天然 top-down; 文本层保持自然 geometryFlipped(不做水平
        // 校正 — E11 实测: 校正会使文本水平镜像)。
        controller.captureContentScreenshot(to: path)
    }

    private static func withTextLayerGeometryCorrection<T>(
        in root: NSView?,
        _ body: () -> T
    ) -> T {
        // AppKit text layers nested under flipped collection/effect views render
        // horizontally mirrored through CALayer.render; normalize only during capture.
        let views = textBearingViews(in: root)
        let original = views.map { ($0, $0.layer?.isGeometryFlipped) }
        for view in views {
            view.layer?.isGeometryFlipped = false
        }
        defer {
            for (view, value) in original {
                if let value {
                    view.layer?.isGeometryFlipped = value
                }
            }
        }
        return body()
    }

    private static func textBearingViews(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        let own: [NSTextField] = if let field = view as? NSTextField {
            [field]
        } else {
            []
        }
        return own + view.subviews.flatMap { textBearingViews(in: $0) }
    }

    /// `<path>_<suffix>.png`(settings: parent 主路径 + `_settings` 副路径)。
    private static func derivedPath(_ path: String, suffix: String) -> String {
        let url = URL(fileURLWithPath: path)
        let base = url.deletingPathExtension().path
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        return "\(base)_\(suffix).\(ext)"
    }
}
