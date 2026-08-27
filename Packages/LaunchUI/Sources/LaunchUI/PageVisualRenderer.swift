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

    /// 全部可用图标 ID(普通 App + 文件夹可见子项): 所有已解析到非 nil
    /// 图标的 AppID 并集。图标代数 epoch 的唯一输入。
    let availableIDs: Set<AppID>

    init(
        appIcons: [AppID: CGImage],
        folderIcons: [FolderID: [CGImage?]],
        availableIDs: Set<AppID>
    ) {
        self.appIcons = appIcons
        self.folderIcons = folderIcons
        self.availableIDs = availableIDs
    }
}

/// 轻量页面渲染器(纯内存, 后台/idle 准备)。
///
/// 输入: layout page 的显示项 + 几何 + 内存图标(CGImage)+ 名称(当前语言)+
/// 文件夹(≤9 子图标缩略)。图标未就绪 → 稳定占位(与 live 一致: 色块 + 首字母);
/// 绝不在手势中触盘/读 Info.plist(渲染请求在 idle 时冻结)。
///
/// 图标代数: 每页独立解析图标, epoch = 该页可用图标集合的稳定哈希。
/// 任何"迟到图标到达"都会改变该页集合 → 新 epoch → 旧视觉失效, 下次 idle 重建
/// (只重建受影响页)。
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

    /// 单页图标请求计划(有界 TaskGroup 的输入; 保持页内请求顺序)。
    /// 每个请求携带自己的 pointSize: 普通 app 按整格 iconSize, 文件夹子图标
    /// 按缩略图实际显示尺寸(metrics.iconSide, P0-05)。
    private enum IconRequest: Sendable {
        case app(AppID, pointSize: Int)
        case folderChild(folderID: FolderID, appID: AppID, index: Int, pointSize: Int)

        var appID: AppID {
            switch self {
            case .app(let id, _): return id
            case .folderChild(_, let id, _, _): return id
            }
        }

        var pointSize: Int {
            switch self {
            case .app(_, let pointSize): return pointSize
            case .folderChild(_, _, _, let pointSize): return pointSize
            }
        }
    }

    /// 解析单页全部图标(idle 调用; 请求并发执行, 不触碰视图树)。
    ///
    /// 并发策略: 先收集唯一请求(普通 app 集合去重; 每个 folder 取
    /// children.prefix(9)), 再用 `withTaskGroup` 并发请求——每批最多 8 个
    /// 在途(一批 addTask 后逐个 `await group.next()` 消耗完再开下一批)。
    /// 结果装回 appIcons / [FolderID: [CGImage?]]; availableIDs = 所有得到
    /// 非 nil 图标的 app/child ID 并集。iconProvider 为 nil 或几何无效时
    /// 返回空集(调用方保持占位语义)。
    func resolveIcons(
        page: Int,
        items: [DisplayModel.DisplayItem],
        folderChildrenPayload: [FolderID: [AppID]],
        geometry: GridGeometry,
        scale: Int,
        iconProvider: (any IconImageProviding)?
    ) async -> PageVisualIconSet {
        guard let iconProvider, geometry.iconSize > 0 else {
            return PageVisualIconSet(appIcons: [:], folderIcons: [:], availableIDs: [])
        }
        // P0-05: 普通 app 按整格 iconSize 请求; 文件夹子图标按缩略图实际
        // 显示尺寸请求(metrics.iconSide, 向下取整, 与 live AppCellView 同一
        // 取整约定 → 同一 IconKey 缓存身份)。T-019: 与 live 一致按图标区
        // (iconSize, AppCellView:636 用 iconPointSize) 取 side —— 旧实现用
        // cellSize(整格)导致请求偏大, 与 live 缓存身份/显示尺寸分叉。
        let appPointSize = max(1, Int(geometry.iconSize.rounded(.down)))
        let folderChildPointSize = max(
            1,
            Int(FolderThumbnailMetrics(side: geometry.iconSize).iconSide.rounded(.down))
        )

        // 1. 收集唯一请求(保持页内首次出现顺序): 普通 app 去重; 每个 folder
        //    取 children.prefix(9)(子项数组保持 payload 顺序)。
        var requests: [IconRequest] = []
        var seenAppIDs: Set<AppID> = []
        var folderChildren: [FolderID: [AppID]] = [:]
        for item in items {
            switch item {
            case .app(let appID):
                if seenAppIDs.insert(appID).inserted {
                    requests.append(.app(appID, pointSize: appPointSize))
                }
            case .folder(let folderID):
                let children = Array(folderChildrenPayload[folderID]?.prefix(FolderThumbnailMetrics.maxIconCount) ?? [])
                if !children.isEmpty {
                    folderChildren[folderID] = children
                }
            }
        }
        // 文件夹子项追加进请求计划(按 folderID 排序保证确定性; index 记录槽位)。
        for folderID in folderChildren.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let children = folderChildren[folderID] else { continue }
            for (index, child) in children.enumerated() {
                requests.append(.folderChild(
                    folderID: folderID,
                    appID: child,
                    index: index,
                    pointSize: folderChildPointSize
                ))
            }
        }

        // 2. 有界并发: 每批 ≤8 个在途; 一批全部消耗完再开下一批。
        var results: [CGImage?] = Array(repeating: nil, count: requests.count)
        let strideCount = 8
        var start = 0
        while start < requests.count {
            let end = min(start + strideCount, requests.count)
            await withTaskGroup(of: (Int, CGImage?).self) { group in
                for requestIndex in start..<end {
                    let request = requests[requestIndex]
                    // IconImageProviding 声明为 Sendable → 发送闭包可直接
                    // 强捕获 provider(实现类均 @MainActor final class)。
                    group.addTask {
                        let image = await iconProvider.icon(
                            for: request.appID, pointSize: request.pointSize, scale: scale
                        )
                        return (requestIndex, image)
                    }
                }
                while let (finishedIndex, image) = await group.next() {
                    results[finishedIndex] = image
                }
            }
            start = end
        }

        // 3. 装回 appIcons / folderIcons; availableIDs = 非 nil 图标 ID 并集。
        //    每个 folder 恒有定长数组(长度 = children.prefix(9) 数), 未解析项
        //    为 nil —— 与旧实现一致, 渲染器按位取用, 不改变像素输出。
        var appIcons: [AppID: CGImage] = [:]
        var folderIcons: [FolderID: [CGImage?]] = [:]
        for (folderID, children) in folderChildren {
            folderIcons[folderID] = Array(repeating: nil, count: children.count)
        }
        var availableIDs: Set<AppID> = []
        for (index, request) in requests.enumerated() {
            guard let image = results[index] else { continue }
            availableIDs.insert(request.appID)
            switch request {
            case .app(let appID, _):
                appIcons[appID] = image
            case .folderChild(let folderID, _, let childIndex, _):
                folderIcons[folderID]?[childIndex] = image
            }
        }
        return PageVisualIconSet(appIcons: appIcons, folderIcons: folderIcons, availableIDs: availableIDs)
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

        // 绘制契约(T-018): 上下文为 y-up 设备坐标, 只按 scale 缩放 —— 不再做
        // 全局 y 翻转。逻辑布局保持 y-down(与 flipped 文档一致, slotOrigin/frame/
        // iconFrame/labelRect/childRect 计算不变), 在绘制边界用 quartzRect(topDown:
        // canvasHeight:) 显式转换(y_quartz = canvasHeight − y_down − h)。这样
        // CGContextDrawImage/CTLineDraw 在 y-up 下自然正向, 位图不再镜像。
        let canvasHeight = CGFloat(pixelHeight) / CGFloat(scale)
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

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
                    context: context, canvasHeight: canvasHeight
                )
                drawLabel(
                    text: label, cellFrame: frame, request: request,
                    context: context, canvasHeight: canvasHeight
                )
            case .folder(_, let label, let childIcons):
                drawFolderThumbnail(
                    frame: frame, childIcons: childIcons, request: request,
                    context: context, canvasHeight: canvasHeight
                )
                drawLabel(
                    text: label, cellFrame: frame, request: request,
                    context: context, canvasHeight: canvasHeight
                )
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

    /// y-down 页面坐标 → y-up Quartz 坐标(绘制边界显式转换)。
    ///
    /// y_quartz = canvasHeight − y_down − h。canvasHeight 用逻辑点
    /// (CGFloat(pixelHeight)/CGFloat(scale))保证亚像素精确 —— 与 scale 后的
    /// CTM 同单位, 避免像素/点混用产生 0.5pt 级偏移。
    nonisolated private static func quartzRect(topDown: CGRect, canvasHeight: CGFloat) -> CGRect {
        CGRect(
            x: topDown.minX,
            y: canvasHeight - topDown.maxY,
            width: topDown.width,
            height: topDown.height
        )
    }

    /// 图标(真实位图 aspect-fit)或占位(圆角色块 + 首字母), 与 AppCellView 一致。
    nonisolated private static func drawAppIcon(
        frame: CGRect,
        rgba: (Float, Float, Float, Float),
        letter: String,
        icon: CGImage?,
        request: PageVisualRenderRequest,
        context: CGContext,
        canvasHeight: CGFloat
    ) {
        let iconSide = min(request.iconSize, frame.width)
        let iconFrame = CGRect(
            x: frame.minX + (frame.width - iconSide) / 2,
            y: frame.minY,
            width: iconSide,
            height: iconSide
        )
        // y-down 逻辑布局 → y-up Quartz 绘制边界。
        let quartz = quartzRect(topDown: iconFrame, canvasHeight: canvasHeight)
        if let icon {
            context.draw(icon, in: quartz)
            return
        }
        // 占位: 圆角 16 色块 + 白色首字母(live: iconLayer.cornerRadius = 16, masksToBounds)。
        context.saveGState()
        let clipPath = CGPath(
            roundedRect: quartz, cornerWidth: 16, cornerHeight: 16, transform: nil
        )
        context.addPath(clipPath)
        context.clip()
        context.setFillColor(red: CGFloat(rgba.0), green: CGFloat(rgba.1), blue: CGFloat(rgba.2), alpha: CGFloat(rgba.3))
        context.fill(quartz)
        drawCenteredText(
            letter,
            in: quartz,
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
        context: CGContext,
        canvasHeight: CGFloat
    ) {
        // T-019(R2): 与 live 容器一致按图标区绘制 —— side = min(iconSize,
        // frame.width)(同 drawAppIcon 的口径: iconSide = min(request.iconSize,
        // frame.width))。旧实现用整格 frame(cellSize)导致缩略图偏大(用户可见
        // "滑动时文件夹变大"), 且与 :155 的 metrics(iconSize) 请求口径分叉。
        // 保持顶部锚定 + 水平居中(thumbFrame.x 居中、y = frame.minY)。
        let side = min(request.iconSize, frame.width)
        let thumbFrame = CGRect(
            x: frame.minX + (frame.width - side) / 2,
            y: frame.minY,
            width: side,
            height: side
        )
        // y-down 逻辑布局 → y-up Quartz 绘制边界。
        let quartz = quartzRect(topDown: thumbFrame, canvasHeight: canvasHeight)
        // P0-04: 几何唯一真值来自 FolderThumbnailMetrics(与 live
        // FolderThumbnailView 共用同一公式, 消除两处硬编码漂移)。
        let metrics = FolderThumbnailMetrics(side: side)
        let radius = metrics.radius
        let path = CGPath(
            roundedRect: quartz, cornerWidth: radius, cornerHeight: radius, transform: nil
        )
        context.saveGState()
        context.addPath(path)
        context.clip()

        // 背景: 白 0.08 + 边框白 0.38(1/scale)。
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.08)
        context.fill(quartz)
        context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.38)
        context.setLineWidth(CGFloat(1) / CGFloat(max(1, request.scale)))
        context.addPath(path)
        context.strokePath()

        // sheen: 顶亮 → 底暗(白 0.18 → 0.02)。y-up 下顶部 = maxY、底部 = minY
        // (与旧 y-down 的 minY→maxY 对调, 保持顶亮底暗)。
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
                start: CGPoint(x: quartz.midX, y: quartz.maxY),
                end: CGPoint(x: quartz.midX, y: quartz.minY),
                options: []
            )
        }

        // 子图标网格(≤9): 几何来自 FolderThumbnailMetrics(top-down childFrame);
        // 经 quartzRect 显式转换到 y-up 绘制边界。
        for (index, icon) in childIcons.prefix(FolderThumbnailMetrics.maxIconCount).enumerated() {
            guard let icon else { continue }
            let childFrame = metrics.childFrame(index: index)
            let childRect = CGRect(
                x: thumbFrame.minX + childFrame.minX,
                y: thumbFrame.minY + childFrame.minY,
                width: childFrame.width,
                height: childFrame.height
            )
            let childQuartz = quartzRect(topDown: childRect, canvasHeight: canvasHeight)
            context.saveGState()
            let childPath = CGPath(
                roundedRect: childQuartz,
                cornerWidth: metrics.childRadius,
                cornerHeight: metrics.childRadius,
                transform: nil
            )
            context.addPath(childPath)
            context.clip()
            context.draw(icon, in: childQuartz)
            context.restoreGState()
        }
        context.restoreGState()
    }

    /// 标签(AppCellView: 10pt 系统字体, 白, 黑 0.85 阴影, 尾部截断, 居中)。
    nonisolated private static func drawLabel(
        text: String,
        cellFrame: CGRect,
        request: PageVisualRenderRequest,
        context: CGContext,
        canvasHeight: CGFloat
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
            in: quartzRect(topDown: labelRect, canvasHeight: canvasHeight),
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
        // T-019: 宽度口径 = 默认 typographic bounds(与 CTLineGetTypographicBounds
        // 逐位一致), 与 CTLineCreateTruncatedLine 的截断决策同一测量。旧实现用
        // [.useGlyphPathBounds] —— 字形路径边界不含字距/尾随空白, 宽度偏小,
        // 超宽判断不触发 → 长名不截断, 与 live byTruncatingTail 不一致。
        let bounds = CTLineGetBoundsWithOptions(line, [])
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
        let finalBounds = CTLineGetBoundsWithOptions(targetLine, [])
        let x = rect.midX - finalBounds.width / 2
        let y = rect.midY - finalBounds.height / 2 - finalBounds.minY

        context.saveGState()
        // 阴影(对齐 live: 黑 0.85, blur 4, 下方 1pt)。y-up 上下文下"下方" = −y
        // (旧 y-down 全局翻转上下文用 (0,1), 修复后必须取反)。
        context.setShadow(
            offset: CGSize(width: 0, height: -1), blur: 4,
            color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.85)
        )
        // y-up 上下文绘制 CoreText: textMatrix 保持 identity 即正向
        // (旧 flipped 上下文必须复位 textMatrix 才能勉强正向, 修复后无需)。
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(targetLine, context)
        context.restoreGState()
    }
}
