import AppKit
import LaunchCore
import Testing
@testable import LaunchUI

@Suite("App Library layout", .serialized)
@MainActor
struct AppLibraryLayoutTests {

    // MARK: - Metrics: 列数与 card width 确定性

    @Test("metrics: 800pt width yields 2 bounded columns inside 30pt edge insets")
    func metricsAt800() {
        let metrics = AppLibraryLayoutMetrics.metrics(availableWidth: 800)
        #expect(metrics.columnCount == 2)
        #expect(metrics.cardWidth == 362)
        #expect(metrics.contentWidth == 740)
        #expect(metrics.contentWidth <= 800 - 2 * AppLibraryLayoutMetrics.defaultHorizontalInset)
        #expect(metrics.cardWidth <= AppLibraryLayoutMetrics.maxCardWidth)
        #expect(metrics.cardWidth >= AppLibraryLayoutMetrics.minCardWidth)
    }

    @Test("metrics: 1200pt width yields 3 bounded columns")
    func metricsAt1200() {
        let metrics = AppLibraryLayoutMetrics.metrics(availableWidth: 1200)
        #expect(metrics.columnCount == 3)
        #expect(almostEqual(metrics.cardWidth, 369.333, tolerance: 0.01))
        #expect(almostEqual(metrics.contentWidth, 1140, tolerance: 0.01))
        #expect(metrics.contentWidth <= 1200 - 2 * AppLibraryLayoutMetrics.defaultHorizontalInset)
    }

    @Test("metrics: 1600pt width yields 4 bounded columns capped at max width")
    func metricsAt1600() {
        let metrics = AppLibraryLayoutMetrics.metrics(availableWidth: 1600)
        #expect(metrics.columnCount == 4)
        #expect(metrics.cardWidth == AppLibraryLayoutMetrics.maxCardWidth)
        #expect(metrics.contentWidth == 1528)
        #expect(metrics.contentWidth <= 1600 - 2 * AppLibraryLayoutMetrics.defaultHorizontalInset)
    }

    @Test("metrics: 2400pt width caps at 4 columns with bounded cards")
    func metricsAt2400() {
        let metrics = AppLibraryLayoutMetrics.metrics(availableWidth: 2400)
        #expect(metrics.columnCount == 4)
        #expect(metrics.cardWidth == AppLibraryLayoutMetrics.maxCardWidth)
        #expect(
            metrics.contentWidth
                == 4 * AppLibraryLayoutMetrics.maxCardWidth + 3 * AppLibraryLayoutMetrics.defaultSpacing
        )
    }

    @Test("metrics: 1470pt width yields 4 columns with square bounded cards")
    func metricsAt1470() {
        let metrics = AppLibraryLayoutMetrics.metrics(availableWidth: 1470)
        #expect(metrics.columnCount == 4)
        #expect(metrics.cardWidth == 340.5)
        #expect(metrics.contentWidth == 1410)
        #expect(metrics.contentWidth <= 1470 - 2 * AppLibraryLayoutMetrics.defaultHorizontalInset)
        #expect(metrics.cardWidth <= AppLibraryLayoutMetrics.maxCardWidth)
        let height = AppLibraryLayoutMetrics.cardHeight(forWidth: metrics.cardWidth)
        #expect(height == metrics.cardWidth)
    }

    @Test("metrics: extreme narrow widths stay finite and non-negative with 1 column")
    func metricsExtremeNarrow() {
        for width: CGFloat in [-10, 0, 100] {
            let metrics = AppLibraryLayoutMetrics.metrics(availableWidth: width)
            #expect(metrics.cardWidth.isFinite)
            #expect(metrics.cardWidth >= 0)
            #expect(metrics.contentWidth.isFinite)
            #expect(metrics.contentWidth >= 0)
            #expect(metrics.columnCount == 1)
        }
        let nan = AppLibraryLayoutMetrics.metrics(availableWidth: .nan)
        #expect(nan.columnCount == 1)
        #expect(nan.cardWidth == 0)
        let infinity = AppLibraryLayoutMetrics.metrics(availableWidth: .infinity)
        #expect(infinity.columnCount == 1)
        #expect(infinity.cardWidth == 0)
    }

    @Test("metrics: column cap clamps wide widths")
    func metricsColumnCapClamps() {
        let metrics = AppLibraryLayoutMetrics.metrics(availableWidth: 2400, columnCap: 2)
        #expect(metrics.columnCount == 2)
    }

    @Test("card height is square with bounded clamp and content height is deterministic")
    func cardAndContentHeights() {
        #expect(AppLibraryLayoutMetrics.cardHeight(forWidth: .nan) == 240)
        #expect(AppLibraryLayoutMetrics.cardHeight(forWidth: 0) == 240)
        #expect(AppLibraryLayoutMetrics.cardHeight(forWidth: 430) == 430)
        #expect(AppLibraryLayoutMetrics.cardHeight(forWidth: 300) == 300)
        #expect(AppLibraryLayoutMetrics.cardHeight(forWidth: 280) == 280)
        #expect(AppLibraryLayoutMetrics.cardHeight(forWidth: 240) == 240)
        #expect(AppLibraryLayoutMetrics.cardHeight(forWidth: 100) == 240)
        #expect(AppLibraryLayoutMetrics.cardHeight(forWidth: 500) == 430)
        #expect(AppLibraryLayoutMetrics.rowCount(itemCount: 0, columns: 4) == 0)
        #expect(AppLibraryLayoutMetrics.rowCount(itemCount: 12, columns: 4) == 3)
        #expect(AppLibraryLayoutMetrics.rowCount(itemCount: 13, columns: 4) == 4)
        let insetHeight = AppLibraryLayoutMetrics.contentHeight(
            rowCount: 3,
            cardHeight: 200,
            rowSpacing: 16,
            contentInsets: AppLibraryLayoutMetrics.defaultContentInsets
        )
        #expect(insetHeight == 3 * 200 + 2 * 16 + 20 + AppLibraryLayoutMetrics.defaultContentInsets.bottom)
        #expect(AppLibraryLayoutMetrics.contentHeight(rowCount: 0, cardHeight: 200) == 0)
    }

    // MARK: - Layout: grid 模式

    @Test("grid layout: frames follow metrics; height from card count only")
    func gridLayoutFramesFollowMetrics() throws {
        let harness = makeHarness(width: 1200, count: 12, mode: .grid)
        harness.layout.prepare()
        let metrics = AppLibraryLayoutMetrics.metrics(availableWidth: 1200)
        let rowHeight = AppLibraryLayoutMetrics.cardHeight(forWidth: metrics.cardWidth)
        let band = 1200 - 2 * AppLibraryLayoutMetrics.defaultHorizontalInset
        let inset = AppLibraryLayoutMetrics.defaultHorizontalInset + max(0, (band - metrics.contentWidth) / 2)
        let topInset = AppLibraryLayoutMetrics.defaultContentInsets.top

        let first = try #require(
            harness.layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))
        )
        #expect(
            first.frame
                == CGRect(
                    x: inset,
                    y: topInset,
                    width: metrics.cardWidth,
                    height: rowHeight
                )
        )

        let second = try #require(
            harness.layout.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))
        )
        #expect(second.frame.minX == inset + metrics.cardWidth + AppLibraryLayoutMetrics.defaultSpacing)

        let rowStart = try #require(
            harness.layout.layoutAttributesForItem(at: IndexPath(item: metrics.columnCount, section: 0))
        )
        #expect(
            rowStart.frame.minY
                == topInset
                    + rowHeight + AppLibraryLayoutMetrics.defaultRowSpacing
        )

        let rows = (12 + metrics.columnCount - 1) / metrics.columnCount
        let expectedHeight = CGFloat(rows) * rowHeight
            + CGFloat(rows - 1) * AppLibraryLayoutMetrics.defaultRowSpacing
            + topInset + AppLibraryLayoutMetrics.defaultContentInsets.bottom
        #expect(harness.layout.collectionViewContentSize == CGSize(width: 1200, height: expectedHeight))

        let last = try #require(
            harness.layout.layoutAttributesForItem(at: IndexPath(item: 11, section: 0))
        )
        #expect(last.frame.maxY <= harness.layout.collectionViewContentSize.height)
    }

    @Test("grid layout: edge insets and 16pt spacing hold on both axes")
    func gridFramesHonorInsetsAndSpacing() throws {
        let harness = makeHarness(width: 800, count: 8, mode: .grid)
        harness.layout.prepare()
        let metrics = AppLibraryLayoutMetrics.metrics(availableWidth: 800)
        let inset = AppLibraryLayoutMetrics.defaultHorizontalInset

        let first = try #require(
            harness.layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))
        )
        #expect(first.frame.minX == inset)
        #expect(first.frame.width == metrics.cardWidth)

        let second = try #require(
            harness.layout.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))
        )
        #expect(second.frame.minX - first.frame.maxX == AppLibraryLayoutMetrics.defaultSpacing)

        let rowStart = try #require(
            harness.layout.layoutAttributesForItem(at: IndexPath(item: metrics.columnCount, section: 0))
        )
        #expect(rowStart.frame.minY - first.frame.maxY == AppLibraryLayoutMetrics.defaultRowSpacing)

        let last = try #require(
            harness.layout.layoutAttributesForItem(at: IndexPath(item: 7, section: 0))
        )
        #expect(last.frame.maxX <= 800 - inset)
        #expect(last.frame.maxY <= harness.layout.collectionViewContentSize.height)
    }

    @Test("grid layout: first row minY == contentInsets.top, never under top chrome")
    func gridFirstRowSitsAtTopInset() throws {
        let topInset: CGFloat = 96
        let harness = makeHarness(
            width: 1470, count: 12, mode: .grid,
            contentInsets: NSEdgeInsets(top: topInset, left: 0, bottom: 20, right: 0)
        )
        harness.layout.prepare()
        let first = try #require(
            harness.layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))
        )
        #expect(first.frame.minY == topInset)
        #expect(first.frame.maxY <= harness.layout.collectionViewContentSize.height)
        // 默认 insets 下第一行也从 topInset 起步(不压搜索栏/齿轮 chrome)。
        let defaultHarness = makeHarness(width: 1470, count: 12, mode: .grid)
        defaultHarness.layout.prepare()
        let defaultFirst = try #require(
            defaultHarness.layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))
        )
        #expect(defaultFirst.frame.minY == AppLibraryLayoutMetrics.defaultContentInsets.top)
    }

    @Test("grid layout: setContentInsets rebuilds first-row offset and reserves bottom")
    func gridSetContentInsetsRebuilds() throws {
        let harness = makeHarness(width: 1470, count: 12, mode: .grid)
        harness.layout.prepare()
        let before = try #require(
            harness.layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))
        )
        #expect(before.frame.minY == AppLibraryLayoutMetrics.defaultContentInsets.top)

        harness.layout.setContentInsets(top: 110, bottom: 20)
        harness.layout.prepare()
        let after = try #require(
            harness.layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))
        )
        #expect(after.frame.minY == 110)
        #expect(after.frame != before.frame)

        // 无变化调用不破坏已构建 frame。
        harness.layout.setContentInsets(top: 110, bottom: 20)
        let stable = try #require(
            harness.layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))
        )
        #expect(stable.frame == after.frame)
    }

    @Test("grid layout: last row never renders under the reserved bottom band at max scroll")
    func gridLastRowClearsBottomReservedBand() throws {
        // 用户窗口 1470×956; 底部保留 = 默认小 padding(20), 不再有 56 保留带。
        let bottomInset = AppLibraryLayoutMetrics.defaultContentInsets.bottom
        let harness = makeHarness(width: 1470, count: 12, mode: .grid)
        harness.layout.prepare()
        let viewportHeight: CGFloat = 956

        let metrics = AppLibraryLayoutMetrics.metrics(availableWidth: 1470)
        #expect(metrics.columnCount == 4)
        #expect(metrics.cardWidth == 340.5)

        let contentHeight = harness.layout.collectionViewContentSize.height
        // contentSize 必须为底部保留带预留空间。
        let last = try #require(
            harness.layout.layoutAttributesForItem(at: IndexPath(item: 11, section: 0))
        )
        #expect(contentHeight - last.frame.maxY >= bottomInset)

        // 最大滚动位置时最后一行卡片底部 ≤ clip 可视高 - bottomInset。
        let maxScroll = max(0, contentHeight - viewportHeight)
        let lastBottomAtMaxScroll = last.frame.maxY - maxScroll
        #expect(lastBottomAtMaxScroll <= viewportHeight - bottomInset)

        // 卡片为方形。
        #expect(last.frame.width == last.frame.height)
    }

    @Test("grid layout: frames are deterministic for a given width and insets")
    func gridFramesDeterministic() throws {
        let harnessA = makeHarness(width: 1200, count: 12, mode: .grid)
        harnessA.layout.prepare()
        let harnessB = makeHarness(width: 1200, count: 12, mode: .grid)
        harnessB.layout.prepare()
        for index in 0..<12 {
            let a = try #require(
                harnessA.layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))
            )
            let b = try #require(
                harnessB.layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))
            )
            #expect(a.frame == b.frame)
        }
        let first = try #require(
            harnessA.layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))
        )
        // 1200pt: contentWidth == band → 内容从 edge inset 起, 两侧留白恰为 24pt。
        #expect(first.frame.minX == AppLibraryLayoutMetrics.defaultHorizontalInset)
    }

    @Test("grid layout: 500 cards produce finite content height without rebuilding model")
    func gridLayoutHandles500Cards() throws {
        let harness = makeHarness(width: 1200, count: 500, mode: .grid)
        harness.layout.prepare()
        let metrics = AppLibraryLayoutMetrics.metrics(availableWidth: 1200)
        let rowHeight = AppLibraryLayoutMetrics.cardHeight(forWidth: metrics.cardWidth)
        let rows = (500 + metrics.columnCount - 1) / metrics.columnCount
        let expected = CGFloat(rows) * rowHeight
            + CGFloat(rows - 1) * AppLibraryLayoutMetrics.defaultRowSpacing
            + AppLibraryLayoutMetrics.defaultContentInsets.top
            + AppLibraryLayoutMetrics.defaultContentInsets.bottom
        #expect(harness.layout.collectionViewContentSize.height == expected)
        #expect(harness.layout.collectionViewContentSize.height.isFinite)
        let last = try #require(
            harness.layout.layoutAttributesForItem(at: IndexPath(item: 499, section: 0))
        )
        #expect(last.frame.width == metrics.cardWidth)
    }

    @Test("grid layout: width-only bounds change invalidates; vertical scroll does not")
    func invalidationPolicy() {
        let harness = makeHarness(width: 1200, count: 8, mode: .grid)
        harness.layout.prepare()
        #expect(
            harness.layout.shouldInvalidateLayout(
                forBoundsChange: NSRect(x: 0, y: 0, width: 1300, height: 600)
            )
        )
        #expect(
            !harness.layout.shouldInvalidateLayout(
                forBoundsChange: NSRect(x: 0, y: 40, width: 1200, height: 600)
            )
        )
        #expect(
            !harness.layout.shouldInvalidateLayout(
                forBoundsChange: NSRect(x: 0, y: 0, width: 1200, height: 600)
            )
        )
    }

    @Test("grid layout: rebuilds frames after width change without residue")
    func rebuildAfterWidthChange() throws {
        let harness = makeHarness(width: 1200, count: 8, mode: .grid)
        harness.layout.prepare()
        let before = try #require(
            harness.layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))
        )
        harness.collectionView.frame.size.width = 800
        harness.layout.invalidateLayout()
        harness.layout.prepare()
        let after = try #require(
            harness.layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))
        )
        #expect(after.frame.width == AppLibraryLayoutMetrics.metrics(availableWidth: 800).cardWidth)
        #expect(after.frame != before.frame)
    }

    // MARK: - Layout: list(detail)模式

    @Test("list mode: single full-width rows with fixed row height")
    func listModeFrames() throws {
        let harness = makeHarness(
            width: 560, count: 5, mode: .list,
            rowSpacing: 4, contentInsets: NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0),
            rowHeight: 44
        )
        harness.layout.prepare()
        let first = try #require(
            harness.layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))
        )
        #expect(almostEqual(first.frame, CGRect(x: 0, y: 8, width: 560, height: 44)))
        let second = try #require(
            harness.layout.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))
        )
        #expect(almostEqual(second.frame.minY, 8 + 44 + 4))
        #expect(almostEqual(harness.layout.collectionViewContentSize.height, 5 * 44 + 4 * 4 + 16))
    }

    // MARK: - Helpers

    private func almostEqual(_ lhs: CGFloat, _ rhs: CGFloat, tolerance: CGFloat = 0.001) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    private func almostEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 0.001) -> Bool {
        almostEqual(lhs.minX, rhs.minX, tolerance: tolerance)
            && almostEqual(lhs.minY, rhs.minY, tolerance: tolerance)
            && almostEqual(lhs.width, rhs.width, tolerance: tolerance)
            && almostEqual(lhs.height, rhs.height, tolerance: tolerance)
    }

    // MARK: - Harness

    private func makeHarness(
        width: CGFloat,
        count: Int,
        mode: AppLibraryLayout.Mode,
        rowSpacing: CGFloat = AppLibraryLayoutMetrics.defaultRowSpacing,
        contentInsets: NSEdgeInsets = AppLibraryLayoutMetrics.defaultContentInsets,
        rowHeight: CGFloat = 44
    ) -> LibraryLayoutHarness {
        LibraryLayoutHarness(
            width: width,
            count: count,
            mode: mode,
            rowSpacing: rowSpacing,
            contentInsets: contentInsets,
            rowHeight: rowHeight
        )
    }
}

@MainActor
private final class LibraryCountDataSource: NSObject, NSCollectionViewDataSource {
    let count: Int

    init(count: Int) {
        self.count = count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        collectionView.makeItem(
            withIdentifier: BlankLibraryItem.identifier, for: indexPath
        ) ?? BlankLibraryItem()
    }
}

@MainActor
private final class BlankLibraryItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("LibraryBlankItem")

    override func loadView() {
        view = NSView()
    }
}

@MainActor
private struct LibraryLayoutHarness {
    let collectionView: NSCollectionView
    let layout: AppLibraryLayout
    private let dataSource: LibraryCountDataSource

    init(
        width: CGFloat,
        count: Int,
        mode: AppLibraryLayout.Mode,
        rowSpacing: CGFloat,
        contentInsets: NSEdgeInsets,
        rowHeight: CGFloat
    ) {
        let collectionView = NSCollectionView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        let dataSource = LibraryCountDataSource(count: count)
        collectionView.dataSource = dataSource
        collectionView.register(
            BlankLibraryItem.self, forItemWithIdentifier: BlankLibraryItem.identifier
        )
        let layout = AppLibraryLayout(
            mode: mode,
            rowSpacing: rowSpacing,
            contentInsets: contentInsets,
            rowHeight: rowHeight
        )
        collectionView.collectionViewLayout = layout
        self.collectionView = collectionView
        self.layout = layout
        self.dataSource = dataSource
    }
}
