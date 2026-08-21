import CoreGraphics
import Foundation
import LaunchCore
import Testing
@testable import LaunchUI

@Suite("PageVisualRenderer: 1x/2x 像素验证", .serialized)
@MainActor
struct PageVisualRendererTests {
    // MARK: - helpers

    /// 把 CGImage 读入 y-down 像素缓冲(memory row 0 = 图像顶部行)。
    ///
    /// 实测: 翻转 CTM 的 CGContext.draw(image:) 把图像的 row 0(顶行)绘制到
    /// rect 底部 → 读取时必须反转 y, 得到与渲染 y-down 空间一致的坐标。
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

    /// (x, y) 为 y-down 坐标(y 从图像顶部起算)。
    private func pixel(_ buffer: [UInt8], width: Int, height: Int, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let row = height - 1 - y
        let index = (row * width + x) * 4
        return (Int(buffer[index]), Int(buffer[index + 1]), Int(buffer[index + 2]), Int(buffer[index + 3]))
    }

    /// 纯色 CGImage 工厂。
    private func solidImage(r: CGFloat, g: CGFloat, b: CGFloat, alpha: CGFloat = 1, size: Int = 8) -> CGImage {
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: r, green: g, blue: b, alpha: alpha)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()!
    }

    private func makeKey(page: Int, scale: Int) -> PageVisualKey {
        PageVisualKey(
            pageIndex: page, displayRevision: 1,
            geometry: PageVisualGeometrySignature(
                columns: 2, rows: 1, cellSize: 60, iconSize: 32,
                horizontalSpacing: 20, verticalSpacing: 20,
                pageWidth: 200, pageHeight: 120, topInset: 0, bottomInset: 0
            ),
            backingScale: scale, languageRevision: 0, iconEpoch: 0
        )
    }

    /// 2 列 1 行几何: gridOrigin=(30,30), gridSize=(140,60)。
    /// item0 = 真实红色图标; item1 = 无图标(占位: 色块 + 首字母)。
    private func makeRequest(scale: Int) -> PageVisualRenderRequest {
        let appA = AppID("/Applications/CompositorA.app")!
        let appB = AppID("/Applications/CompositorB.app")!
        let colorIndex = PageVisualRenderer.colorIndex(for: appB.rawValue)
        let rgba = PageVisualRenderer.placeholderRGBA(colorIndex: colorIndex)
        return PageVisualRenderRequest(
            key: makeKey(page: 1, scale: scale),
            gridOrigin: CGPoint(x: 30, y: 30),
            gridSize: CGSize(width: 140, height: 60),
            columns: 2, rows: 1, cellSize: 60, iconSize: 32,
            horizontalSpacing: 20, verticalSpacing: 20,
            scale: scale,
            cells: [
                .app(
                    slot: 0, colorRGBA: rgba, letter: "A",
                    label: appA.rawValue, icon: solidImage(r: 1, g: 0, b: 0)
                ),
                .app(
                    slot: 1, colorRGBA: rgba, letter: "B",
                    label: appB.rawValue, icon: nil
                ),
            ]
        )
    }

    // MARK: - 1x

    @Test("1x: 位图尺寸 = 网格内容区像素; 真实图标按几何落位")
    func scaleOneRealIconPlacement() {
        let visual = PageVisualRenderer.rasterize(makeRequest(scale: 1))
        #expect(visual != nil)
        let image = visual!.image
        #expect(image.width == 140)
        #expect(image.height == 60)
        #expect(visual!.rasterScale == 1)
        #expect(visual!.logicalBounds == CGRect(x: 0, y: 0, width: 140, height: 60))

        let pixels = readPixels(image)
        // item0 图标中心(页面 y-down 坐标 (60,46) → 位图 (30,16)): 红色。
        let red = pixel(pixels, width: 140, height: 60, x: 30, y: 16)
        #expect(red.r > 200 && red.g < 60 && red.b < 60 && red.a == 255)
        // 图标角(避开圆角/插值边缘): (44,30) → 位图 (14,0)。
        let corner = pixel(pixels, width: 140, height: 60, x: 14, y: 0)
        #expect(corner.r > 200 && corner.a == 255)
    }

    @Test("1x: 占位色块按几何落位; 标签白字在标签区; 空隙透明")
    func scaleOnePlaceholderLabelAndGap() {
        let appB = AppID("/Applications/CompositorB.app")!
        let visual = PageVisualRenderer.rasterize(makeRequest(scale: 1))!
        let pixels = readPixels(visual.image)
        let rgba = PageVisualRenderer.placeholderRGBA(
            colorIndex: PageVisualRenderer.colorIndex(for: appB.rawValue)
        )

        // item1 占位块内部、避开首字母字形(页面 (127,46) → 位图 (97,16))。
        let center = pixel(pixels, width: 140, height: 60, x: 97, y: 16)
        #expect(
            abs(center.r - Int(rgba.0 * 255)) <= 4
                && abs(center.g - Int(rgba.1 * 255)) <= 4
                && abs(center.b - Int(rgba.2 * 255)) <= 4,
            "占位色块颜色/位置与几何一致"
        )
        // 首字母: 图标区内应有白色字形像素(item1 图标位图 x 94..125, y 0..31)。
        var letterFound = false
        for y in 8...24 {
            for x in 100...120 where !letterFound {
                let p = pixel(pixels, width: 140, height: 60, x: x, y: y)
                if p.r > 230, p.g > 230, p.b > 230 { letterFound = true }
            }
        }
        #expect(letterFound, "占位首字母应绘制在图标区")

        // 标签区(cell1: 位图 x 82..136, y 40..52)应有白色文字像素。
        var labelFound = false
        for y in 40...52 {
            for x in 82...136 where !labelFound {
                let p = pixel(pixels, width: 140, height: 60, x: x, y: y)
                if p.r > 150, p.g > 150, p.b > 150 { labelFound = true }
            }
        }
        #expect(labelFound, "标签应绘制在单元格底部")

        // 空隙透明: 两图标之间(位图 x 46..93, y 16)。
        let gap = pixel(pixels, width: 140, height: 60, x: 70, y: 16)
        #expect(gap.a == 0, "图标之间应保持透明(壁纸透出)")
    }

    // MARK: - 2x

    @Test("2x: 位图像素尺寸翻倍; 几何落位按 2× 缩放")
    func scaleTwoDoubleResolution() {
        let visual = PageVisualRenderer.rasterize(makeRequest(scale: 2))
        #expect(visual != nil)
        let image = visual!.image
        #expect(image.width == 280)
        #expect(image.height == 120)
        #expect(visual!.rasterScale == 2)

        let pixels = readPixels(image)
        // item0 图标中心 2×: (60, 32)。
        let red = pixel(pixels, width: 280, height: 120, x: 60, y: 32)
        #expect(red.r > 200 && red.g < 60 && red.b < 60 && red.a == 255)

        // item1 占位块内部 2×、避开字形: (194, 32)。
        let appB = AppID("/Applications/CompositorB.app")!
        let rgba = PageVisualRenderer.placeholderRGBA(
            colorIndex: PageVisualRenderer.colorIndex(for: appB.rawValue)
        )
        let placeholder = pixel(pixels, width: 280, height: 120, x: 194, y: 32)
        #expect(
            abs(placeholder.r - Int(rgba.0 * 255)) <= 4
                && abs(placeholder.g - Int(rgba.1 * 255)) <= 4,
            "2x 占位落位与 1x 逻辑坐标一致"
        )

        // 空隙透明 2×: (140, 32)。
        let gap = pixel(pixels, width: 280, height: 120, x: 140, y: 32)
        #expect(gap.a == 0)
    }

    // MARK: - 文件夹缩略图

    @Test("文件夹缩略图: 玻璃底 + sheen + 子图标网格落位(1x/2x)")
    func folderThumbnailChildGridPlacement() {
        let geometry = GridGeometry(
            columns: 1, rows: 1, cellSize: 120, iconSize: 96,
            horizontalSpacing: 20, verticalSpacing: 20,
            pageWidth: 150, pageHeight: 150, topInset: 0, bottomInset: 0
        )
        let folderID = FolderID("/Applications/CompositorFolder.app")!

        func request(scale: Int) -> PageVisualRenderRequest {
            PageVisualRenderRequest(
                key: PageVisualKey(
                    pageIndex: 0, displayRevision: 1,
                    geometry: PageVisualGeometrySignature(geometry: geometry),
                    backingScale: scale, languageRevision: 0, iconEpoch: 0
                ),
                gridOrigin: CGPoint(x: 15, y: 15),
                gridSize: CGSize(width: 120, height: 120),
                columns: 1, rows: 1, cellSize: 120, iconSize: 96,
                horizontalSpacing: 20, verticalSpacing: 20,
                scale: scale,
                cells: [.folder(
                    slot: 0,
                    label: folderID.rawValue,
                    childIcons: [solidImage(r: 0, g: 0, b: 1), nil]
                )]
            )
        }

        // side=120, padding=13.2, gap=3, iconSide≈29.2; child0 中心 ≈ (27.8, 27.8)。
        let oneX = PageVisualRenderer.rasterize(request(scale: 1))!
        let pixels1 = readPixels(oneX.image)
        let child1 = pixel(pixels1, width: 120, height: 120, x: 28, y: 28)
        #expect(child1.b > 200 && child1.a == 255, "子图标应按网格落位")
        let fill = pixel(pixels1, width: 120, height: 120, x: 60, y: 100)
        #expect(fill.a > 10 && fill.a < 100, "缩略图容器应为半透明玻璃底")

        let twoX = PageVisualRenderer.rasterize(request(scale: 2))!
        let pixels2 = readPixels(twoX.image)
        #expect(twoX.image.width == 240 && twoX.image.height == 240)
        let child2 = pixel(pixels2, width: 240, height: 240, x: 55, y: 55)
        #expect(child2.b > 200 && child2.a == 255, "2x 子图标中心按 2× 落位")
    }
}
