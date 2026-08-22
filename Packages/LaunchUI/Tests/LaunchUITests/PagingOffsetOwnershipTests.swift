import AppKit
import Foundation
import Testing
@testable import LaunchUI

@Suite("Paging offset ownership", .serialized)
@MainActor
struct PagingOffsetOwnershipTests {
    private func source(named name: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = packageRoot
            .appendingPathComponent("Sources/LaunchUI")
            .appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func makeController(
        pageWidth: CGFloat = 640,
        pageCount: Int = 4
    ) -> (PagingInteractionController, NSView) {
        let controller = PagingInteractionController()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: pageWidth, height: 480))
        controller.linkView = view
        controller.onReadPageWidth = { pageWidth }
        controller.onReadPageCount = { pageCount }
        return (controller, view)
    }

    @Test("Grid keeps horizontal offset writes behind the paging writer")
    func gridHasSingleHorizontalOffsetWriter() throws {
        let grid = try source(named: "GridViewController.swift")

        #expect(!grid.contains("scrollToPage"))
        #expect(!grid.contains("private extension NSCollectionView"))
        #expect(grid.contains("paging.jumpTo(page: physicalSurfaceIndex)"))
        #expect(grid.contains("physicalIndex(forLayoutPage"))
        #expect(grid.contains("paging.jumpTo(page: 0)"))
        // P2: 唯一 offset writer 注入(routeScroll)+ compositor settle 完成的一次性
        // clip 同步(onSyncClip) + v0.5.2 settling 遮盖下渐进跟进
        // (advanceRealClipBehindCover, 由 routeScroll 在引擎帧内调用)——
        // 三处写都只由 PagingInteractionController 驱动。
        #expect(grid.components(separatedBy: "contentView.scroll(").count - 1 == 3)
        #expect(grid.contains("private func advanceRealClipBehindCover()"))
        #expect(grid.contains("private func routeScroll(_ offset: CGFloat)"))
        #expect(grid.contains("func readPagingOffset() -> CGFloat"))
    }

    @Test("jump cancels settle/display-link and writes the exact page offset")
    func jumpCancelsAnimationAndWritesExactOffset() {
        let (controller, linkView) = makeController()
        var currentOffset: CGFloat = 0
        var writes: [CGFloat] = []
        withExtendedLifetime(linkView) {
            controller.onReadCurrentOffset = { currentOffset }
            controller.onScroll = { offset in
                currentOffset = offset
                writes.append(offset)
            }

            controller.startSettle(toPage: 1)
            #expect(controller.phase == .settling)
            #expect(controller.isDisplayLinkActive)

            controller.jumpTo(page: 2)

            #expect(controller.phase == .idle)
            #expect(!controller.isDisplayLinkActive)
            #expect(currentOffset == 1_280)
            #expect(writes == [1_280])
            #expect(controller.scrollWriteCount == 1)

            let writesAfterJump = writes
            #expect(controller.probeDisplayFrame())
            #expect(writes == writesAfterJump)
        }
    }
}
