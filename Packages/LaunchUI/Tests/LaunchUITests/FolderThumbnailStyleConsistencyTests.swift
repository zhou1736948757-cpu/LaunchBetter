import AppKit
import CoreGraphics
import Foundation
import LaunchCore
import Testing
@testable import LaunchUI

/// T-020: FolderThumbnailStyle 常量源一致性测试。
///
/// 覆盖三条路径:
/// - 常量值 = 修复前数值(0.08/0.38/0.18/0.02), 只消除 duplication 不改变视觉;
/// - live(FolderThumbnailView): 背景/border/sheen layer 颜色 alpha == 常量,
///   且不再是 NSVisualEffectView(无动态系统毛玻璃);
/// - raster(PageVisualRenderer.drawFolderThumbnail): 光栅化合成 alpha 与
///   常量推导值一致(证明 raster 引用同一常量源, 无硬编码残留)。
@Suite("FolderThumbnailStyle constants (T-020)")
@MainActor
struct FolderThumbnailStyleConsistencyTests {
    // MARK: - helpers

    /// 从 cell 视图树中定位 FolderThumbnailView(私有类, 经层级结构识别:
    /// 其 layer 树含 sheen CAGradientLayer, 不耦合类型名)。
    private func findFolderThumbnailView(in cell: AppCellView) -> NSView? {
        guard let pressContainer = cell.view.subviews.first else { return nil }
        return pressContainer.subviews.first { isFolderThumbnailView($0) }
    }

    private func isFolderThumbnailView(_ view: NSView) -> Bool {
        view.layer?.sublayers?.first?.sublayers?.contains { $0 is CAGradientLayer } == true
    }

    /// 建一个带窗口的 cell, 保证 loadView 与布局路径被真实执行。
    private func makeCellInWindow() -> (cell: AppCellView, window: NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 180),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let cell = AppCellView()
        window.contentView = cell.view
        window.layoutIfNeeded()
        cell.view.layoutSubtreeIfNeeded()
        return (cell, window)
    }

    private func configureFolder(_ cell: AppCellView) {
        let children = (0..<3).map { AppID("/Applications/Child\($0).app")! }
        cell.configureFolder(
            displayName: "Folder",
            accessibilityHint: "Folder",
            folderID: FolderID("folder://t020-style")!,
            children: children,
            pointSize: 80,
            iconProvider: nil
        )
        cell.view.layoutSubtreeIfNeeded()
    }

    /// 把 CGImage 读入像素缓冲(翻转 CTM 后 buffer row 0 = 图像底部; 与
    /// FolderThumbnailMetricsWiringTests.readPixels 同一约定 —— 消费方用
    /// row = height-1-yDown 把 y-down 坐标映射到缓冲行)。
    private func readPixels(_ image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &buffer, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return buffer }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    // MARK: - 常量值

    @Test("FolderThumbnailStyle 常量 = 修复前数值(0.08/0.38/0.18/0.02)")
    func constantsMatchPreFixValues() {
        #expect(FolderThumbnailStyle.backgroundAlpha == 0.08)
        #expect(FolderThumbnailStyle.borderAlpha == 0.38)
        #expect(FolderThumbnailStyle.sheenTopAlpha == 0.18)
        #expect(FolderThumbnailStyle.sheenBottomAlpha == 0.02)
    }

    // MARK: - live 接线

    @Test("live: FolderThumbnailView 是普通 NSView(非 NSVisualEffectView), 无动态毛玻璃")
    func liveThumbnailIsPlainNSView() {
        let (cell, window) = makeCellInWindow()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        configureFolder(cell)
        let thumbnail = findFolderThumbnailView(in: cell)
        #expect(thumbnail != nil)
        // T-020 核心: 不再是 NSVisualEffectView(material/blendingMode/state 已移除)。
        #expect(!(thumbnail is NSVisualEffectView))
    }

    @Test("live: 背景/border/sheen layer 颜色 alpha == FolderThumbnailStyle 常量")
    func liveLayerColorsUseStyleConstants() throws {
        let (cell, window) = makeCellInWindow()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        configureFolder(cell)
        let thumbnail = try #require(findFolderThumbnailView(in: cell))
        let layer = try #require(thumbnail.layer)

        // 背景: 白 backgroundAlpha。
        let background = try #require(layer.backgroundColor)
        #expect(abs(background.alpha - FolderThumbnailStyle.backgroundAlpha) < 1e-6)
        // 边框: 白 borderAlpha。
        let border = try #require(layer.borderColor)
        #expect(abs(border.alpha - FolderThumbnailStyle.borderAlpha) < 1e-6)

        // sheen: iconContainerLayer 首个子层 = CAGradientLayer, 颜色 alpha =
        // sheenTopAlpha → sheenBottomAlpha。
        let container = try #require(layer.sublayers?.first)
        let sheen = try #require(container.sublayers?.compactMap { $0 as? CAGradientLayer }.first)
        let colors = try #require(sheen.colors)
        #expect(colors.count == 2)
        // CAGradientLayer.colors 元素恒为 CGColor(CF 桥接, 条件转换恒成功)。
        let topColor = colors[0] as! CGColor
        let bottomColor = colors[1] as! CGColor
        #expect(abs(topColor.alpha - FolderThumbnailStyle.sheenTopAlpha) < 1e-6)
        #expect(abs(bottomColor.alpha - FolderThumbnailStyle.sheenBottomAlpha) < 1e-6)
    }

    // MARK: - raster 接线(合成 alpha 与常量推导值一致)

    @Test("raster: 缩略图合成 alpha = 常量推导值(背景 0.08 + sheen 渐变)")
    func rasterizedFolderSurfaceMatchesStyleConstants() throws {
        let geometry = GridGeometry(
            columns: 1, rows: 1, cellSize: 120, iconSize: 96,
            horizontalSpacing: 20, verticalSpacing: 20,
            pageWidth: 150, pageHeight: 150, topInset: 0, bottomInset: 0
        )
        let request = PageVisualRenderRequest(
            key: PageVisualKey(
                pageIndex: 0, displayRevision: 1,
                geometry: PageVisualGeometrySignature(geometry: geometry),
                backingScale: 1, languageRevision: 0, iconEpoch: 0
            ),
            gridOrigin: CGPoint(x: 15, y: 15),
            gridSize: CGSize(width: 120, height: 120),
            columns: 1, rows: 1, cellSize: 120, iconSize: 96,
            horizontalSpacing: 20, verticalSpacing: 20,
            scale: 1,
            cells: [.folder(slot: 0, label: "F", childIcons: [])]
        )
        let visual = try #require(PageVisualRenderer.rasterize(request))
        let pixels = readPixels(visual.image)
        let width = visual.image.width
        let height = visual.image.height
        #expect(width == 120 && height == 120)

        // 几何(T-019): thumbFrame = (12, 0, 96, 96)(y-down, 顶部锚定+水平居中)。
        // 合成 alpha = backgroundAlpha + sheen(t) * (1 - backgroundAlpha),
        // sheen(t) = sheenTopAlpha - (sheenTopAlpha - sheenBottomAlpha) * t,
        // t = (120 - y_up_center) / 96。采样中心列 x=60, 避开 1px 边框与圆角。
        // 缓冲行映射: buffer row = height-1-yDown(探针实证 row 0 = 图像底部)。
        func alphaAt(yDown: Int) -> Int {
            let row = height - 1 - yDown
            let index = (row * width + 60) * 4
            return Int(pixels[index + 3])
        }
        // 顶(y-down 2, 2px 内): t≈0.026 → sheen≈0.176 → alpha_out≈0.242 → 8bit≈62。
        let top = alphaAt(yDown: 2)
        #expect(top >= 58 && top <= 65, "顶部合成 alpha ≈ 0.242, 实际 \(top)")
        // 中(y-down 48, t≈0.505): sheen≈0.099 → alpha_out≈0.171 → 8bit≈44。
        let center = alphaAt(yDown: 48)
        #expect(center >= 40 && center <= 48, "中部合成 alpha ≈ 0.171, 实际 \(center)")
        // 底(y-down 94, 2px 内): t≈0.984 → sheen≈0.023 → alpha_out≈0.101 → 8bit≈26。
        let bottom = alphaAt(yDown: 94)
        #expect(bottom >= 22 && bottom <= 28, "底部合成 alpha ≈ 0.101, 实际 \(bottom)")
        // 单调: 顶 > 中 > 底(顶亮底暗)。
        #expect(top > center && center > bottom)
    }
}
