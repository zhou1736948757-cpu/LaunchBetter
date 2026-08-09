import AppKit
import LaunchCore
import Testing
@testable import LaunchUI

@Suite("Folder drop geometry")
struct FolderDropGeometryTests {
    private func makeGeometry(pageHeight: CGFloat = 376) -> GridGeometry {
        GridGeometry(
            columns: 3,
            rows: 3,
            cellSize: 96,
            iconSize: 80,
            horizontalSpacing: 20,
            verticalSpacing: 20,
            pageWidth: 364,
            pageHeight: pageHeight
        )
    }

    @Test("all gaps use row-major search frames for counts one through ten")
    func gapFrameMatrix() throws {
        let geometry = makeGeometry()

        for count in 1...10 {
            let drop = FolderDropGeometry(geometry: geometry, itemCount: count)
            for gap in 0...count {
                let actual = try #require(drop.frame(forGap: gap))
                let expected = geometry.searchFrame(
                    forIndex: gap,
                    itemCount: count
                )
                #expect(
                    actual == expected,
                    "count=\(count) gap=\(gap) actual=\(actual) expected=\(expected)"
                )
            }
        }
    }

    @Test("row transition boundaries resolve to gaps three six and nine")
    func rowBoundaryMatrix() throws {
        let geometry = makeGeometry()

        for count in 1...10 {
            let drop = FolderDropGeometry(geometry: geometry, itemCount: count)
            for gap in stride(from: 3, through: count, by: 3) {
                let point = try #require(drop.boundaryPoint(forGap: gap))
                #expect(
                    drop.gap(for: point) == gap,
                    "count=\(count) gap=\(gap) point=\(point)"
                )
            }
        }
    }

    @Test("every insertion boundary is deterministic")
    func everyGapBoundary() throws {
        let geometry = makeGeometry()

        for count in 1...10 {
            let drop = FolderDropGeometry(geometry: geometry, itemCount: count)
            for gap in 0...count {
                let point = try #require(drop.boundaryPoint(forGap: gap))
                #expect(
                    drop.gap(for: point) == gap,
                    "count=\(count) gap=\(gap) point=\(point)"
                )
            }
        }
    }

    @Test("partial-row trailing slot centers resolve to the trailing gap")
    func partialRowTrailingSlotCenters() throws {
        let geometry = makeGeometry()
        for count in [4, 5, 7, 8] {
            let drop = FolderDropGeometry(geometry: geometry, itemCount: count)
            let frame = try #require(drop.frame(forGap: count))
            #expect(
                drop.gap(for: CGPoint(x: frame.midX, y: frame.midY)) == count,
                "count=\(count) trailingFrame=\(frame)"
            )
        }
    }

    @Test("the fourth row stays in document coordinates after scrolling")
    func scrolledFourthRowGeometry() throws {
        let drop = FolderDropGeometry(geometry: makeGeometry(), itemCount: 10)
        let fourthRow = try #require(drop.frame(forGap: 10))
        let visibleAfterScroll = fourthRow.offsetBy(dx: 0, dy: -116)
        let boundaryPoint = try #require(drop.boundaryPoint(forGap: 10))
        let visibleBoundaryPoint = CGPoint(
            x: boundaryPoint.x,
            y: boundaryPoint.y - 116
        )

        #expect(fourthRow.minY == 372)
        #expect(visibleAfterScroll.minY == 256)
        #expect(visibleBoundaryPoint.y == 304)
        #expect(drop.gap(for: boundaryPoint) == 10)
    }
}

@Suite("Paging grid folder search geometry")
@MainActor
struct PagingGridFolderSearchGeometryTests {
    private func makeGeometry(pageHeight: CGFloat = 376) -> GridGeometry {
        GridGeometry(
            columns: 3,
            rows: 3,
            cellSize: 96,
            iconSize: 80,
            horizontalSpacing: 20,
            verticalSpacing: 20,
            pageWidth: 364,
            pageHeight: pageHeight
        )
    }

    private func makeLayout() -> PagingGridLayout {
        let layout = PagingGridLayout(
            columns: 3,
            rows: 3,
            cellSize: 96,
            iconSize: 80,
            horizontalSpacing: 20,
            verticalSpacing: 20
        )
        layout.mode = .search
        return layout
    }

    @Test("search height shrinks across nine ten nine without stale document height")
    func searchHeightShrinks() {
        let layout = makeLayout()
        let geometry = makeGeometry()

        let nine = layout.searchContentSize(forItemCount: 9, geometry: geometry)
        let ten = layout.searchContentSize(forItemCount: 10, geometry: geometry)
        let nineAgain = layout.searchContentSize(forItemCount: 9, geometry: geometry)

        #expect(nine.height == 376)
        #expect(ten.height == 492)
        #expect(nineAgain.height == 376)
    }

    @Test("folder drag reservation keeps the virtual trailing slot in content")
    func trailingSlotReservation() throws {
        let layout = makeLayout()
        layout.reservesSearchTrailingSlot = true
        let geometry = makeGeometry()
        let size = layout.searchContentSize(forItemCount: 9, geometry: geometry)
        let trailing = geometry.searchFrame(forIndex: 9, itemCount: 9)

        #expect(size.height >= trailing.maxY + FolderDropGeometry.searchPadding)
        #expect(size.height == 492)
    }

    @Test("live geometry uses clip height instead of document height")
    func liveGeometryUsesClipHeight() {
        let layout = makeLayout()
        let collectionView = ClickableCollectionView()
        collectionView.collectionViewLayout = layout

        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 364, height: 376)
        )
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = collectionView
        collectionView.frame = NSRect(x: 0, y: 0, width: 364, height: 492)
        scrollView.layoutSubtreeIfNeeded()

        let clipHeight = scrollView.contentView.bounds.height
        #expect(clipHeight > 0)
        #expect(layout.liveGeometry.pageHeight == clipHeight)
    }
}
