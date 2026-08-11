import AppKit
import Testing
@testable import LaunchUI

@Suite("Paging grid layout query index", .serialized)
@MainActor
struct PagingGridLayoutQueryTests {
    @Test("single-page query visits one page of candidates across many pages")
    func singlePageQueryHasBoundedCandidateCount() throws {
        let pageCount = 1_000
        let itemsPerPage = 56
        let harness = makeHarness(
            pageCount: pageCount,
            itemsPerPage: itemsPerPage
        )
        let layout = harness.layout
        let pageWidth = harness.scrollView.contentView.bounds.width
        let targetPage = 617
        let queryRect = NSRect(
            x: CGFloat(targetPage) * pageWidth,
            y: 0,
            width: pageWidth,
            height: harness.scrollView.contentView.bounds.height
        )

        let attributes = layout.layoutAttributesForElements(in: queryRect)

        #expect(layout.itemFrameCount == pageCount * itemsPerPage)
        #expect(layout.lastAttributeCandidateCount == itemsPerPage)
        #expect(layout.lastAttributeCandidateCount < layout.itemFrameCount / 100)
        #expect(attributes.count == itemsPerPage)
        #expect(attributes.allSatisfy { $0.indexPath?.section == targetPage })
    }

    @Test("query crossing a page edge visits only the two intersecting pages")
    func pageEdgeQueryVisitsTwoPages() {
        let itemsPerPage = 56
        let harness = makeHarness(pageCount: 500, itemsPerPage: itemsPerPage)
        let layout = harness.layout
        let pageWidth = harness.scrollView.contentView.bounds.width
        let edge = CGFloat(250) * pageWidth
        let queryRect = NSRect(
            x: edge - 400,
            y: 0,
            width: 800,
            height: harness.scrollView.contentView.bounds.height
        )

        _ = layout.layoutAttributesForElements(in: queryRect)

        #expect(layout.lastAttributeCandidateCount == itemsPerPage * 2)
    }

    @Test("overflowing narrow-page geometry keeps exhaustive query results")
    func narrowPageOverflowKeepsQueryCorrectness() {
        let pageCount = 40
        let itemsPerPage = 56
        let harness = makeHarness(
            pageCount: pageCount,
            itemsPerPage: itemsPerPage,
            viewportWidth: 300
        )
        let layout = harness.layout
        let pageWidth = harness.scrollView.contentView.bounds.width
        let queryRect = NSRect(
            x: CGFloat(20) * pageWidth,
            y: 0,
            width: pageWidth,
            height: harness.scrollView.contentView.bounds.height
        )

        let indexed = Set(
            layout.layoutAttributesForElements(in: queryRect).compactMap(\.indexPath)
        )
        var exhaustive = Set<IndexPath>()
        for section in 0..<pageCount {
            for item in 0..<itemsPerPage {
                let indexPath = IndexPath(item: item, section: section)
                if layout.layoutAttributesForItem(at: indexPath)?.frame.intersects(queryRect) == true {
                    exhaustive.insert(indexPath)
                }
            }
        }

        #expect(indexed == exhaustive)
        #expect(layout.lastAttributeCandidateCount <= itemsPerPage * 3)
        #expect(layout.lastAttributeCandidateCount < layout.itemFrameCount / 10)
    }

    private func makeHarness(
        pageCount: Int,
        itemsPerPage: Int,
        viewportWidth: CGFloat = 1_200
    ) -> LayoutHarness {
        let layout = PagingGridLayout(
            columns: 7,
            rows: 8,
            cellSize: 72,
            iconSize: 56,
            horizontalSpacing: 20,
            verticalSpacing: 20
        )
        layout.setContentInsets(top: 40, bottom: 40)

        let dataSource = PagingGridLayoutDataSource(
            pageCount: pageCount,
            itemsPerPage: itemsPerPage
        )
        let collectionView = ClickableCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = dataSource

        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: viewportWidth, height: 900)
        )
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.documentView = collectionView
        collectionView.frame = scrollView.contentView.bounds
        collectionView.reloadData()
        scrollView.layoutSubtreeIfNeeded()
        collectionView.layoutSubtreeIfNeeded()
        layout.prepare()

        return LayoutHarness(
            layout: layout,
            scrollView: scrollView,
            dataSource: dataSource
        )
    }
}

@MainActor
private struct LayoutHarness {
    let layout: PagingGridLayout
    let scrollView: NSScrollView
    // NSCollectionView.dataSource is weak; retain the fixture for the test.
    let dataSource: PagingGridLayoutDataSource
}

@MainActor
private final class PagingGridLayoutDataSource: NSObject, NSCollectionViewDataSource {
    let pageCount: Int
    let itemsPerPage: Int

    init(pageCount: Int, itemsPerPage: Int) {
        self.pageCount = pageCount
        self.itemsPerPage = itemsPerPage
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int {
        pageCount
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        itemsPerPage
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        NSCollectionViewItem()
    }
}
