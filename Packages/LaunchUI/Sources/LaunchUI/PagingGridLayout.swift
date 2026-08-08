import AppKit
import LaunchCore

/// 分页网格布局: 每页 = collection view 宽度,页内按列×行排布。
///
/// 基于 Phase 1B spike 验证的布局(测量: 翻页/重排无帧时间尖峰)。
/// 布局只做几何计算,不持有任何数据模型。
public final class PagingGridLayout: NSCollectionViewLayout {
    public let columns: Int
    public let rows: Int
    public let itemSize: CGFloat
    public let spacing: CGFloat

    private var itemFrames: [IndexPath: CGRect] = [:]
    private var contentWidth: CGFloat = 0
    private var contentHeight: CGFloat = 0

    public init(columns: Int, rows: Int, itemSize: CGFloat, spacing: CGFloat) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.itemSize = itemSize
        self.spacing = spacing
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var collectionViewContentSize: NSSize {
        NSSize(width: contentWidth, height: contentHeight)
    }

    public override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let bounds = collectionView.bounds
        contentHeight = bounds.height
        itemFrames = [:]

        let sectionCount = collectionView.numberOfSections
        // 页宽 = clip 可视宽度(不是文档 frame 宽度! 否则与 frame 断言互相放大)
        let pageWidth = collectionView.enclosingScrollView?.contentView.bounds.width
            ?? bounds.width
        contentWidth = CGFloat(sectionCount) * pageWidth
        guard sectionCount > 0 else { return }

        // 关键: 文档视图宽度必须等于内容宽度, 否则滚动范围只有一页。
        // 通过 ClickableCollectionView 的宽度锁定执行(防 NSClipView 滚动约束)。
        if let paged = collectionView as? ClickableCollectionView {
            paged.lockDocumentWidth(contentWidth)
        } else if collectionView.frame.width != contentWidth {
            collectionView.frame.size.width = contentWidth
        }

        let gridWidth = CGFloat(columns) * itemSize + CGFloat(columns - 1) * spacing
        let gridHeight = CGFloat(rows) * itemSize + CGFloat(rows - 1) * spacing
        let startX = (pageWidth - gridWidth) / 2
        let startY = (bounds.height - gridHeight) / 2

        for section in 0..<sectionCount {
            let itemCount = collectionView.numberOfItems(inSection: section)
            for index in 0..<itemCount {
                let col = index % columns
                let row = index / columns
                let x = CGFloat(section) * pageWidth + startX + CGFloat(col) * (itemSize + spacing)
                let y = startY + CGFloat(row) * (itemSize + spacing)
                itemFrames[IndexPath(item: index, section: section)] = CGRect(
                    x: x, y: y, width: itemSize, height: itemSize
                )
            }
        }
    }

    public override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        itemFrames.compactMap { indexPath, frame in
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

    public override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        true
    }
}
