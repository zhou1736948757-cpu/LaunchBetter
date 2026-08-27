import CoreGraphics
import CoreText
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

        // T-019(R2): side = min(iconSize, frame.width) = 96(整格 120 缩小为
        // 图标区, 与 live 容器一致) → thumbFrame x=(120-96)/2=12, y=0。
        // metrics(96): padding=10.56, gap=2.4, iconSide≈23.36; child0 区域
        // (22.56, 10.56, 23.36, 23.36) 中心 ≈ (34.2, 22.2)。
        let oneX = PageVisualRenderer.rasterize(request(scale: 1))!
        let pixels1 = readPixels(oneX.image)
        let child1 = pixel(pixels1, width: 120, height: 120, x: 34, y: 28)
        #expect(child1.b > 200 && child1.a == 255, "子图标应按网格落位")
        let fill = pixel(pixels1, width: 120, height: 120, x: 60, y: 40)
        #expect(fill.a > 10 && fill.a < 100, "缩略图容器应为半透明玻璃底")

        let twoX = PageVisualRenderer.rasterize(request(scale: 2))!
        let pixels2 = readPixels(twoX.image)
        #expect(twoX.image.width == 240 && twoX.image.height == 240)
        let child2 = pixel(pixels2, width: 240, height: 240, x: 68, y: 56)
        #expect(child2.b > 200 && child2.a == 255, "2x 子图标中心按 2× 落位")
    }

    // MARK: - T-018: 不对称方向断言(镜像根因回归)

    /// 不对称方向 fixture: 上半红、下半蓝(镜像不对称; 纯色/对称 fixture 无法检测翻转)。
    ///
    /// CGContext 为 y-up: y=0 是图像底行, 故 fill(y: size/2..<size) = 上半红,
    /// fill(y: 0..<size/2) = 下半蓝。镜像后输出中该图标呈现"蓝上红下"。
    private func asymmetricIcon(size: Int = 16) -> CGImage {
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: size / 2, width: size, height: size / 2))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size / 2))
        return context.makeImage()!
    }

    /// 带方向字母 fixture: 'T'(顶横条 + 下竖干); 镜像后横条落底部。
    private func letterTIcon(size: Int = 16) -> CGImage {
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let font = CTFontCreateUIFontForLanguage(.system, CGFloat(size), nil)!
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ]
        let attributed = CFAttributedStringCreate(nil, "T" as CFString, attributes as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        context.textPosition = CGPoint(
            x: (CGFloat(size) - bounds.width) / 2 - bounds.minX,
            y: (CGFloat(size) - bounds.height) / 2 - bounds.minY
        )
        CTLineDraw(line, context)
        return context.makeImage()!
    }

    /// 1 列 1 行方向请求: gridOrigin=(15,15), gridSize=(120,120), cellSize=120,
    /// iconSize=96 → 图标区 y-down 0..96, 标签区 y-down 96..120。
    private func makeDirectionRequest(
        scale: Int, cell: PageVisualRenderRequest.CellRenderSpec
    ) -> PageVisualRenderRequest {
        PageVisualRenderRequest(
            key: PageVisualKey(
                pageIndex: 0, displayRevision: 1,
                geometry: PageVisualGeometrySignature(
                    columns: 1, rows: 1, cellSize: 120, iconSize: 96,
                    horizontalSpacing: 20, verticalSpacing: 20,
                    pageWidth: 150, pageHeight: 150, topInset: 0, bottomInset: 0
                ),
                backingScale: scale, languageRevision: 0, iconEpoch: 0
            ),
            gridOrigin: CGPoint(x: 15, y: 15),
            gridSize: CGSize(width: 120, height: 120),
            columns: 1, rows: 1, cellSize: 120, iconSize: 96,
            horizontalSpacing: 20, verticalSpacing: 20,
            scale: scale,
            cells: [cell]
        )
    }

    /// y-down 缓冲中指定区域的白像素计数(>200 阈值; 字形/标签用)。
    private func whiteCount(
        _ buffer: [UInt8], width: Int, height: Int,
        xRange: Range<Int>, yRange: Range<Int>
    ) -> Int {
        var count = 0
        for y in yRange {
            let row = height - 1 - y
            for x in xRange {
                let i = (row * width + x) * 4
                if buffer[i] > 200, buffer[i + 1] > 200, buffer[i + 2] > 200 {
                    count += 1
                }
            }
        }
        return count
    }

    @Test("T-018 1x: 不对称图标方向 — 图标区顶部=红、底部=蓝(位图未镜像)")
    func scaleOneAsymmetricIconOrientation() {
        let cell = PageVisualRenderRequest.CellRenderSpec.app(
            slot: 0, colorRGBA: (0.1, 0.1, 0.1, 1), letter: "T",
            label: "T018", icon: asymmetricIcon()
        )
        let visual = PageVisualRenderer.rasterize(makeDirectionRequest(scale: 1, cell: cell))!
        let pixels = readPixels(visual.image)
        // 图标区 y-down 0..96: 顶部(y-down 4)应红, 底部(y-down 92)应蓝。
        // 修复前(全局负 Y CTM 下 CGContextDrawImage 未补偿)该图标上下颠倒:
        // 顶部=蓝、底部=红 → 断言必失败。
        let top = pixel(pixels, width: 120, height: 120, x: 60, y: 4)
        #expect(top.r > 200 && top.g < 60 && top.b < 60 && top.a == 255, "图标区顶部应为红(未镜像)")
        let bottom = pixel(pixels, width: 120, height: 120, x: 60, y: 92)
        #expect(bottom.b > 200 && bottom.r < 60 && bottom.g < 60 && bottom.a == 255, "图标区底部应为蓝(未镜像)")
    }

    @Test("T-018 2x: 不对称图标方向 — 2× 位图同样未镜像")
    func scaleTwoAsymmetricIconOrientation() {
        let cell = PageVisualRenderRequest.CellRenderSpec.app(
            slot: 0, colorRGBA: (0.1, 0.1, 0.1, 1), letter: "T",
            label: "T018", icon: asymmetricIcon()
        )
        let visual = PageVisualRenderer.rasterize(makeDirectionRequest(scale: 2, cell: cell))!
        let pixels = readPixels(visual.image)
        // 2×: 图标区 y-down 0..192; 顶部(y-down 8)红, 底部(y-down 184)蓝。
        let top = pixel(pixels, width: 240, height: 240, x: 120, y: 8)
        #expect(top.r > 200 && top.g < 60 && top.b < 60 && top.a == 255, "2x 图标区顶部应为红(未镜像)")
        let bottom = pixel(pixels, width: 240, height: 240, x: 120, y: 184)
        #expect(bottom.b > 200 && bottom.r < 60 && bottom.g < 60 && bottom.a == 255, "2x 图标区底部应为蓝(未镜像)")
    }

    @Test("T-018 1x: 方向字母 'T' 图标 — 顶横条在图标区上半(顶点方向正确)")
    func scaleOneLetterTIconOrientation() {
        let cell = PageVisualRenderRequest.CellRenderSpec.app(
            slot: 0, colorRGBA: (0.1, 0.1, 0.1, 1), letter: "T",
            label: "T018", icon: letterTIcon()
        )
        let visual = PageVisualRenderer.rasterize(makeDirectionRequest(scale: 1, cell: cell))!
        let pixels = readPixels(visual.image)
        // 'T' 字形: 横条(宽)在顶部、竖干(窄)在下。镜像后横条落底部。
        // 图标区上半(y-down 0..48)白像素应显著多于下半(y-down 48..96)。
        let topHalf = whiteCount(pixels, width: 120, height: 120, xRange: 0..<120, yRange: 0..<48)
        let bottomHalf = whiteCount(pixels, width: 120, height: 120, xRange: 0..<120, yRange: 48..<96)
        #expect(
            topHalf > bottomHalf,
            "横条应在图标区顶部(topHalf=\(topHalf) bottomHalf=\(bottomHalf))"
        )
    }

    @Test("T-018 1x: 占位首字母方向 — 'T' 字形横条在图标区上半(CTLineDraw 未镜像)")
    func scaleOnePlaceholderLetterOrientation() {
        let cell = PageVisualRenderRequest.CellRenderSpec.app(
            slot: 0, colorRGBA: (0.1, 0.1, 0.1, 1), letter: "T",
            label: "T018", icon: nil
        )
        let visual = PageVisualRenderer.rasterize(makeDirectionRequest(scale: 1, cell: cell))!
        let pixels = readPixels(visual.image)
        // 占位首字母经 drawCenteredText(CTLineDraw)绘制; 修复前 flipped 上下文
        // 下字形上下颠倒(横条落底部)。上半白像素应多于下半。
        let topHalf = whiteCount(pixels, width: 120, height: 120, xRange: 0..<120, yRange: 0..<48)
        let bottomHalf = whiteCount(pixels, width: 120, height: 120, xRange: 0..<120, yRange: 48..<96)
        #expect(
            topHalf > bottomHalf,
            "占位首字母横条应在顶部(topHalf=\(topHalf) bottomHalf=\(bottomHalf))"
        )
    }

    // MARK: - T-019: 标签截断契约(与 live byTruncatingTail 对齐) + 文件夹尺寸

    /// 1 列 1 行标签截断请求: gridOrigin=(0,0), gridSize=(cellSize, cellSize)。
    /// labelRect 与 drawLabel 口径一致: x=2, width=cellSize−4。
    private func makeTruncationRequest(
        label: String, cellSize: Double, scale: Int
    ) -> PageVisualRenderRequest {
        PageVisualRenderRequest(
            key: PageVisualKey(
                pageIndex: 0, displayRevision: 1,
                geometry: PageVisualGeometrySignature(
                    columns: 1, rows: 1, cellSize: cellSize, iconSize: 32,
                    horizontalSpacing: 20, verticalSpacing: 20,
                    pageWidth: cellSize, pageHeight: cellSize, topInset: 0, bottomInset: 0
                ),
                backingScale: scale, languageRevision: 0, iconEpoch: 0
            ),
            gridOrigin: .zero,
            gridSize: CGSize(width: cellSize, height: cellSize),
            columns: 1, rows: 1, cellSize: cellSize, iconSize: 32,
            horizontalSpacing: 20, verticalSpacing: 20,
            scale: scale,
            cells: [.app(
                slot: 0, colorRGBA: (0.1, 0.1, 0.1, 1), letter: "A",
                label: label, icon: nil
            )]
        )
    }

    /// 标签带(y-down 行 [minY, maxY])内白像素的最右 x(像素坐标)。
    private func labelInkRightmost(
        _ buffer: [UInt8], width: Int, height: Int,
        cellSize: Double, scale: Int
    ) -> Int? {
        let gap = max(6.0, (cellSize - 32) / 4)
        let bandMinY = Int(((cellSize - gap - 13) * Double(scale)).rounded(.up))
        let bandMaxY = Int(((cellSize - gap) * Double(scale)).rounded(.down))
        var rightmost: Int? = nil
        for y in bandMinY...bandMaxY {
            let row = height - 1 - y
            for x in 0..<width {
                let i = (row * width + x) * 4
                if buffer[i] > 200, buffer[i + 1] > 200, buffer[i + 2] > 200 {
                    rightmost = max(rightmost ?? -1, x)
                }
            }
        }
        return rightmost
    }

    @Test("T-019 截断: band 文本(typo 宽 > rect 宽, 但 glyph-path 宽 < rect 宽) → 必须截断, ink 收进 rect")
    func truncationBandTextIsTruncated() {
        // "Photoshop" @10pt: typo≈51.8, glyphPath≈50.2。labelRect 宽 = 55−4 = 51
        // 恰好落在"修复前口径不截断、修复后口径截断"的 band 内。
        let cellSize = 55.0
        let scale = 4
        let visual = PageVisualRenderer.rasterize(
            makeTruncationRequest(label: "Photoshop", cellSize: cellSize, scale: scale)
        )!
        let pixels = readPixels(visual.image)
        // labelRect: x 2..53(宽 51); band y-down 36..49 × scale。
        let rectMaxXPx = Int((2.0 + 51.0) * Double(scale))
        let rightmost = labelInkRightmost(
            pixels, width: visual.image.width, height: visual.image.height,
            cellSize: cellSize, scale: scale
        )
        // 截断后省略号收在 rect 内(ink ≤ maxX−2pt); 修复前画全名, ink 溢出到 maxX 附近。
        #expect(rightmost != nil, "标签应已绘制")
        #expect(
            rightmost! <= rectMaxXPx - 2 * scale,
            "截断文本应收在 labelRect 内(修复前画全名, rightmost=\(rightmost ?? -1) > \(rectMaxXPx - 2 * scale))"
        )
        #expect(rightmost! >= 4 * scale, "标签文本应存在")
    }

    @Test("T-019 截断: 超长文本(远宽于 rect) → 截断后不超 rect")
    func truncationLongTextFits() {
        let cellSize = 55.0
        let scale = 1
        let visual = PageVisualRenderer.rasterize(
            makeTruncationRequest(
                label: "Super long app name that keeps going and going ", cellSize: cellSize, scale: scale
            )
        )!
        let pixels = readPixels(visual.image)
        let rightmost = labelInkRightmost(
            pixels, width: visual.image.width, height: visual.image.height,
            cellSize: cellSize, scale: scale
        )
        #expect(rightmost != nil, "截断文本应已绘制")
        #expect(rightmost! <= Int(2.0 + 51.0) + 2, "超长文本必须截断且 ink 不超过 labelRect+1pt")
    }

    @Test("T-019 截断: 短文本不截断(完整绘制, 不提前省略)")
    func truncationShortTextNotTruncated() {
        let cellSize = 55.0
        let scale = 1
        let visual = PageVisualRenderer.rasterize(
            makeTruncationRequest(label: "Test", cellSize: cellSize, scale: scale)
        )!
        let pixels = readPixels(visual.image)
        let rightmost = labelInkRightmost(
            pixels, width: visual.image.width, height: visual.image.height,
            cellSize: cellSize, scale: scale
        )
        // "Test" @10pt 宽 ≈ 23pt, 完整绘制 → ink 右缘 ≈ 4 + 23 ≈ 27(居中以 typo 23/2)。
        // 断言 ink 越过 labelRect 中线(≈16pt) 且不超右缘: 未截断、未提前裁剪。
        #expect(rightmost != nil, "短标签应已绘制")
        #expect(rightmost! >= 24, "短文本应完整绘制(rightmost=\(rightmost ?? -1), 未截断)")
        #expect(rightmost! <= Int(2.0 + 51.0) + 2, "短文本 ink 不应超出 labelRect")
    }

    @Test("T-019 文件夹: resolveIcons 子图标按 metrics(iconSize).iconSide 请求(对齐 live)")
    func folderChildRequestsUseIconSize() async {
        let geometry = GridGeometry(
            columns: 1, rows: 1, cellSize: 120, iconSize: 96,
            horizontalSpacing: 20, verticalSpacing: 20,
            pageWidth: 150, pageHeight: 150, topInset: 0, bottomInset: 0
        )
        let appA = AppID("/Applications/T019App.app")!
        let folderID = FolderID("/Applications/T019Folder.app")!
        let child1 = AppID("/Applications/T019Child1.app")!
        let child2 = AppID("/Applications/T019Child2.app")!

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

        // T-019 契约: 与 live(AppCellView:636 用 iconPointSize)一致 → side=iconSize=96
        // (旧实现用 cellSize=120 → iconSide=29, 偏大)。side=96 → iconSide=23.36 → 23。
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


    @Test("T-018 文件夹: 不对称子图标在缩略图内未镜像(红上/蓝下)")
    func folderChildIconOrientation() {
        let geometry = GridGeometry(
            columns: 1, rows: 1, cellSize: 120, iconSize: 96,
            horizontalSpacing: 20, verticalSpacing: 20,
            pageWidth: 150, pageHeight: 150, topInset: 0, bottomInset: 0
        )
        let folderID = FolderID("/Applications/CompositorFolder.app")!
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
                childIcons: [asymmetricIcon(), nil, nil]
            )]
        )
        let visual = PageVisualRenderer.rasterize(request)!
        let pixels = readPixels(visual.image)
        // T-019(R2): side=96 → padding=10.56, iconSide≈23.36; 子图标 0 区域
        // y-down (22.56, 10.56, 23.36, 23.36): 顶部(y-down 14)应红, 底部
        // (y-down 28)应蓝。
        let top = pixel(pixels, width: 120, height: 120, x: 34, y: 14)
        #expect(top.r > 200 && top.g < 60 && top.b < 60 && top.a == 255, "子图标顶部应为红(未镜像)")
        let bottom = pixel(pixels, width: 120, height: 120, x: 34, y: 28)
        #expect(bottom.b > 200 && bottom.r < 60 && bottom.g < 60 && bottom.a == 255, "子图标底部应为蓝(未镜像)")
    }
}
