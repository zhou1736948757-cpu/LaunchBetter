import CoreGraphics
import Foundation

/// 网格几何: 分页网格布局的唯一几何真值(Stage 1, P0)。
///
/// 取代散落在 PagingGridLayout / GridViewController / DragController / AppCellView /
/// IconRepository 各自维护的 pageWidth / itemSize / iconSize / spacing / slotStep 硬编码。
///
/// 坐标系约定:
/// - 文档坐标(document): 水平方向, 页 0 从 0 开始, 页 p 原点在 `pageWidth * p`;
///   垂直方向 y 向下(flipped 文档视图, Stage 1 §11 修复), 网格垂直居中。
/// - 页宽 `pageWidth` = NSClipView 可视宽度(滚动视图 contentView.bounds.width),
///   绝不等同于 `collectionView.bounds.width`(文档视图宽度 = 页宽 × 页数)。
///
/// 纯计算结构: 不依赖 AppKit, 可在不启动启动器的情况下完整测试。
public struct GridGeometry: Sendable, Equatable {
    /// 搜索/文件夹搜索内容的内部边距; chrome gap 由窗口层另行负责。
    public static let defaultSearchPadding: CGFloat = 24

    /// 每页列数。
    public let columns: Int

    /// 每页行数。
    public let rows: Int

    /// 单元格边长(pt): 图标槽位的对齐步进单位。
    public let cellSize: CGFloat

    /// 图标显示边长(pt): 实际渲染图标与 IconKey pointSize 的唯一真值。
    public let iconSize: CGFloat

    /// 水平间距(pt)。
    public let horizontalSpacing: CGFloat

    /// 垂直间距(pt)。
    public let verticalSpacing: CGFloat

    /// 页宽(pt) = NSClipView 可视宽度。
    public let pageWidth: CGFloat

    /// 页高(pt) = 文档视图高度(通常等于可视高度)。
    public let pageHeight: CGFloat

    /// 每页槽位容量。
    public var pageCapacity: Int { columns * rows }

    /// 网格内容总宽(不含页边距)。
    public var gridWidth: CGFloat {
        CGFloat(columns) * cellSize + CGFloat(columns - 1) * horizontalSpacing
    }

    /// 网格内容总高(不含页边距)。
    public var gridHeight: CGFloat {
        CGFloat(rows) * cellSize + CGFloat(rows - 1) * verticalSpacing
    }

    /// 顶部保留区(pt): 搜索框占用(安全区 + 搜索框实际高度 + 间距), 网格不得顶出。
    /// 由调用方(窗口层)基于真实布局计算传入, 非魔法数。
    public let topInset: CGFloat

    /// 底部保留区(pt): 页点 + 底部安全间距, 网格不得压住页点。
    public let bottomInset: CGFloat

    /// 网格可用的内容区域(文档坐标, y-down)。
    /// `topInset`/`bottomInset` 都从同一个文档顶部/底部语义测量, 避免
    /// 在调用方重新解释上下边界。
    public var availableContentRect: CGRect {
        CGRect(
            x: 0,
            y: topInset,
            width: pageWidth,
            height: max(0, pageHeight - topInset - bottomInset)
        )
    }

    /// 网格原点: 页内网格起点(页 0 文档坐标)。
    /// 网格在 `availableContentRect` 内垂直居中(顶部已保留给搜索框,
    /// 底部已保留给页点); 网格超高时保持顶部安全区, 底部允许溢出。
    public var gridOrigin: CGPoint {
        let available = availableContentRect
        let minY = available.minY
        let maxY = available.maxY - gridHeight
        let centeredY = available.minY + (available.height - gridHeight) / 2
        let y: CGFloat
        if maxY < minY {
            // 网格放不下时优先保护顶部搜索区, 底部再允许溢出。
            y = minY
        } else {
            y = min(max(centeredY, minY), maxY)
        }
        return CGPoint(
            x: (pageWidth - gridWidth) / 2,
            y: y
        )
    }

    public init(
        columns: Int,
        rows: Int,
        cellSize: CGFloat,
        iconSize: CGFloat,
        horizontalSpacing: CGFloat,
        verticalSpacing: CGFloat,
        pageWidth: CGFloat,
        pageHeight: CGFloat,
        topInset: CGFloat = 160,
        bottomInset: CGFloat = 40
    ) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.cellSize = cellSize
        self.iconSize = iconSize
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
        self.pageWidth = pageWidth
        self.pageHeight = pageHeight
        self.topInset = max(0, topInset)
        self.bottomInset = max(0, bottomInset)
    }

    /// 页 p 的文档坐标原点 x。
    public func pageOriginX(page: Int) -> CGFloat {
        CGFloat(page) * pageWidth
    }

    /// 页 p 的文档坐标原点。
    public func pageOrigin(page: Int) -> CGPoint {
        CGPoint(x: pageOriginX(page: page), y: 0)
    }

    /// 吸附目标页(v0.1.4 跟手吸附): 当前水平偏移相对当前页,
    /// 超过 threshold × 页宽则翻向该方向, 否则弹回当前页。结果钳制在页数内。
    public func snapTarget(
        currentOffsetX: CGFloat,
        currentPage: Int,
        pageCount: Int,
        threshold: CGFloat = 0.35
    ) -> Int {
        guard pageWidth > 0 else { return min(max(0, currentPage), max(0, pageCount - 1)) }
        let currentX = CGFloat(currentPage) * pageWidth
        let offset = currentOffsetX - currentX
        var target: Int
        if offset > pageWidth * threshold {
            target = currentPage + 1
        } else if offset < -pageWidth * threshold {
            target = currentPage - 1
        } else {
            target = currentPage
        }
        return min(max(0, target), max(0, pageCount - 1))
    }

    /// 页 p 的文档坐标可视矩形。
    public func pageRect(page: Int) -> CGRect {
        CGRect(x: pageOriginX(page: page), y: 0, width: pageWidth, height: pageHeight)
    }

    /// 页内槽位原点(相对页原点, 垂直居中)。
    public func slotOrigin(slot: Int) -> CGPoint {
        let col = slot % columns
        let row = slot / columns
        return CGPoint(
            x: gridOrigin.x + CGFloat(col) * (cellSize + horizontalSpacing),
            y: gridOrigin.y + CGFloat(row) * (cellSize + verticalSpacing)
        )
    }

    /// 槽位 frame(文档坐标)。
    public func frame(forSlot slot: Int, in page: Int) -> CGRect {
        let origin = slotOrigin(slot: slot)
        return CGRect(
            x: pageOriginX(page: page) + origin.x,
            y: origin.y,
            width: cellSize,
            height: cellSize
        )
    }

    /// 扁平索引 → (页, 槽位)。
    public func pageAndSlot(forFlatIndex index: Int) -> (page: Int, slot: Int) {
        (index / pageCapacity, index % pageCapacity)
    }

    /// 扁平索引 → frame(文档坐标)。
    public func frame(forFlatIndex index: Int) -> CGRect {
        let (page, slot) = pageAndSlot(forFlatIndex: index)
        return frame(forSlot: slot, in: page)
    }

    /// 文档坐标点 → 页(向下取整, 不越界钳制)。
    public func page(forDocumentPoint p: CGPoint) -> Int {
        Int(floor(p.x / pageWidth))
    }

    /// 文档坐标点 → 页(钳制到页数-1 以内)。
    public func page(forDocumentPoint p: CGPoint, pageCount: Int) -> Int {
        min(max(0, page(forDocumentPoint: p)), max(0, pageCount - 1))
    }

    /// 文档坐标点 → 页内槽位(钳制到网格内, 永不越界)。
    public func slot(forDocumentPoint p: CGPoint) -> Int {
        let rawPage = page(forDocumentPoint: p)
        return slot(inPageLocal: CGPoint(x: p.x - pageOriginX(page: rawPage), y: p.y))
    }

    /// 文档坐标点 → 页 + 页内槽位(钳制, 拖拽 hit testing 唯一入口)。
    /// 点先钳制进目标页矩形(水平), 再计算槽位(跨页边界/页面外点稳定落位)。
    public func pageAndSlot(forDocumentPoint p: CGPoint, pageCount: Int) -> (page: Int, slot: Int) {
        let page = page(forDocumentPoint: p, pageCount: pageCount)
        let minX = pageOriginX(page: page)
        let pageLocalX = min(max(p.x - minX, 0), pageWidth)
        return (page, slot(inPageLocal: CGPoint(x: pageLocalX, y: p.y)))
    }

    /// 页内局部坐标 → 槽位(点已位于某页内, 不再推算页)。
    private func slot(inPageLocal q: CGPoint) -> Int {
        let origin = gridOrigin
        let stepX = cellSize + horizontalSpacing
        let stepY = cellSize + verticalSpacing
        let col = Int(floor((q.x - origin.x) / stepX))
        let row = Int(floor((q.y - origin.y) / stepY))
        let clampedCol = min(max(0, col), columns - 1)
        let clampedRow = min(max(0, row), rows - 1)
        return clampedRow * columns + clampedCol
    }

    /// 搜索模式: 给定结果数量所需行数(列主序填充)。
    public func searchRowsNeeded(forItemCount count: Int) -> Int {
        guard count > 0, columns > 0 else { return 0 }
        return (count + columns - 1) / columns
    }

    /// 搜索模式文档尺寸: 内容不足一页时保持一页高度, 溢出时按行数增长。
    /// 顶部保留区只在文档顶部应用一次; 后续滚动行不重复占用。
    public func searchContentSize(
        forItemCount count: Int,
        padding: CGFloat = GridGeometry.defaultSearchPadding
    ) -> CGSize {
        let rowsNeeded = searchRowsNeeded(forItemCount: count)
        guard rowsNeeded > 0 else {
            return CGSize(width: pageWidth, height: pageHeight)
        }
        let contentHeight = topInset
            + CGFloat(rowsNeeded) * cellSize
            + CGFloat(max(0, rowsNeeded - 1)) * verticalSpacing
            + padding * 2
        return CGSize(
            width: pageWidth,
            height: max(pageHeight, contentHeight)
        )
    }

    /// 搜索模式槽位 frame(文档坐标, y-down): 第 0 行从可用内容区顶部开始。
    public func searchFrame(
        forIndex index: Int,
        itemCount: Int,
        padding: CGFloat = GridGeometry.defaultSearchPadding
    ) -> CGRect {
        let col = index % columns
        let row = index / columns
        let stepX = cellSize + horizontalSpacing
        let stepY = cellSize + verticalSpacing
        let x = (pageWidth - gridWidth) / 2 + CGFloat(col) * stepX
        let y = availableContentRect.minY + padding + CGFloat(row) * stepY
        return CGRect(x: x, y: y, width: cellSize, height: cellSize)
    }
}
