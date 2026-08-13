import AppKit
import LaunchCore
import Testing
@testable import LaunchUI

@Suite("Leading surface layout", .serialized)
@MainActor
struct LeadingSurfaceLayoutTests {
    @Test("disabled keeps physical section 0 as a normal grid page")
    func disabledRegressionMatchesPlainGeometry() throws {
        let harness = makeHarness(physicalSections: 3, itemsPerPage: 56, leadingEnabled: false)
        let layout = harness.layout
        let geometry = try #require(layout.currentGeometry)

        for (section, slot) in [(0, 0), (0, 13), (1, 7), (2, 55)] {
            let attrs = try #require(
                layout.layoutAttributesForItem(at: IndexPath(item: slot, section: section))
            )
            #expect(attrs.frame == geometry.frame(forSlot: slot, in: section))
        }
        #expect(layout.itemFrameCount == 3 * 56)
    }

    @Test("enabled gives section 0 the full page and shifts layout pages by one")
    func enabledHostAndShiftedPages() throws {
        let harness = makeHarness(physicalSections: 3, itemsPerPage: 56, leadingEnabled: true)
        let layout = harness.layout
        let geometry = try #require(layout.currentGeometry)
        let pageWidth = geometry.pageWidth

        let host = try #require(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
        #expect(host.frame == CGRect(x: 0, y: 0, width: pageWidth, height: geometry.pageHeight))

        let s1Slot0 = try #require(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 1)))
        #expect(s1Slot0.frame == geometry.frame(forSlot: 0, in: 1))
        #expect(s1Slot0.frame.minX == pageWidth + geometry.frame(forSlot: 0, in: 0).minX)

        let s1Slot23 = try #require(layout.layoutAttributesForItem(at: IndexPath(item: 23, section: 1)))
        #expect(s1Slot23.frame == geometry.frame(forSlot: 23, in: 1))
        #expect(s1Slot23.frame.minX == pageWidth + geometry.frame(forSlot: 23, in: 0).minX)

        let s2Slot0 = try #require(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 2)))
        #expect(s2Slot0.frame == geometry.frame(forSlot: 0, in: 2))
        #expect(s2Slot0.frame.minX == pageWidth + geometry.frame(forSlot: 0, in: 1).minX)
    }

    @Test("content width spans physical sections in both modes")
    func contentWidthSpansPhysicalSections() throws {
        let enabled = makeHarness(physicalSections: 4, itemsPerPage: 56, leadingEnabled: true)
        let disabled = makeHarness(physicalSections: 4, itemsPerPage: 56, leadingEnabled: false)
        let geometry = try #require(enabled.layout.currentGeometry)

        #expect(enabled.layout.collectionViewContentSize.width == 4 * geometry.pageWidth)
        #expect(disabled.layout.collectionViewContentSize.width == 4 * geometry.pageWidth)
        #expect(enabled.layout.collectionViewContentSize.height == geometry.pageHeight)
        #expect(disabled.layout.collectionViewContentSize.height == geometry.pageHeight)
    }

    @Test("toggling leading invalidates and rebuilds frames without residue")
    func toggleRebuildsFrames() throws {
        let harness = makeHarness(physicalSections: 3, itemsPerPage: 56, leadingEnabled: false)
        let layout = harness.layout
        let plain = try #require(layout.currentGeometry)

        harness.dataSource.leadingEnabled = true
        harness.reloadData()
        layout.leadingSurfaceEnabled = true
        layout.prepare()
        let enabledGeometry = try #require(layout.currentGeometry)
        let host = try #require(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
        #expect(
            host.frame
                == CGRect(x: 0, y: 0, width: enabledGeometry.pageWidth, height: enabledGeometry.pageHeight)
        )
        #expect(
            layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 1))?.frame
                == enabledGeometry.frame(forSlot: 0, in: 1)
        )

        harness.dataSource.leadingEnabled = false
        harness.reloadData()
        layout.leadingSurfaceEnabled = false
        layout.prepare()
        let restored = try #require(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
        let plainSlot0 = plain.frame(forSlot: 0, in: 0)
        #expect(restored.frame == plainSlot0)
        #expect(
            restored.frame
                != CGRect(x: 0, y: 0, width: plain.pageWidth, height: plain.pageHeight)
        )
        #expect(
            layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 1))?.frame
                == plain.frame(forSlot: 0, in: 1)
        )
        #expect(layout.itemFrameCount == 3 * 56)
    }

    @Test("resize invalidates and rebuilds shifted frames at the new page width")
    func resizeRebuildsFrames() throws {
        let harness = makeHarness(physicalSections: 3, itemsPerPage: 56, leadingEnabled: true)
        let layout = harness.layout
        let scrollView = harness.scrollView
        let oldWidth = scrollView.contentView.bounds.width

        scrollView.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        scrollView.layoutSubtreeIfNeeded()
        layout.prepare()

        let geometry = try #require(layout.currentGeometry)
        #expect(geometry.pageWidth < oldWidth)
        let host = try #require(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
        #expect(host.frame == CGRect(x: 0, y: 0, width: geometry.pageWidth, height: geometry.pageHeight))
        #expect(
            layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 1))?.frame
                == geometry.frame(forSlot: 0, in: 1)
        )
    }

    @Test("search mode keeps single-section vertical semantics without leading offset")
    func searchModeIgnoresLeadingHost() throws {
        let layout = makeHarness(
            physicalSections: 1,
            itemsPerPage: 40,
            leadingEnabled: true,
            hostItemCount: 40
        ).layout
        layout.mode = .search
        layout.prepare()

        let geometry = try #require(layout.currentGeometry)
        let first = try #require(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
        #expect(first.frame == geometry.searchFrame(forIndex: 0, itemCount: 40))
        #expect(first.frame.minX + first.frame.width <= geometry.pageWidth)

        let last = try #require(layout.layoutAttributesForItem(at: IndexPath(item: 39, section: 0)))
        #expect(last.frame == geometry.searchFrame(forIndex: 39, itemCount: 40))

        #expect(layout.collectionViewContentSize.width == geometry.pageWidth)
        #expect(
            layout.collectionViewContentSize.height
                == geometry.searchContentSize(forItemCount: 40).height
        )
    }

    @Test("attributes query treats the host page as one candidate section")
    func hostPageQueryIsBounded() throws {
        let harness = makeHarness(physicalSections: 4, itemsPerPage: 56, leadingEnabled: true)
        let layout = harness.layout
        let geometry = try #require(layout.currentGeometry)
        let pageWidth = geometry.pageWidth

        let hostAttrs = layout.layoutAttributesForElements(
            in: NSRect(x: 0, y: 0, width: pageWidth, height: 900)
        )
        #expect(hostAttrs.count == 1)
        #expect(hostAttrs.first?.indexPath == IndexPath(item: 0, section: 0))
        #expect(layout.lastAttributeCandidateCount == 1)

        let page1Attrs = layout.layoutAttributesForElements(
            in: NSRect(x: pageWidth, y: 0, width: pageWidth, height: 900)
        )
        #expect(page1Attrs.count == 56)
        #expect(page1Attrs.allSatisfy { $0.indexPath?.section == 1 })
        #expect(layout.lastAttributeCandidateCount == 56)

        let crossing = layout.layoutAttributesForElements(
            in: NSRect(x: pageWidth - 500, y: 0, width: 1_000, height: 900)
        )
        #expect(layout.lastAttributeCandidateCount == 1 + 56)
        #expect(crossing.contains { $0.indexPath == IndexPath(item: 0, section: 0) })
        #expect(crossing.allSatisfy { ($0.indexPath?.section ?? -1) <= 1 })
    }

    @Test("gutter query inside the host page still returns the host item")
    func hostPageGutterQueryFindsHost() throws {
        let harness = makeHarness(physicalSections: 3, itemsPerPage: 56, leadingEnabled: true)
        let layout = harness.layout

        let attrs = layout.layoutAttributesForElements(
            in: NSRect(x: 0, y: 0, width: 20, height: 900)
        )
        #expect(attrs.count == 1)
        #expect(attrs.first?.indexPath == IndexPath(item: 0, section: 0))
    }

    @Test("disabled gutter query stays empty as before")
    func disabledGutterQueryStaysEmpty() {
        let layout = makeHarness(physicalSections: 3, itemsPerPage: 56, leadingEnabled: false).layout
        let attrs = layout.layoutAttributesForElements(
            in: NSRect(x: 0, y: 0, width: 20, height: 900)
        )
        #expect(attrs.isEmpty)
    }

    @MainActor
    private func makeHarness(
        physicalSections: Int,
        itemsPerPage: Int,
        leadingEnabled: Bool,
        hostItemCount: Int = 1,
        viewportWidth: CGFloat = 1_200
    ) -> LeadingSurfaceHarness {
        let layout = PagingGridLayout(
            columns: 7,
            rows: 8,
            cellSize: 72,
            iconSize: 56,
            horizontalSpacing: 20,
            verticalSpacing: 20
        )
        layout.leadingSurfaceEnabled = leadingEnabled
        layout.setContentInsets(top: 40, bottom: 40)

        let dataSource = LeadingSurfaceDataSource(
            physicalSections: physicalSections,
            itemsPerPage: itemsPerPage,
            hostItemCount: hostItemCount,
            leadingEnabled: leadingEnabled
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

        return LeadingSurfaceHarness(
            layout: layout,
            scrollView: scrollView,
            dataSource: dataSource,
            collectionView: collectionView
        )
    }
}

@MainActor
private struct LeadingSurfaceHarness {
    let layout: PagingGridLayout
    let scrollView: NSScrollView
    // NSCollectionView.dataSource is weak; retain the fixture for the test.
    let dataSource: LeadingSurfaceDataSource
    let collectionView: ClickableCollectionView

    func reloadData() {
        collectionView.reloadData()
    }
}

@MainActor
private final class LeadingSurfaceDataSource: NSObject, NSCollectionViewDataSource {
    let physicalSections: Int
    let itemsPerPage: Int
    let hostItemCount: Int
    var leadingEnabled: Bool

    init(physicalSections: Int, itemsPerPage: Int, hostItemCount: Int, leadingEnabled: Bool) {
        self.physicalSections = physicalSections
        self.itemsPerPage = itemsPerPage
        self.hostItemCount = hostItemCount
        self.leadingEnabled = leadingEnabled
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int {
        physicalSections
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        section == 0 ? (leadingEnabled ? hostItemCount : itemsPerPage) : itemsPerPage
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        NSCollectionViewItem()
    }
}
