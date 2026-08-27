import AppKit
import CoreGraphics
import Foundation
import LaunchCore
import Testing
@testable import LaunchUI

/// P0-05: FolderThumbnailMetrics 消费者接线测试。
///
/// 覆盖两条路径的几何与请求尺寸:
/// - live(AppCellView.FolderThumbnailView): 子图标 layer frame = metrics
///   childFrame 按 bounds.height 翻转; 子图标请求 pointSize = metrics.iconSide。
/// - PageVisual(PageVisualRenderer): resolveIcons 子图标请求 pointSize =
///   metrics(iconSize).iconSide(T-019: 与 live 一致按图标区, 旧实现按
///   cellSize 偏大); 光栅化子图标像素范围 = metrics(iconSize).iconSide。
///
/// 不触碰懒分配/生命周期(configure/reset/复用路径由既有测试覆盖)。
@Suite("FolderThumbnailMetrics consumer wiring (P0-05)")
@MainActor
struct FolderThumbnailMetricsWiringTests {
    // MARK: - helpers

    /// 记录请求的图标提供者(同步记录, 立即返回 nil)。
    @MainActor
    private final class RecordingIconProvider: IconImageProviding {
        private(set) var requests: [(appID: AppID, pointSize: Int, scale: Int)] = []

        func icon(for appID: AppID, pointSize: Int, scale: Int) async -> CGImage? {
            requests.append((appID, pointSize, scale))
            return nil
        }

        func trimMemoryForHidden() {}
    }

    /// 等待异步消费者任务把请求记录进 provider(全部 MainActor, yield 即可推进)。
    private func waitForRequests(
        _ provider: RecordingIconProvider,
        count: Int,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) async {
        for _ in 0..<200 where provider.requests.count < count {
            await Task.yield()
        }
        #expect(provider.requests.count == count, sourceLocation: SourceLocation(
            fileID: fileID, filePath: filePath, line: line, column: column
        ))
    }

    /// 近似 CGRect 相等: CALayer 的 frame setter 经 bounds/position 往返,
    /// 读回值可能差 1 ulp(如 8.8 → 8.799999999999999), 用 1e-9 容差比较。
    private func framesEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1e-9
            && abs(a.minY - b.minY) < 1e-9
            && abs(a.width - b.width) < 1e-9
            && abs(a.height - b.height) < 1e-9
    }

    /// 从 cell 视图树中定位 FolderThumbnailView(私有类, 经层级查找)。
    private func findFolderThumbnailView(in cell: AppCellView) -> NSVisualEffectView? {
        guard let pressContainer = cell.view.subviews.first else { return nil }
        return pressContainer.subviews.first { $0 is NSVisualEffectView } as? NSVisualEffectView
    }

    /// 缩略图 layer 树中的 9 个子图标 layer(排除 sheen 渐变层)。
    private func iconLayers(of thumbnail: NSVisualEffectView) -> [CALayer] {
        guard let container = thumbnail.layer?.sublayers?.first else { return [] }
        return container.sublayers?.compactMap { $0 as? CALayer }
            .filter { !($0 is CAGradientLayer) } ?? []
    }

    /// 把 CGImage 读入 y-down 像素缓冲(不翻转: buffer row 0 = 图像顶行,
    /// 与 rasterize 的 y-down 上下文一致)。
    private func readPixels(_ image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &buffer, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return buffer }
        // T-019(R2 同步): 与 PageVisualRendererTests.readPixels 同一约定 ——
        // 翻转 CTM 使缓冲 row 0 = 图像顶部(y-down), 后续断言统一用 y-down 坐标。
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private func solidImage(r: CGFloat, g: CGFloat, b: CGFloat, size: Int = 8) -> CGImage {
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: r, green: g, blue: b, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()!
    }

    // MARK: - live: 请求尺寸

    @Test("live: 文件夹子图标按 metrics.iconSide 请求; 普通 app 仍按整格尺寸")
    func folderChildRequestsUseIconSidePointSize() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 180),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        let cell = AppCellView()
        window.contentView = cell.view
        window.layoutIfNeeded()
        cell.view.layoutSubtreeIfNeeded()

        let provider = RecordingIconProvider()
        let folderID = FolderID("folder://p0-05-request")!
        let children = (0..<3).map { AppID("/Applications/Child\($0).app")! }
        cell.configureFolder(
            displayName: "Folder",
            accessibilityHint: "Folder",
            folderID: folderID,
            children: children,
            pointSize: 80,
            iconProvider: provider
        )
        cell.view.layoutSubtreeIfNeeded()
        await waitForRequests(provider, count: 3)

        // side=80 → padding=8.8, gap=2, iconSide=(80-17.6-4)/3=19.47 → 19。
        let expectedChildSize = max(
            1, Int(FolderThumbnailMetrics(side: 80).iconSide.rounded(.down))
        )
        #expect(expectedChildSize == 19)
        let scale = max(1, Int(window.backingScaleFactor.rounded()))
        for request in provider.requests {
            #expect(request.pointSize == expectedChildSize)
            #expect(request.scale == scale)
        }
        #expect(provider.requests.map(\.appID) == children)

        // 普通 app 配置: 仍按整格 iconPointSize 请求。
        let appProvider = RecordingIconProvider()
        cell.configure(
            displayName: "App",
            colorIndex: 0,
            accessibilityHint: "App",
            appID: AppID("/Applications/Plain.app")!,
            pointSize: 80,
            iconProvider: appProvider
        )
        await waitForRequests(appProvider, count: 1)
        #expect(appProvider.requests.first?.pointSize == 80)
    }

    // MARK: - live: 几何

    @Test("live: 子图标 layer frame = metrics.childFrame 按 bounds.height 翻转")
    func folderThumbnailLayerFramesMatchMetricsFlipped() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 180),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        let cell = AppCellView()
        window.contentView = cell.view
        window.layoutIfNeeded()
        cell.view.layoutSubtreeIfNeeded()

        let children = (0..<9).map { AppID("/Applications/Child\($0).app")! }
        cell.configureFolder(
            displayName: "Folder",
            accessibilityHint: "Folder",
            folderID: FolderID("folder://p0-05-geometry")!,
            children: children,
            pointSize: 80,
            iconProvider: nil
        )
        cell.view.layoutSubtreeIfNeeded()

        let thumbnail = try #require(findFolderThumbnailView(in: cell))
        let metrics = FolderThumbnailMetrics(side: min(
            thumbnail.bounds.width, thumbnail.bounds.height
        ))
        #expect(metrics.side == 80)
        #expect(thumbnail.layer?.cornerRadius == metrics.radius)
        #expect(thumbnail.layer?.sublayers?.first?.cornerRadius == metrics.radius)

        let layers = iconLayers(of: thumbnail)
        #expect(layers.count == 9)
        for (index, iconLayer) in layers.enumerated() {
            let frame = metrics.childFrame(index: index)
            // AppKit 非翻转视图: y = bounds.height - childFrame.maxY(网格锚定
            // 到完整 bounds 底部; 正方形 bounds 下 bounds.height == side)。
            let expected = CGRect(
                x: frame.minX,
                y: thumbnail.bounds.height - frame.maxY,
                width: frame.width,
                height: frame.height
            )
            #expect(framesEqual(iconLayer.frame, expected), "子图标 \(index) frame 与 metrics 翻转一致")
            #expect(iconLayer.cornerRadius == metrics.childRadius)
        }
    }

    // MARK: - PageVisual: 请求尺寸

    @Test("PageVisual: resolveIcons 子图标按 metrics(iconSize).iconSide 请求(T-019)")
    func resolveIconsRequestsFolderChildrenAtIconSide() async {
        let geometry = GridGeometry(
            columns: 1, rows: 1, cellSize: 120, iconSize: 96,
            horizontalSpacing: 20, verticalSpacing: 20,
            pageWidth: 150, pageHeight: 150, topInset: 0, bottomInset: 0
        )
        let appA = AppID("/Applications/PageApp.app")!
        let folderID = FolderID("/Applications/PageFolder.app")!
        let child1 = AppID("/Applications/PageChild1.app")!
        let child2 = AppID("/Applications/PageChild2.app")!

        let provider = RecordingIconProvider()
        let renderer = PageVisualRenderer()
        let icons = await renderer.resolveIcons(
            page: 0,
            items: [.app(appA), .folder(folderID)],
            folderChildrenPayload: [folderID: [child1, child2]],
            geometry: geometry,
            scale: 2,
            iconProvider: provider
        )
        #expect(icons.folderIcons[folderID]?.count == 2)

        // T-019: 渲染器缩略图绘制在图标区(与 live 容器一致): side = iconSize=96
        // → iconSide=23.36 → 23。普通 app 仍按 iconSize=96。
        let expectedChildSize = max(
            1, Int(FolderThumbnailMetrics(side: geometry.iconSize).iconSide.rounded(.down))
        )
        #expect(expectedChildSize == 23)
        let byID = Dictionary(uniqueKeysWithValues: provider.requests.map { ($0.appID, $0) })
        #expect(byID[appA]?.pointSize == 96)
        #expect(byID[child1]?.pointSize == expectedChildSize)
        #expect(byID[child2]?.pointSize == expectedChildSize)
        #expect(provider.requests.allSatisfy { $0.scale == 2 })
    }

    // MARK: - PageVisual: 光栅化几何

    @Test("PageVisual: 光栅化子图标像素范围 = metrics.iconSide(几何接线)")
    func rasterizedFolderChildExtentMatchesIconSide() throws {
        let geometry = GridGeometry(
            columns: 1, rows: 1, cellSize: 120, iconSize: 96,
            horizontalSpacing: 20, verticalSpacing: 20,
            pageWidth: 150, pageHeight: 150, topInset: 0, bottomInset: 0
        )
        let folderID = FolderID("/Applications/ExtentFolder.app")!
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
            cells: [.folder(
                slot: 0,
                label: folderID.rawValue,
                childIcons: [solidImage(r: 0, g: 0, b: 1), nil]
            )]
        )
        let visual = try #require(PageVisualRenderer.rasterize(request))
        let pixels = readPixels(visual.image)
        let width = visual.image.width
        let height = visual.image.height

        // T-019(R2): side = min(iconSize, frame.width) = 96 → iconSide≈23.36
        // → 蓝色子图标像素包围盒约 23×23 pt。
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            // y-down 坐标(缓冲 row 0 = 底部; 与 readPixels 的翻转 CTM 对应)。
            let row = height - 1 - y
            for x in 0..<width {
                let index = (row * width + x) * 4
                if pixels[index + 2] > 200, Int(pixels[index + 2]) > Int(pixels[index]) * 2 {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }
        let extentWidth = maxX - minX + 1
        let extentHeight = maxY - minY + 1
        #expect(extentWidth >= 22 && extentWidth <= 24, "子图标宽 ≈ iconSide(23.36)")
        #expect(extentHeight >= 22 && extentHeight <= 24, "子图标高 ≈ iconSide(23.36)")
        // 中心 ≈ (34.2, 22.2)(y-down 图像坐标; 与
        // folderThumbnailChildGridPlacement 的 child0 落位一致)。
        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2
        #expect(centerX >= 32 && centerX <= 36, "子图标水平中心 ≈ 34.2")
        #expect(centerY >= 20 && centerY <= 24, "子图标垂直中心 ≈ 22.2")
    }
}
