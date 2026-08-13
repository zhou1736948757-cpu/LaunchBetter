import AppKit
import LaunchCore

/// App Library 卡片网格的纯几何度量(确定性, 可测试)。
///
/// 输入 available width / spacing / min / preferred / max card width, 输出
/// 列数与 card width。card width 有界(不随屏幕宽度无限拉伸); 2-4 列在常见
/// 桌面宽度(800/1200/1600pt)成立; 极窄宽度仍返回 finite/non-negative 值。
public struct AppLibraryLayoutMetrics: Equatable, Sendable {
    /// 卡间/行间默认间距。
    public static let defaultSpacing: CGFloat = 16
    /// 行间默认间距。
    public static let defaultRowSpacing: CGFloat = 16
    /// 网格模式内容区默认水平 edge inset(两侧各 24, 卡片不贴边)。
    public static let defaultHorizontalInset: CGFloat = 24
    /// 内容区默认垂直 inset(顶部留白 20; 底部默认小 padding 20)。
    /// 顶部保留带在宿主窗口层 chrome(搜索框)下由 `setContentInsets` 覆盖。
    public static let defaultContentInsets = NSEdgeInsets(top: 20, left: 0, bottom: 20, right: 0)
    /// card width 下界。
    public static let minCardWidth: CGFloat = 280
    /// 目标 card width(决定列数)。
    public static let preferredCardWidth: CGFloat = 360
    /// card width 上界。
    public static let maxCardWidth: CGFloat = 430
    /// 列数上界。
    public static let maxColumnCount = 4

    public let columnCount: Int
    public let cardWidth: CGFloat
    /// 实际内容总宽(用于水平居中; 恒 ≤ available width)。
    public let contentWidth: CGFloat

    public init(columnCount: Int, cardWidth: CGFloat, contentWidth: CGFloat) {
        self.columnCount = columnCount
        self.cardWidth = cardWidth
        self.contentWidth = contentWidth
    }

    /// 确定性计算列数与 card width。
    ///
    /// 规则:
    /// 1. 水平 edge inset 两侧各 `horizontalInset`, 列数/宽度按 inset 后的有效
    ///    宽度(带区)计算; contentWidth 恒 ≤ 带区宽度, 卡片不越过 edge inset。
    /// 2. 有效宽度 = min(带区, 列数上界*maxWidth + 间距), 保证 card width 有界。
    /// 3. 列数 = 按 preferred width 能放下的列数, 收敛到 [1, columnCap]。
    /// 4. card width = (有效宽度 - 列间距) / 列数, 并收敛到 maxWidth(方形卡片
    ///    在常见桌面宽度下恒 ≤ 430); 单列时收敛到 maxWidth(居中留白)。
    /// 5. 非有限/非正宽度 → (1, 0, 0), 恒 finite 且 non-negative。
    public static func metrics(
        availableWidth: CGFloat,
        spacing: CGFloat = defaultSpacing,
        minCardWidth: CGFloat = Self.minCardWidth,
        preferredCardWidth: CGFloat = Self.preferredCardWidth,
        maxCardWidth: CGFloat = Self.maxCardWidth,
        columnCap: Int = Self.maxColumnCount,
        horizontalInset: CGFloat = defaultHorizontalInset
    ) -> AppLibraryLayoutMetrics {
        guard availableWidth.isFinite, availableWidth > 0 else {
            return AppLibraryLayoutMetrics(columnCount: 1, cardWidth: 0, contentWidth: 0)
        }
        let cap = max(1, columnCap)
        let gap = max(0, spacing)
        let inset = max(0, horizontalInset)
        let minW = max(1, minCardWidth)
        let prefW = max(minW, preferredCardWidth)
        let maxW = max(prefW, maxCardWidth)
        let band = max(0, availableWidth - 2 * inset)
        guard band > 0 else {
            return AppLibraryLayoutMetrics(columnCount: 1, cardWidth: 0, contentWidth: 0)
        }
        let maxContentWidth = CGFloat(cap) * maxW + CGFloat(cap - 1) * gap
        let effective = min(band, maxContentWidth)

        var columns = Int((effective + gap) / (prefW + gap))
        columns = min(max(1, columns), cap)

        var width: CGFloat
        if columns == 1 {
            width = min(effective, maxW)
        } else {
            width = (effective - CGFloat(columns - 1) * gap) / CGFloat(columns)
            if width < minW {
                columns = 1
                width = min(effective, maxW)
            } else {
                width = min(width, maxW)
            }
        }
        let contentWidth = columns == 1
            ? width
            : CGFloat(columns) * width + CGFloat(columns - 1) * gap
        return AppLibraryLayoutMetrics(
            columnCount: columns,
            cardWidth: width,
            contentWidth: min(effective, contentWidth)
        )
    }

    /// card 高度随宽度确定性缩放: 方形(height = width), clamp 到 [240, 430]。
    public static func cardHeight(forWidth width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0 else { return 240 }
        return min(430, max(240, width))
    }

    public static func rowCount(itemCount: Int, columns: Int) -> Int {
        guard itemCount > 0 else { return 0 }
        let cols = max(1, columns)
        return (itemCount + cols - 1) / cols
    }

    /// 垂直内容高度: 按 card 数与 card 高度计算, 顶部/底部 inset 计入 contentSize。
    /// 顶部 inset 即首行偏移, 底部 inset 是 contentSize 预留的保留带(最大滚动时
    /// 最后一行卡片底部 = clip 可视高 - bottomInset)。
    public static func contentHeight(
        rowCount: Int,
        cardHeight: CGFloat,
        rowSpacing: CGFloat = defaultRowSpacing,
        contentInsets: NSEdgeInsets = defaultContentInsets
    ) -> CGFloat {
        guard rowCount > 0 else { return 0 }
        return CGFloat(rowCount) * max(0, cardHeight)
            + CGFloat(max(0, rowCount - 1)) * max(0, rowSpacing)
            + max(0, contentInsets.top) + max(0, contentInsets.bottom)
    }
}

/// App Library 卡片网格/列表的 AppKit 布局(flipped, y-down)。
///
/// 不复用 PagingGridLayout 的 slot/page 数学; 只按卡片身份计数 + 宽度度量
/// 计算 frame, 垂直滚动不重建 model 或图标。grid 模式 2-4 列; list 模式
/// (detail) 单列整宽行。
@MainActor
public final class AppLibraryLayout: NSCollectionViewLayout {
    public enum Mode {
        case grid
        case list
    }

    private let mode: Mode
    private let spacing: CGFloat
    private let rowSpacing: CGFloat
    private var contentInsets: NSEdgeInsets
    private let rowHeight: CGFloat

    private var cachedAttributes: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
    private var contentSize: CGSize = .zero
    private var preparedWidth: CGFloat = -1
    private var preparedItemCount = -1

    public init(
        mode: Mode = .grid,
        spacing: CGFloat = AppLibraryLayoutMetrics.defaultSpacing,
        rowSpacing: CGFloat = AppLibraryLayoutMetrics.defaultRowSpacing,
        contentInsets: NSEdgeInsets = AppLibraryLayoutMetrics.defaultContentInsets,
        rowHeight: CGFloat = 44
    ) {
        self.mode = mode
        self.spacing = max(0, spacing)
        self.rowSpacing = max(0, rowSpacing)
        self.contentInsets = NSEdgeInsets(
            top: max(0, contentInsets.top),
            left: max(0, contentInsets.left),
            bottom: max(0, contentInsets.bottom),
            right: max(0, contentInsets.right)
        )
        self.rowHeight = max(8, rowHeight)
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 运行时更新顶部/底部保留带(宿主窗口 chrome 变化后调用)。
    /// 重置 prepare 缓存强制重建 frame 与 contentSize; 无变化时 no-op。
    public func setContentInsets(top: CGFloat, bottom: CGFloat) {
        let t = max(0, top)
        let b = max(0, bottom)
        guard t != contentInsets.top || b != contentInsets.bottom else { return }
        contentInsets = NSEdgeInsets(
            top: t,
            left: contentInsets.left,
            bottom: b,
            right: contentInsets.right
        )
        preparedWidth = -1
        preparedItemCount = -1
        invalidateLayout()
    }

    public override var collectionViewContentSize: CGSize { contentSize }

    public override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        abs(newBounds.width - preparedWidth) > 0.5
    }

    public override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let width = collectionView.bounds.width
        let count = collectionView.numberOfItems(inSection: 0)
        guard width.isFinite, width >= 0 else { return }
        guard count != preparedItemCount || abs(width - preparedWidth) > 0.5 else { return }
        buildAttributes(width: width, count: count)
    }

    public override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        cachedAttributes.values.filter { $0.frame.intersects(rect) }
    }

    public override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        cachedAttributes[indexPath]
    }

    private func buildAttributes(width: CGFloat, count: Int) {
        let columns: Int
        let cardWidth: CGFloat
        let rowHeight: CGFloat
        let contentWidth: CGFloat
        let horizontalInset: CGFloat

        if mode == .grid {
            let inset = AppLibraryLayoutMetrics.defaultHorizontalInset
            let metrics = AppLibraryLayoutMetrics.metrics(
                availableWidth: width,
                horizontalInset: inset
            )
            columns = metrics.columnCount
            cardWidth = metrics.cardWidth
            rowHeight = AppLibraryLayoutMetrics.cardHeight(forWidth: cardWidth)
            contentWidth = metrics.contentWidth
            // 网格内容在 inset 后的带区内水平居中: 两侧留白恒 ≥ edge inset。
            let band = max(0, width - 2 * inset)
            horizontalInset = inset + max(0, (band - contentWidth) / 2)
        } else {
            columns = 1
            cardWidth = max(0, width)
            rowHeight = self.rowHeight
            contentWidth = width
            horizontalInset = 0
        }

        let rows = AppLibraryLayoutMetrics.rowCount(itemCount: count, columns: columns)
        let height = AppLibraryLayoutMetrics.contentHeight(
            rowCount: rows,
            cardHeight: rowHeight,
            rowSpacing: rowSpacing,
            contentInsets: contentInsets
        )

        var attributes: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
        attributes.reserveCapacity(count)
        for index in 0..<count {
            let row = index / columns
            let column = index % columns
            let frame = CGRect(
                x: horizontalInset + CGFloat(column) * (cardWidth + spacing),
                y: contentInsets.top + CGFloat(row) * (rowHeight + rowSpacing),
                width: cardWidth,
                height: rowHeight
            )
            let itemAttributes = NSCollectionViewLayoutAttributes(
                forItemWith: IndexPath(item: index, section: 0)
            )
            itemAttributes.frame = frame
            attributes[IndexPath(item: index, section: 0)] = itemAttributes
        }

        cachedAttributes = attributes
        contentSize = CGSize(width: max(0, width), height: height)
        preparedWidth = width
        preparedItemCount = count
    }
}

/// App Library 集合视图(flipped, y-down): 与 `AppLibraryLayout` 的
/// y-down frame 数学一致, 垂直滚动时 bounds.origin 同步正确。
@MainActor
final class LibraryCollectionView: NSCollectionView {
    override var isFlipped: Bool { true }
}
