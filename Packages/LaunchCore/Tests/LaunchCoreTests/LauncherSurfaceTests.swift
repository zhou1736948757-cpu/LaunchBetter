import XCTest
@testable import LaunchCore

/// Stage E1: LauncherSurface 语义/物理映射契约测试。
final class LauncherSurfaceTests: XCTestCase {
    // 1 个 Layout page: physical [Library, Page0], Page0 默认 physical 1。
    func testSingleLayoutPagePhysicalOrdering() {
        let index = LauncherSurfaceIndex(layoutPageCount: 1)
        XCTAssertEqual(index.physicalSurfaceCount, 2)
        XCTAssertEqual(index.physicalIndex(for: .appLibrary), 0)
        XCTAssertEqual(index.physicalIndex(for: .layoutPage(0)), 1)
        XCTAssertEqual(index.surface(forPhysicalIndex: 0), .appLibrary)
        XCTAssertEqual(index.surface(forPhysicalIndex: 1), .layoutPage(0))
    }

    // 3 个 Layout pages: physical [Library, Page0, Page1, Page2]。
    func testThreeLayoutPagesPhysicalOrdering() {
        let index = LauncherSurfaceIndex(layoutPageCount: 3)
        XCTAssertEqual(index.physicalSurfaceCount, 4)
        for (page, physical) in [(0, 1), (1, 2), (2, 3)] {
            XCTAssertEqual(index.physicalIndex(for: .layoutPage(page)), physical)
            XCTAssertEqual(index.surface(forPhysicalIndex: physical), .layoutPage(page))
        }
    }

    // .layoutPage(-1) / .layoutPage(999) 确定性 clamp。
    func testLayoutPageClampsInvalidIndex() {
        let index = LauncherSurfaceIndex(layoutPageCount: 3)
        XCTAssertEqual(index.physicalIndex(for: .layoutPage(-1)), 1)
        XCTAssertEqual(index.physicalIndex(for: .layoutPage(-100)), 1)
        XCTAssertEqual(index.physicalIndex(for: .layoutPage(999)), 3)
        let single = LauncherSurfaceIndex(layoutPageCount: 1)
        XCTAssertEqual(single.physicalIndex(for: .layoutPage(999)), 1)
    }

    // physical -1 / 999 确定性 clamp。
    func testPhysicalIndexClampsBoundaries() {
        let index = LauncherSurfaceIndex(layoutPageCount: 3)
        XCTAssertEqual(index.surface(forPhysicalIndex: -1), .appLibrary)
        XCTAssertEqual(index.surface(forPhysicalIndex: -999), .appLibrary)
        XCTAssertEqual(index.surface(forPhysicalIndex: 4), .layoutPage(2))
        XCTAssertEqual(index.surface(forPhysicalIndex: 999), .layoutPage(2))
    }

    // physical 0 不能得到普通 Layout page index。
    func testPhysicalZeroIsNeverALayoutPage() {
        let index = LauncherSurfaceIndex(layoutPageCount: 1)
        XCTAssertNil(index.layoutPageIndex(forPhysicalIndex: 0))
        XCTAssertEqual(index.layoutPageIndex(forPhysicalIndex: 1), 0)

        let three = LauncherSurfaceIndex(layoutPageCount: 3)
        XCTAssertNil(three.layoutPageIndex(forPhysicalIndex: 0))
        XCTAssertEqual(three.layoutPageIndex(forPhysicalIndex: 1), 0)
        XCTAssertEqual(three.layoutPageIndex(forPhysicalIndex: 2), 1)
        XCTAssertEqual(three.layoutPageIndex(forPhysicalIndex: 3), 2)
        XCTAssertNil(three.layoutPageIndex(forPhysicalIndex: 4))
        XCTAssertNil(three.layoutPageIndex(forPhysicalIndex: -1))
    }

    // physicalSurfaceCount == layoutPageCount + 1 且至少 2。
    func testPhysicalSurfaceCountInvariant() {
        for count in [-10, 0, 1, 2, 3, 42] {
            let index = LauncherSurfaceIndex(layoutPageCount: count)
            XCTAssertGreaterThanOrEqual(index.physicalSurfaceCount, 2)
            XCTAssertEqual(index.physicalSurfaceCount, index.layoutPageCount + 1)
        }
    }

    // layoutPageCount 规范化为至少 1。
    func testLayoutPageCountNormalizesToAtLeastOne() {
        XCTAssertEqual(LauncherSurfaceIndex(layoutPageCount: 0).layoutPageCount, 1)
        XCTAssertEqual(LauncherSurfaceIndex(layoutPageCount: -5).layoutPageCount, 1)
        XCTAssertEqual(LauncherSurfaceIndex(layoutPageCount: 1).layoutPageCount, 1)
        XCTAssertEqual(LauncherSurfaceIndex(layoutPageCount: 3).layoutPageCount, 3)
    }

    // 映射往返稳定: surface ↔ physical 双向往返恒等, 越界输入往返收敛到 clamp 值。
    func testMappingRoundTripIsStable() {
        let index = LauncherSurfaceIndex(layoutPageCount: 3)
        let surfaces: [LauncherSurface] = [.appLibrary, .layoutPage(0), .layoutPage(1), .layoutPage(2)]
        for surface in surfaces {
            XCTAssertEqual(index.surface(forPhysicalIndex: index.physicalIndex(for: surface)), surface)
        }
        for physical in 0..<index.physicalSurfaceCount {
            XCTAssertEqual(index.physicalIndex(for: index.surface(forPhysicalIndex: physical)), physical)
        }
        XCTAssertEqual(index.surface(forPhysicalIndex: index.physicalIndex(for: .layoutPage(-1))), .layoutPage(0))
        XCTAssertEqual(index.surface(forPhysicalIndex: index.physicalIndex(for: .layoutPage(999))), .layoutPage(2))
    }

    // Equatable 语义稳定。
    func testEquatableSemantics() {
        XCTAssertEqual(LauncherSurface.appLibrary, .appLibrary)
        XCTAssertEqual(LauncherSurface.layoutPage(2), .layoutPage(2))
        XCTAssertNotEqual(LauncherSurface.layoutPage(2), .layoutPage(3))
        XCTAssertNotEqual(LauncherSurface.appLibrary, .layoutPage(0))
        XCTAssertEqual(LauncherSurfaceIndex(layoutPageCount: 3), LauncherSurfaceIndex(layoutPageCount: 3))
        XCTAssertNotEqual(LauncherSurfaceIndex(layoutPageCount: 3), LauncherSurfaceIndex(layoutPageCount: 4))
    }

    // Sendable: 跨 Task 边界捕获编译通过且值稳定。
    func testSendableAcrossTaskBoundary() async {
        let index = LauncherSurfaceIndex(layoutPageCount: 3)
        let surface = LauncherSurface.layoutPage(2)
        let result = await Task.detached {
            (index.physicalIndex(for: surface), surface)
        }.value
        XCTAssertEqual(result.0, 3)
        XCTAssertEqual(result.1, .layoutPage(2))
    }
}
