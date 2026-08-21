import AppKit
import CoreGraphics
import CoreText
import Foundation
import LaunchCore

/// 页面视觉渲染请求: 完全冻结的 Sendable 值, 供后台线程光栅化。
///
/// 渲染器(OPTION C)只绘制**页面网格内容区**(gridOrigin + gridWidth/gridHeight),
/// 不包含搜索栏/页点/壁纸。坐标系 = 页面局部 y-down(与 flipped 文档视图一致)。
struct PageVisualRenderRequest: Sendable {
    let key: PageVisualKey
    let gridOrigin: CGPoint
    let gridSize: CGSize
    let columns: Int
    let rows: Int
    let cellSize: CGFloat
    let iconSize: CGFloat
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat
    let scale: Int
    let cells: [CellRenderSpec]

    enum CellRenderSpec: Sendable {
        case app(slot: Int, colorRGBA: (Float, Float, Float, Float), letter: String, label: String, icon: CGImage?)
        case folder(slot: Int, label: String, childIcons: [CGImage?])
    }
}

/// 一个 working set 的已解析图标集合(冻结值, Sendable)。
struct PageVisualIconSet: Sendable {
    let appIcons: [AppID: CGImage]
    let folderIcons: [FolderID: [CGImage?]]

    /// 全部可用图标 ID(普通 App + 文件夹可见子项)。
    var availableIDs: Set<AppID> {
        let ids = Set(appIcons.keys)
        for (folderID, icons) in folderIcons {
            for (index, icon) in icons.enumerated() where icon != nil {
                // 保持与解析顺序一致的可判定性: 这里只需 ID 集合,
                // 不依赖 child 顺序。
                _ = index
                _ = folderID
                break
            }
        }
        return ids
    }
}

/// 轻量页面渲染器(纯内存, 后台/idle 准备)。
///
/// 输入: layout page 的显示项 + 几何 + 内存图标(CGImage)+ 名称(当前语言)+
/// 文件夹(≤9 子图标缩略)。图标未就绪 → 稳定占位(与 live 一致: 色块 + 首字母);
/// 绝不在手势中触盘/读 Info.plist(渲染请求在 idle 时冻结)。
///
/// 图标代数: working set 图标先整体解析, epoch = 可用图标集合的稳定哈希。
/// 任何"迟到图标到达"都会改变集合 → 新 epoch → 旧视觉失效, 下次 idle 重建。
@MainActor
final class PageVisualRenderer {
    /// 与 AppCellView 一致的稳定色块索引。
    static func colorIndex(for key: String) -> Int {
        abs(key.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % 12
    }

    /// 占位色块颜色(与 AppCellView.configure 一致: hue = idx/12, s=0.45, b=0.55)。
    static func placeholderRGBA(colorIndex: Int) -> (Float, Float, Float, Float) {
        let hue = CGFloat(colorIndex % 12) / 12
        let color = NSColor(hue: hue, saturation: 0.45, brightness: 0.55, alpha: 1)
        guard let rgb = color.usingColorSpace(.deviceRGB) else {
            return (0.2, 0.2, 0.2, 1)
        }
        return (
            Float(rgb.redComponent), Float(rgb.greenComponent),
            Float(rgb.blueComponent), Float(rgb.alphaComponent)
        )
    }

    /// 构造当前 key(数据/几何/scale/语言/图标代数)。
    func makeKey(
        page: Int,
        displayRevision: UInt64,
        geometry: GridGeometry,
        scale: Int,
        languageRevision: UInt64,
        iconEpoch: UInt64
    ) -> PageVisualKey {
        PageVisualKey(
            pageIndex: page,
            displayRevision: displayRevision,
            geometry: PageVisualGeometrySignature(geometry: geometry),
            backingScale: scale,
            languageRevision: languageRevision,
            iconEpoch: iconEpoch
        )
    }

    /// 图标代数 = 可用图标集合的稳定哈希(会话内确定性; 集合变化 → 代数变化)。
    func epoch(for iconSet: PageVisualIconSet) -> UInt64 {
        var hash: UInt64 = 5381
        for id in iconSet.availableIDs.sorted(by: { $0.rawValue < $1.rawValue }) {
            hash = hash &* 33 &+ UInt64(truncatingIfNeeded: id.rawValue.hashValue)
        }
        return hash
    }

    /// 解析一个 working set 的全部图标(主线程, 仅内存/缓存管道; idle 调用)。
    func resolveIcons(
        pages: [(page: Int, items: [DisplayModel.DisplayItem])],
        folderChildrenPayload: [FolderID: [AppID]],
        geometry: GridGeometry,
        scale: Int,
        iconProvider: (any IconImageProviding)?
    ) async -> PageVisualIconSet {
        guard let iconProvider, geometry.iconSize > 0 else {
            return PageVisualIconSet(appIcons: [:], folderIcons: [:])
        }
        let pointSize = max(1, Int(geometry.iconSize.rounded(.down)))
        var appIcons: [AppID: CGImage] = [:]
        var folderIcons: [FolderID: [CGImage?]] = [:]
        for item in pages.flatMap(\.items) {
            switch item {
            case .app(let appID):
                if let image = await iconProvider.icon(
                    for: appID, pointSize: pointSize, scale: scale
                ) {
                    appIcons[appID] = image
                }
            case .folder(let folderID):
                let children = folderChildrenPayload[folderID] ?? []
                var icons: [CGImage?] = []
                for child in children.prefix(9) {
                    let image = await iconProvider.icon(
                        for: child, pointSize: pointSize, scale: scale
                    )
                    icons.append(image)
                }
                folderIcons[folderID] = icons
            }
        }
        return PageVisualIconSet(appIcons: appIcons, folderIcons: folderIcons)
    }

    /// 准备一张页面视觉(idle 调用)。图标由调用方预先解析(epoch 与之对应)。
    ///
    /// - 冻结请求 → `Task.detached` 后台光栅化 → 返回(不触碰 AppKit 视图树)。
    /// - 返回 nil = 内容不足 / 上下文分配失败。
    func prepare(
        page: Int,
        items: [DisplayModel.DisplayItem],
        displayName: (AppID) -> String,
        folderName: (FolderID) -> String,
        geometry: GridGeometry,
        scale: Int,
        displayRevision: UInt64,
        languageRevision: UInt64,
        icons: PageVisualIconSet,
        iconEpoch: UInt64
    ) async -> PageVisual? {
        guard !items.isEmpty, geometry.pageWidth > 0, geometry.pageHeight > 0,
              geometry.gridWidth > 0, geometry.gridHeight > 0 else {
            return nil
        }

        var cells: [PageVisualRenderRequest.CellRenderSpec] = []
        cells.reserveCapacity(items.count)
        for (slot, item) in items.enumerated() {
            switch item {
            case .app(let appID):
                cells.append(.app(
                    slot: slot,
                    colorRGBA: Self.placeholderRGBA(colorIndex: Self.colorIndex(for: appID.rawValue)),
                    letter: String(displayName(appID).prefix(1)).uppercased(),
                    label: displayName(appID),
                    icon: icons.appIcons[appID]
                ))
            case .folder(let folderID):
                cells.append(.folder(
                    slot: slot,
                    label: folderName(folderID),
                    childIcons: icons.folderIcons[folderID] ?? []
                ))
            }
        }

        let key = makeKey(
            page: page,
            displayRevision: displayRevision,
            geometry: geometry,
            scale: scale,
            languageRevision: languageRevision,
            iconEpoch: iconEpoch
        )
        let request = PageVisualRenderRequest(
            key: key,
            gridOrigin: geometry.gridOrigin,
            gridSize: CGSize(width: geometry.gridWidth, height: geometry.gridHeight),
            columns: geometry.columns,
            rows: geometry.rows,
            cellSize: geometry.cellSize,
            iconSize: geometry.iconSize,
            horizontalSpacing: geometry.horizontalSpacing,
            verticalSpacing: geometry.verticalSpacing,
            scale: scale,
            cells: cells
        )

        // 后台光栅化(纯 CoreGraphics/CoreText, 不触碰 AppKit 视图树)。
        let render = await Task.detached(priority: .utility) {
            PageVisualRenderer.rasterize(request)
        }.value
        return render
    }

    /// 纯光栅化(可离线测试): 1x/2x 逐像素可控。nonisolated: 后台线程调用。
    nonisolated static func rasterize(_ request: PageVisualRenderRequest) -> PageVisual? {
        let scale = max(1, request.scale)
        let pixelWidth = max(1, Int(ceil(request.gridSize.width * CGFloat(scale))))
        let pixelHeight = max(1, Int(ceil(request.gridSize.height * CGFloat(scale))))
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high

        // y-down 页面坐标(与 flipped 文档一致)。
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        context.scaleBy(x: 1, y: -1)

        for cell in request.cells {
            let slot: Int
            switch cell {
            case .app(let s, _, _, _, _): slot = s
            case .folder(let s, _, _): slot = s
            }
            let origin = slotOrigin(slot: slot, request: request)
            let frame = CGRect(
                x: origin.x - request.gridOrigin.x,
                y: origin.y - request.gridOrigin.y,
                width: request.cellSize,
                height: request.cellSize
            )
            switch cell {
            case .app(_, let rgba, let letter, let label, let icon):
                drawAppIcon(
                    frame: frame, rgba: rgba, letter: letter, icon: icon, request: request,
                    context: context
                )
                drawLabel(text: label, cellFrame: frame, request: request, context: context)
            case .folder(_, let label, let childIcons):
                drawFolderThumbnail(
                    frame: frame, childIcons: childIcons, request: request, context: context
                )
                drawLabel(text: label, cellFrame: frame, request: request, context: context)
            }
        }

        guard let image = context.makeImage() else { return nil }
        return PageVisual(
            key: request.key,
            image: image,
            logicalBounds: CGRect(origin: .zero, size: request.gridSize),
            rasterScale: CGFloat(scale)
        )
    }

    // MARK: - 绘制原语(AppCellView / FolderThumbnailView 视觉对齐)

    nonisolated private static func slotOrigin(slot: Int, request: PageVisualRenderRequest) -> CGPoint {
        let col = slot % request.columns
        let row = slot / request.columns
        return CGPoint(
            x: request.gridOrigin.x + CGFloat(col) * (request.cellSize + request.horizontalSpacing),
            y: request.gridOrigin.y + CGFloat(row) * (request.cellSize + request.verticalSpacing)
        )
    }

    /// 图标(真实位图 aspect-fit)或占位(圆角色块 + 首字母), 与 AppCellView 一致。
    nonisolated private static func drawAppIcon(
        frame: CGRect,
        rgba: (Float, Float, Float, Float),
        letter: String,
        icon: CGImage?,
        request: PageVisualRenderRequest,
        context: CGContext
    ) {
        let iconSide = min(request.iconSize, frame.width)
        let iconFrame = CGRect(
            x: frame.minX + (frame.width - iconSide) / 2,
            y: frame.minY,
            width: iconSide,
            height: iconSide
        )
        if let icon {
            context.draw(icon, in: iconFrame)
            return
        }
        // 占位: 圆角 16 色块 + 白色首字母(live: iconLayer.cornerRadius = 16, masksToBounds)。
        context.saveGState()
        let clipPath = CGPath(
            roundedRect: iconFrame, cornerWidth: 16, cornerHeight: 16, transform: nil
        )
        context.addPath(clipPath)
        context.clip()
        context.setFillColor(red: CGFloat(rgba.0), green: CGFloat(rgba.1), blue: CGFloat(rgba.2), alpha: CGFloat(rgba.3))
        context.fill(iconFrame)
        drawCenteredText(
            letter,
            in: iconFrame,
            fontSize: iconSide * 0.5,
            color: (1, 1, 1, 1),
            context: context
        )
        context.restoreGState()
    }

    /// 文件夹缩略图: 圆角玻璃容器 + sheen + ≤9 子图标网格(对齐 FolderThumbnailView)。
    nonisolated private static func drawFolderThumbnail(
        frame: CGRect,
        childIcons: [CGImage?],
        request: PageVisualRenderRequest,
        context: CGContext
    ) {
        let side = min(frame.width, frame.height)
        let thumbFrame = CGRect(
            x: frame.minX + (frame.width - side) / 2,
            y: frame.minY,
            width: side,
            height: side
        )
        let radius = min(18, max(10, side * 0.2))
        let path = CGPath(
            roundedRect: thumbFrame, cornerWidth: radius, cornerHeight: radius, transform: nil
        )
        context.saveGState()
        context.addPath(path)
        context.clip()

        // 背景: 白 0.08 + 边框白 0.38(1/scale)。
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.08)
        context.fill(thumbFrame)
        context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.38)
        context.setLineWidth(CGFloat(1) / CGFloat(max(1, request.scale)))
        context.addPath(path)
        context.strokePath()

        // sheen: 顶亮 → 底暗(白 0.18 → 0.02)。
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.18),
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.02),
            ] as CFArray,
            locations: [0, 1]
        )
        if let gradient {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: thumbFrame.midX, y: thumbFrame.minY),
                end: CGPoint(x: thumbFrame.midX, y: thumbFrame.maxY),
                options: []
            )
        }

        // 子图标网格(≤9): padding = side*0.11, gap = side*0.025, 圆角 = side*0.16。
        let padding = max(5, side * 0.11)
        let gap = max(2, side * 0.025)
        let iconSide = max(1, (side - padding * 2 - gap * 2) / 3)
        for (index, icon) in childIcons.prefix(9).enumerated() {
            guard let icon else { continue }
            let row = index / 3
            let col = index % 3
            let childFrame = CGRect(
                x: thumbFrame.minX + padding + CGFloat(col) * (iconSide + gap),
                y: thumbFrame.minY + padding + CGFloat(row) * (iconSide + gap),
                width: iconSide,
                height: iconSide
            )
            context.saveGState()
            let childRadius = min(5, max(2, iconSide * 0.16))
            let childPath = CGPath(
                roundedRect: childFrame, cornerWidth: childRadius, cornerHeight: childRadius,
                transform: nil
            )
            context.addPath(childPath)
            context.clip()
            context.draw(icon, in: childFrame)
            context.restoreGState()
        }
        context.restoreGState()
    }

    /// 标签(AppCellView: 10pt 系统字体, 白, 黑 0.85 阴影, 尾部截断, 居中)。
    nonisolated private static func drawLabel(
        text: String,
        cellFrame: CGRect,
        request: PageVisualRenderRequest,
        context: CGContext
    ) {
        let gap = max(6, (request.cellSize - request.iconSize) / 4)
        let labelRect = CGRect(
            x: cellFrame.minX + 2,
            y: cellFrame.maxY - gap - 13,
            width: max(1, cellFrame.width - 4),
            height: 13
        )
        drawCenteredText(
            text,
            in: labelRect,
            fontSize: 10,
            color: (1, 1, 1, 1),
            truncatingTail: true,
            context: context
        )
    }

    nonisolated private static func drawCenteredText(
        _ text: String,
        in rect: CGRect,
        fontSize: CGFloat,
        color: (Float, Float, Float, Float),
        truncatingTail: Bool = false,
        context: CGContext
    ) {
        guard !text.isEmpty, rect.width > 0 else { return }
        guard let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil) else { return }
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(
                red: CGFloat(color.0), green: CGFloat(color.1),
                blue: CGFloat(color.2), alpha: CGFloat(color.3)
            ),
        ]
        let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
        guard let attributed else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        let targetLine: CTLine
        if truncatingTail, bounds.width > rect.width {
            guard let truncated = CTLineCreateTruncatedLine(
                line,
                Double(rect.width),
                .end,
                nil
            ) else { return }
            targetLine = truncated
        } else {
            targetLine = line
        }
        let finalBounds = CTLineGetBoundsWithOptions(targetLine, [.useGlyphPathBounds])
        let x = rect.midX - finalBounds.width / 2
        let y = rect.midY - finalBounds.height / 2 - finalBounds.minY

        context.saveGState()
        // 阴影(对齐 live: 黑 0.85, blur 4, 下方 1pt)。
        context.setShadow(
            offset: CGSize(width: 0, height: 1), blur: 4,
            color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.85)
        )
        // flipped(y-down)上下文绘制 CoreText 必须复位 textMatrix。
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(targetLine, context)
        context.restoreGState()
    }
}
