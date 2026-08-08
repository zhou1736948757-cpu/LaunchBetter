import CoreGraphics
import Foundation
import XCTest
@testable import LaunchCore

/// GridGeometry 纯逻辑测试(Stage 1, P0): 不启动真实 Launcher。
final class GridGeometryTests: XCTestCase {
    private func makeGeometry(
        columns: Int = 7,
        rows: Int = 6,
        cellSize: CGFloat = 96,
        iconSize: CGFloat = 80,
        spacing: CGFloat = 28,
        pageWidth: CGFloat = 1200,
        pageHeight: CGFloat = 800
    ) -> GridGeometry {
        GridGeometry(
            columns: columns, rows: rows, cellSize: cellSize, iconSize: iconSize,
            horizontalSpacing: spacing, verticalSpacing: spacing,
            pageWidth: pageWidth, pageHeight: pageHeight
        )
    }

    // MARK: - 容量与尺寸

    func testPageCapacity() {
        XCTAssertEqual(makeGeometry(columns: 7, rows: 6).pageCapacity, 42)
        XCTAssertEqual(makeGeometry(columns: 8, rows: 5).pageCapacity, 40)
        XCTAssertEqual(makeGeometry(columns: 4, rows: 3).pageCapacity, 12)
    }

    func testGridExtentCentered() {
        let g = makeGeometry(columns: 7, rows: 6, pageWidth: 1200, pageHeight: 800)
        // 网格宽 = 7*96 + 6*28 = 840; 网格高 = 6*96 + 5*28 = 716
        XCTAssertEqual(g.gridWidth, 840)
        XCTAssertEqual(g.gridHeight, 716)
        XCTAssertEqual(g.gridOrigin.x, (1200 - 840) / 2)
        XCTAssertEqual(g.gridOrigin.y, (800 - 716) / 2)
    }

    // MARK: - frame(forSlot:in:)

    func testFirstSlotFrame() {
        let g = makeGeometry()
        let frame = g.frame(forSlot: 0, in: 0)
        XCTAssertEqual(frame.minX, g.gridOrigin.x)
        XCTAssertEqual(frame.minY, g.gridOrigin.y)
        XCTAssertEqual(frame.width, 96)
        XCTAssertEqual(frame.height, 96)
    }

    func testSecondRowFirstSlot() {
        let g = makeGeometry()
        // slot 7 = 第 1 行(列主序): 同列, 高一个槽位
        let frame = g.frame(forSlot: 7, in: 0)
        XCTAssertEqual(frame.minX, g.frame(forSlot: 0, in: 0).minX)
        XCTAssertEqual(frame.minY, g.frame(forSlot: 0, in: 0).minY + 96 + 28)
    }

    func testLastSlotOnPage() {
        let g = makeGeometry(columns: 7, rows: 6)
        let frame = g.frame(forSlot: 41, in: 0)
        XCTAssertEqual(frame.maxX, g.gridOrigin.x + g.gridWidth)
        XCTAssertEqual(frame.maxY, g.gridOrigin.y + g.gridHeight)
    }

    func testCrossPageSlotFrame() {
        let g = makeGeometry(pageWidth: 1200)
        // 第 1 页第一个槽位 vs 第 2 页第一个槽位: 相差一个页宽
        let page0 = g.frame(forSlot: 0, in: 0)
        let page1 = g.frame(forSlot: 0, in: 1)
        XCTAssertEqual(page1.minX, page0.minX + 1200)
        XCTAssertEqual(page1.minY, page0.minY)
    }

    func testFlatIndexFrameAcrossPages() {
        let g = makeGeometry(columns: 7, rows: 6)
        // flat 0 → page 0 slot 0; flat 42 → page 1 slot 0; flat 84 → page 2 slot 0
        XCTAssertEqual(g.frame(forFlatIndex: 0), g.frame(forSlot: 0, in: 0))
        XCTAssertEqual(g.frame(forFlatIndex: 42), g.frame(forSlot: 0, in: 1))
        XCTAssertEqual(g.frame(forFlatIndex: 84), g.frame(forSlot: 0, in: 2))
    }

    // MARK: - point → page

    func testPageForPoint() {
        let g = makeGeometry(pageWidth: 1200)
        XCTAssertEqual(g.page(forDocumentPoint: CGPoint(x: 0, y: 400)), 0)
        XCTAssertEqual(g.page(forDocumentPoint: CGPoint(x: 1199, y: 400)), 0)
        XCTAssertEqual(g.page(forDocumentPoint: CGPoint(x: 1200, y: 400)), 1)
        XCTAssertEqual(g.page(forDocumentPoint: CGPoint(x: 2399, y: 400)), 1)
        XCTAssertEqual(g.page(forDocumentPoint: CGPoint(x: 2400, y: 400)), 2)
        // 负坐标(文档原点左侧)→ 钳制到 0
        XCTAssertEqual(g.page(forDocumentPoint: CGPoint(x: -10, y: 400), pageCount: 3), 0)
        // 超出页数 → 钳制
        XCTAssertEqual(g.page(forDocumentPoint: CGPoint(x: 99999, y: 400), pageCount: 3), 2)
    }

    func testPageRect() {
        let g = makeGeometry(pageWidth: 1200, pageHeight: 800)
        XCTAssertEqual(g.pageRect(page: 0), CGRect(x: 0, y: 0, width: 1200, height: 800))
        XCTAssertEqual(g.pageRect(page: 1), CGRect(x: 1200, y: 0, width: 1200, height: 800))
        XCTAssertEqual(g.pageRect(page: 2), CGRect(x: 2400, y: 0, width: 1200, height: 800))
    }

    // MARK: - point → slot

    func testSlotForPointCenter() {
        let g = makeGeometry()
        let firstFrame = g.frame(forSlot: 0, in: 0)
        let center = CGPoint(x: firstFrame.midX, y: firstFrame.midY)
        XCTAssertEqual(g.slot(forDocumentPoint: center), 0)
    }

    func testSlotForPointAdjacent() {
        let g = makeGeometry()
        // 第一个槽位右侧一个步进 = slot 1
        let first = g.frame(forSlot: 0, in: 0)
        let p = CGPoint(x: first.maxX + 28 + 48, y: first.midY)
        XCTAssertEqual(g.slot(forDocumentPoint: p), 1)
        // 第一个槽位上方一个步进 = slot 7(列主序)
        let p2 = CGPoint(x: first.midX, y: first.maxY + 28 + 48)
        XCTAssertEqual(g.slot(forDocumentPoint: p2), 7)
    }

    func testSlotForPointClampedOutOfGrid() {
        let g = makeGeometry(columns: 7, rows: 6)
        // 网格右下角之外 → 钳制到最后槽位
        let corner = CGPoint(x: g.gridOrigin.x + g.gridWidth + 50, y: g.gridOrigin.y + g.gridHeight + 50)
        XCTAssertEqual(g.slot(forDocumentPoint: corner), 41)
        // 网格左下角之外 → 钳制到槽位 0
        let outside = CGPoint(x: 0, y: 0)
        XCTAssertEqual(g.slot(forDocumentPoint: outside), 0)
    }

    func testSlotForPointOnSecondPage() {
        let g = makeGeometry(pageWidth: 1200)
        let page1Frame = g.frame(forSlot: 5, in: 1)
        let p = CGPoint(x: page1Frame.midX, y: page1Frame.midY)
        XCTAssertEqual(g.slot(forDocumentPoint: p), 5)
        let (page, slot) = g.pageAndSlot(forDocumentPoint: p, pageCount: 3)
        XCTAssertEqual(page, 1)
        XCTAssertEqual(slot, 5)
    }

    func testPageAndSlotClamped() {
        let g = makeGeometry(pageWidth: 1200)
        let (page, slot) = g.pageAndSlot(
            forDocumentPoint: CGPoint(x: 99999, y: 99999), pageCount: 3
        )
        XCTAssertEqual(page, 2)
        XCTAssertEqual(slot, 41)
    }

    // MARK: - 不同 columns/rows/page widths

    func testDifferentGridSizes() {
        let small = makeGeometry(columns: 4, rows: 3, cellSize: 64, spacing: 16, pageWidth: 600, pageHeight: 400)
        XCTAssertEqual(small.pageCapacity, 12)
        XCTAssertEqual(small.gridWidth, 4 * 64 + 3 * 16)
        XCTAssertEqual(small.gridHeight, 3 * 64 + 2 * 16)
        // 中心点 → 槽位 0
        let first = small.frame(forSlot: 0, in: 0)
        XCTAssertEqual(small.slot(forDocumentPoint: CGPoint(x: first.midX, y: first.midY)), 0)
        // 跨页
        XCTAssertEqual(small.frame(forSlot: 0, in: 2).minX, first.minX + 2 * 600)
    }

    func testWideNarrowPageWidths() {
        let wide = makeGeometry(pageWidth: 2000)
        XCTAssertEqual(wide.frame(forSlot: 0, in: 1).minX, wide.frame(forSlot: 0, in: 0).minX + 2000)
        let narrow = makeGeometry(pageWidth: 400)
        XCTAssertEqual(narrow.frame(forSlot: 0, in: 1).minX, narrow.frame(forSlot: 0, in: 0).minX + 400)
    }

    // MARK: - 搜索模式

    func testSearchRowsNeeded() {
        let g = makeGeometry(columns: 7, rows: 6)
        XCTAssertEqual(g.searchRowsNeeded(forItemCount: 0), 0)
        XCTAssertEqual(g.searchRowsNeeded(forItemCount: 1), 1)
        XCTAssertEqual(g.searchRowsNeeded(forItemCount: 7), 1)
        XCTAssertEqual(g.searchRowsNeeded(forItemCount: 8), 2)
        XCTAssertEqual(g.searchRowsNeeded(forItemCount: 42), 6)
        XCTAssertEqual(g.searchRowsNeeded(forItemCount: 43), 7)
        XCTAssertEqual(g.searchRowsNeeded(forItemCount: 100), 15)
    }

    func testSearchContentSizeFitsPageWhenSmall() {
        let g = makeGeometry(pageWidth: 1200, pageHeight: 800)
        let size = g.searchContentSize(forItemCount: 10)
        XCTAssertEqual(size.width, 1200)
        XCTAssertEqual(size.height, 800) // 一页内容 → 保持页高
    }

    func testSearchContentSizeGrowsWhenOverflow() {
        let g = makeGeometry(columns: 7, rows: 6, pageWidth: 1200, pageHeight: 800)
        let size = g.searchContentSize(forItemCount: 100)
        XCTAssertEqual(size.width, 1200)
        // 15 行 * 96 + 14 * 28 + 48 边距
        let expected = 15 * 96 + 14 * 28 + 48
        XCTAssertEqual(size.height, CGFloat(expected))
        XCTAssertGreaterThan(size.height, 800)
    }

    func testSearchFramesAllInDocument() {
        let g = makeGeometry(columns: 7, rows: 6, pageWidth: 1200, pageHeight: 800)
        let count = 100
        let size = g.searchContentSize(forItemCount: count)
        for index in 0..<count {
            let frame = g.searchFrame(forIndex: index, itemCount: count)
            // 全部结果必须位于文档矩形内(可滚动访问, Stage 1 §11)
            XCTAssertTrue(size.width > frame.maxX || size.width >= frame.maxX, "idx \(index) 超宽")
            XCTAssertTrue(size.height >= frame.maxY + 1, "idx \(index) 超高 frame=\(frame) size=\(size)")
            XCTAssertGreaterThanOrEqual(frame.minY, 0, "idx \(index) 越下界")
        }
    }

    func testSearchFramesTopAnchored() {
        let g = makeGeometry(columns: 7, rows: 6, pageWidth: 1200, pageHeight: 800)
        let frame0 = g.searchFrame(forIndex: 0, itemCount: 100)
        let frame7 = g.searchFrame(forIndex: 7, itemCount: 100) // 第二行
        // y-down: 行 0 在最上(更小的 y)
        XCTAssertLessThan(frame0.minY, frame7.minY)
        XCTAssertEqual(frame0.minY, 24) // padding 顶部锚定
        // 同列: x 相同
        XCTAssertEqual(frame0.minX, frame7.minX)
    }
}

extension GridGeometryTests {
    // MARK: - 吸附目标(v0.1.4)

    func testSnapTargetStaysWhenSmallOffset() {
        let g = makeGeometry(pageWidth: 1200)
        // 20% 位移 → 弹回当前页
        XCTAssertEqual(g.snapTarget(currentOffsetX: 1200 + 240, currentPage: 1, pageCount: 3), 1)
        XCTAssertEqual(g.snapTarget(currentOffsetX: 1200 - 240, currentPage: 1, pageCount: 3), 1)
    }

    func testSnapTargetAdvancesWhenLargeOffset() {
        let g = makeGeometry(pageWidth: 1200)
        // 40% 位移 → 翻页
        XCTAssertEqual(g.snapTarget(currentOffsetX: 1200 + 480, currentPage: 1, pageCount: 3), 2)
        XCTAssertEqual(g.snapTarget(currentOffsetX: 1200 - 480, currentPage: 1, pageCount: 3), 0)
    }

    func testSnapTargetClampsAtBounds() {
        let g = makeGeometry(pageWidth: 1200)
        // 第 0 页向左 → 钳制回 0; 最后一页向右 → 钳制
        XCTAssertEqual(g.snapTarget(currentOffsetX: -480, currentPage: 0, pageCount: 3), 0)
        XCTAssertEqual(g.snapTarget(currentOffsetX: 2400 + 480, currentPage: 2, pageCount: 3), 2)
    }

    func testSnapTargetSinglePage() {
        let g = makeGeometry(pageWidth: 1200)
        XCTAssertEqual(g.snapTarget(currentOffsetX: 0, currentPage: 0, pageCount: 1), 0)
        XCTAssertEqual(g.snapTarget(currentOffsetX: 999, currentPage: 0, pageCount: 1), 0)
    }

    func testSnapTargetExactPage() {
        let g = makeGeometry(pageWidth: 1200)
        XCTAssertEqual(g.snapTarget(currentOffsetX: 1200, currentPage: 1, pageCount: 3), 1)
        XCTAssertEqual(g.snapTarget(currentOffsetX: 0, currentPage: 0, pageCount: 3), 0)
    }
}
