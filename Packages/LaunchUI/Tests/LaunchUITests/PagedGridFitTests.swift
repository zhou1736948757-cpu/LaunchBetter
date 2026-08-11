import XCTest
import LaunchCore
@testable import LaunchUI

final class PagedGridFitTests: XCTestCase {
    func testNormalFitPreservesRequestedMetrics() {
        let metrics = PagedGridFitMetrics(
            rows: 8,
            cellSize: 108,
            iconSize: 80,
            horizontalSpacing: 28,
            verticalSpacing: 28,
            availableHeight: 1_100
        )

        XCTAssertEqual(metrics.scale, 1)
        XCTAssertEqual(metrics.cellSize, 108)
        XCTAssertEqual(metrics.iconSize, 80)
        XCTAssertEqual(metrics.horizontalSpacing, 28)
        XCTAssertEqual(metrics.verticalSpacing, 28)
    }

    func testPagedFitShrinksIconAndKeepsCapacity() {
        let metrics = PagedGridFitMetrics(
            rows: 8,
            cellSize: 108,
            iconSize: 80,
            horizontalSpacing: 28,
            verticalSpacing: 28,
            availableHeight: 900 - 70 - 44
        )
        let geometry = GridGeometry(
            columns: 7,
            rows: 8,
            cellSize: metrics.cellSize,
            iconSize: metrics.iconSize,
            horizontalSpacing: metrics.horizontalSpacing,
            verticalSpacing: metrics.verticalSpacing,
            pageWidth: 1_200,
            pageHeight: 900,
            topInset: 70,
            bottomInset: 44
        )

        XCTAssertLessThanOrEqual(geometry.gridHeight, 786)
        XCTAssertLessThan(metrics.iconSize, 80)
        XCTAssertEqual(geometry.pageCapacity, 56)
        let lastFrame = geometry.frame(forSlot: geometry.pageCapacity - 1, in: 0)
        XCTAssertLessThanOrEqual(lastFrame.maxY, geometry.pageHeight - geometry.bottomInset)
    }

    func testEightRowsWithLargerIconStillFits() {
        let metrics = PagedGridFitMetrics(
            rows: 8,
            cellSize: 124,
            iconSize: 96,
            horizontalSpacing: 28,
            verticalSpacing: 28,
            availableHeight: 786
        )

        XCTAssertLessThanOrEqual(metrics.gridHeight, 786)
        XCTAssertLessThan(metrics.iconSize, 96)
        XCTAssertGreaterThanOrEqual(metrics.cellSize, metrics.iconSize)
        XCTAssertGreaterThanOrEqual(metrics.horizontalSpacing, 0)
        XCTAssertGreaterThanOrEqual(metrics.verticalSpacing, 0)
    }

    func testSearchModeHelperKeepsRawMetrics() {
        let metrics = PagedGridFitMetrics(
            rows: 8,
            cellSize: 108,
            iconSize: 80,
            horizontalSpacing: 28,
            verticalSpacing: 28,
            availableHeight: 786,
            enabled: false
        )

        XCTAssertEqual(metrics.scale, 1)
        XCTAssertEqual(metrics.cellSize, 108)
        XCTAssertEqual(metrics.iconSize, 80)
        XCTAssertEqual(metrics.horizontalSpacing, 28)
        XCTAssertEqual(metrics.verticalSpacing, 28)
    }

    func testExtremeHeightHasFiniteNonNegativeMetricsAndFits() {
        let metrics = PagedGridFitMetrics(
            rows: 8,
            cellSize: 108,
            iconSize: 96,
            horizontalSpacing: 28,
            verticalSpacing: 28,
            availableHeight: 0
        )

        XCTAssertTrue(metrics.cellSize.isFinite)
        XCTAssertTrue(metrics.iconSize.isFinite)
        XCTAssertTrue(metrics.horizontalSpacing.isFinite)
        XCTAssertTrue(metrics.verticalSpacing.isFinite)
        XCTAssertGreaterThanOrEqual(metrics.cellSize, 0)
        XCTAssertGreaterThanOrEqual(metrics.iconSize, 0)
        XCTAssertGreaterThanOrEqual(metrics.horizontalSpacing, 0)
        XCTAssertGreaterThanOrEqual(metrics.verticalSpacing, 0)
        XCTAssertLessThanOrEqual(metrics.gridHeight, 0)
    }
}
