import AppKit
import LaunchCore

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

    /// 布局模式(搜索模式切换分页为垂直滚动)。
    public var mode: Mode = .paged

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

    private func buildGeometry(usingClipWidth clipWidth: CGFloat) -> GridGeometry {
        let height = collectionView?.bounds.height ?? 0
        return GridGeometry(
            columns: columns,
            rows: rows,
            cellSize: cellSize,
            iconSize: iconSize,
            horizontalSpacing: horizontalSpacing,
            verticalSpacing: verticalSpacing,
            pageWidth: clipWidth > 0 ? clipWidth : (collectionView?.bounds.width ?? 0),
            pageHeight: height
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
            preparePaged(geometry: geometry, bounds: bounds, collectionView: collectionView)
        case .search:
            prepareSearch(geometry: geometry, bounds: bounds, collectionView: collectionView)
        }
    }

    private func preparePaged(
        geometry: GridGeometry,
        bounds: NSRect,
        collectionView: NSCollectionView
    ) {
        let sectionCount = collectionView.numberOfSections
        contentWidth = CGFloat(sectionCount) * geometry.pageWidth
        contentHeight = bounds.height
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
        let size = geometry.searchContentSize(forItemCount: itemCount)
        contentWidth = size.width
        contentHeight = size.height
        lockDocumentWidth(size.width, collectionView: collectionView)

        for index in 0..<itemCount {
            itemFrames[IndexPath(item: index, section: 0)] = geometry.searchFrame(
                forIndex: index, itemCount: itemCount
            )
        }
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
