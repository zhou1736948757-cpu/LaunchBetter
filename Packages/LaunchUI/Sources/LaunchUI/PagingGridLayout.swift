import AppKit
import LaunchCore

/// 分页网格的纯高度适配计算。
///
/// `enabled == false` 时保留传入的原始 metrics，供搜索模式使用；分页模式
/// 才会把可伸缩的图标/间距压进可用高度。极端高度下允许图标低于 AppCellView
/// 的 16pt 请求下限，以保证几何本身不会越过可用区域。
internal struct PagedGridFitMetrics: Equatable {
    let rows: Int
    let cellSize: CGFloat
    let iconSize: CGFloat
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat
    let scale: CGFloat
    let fixedChrome: CGFloat

    var gridHeight: CGFloat {
        CGFloat(rows) * cellSize
            + CGFloat(max(0, rows - 1)) * verticalSpacing
    }

    init(
        rows: Int,
        cellSize: CGFloat,
        iconSize: CGFloat,
        horizontalSpacing: CGFloat,
        verticalSpacing: CGFloat,
        availableHeight: CGFloat,
        enabled: Bool = true
    ) {
        let safeRows = max(1, rows)
        self.rows = safeRows

        guard enabled else {
            self.cellSize = cellSize
            self.iconSize = iconSize
            self.horizontalSpacing = horizontalSpacing
            self.verticalSpacing = verticalSpacing
            self.scale = 1
            self.fixedChrome = max(0, cellSize - iconSize)
            return
        }

        let safeHeight = Self.finiteNonNegative(availableHeight)
        let safeCellSize = Self.finiteNonNegative(cellSize)
        let safeIconSize = Self.finiteNonNegative(iconSize)
        let safeHorizontalSpacing = Self.finiteNonNegative(horizontalSpacing)
        let safeVerticalSpacing = Self.finiteNonNegative(verticalSpacing)
        let rowCount = CGFloat(safeRows)
        let gapCount = CGFloat(max(0, safeRows - 1))

        let requestedFixedChrome = Self.finiteNonNegative(safeCellSize - safeIconSize)
        let requestedScalable = Self.safeAdd(
            Self.safeMultiply(rowCount, safeIconSize),
            Self.safeMultiply(gapCount, safeVerticalSpacing)
        )
        let fixedChromeHeight = Self.safeMultiply(rowCount, requestedFixedChrome)
        let scaleNumerator = max(0, safeHeight - fixedChromeHeight)
        let requestedScale = requestedScalable > 0
            ? scaleNumerator / requestedScalable
            : 1
        let scale = Self.finiteNonNegative(min(1, max(0, requestedScale)))

        var effectiveFixedChrome = requestedFixedChrome
        var effectiveIconSize = max(16, Self.safeMultiply(safeIconSize, scale))

        // 首先按 requested scale 压缩 chrome；在仍有至少 16pt/行时，优先
        // 保留图标下限，并把剩余预算给 chrome。
        let minimumIconHeight = Self.safeMultiply(rowCount, 16)
        let minimumRequestedHeight = Self.safeAdd(fixedChromeHeight, minimumIconHeight)
        if safeHeight < minimumRequestedHeight {
            if safeHeight >= minimumIconHeight {
                let chromeBudget = max(0, (safeHeight - minimumIconHeight) / rowCount)
                effectiveFixedChrome = min(
                    Self.safeMultiply(requestedFixedChrome, scale),
                    chromeBudget
                )
                effectiveIconSize = 16
            } else {
                // 连每行 16pt 都放不下时，几何优先于 pointSize 下限，
                // 让图标也按每行可用空间收缩，避免最终 gridHeight 溢出。
                effectiveFixedChrome = 0
                effectiveIconSize = safeHeight / rowCount
            }
        }

        let maxCellSize = safeHeight / rowCount
        var effectiveCellSize = Self.safeAdd(effectiveFixedChrome, effectiveIconSize)
        if effectiveCellSize > maxCellSize {
            effectiveFixedChrome = min(effectiveFixedChrome, maxCellSize)
            effectiveIconSize = max(0, maxCellSize - effectiveFixedChrome)
            effectiveCellSize = Self.safeAdd(effectiveFixedChrome, effectiveIconSize)
        }

        var effectiveVerticalSpacing: CGFloat = 0
        if safeRows > 1 {
            let remainingHeight = max(0, safeHeight - Self.safeMultiply(rowCount, effectiveCellSize))
            effectiveVerticalSpacing = max(
                0,
                min(safeVerticalSpacing, remainingHeight / gapCount)
            )
        }

        // 防止浮点舍入或极端输入把最后一行推过可用区域。
        var finalGridHeight = Self.safeAdd(
            Self.safeMultiply(rowCount, effectiveCellSize),
            Self.safeMultiply(gapCount, effectiveVerticalSpacing)
        )
        if finalGridHeight > safeHeight {
            effectiveVerticalSpacing = 0
            finalGridHeight = Self.safeMultiply(rowCount, effectiveCellSize)
            if finalGridHeight > safeHeight {
                effectiveCellSize = maxCellSize
                effectiveFixedChrome = min(effectiveFixedChrome, effectiveCellSize)
                effectiveIconSize = max(0, effectiveCellSize - effectiveFixedChrome)
            }
        }

        self.cellSize = Self.finiteNonNegative(effectiveCellSize)
        self.iconSize = Self.finiteNonNegative(effectiveIconSize)
        self.horizontalSpacing = Self.finiteNonNegative(
            Self.safeMultiply(safeHorizontalSpacing, scale)
        )
        self.verticalSpacing = Self.finiteNonNegative(effectiveVerticalSpacing)
        self.scale = scale
        self.fixedChrome = Self.finiteNonNegative(effectiveFixedChrome)
    }

    private static func finiteNonNegative(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }

    private static func safeMultiply(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
        guard lhs > 0, rhs > 0 else { return 0 }
        let maxValue = CGFloat.greatestFiniteMagnitude
        guard lhs <= maxValue / rhs else { return maxValue }
        return lhs * rhs
    }

    private static func safeAdd(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
        let maxValue = CGFloat.greatestFiniteMagnitude
        guard lhs <= maxValue - rhs else { return maxValue }
        return lhs + rhs
    }
}

/// 分页网格布局: 每页 = 可视页宽, 页内按列×行排布。
///
/// 几何唯一真值 = GridGeometry(Stage 1, P0): 本布局只把
/// columns/rows/cellSize/iconSize/spacing + 实时 clip 宽喂给 GridGeometry,
/// 不再自行维护一份 pageWidth/itemSize 数学。
///
/// 两种模式:
/// - `.paged`: 每 section = 一页, 横向分页(默认)
/// - `.search`: 单 section 垂直可滚结果网格(结果可超过一页容量)
public final class PagingGridLayout: NSCollectionViewLayout {
    public enum Mode: Equatable {
        case paged
        case search
    }

    public private(set) var columns: Int
    public private(set) var rows: Int
    public private(set) var cellSize: CGFloat
    public private(set) var iconSize: CGFloat
    public private(set) var horizontalSpacing: CGFloat
    public private(set) var verticalSpacing: CGFloat

    /// 顶部保留区(pt): 搜索框占用(由窗口层计算, 网格不得顶出)。
    public private(set) var topInset: CGFloat = 160

    /// 底部保留区(pt): 页点占用(由窗口层计算, 网格不得压住)。
    public private(set) var bottomInset: CGFloat = 40

    /// 布局模式(搜索模式切换分页为垂直滚动)。
    public var mode: Mode = .paged

    /// 搜索拖拽时保留末尾虚拟槽位所需的文档空间。
    /// 默认关闭，普通搜索结果仍只占实际结果所需高度；文件夹拖拽会临时开启。
    var reservesSearchTrailingSlot = false {
        didSet {
            guard oldValue != reservesSearchTrailingSlot else { return }
            invalidateLayout()
        }
    }

    private var itemFrames: [IndexPath: CGRect] = [:]
    private var contentWidth: CGFloat = 0
    private var contentHeight: CGFloat = 0

    /// 诊断: prepare() 调用计数(布局失效测量, Stage 1 §31)。
    public private(set) var prepareCount = 0

    /// 诊断: 当前 item 帧数。
    public var itemFrameCount: Int { itemFrames.count }

    /// 诊断: layoutAttributesForElements 查询计数(§56 测量)。
    public private(set) var attributeQueryCount = 0


    /// 最近一次 prepare 使用的几何(供 GridViewController/DragController 同步读取)。
    public private(set) var currentGeometry: GridGeometry?

    /// 上次 prepare 时的可视尺寸(失效判定基准, Stage 1 §31)。
    private var lastVisibleWidth: CGFloat = 0
    private var lastVisibleHeight: CGFloat = 0

    public init(
        columns: Int,
        rows: Int,
        cellSize: CGFloat,
        iconSize: CGFloat,
        horizontalSpacing: CGFloat,
        verticalSpacing: CGFloat
    ) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.cellSize = cellSize
        self.iconSize = iconSize
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
        super.init()
    }

    /// 结构参数更新(Settings 变更): 重建几何, 后续 prepare 使用新值。
    func update(
        columns: Int,
        rows: Int,
        iconSize: CGFloat,
        cellSize: CGFloat,
        horizontalSpacing: CGFloat,
        verticalSpacing: CGFloat
    ) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.iconSize = iconSize
        self.cellSize = cellSize
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
        invalidateLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var collectionViewContentSize: NSSize {
        NSSize(width: contentWidth, height: contentHeight)
    }

    /// 当前(未触发 prepare 的)几何: 用最新参数 + 实时 clip 宽推算。
    /// 供拖拽 hit testing 在 prepare 未执行时也能拿到一致几何。
    var liveGeometry: GridGeometry {
        buildGeometry(usingClipWidth: visibleClipWidth)
    }

    private var visibleClipWidth: CGFloat {
        guard let collectionView else { return 0 }
        return collectionView.enclosingScrollView?.contentView.bounds.width
            ?? collectionView.bounds.width
    }

    private var visibleClipHeight: CGFloat {
        guard let collectionView else { return 0 }
        return collectionView.enclosingScrollView?.contentView.bounds.height
            ?? collectionView.bounds.height
    }

    /// 更新顶部/底部保留区(搜索框尺寸/页点变化时由窗口层调用)。
    /// 只改变可用内容区, 水平分页/列行布局不变。
    func setContentInsets(top: CGFloat, bottom: CGFloat) {
        let t = max(0, top)
        let b = max(0, bottom)
        guard t != topInset || b != bottomInset else { return }
        topInset = t
        bottomInset = b
        invalidateLayout()
    }

    private func buildGeometry(usingClipWidth clipWidth: CGFloat) -> GridGeometry {
        let height = visibleClipHeight > 0
            ? visibleClipHeight
            : (collectionView?.bounds.height ?? 0)
        let availableHeight = max(0, height - topInset - bottomInset)
        let metrics = PagedGridFitMetrics(
            rows: rows,
            cellSize: cellSize,
            iconSize: iconSize,
            horizontalSpacing: horizontalSpacing,
            verticalSpacing: verticalSpacing,
            availableHeight: availableHeight,
            enabled: mode == .paged
        )
        return GridGeometry(
            columns: columns,
            rows: rows,
            cellSize: metrics.cellSize,
            iconSize: metrics.iconSize,
            horizontalSpacing: metrics.horizontalSpacing,
            verticalSpacing: metrics.verticalSpacing,
            pageWidth: clipWidth > 0 ? clipWidth : (collectionView?.bounds.width ?? 0),
            pageHeight: height,
            topInset: topInset,
            bottomInset: bottomInset
        )
    }

    public override func prepare() {
        super.prepare()
        prepareCount += 1
        guard let collectionView else { return }
        let bounds = collectionView.bounds
        let geometry = buildGeometry(usingClipWidth: visibleClipWidth)
        currentGeometry = geometry
        itemFrames = [:]
        lastVisibleWidth = geometry.pageWidth
        // 失效基准 = clip 可视高(搜索模式文档更高, 不能以文档高为基准, 否则每次滚动都失效)
        lastVisibleHeight = collectionView.enclosingScrollView?.contentView.bounds.height
            ?? bounds.height

        switch mode {
        case .paged:
            preparePaged(geometry: geometry, collectionView: collectionView)
        case .search:
            prepareSearch(geometry: geometry, bounds: bounds, collectionView: collectionView)
        }
    }

    private func preparePaged(
        geometry: GridGeometry,
        collectionView: NSCollectionView
    ) {
        let sectionCount = collectionView.numberOfSections
        contentWidth = CGFloat(sectionCount) * geometry.pageWidth
        // 分页文档高度必须跟随当前 clip viewport, 不能沿用上一次 document bounds
        // (搜索溢出/换屏或 resize 后可能是旧高度)。
        contentHeight = geometry.pageHeight
        guard sectionCount > 0 else { return }

        lockDocumentWidth(contentWidth, collectionView: collectionView)

        for section in 0..<sectionCount {
            let itemCount = collectionView.numberOfItems(inSection: section)
            for index in 0..<itemCount {
                itemFrames[IndexPath(item: index, section: section)] = geometry.frame(
                    forSlot: index, in: section
                )
            }
        }
    }

    private func prepareSearch(
        geometry: GridGeometry,
        bounds: NSRect,
        collectionView: NSCollectionView
    ) {
        let sectionCount = collectionView.numberOfSections
        guard sectionCount > 0 else {
            contentWidth = geometry.pageWidth
            contentHeight = bounds.height
            return
        }
        let itemCount = collectionView.numberOfItems(inSection: 0)
        let size = searchContentSize(forItemCount: itemCount, geometry: geometry)
        contentWidth = size.width
        contentHeight = size.height
        lockDocumentWidth(size.width, collectionView: collectionView)

        for index in 0..<itemCount {
            itemFrames[IndexPath(item: index, section: 0)] = geometry.searchFrame(
                forIndex: index, itemCount: itemCount
            )
        }
    }

    /// Pure search-size calculation, shared by prepare() and geometry tests.
    /// The optional reservation makes a virtual trailing slot a real document
    /// coordinate during folder drag without changing ordinary search mode.
    func searchContentSize(forItemCount count: Int, geometry: GridGeometry) -> CGSize {
        var size = geometry.searchContentSize(forItemCount: count)
        guard reservesSearchTrailingSlot, count > 0 else { return size }

        let trailing = geometry.searchFrame(
            forIndex: count,
            itemCount: count,
            padding: FolderDropGeometry.searchPadding
        )
        size.height = max(
            size.height,
            trailing.maxY + FolderDropGeometry.searchPadding
        )
        return size
    }

    private func lockDocumentWidth(_ width: CGFloat, collectionView: NSCollectionView) {
        if let paged = collectionView as? ClickableCollectionView {
            paged.lockDocumentWidth(width)
        } else if collectionView.frame.width != width {
            collectionView.frame.size.width = width
        }
    }

    public override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        attributeQueryCount += 1
        return itemFrames.compactMap { indexPath, frame in
            guard frame.intersects(rect) else { return nil }
            let attrs = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
            attrs.frame = frame
            return attrs
        }
    }

    public override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard let frame = itemFrames[indexPath] else { return nil }
        let attrs = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        attrs.frame = frame
        return attrs
    }

    /// 仅当可视尺寸(页宽/页高)变化时才重算布局。
    /// 滚动/翻页动画只改变文档 bounds.origin(帧是文档坐标静态值)→ 不失效;
    /// AppKit 每次滚动还会"提议"把文档收成 clip 宽, 一律忽略(宽度锁在 ClickableCollectionView)。
    public override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        guard let collectionView else { return false }
        let clipWidth = collectionView.enclosingScrollView?.contentView.bounds.width
            ?? newBounds.width
        let clipHeight = collectionView.enclosingScrollView?.contentView.bounds.height
            ?? newBounds.height
        let invalidate = clipWidth != lastVisibleWidth || clipHeight != lastVisibleHeight
        lastVisibleWidth = clipWidth
        lastVisibleHeight = clipHeight
        return invalidate
    }
}
