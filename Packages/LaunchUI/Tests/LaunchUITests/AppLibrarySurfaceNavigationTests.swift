import AppKit
import LaunchCore
import Testing
@testable import LaunchUI

/// Stage E8: leading App Library surface 接入后的 physical/semantic 映射契约。
///
/// 覆盖: snapshot section 顺序、默认物理 surface、goToPage 物理映射、翻页边界
/// (Page1 previous → Library, Library next → Page1)、paging 物理页数与文档宽、
/// 页点只计普通页、Search 恢复语义 surface、leading offset 下的 frame/拖拽坐标
/// 映射、Library host 非 drop target、普通 Folder/App 回归、无 Layout 状态变更。
@Suite("App Library surface navigation", .serialized)
@MainActor
struct AppLibrarySurfaceNavigationTests {
    private func makeApp(_ n: Int) -> AppID {
        AppID("/Applications/LibraryNav\(n).app")!
    }

    private func makeFolder(_ n: Int) -> FolderID {
        FolderID("/Applications/LibraryNavFolder\(n).app")!
    }

    private func makeThreePages() -> [[DisplayModel.DisplayItem]] {
        [
            [.app(makeApp(1)), .app(makeApp(2))],
            [.app(makeApp(3)), .app(makeApp(4))],
            [.app(makeApp(5)), .app(makeApp(6))],
        ]
    }

    private func makeGrid(
        pages: [[DisplayModel.DisplayItem]]
    ) -> GridSurfaceHarness {
        let store = LibraryNavTestStore(pages: pages)
        let grid = GridViewController(store: store, iconProvider: nil)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = grid.view
        window.layoutIfNeeded()
        grid.view.layoutSubtreeIfNeeded()
        grid.refresh()
        grid.view.layoutSubtreeIfNeeded()
        grid.collectionViewRef.layoutSubtreeIfNeeded()
        return GridSurfaceHarness(store: store, grid: grid, window: window)
    }

    private func clipOffsetX(_ grid: GridViewController) -> CGFloat {
        grid.collectionViewRef.enclosingScrollView?.contentView.bounds.origin.x ?? -1
    }

    private func windowPoint(_ documentPoint: NSPoint, on grid: GridViewController) -> NSPoint {
        grid.collectionViewRef.convert(documentPoint, to: nil)
    }

    // MARK: - Snapshot section ordering

    @Test("1 ordinary page: physical sections = [Library, Page0]")
    func onePageSnapshotSectionOrdering() throws {
        let harness = makeGrid(pages: [[.app(makeApp(1)), .app(makeApp(2))]])
        #expect(harness.grid.pageCountValue == 1)
        #expect(harness.grid.physicalSurfaceCount == 2)
        #expect(harness.grid.snapshotSectionCountsForDiag == [1, 2])
    }

    @Test("3 ordinary pages: Library 0, Page0 1, Page1 2, Page2 3")
    func threePageSnapshotSectionOrdering() throws {
        let harness = makeGrid(pages: makeThreePages())
        #expect(harness.grid.pageCountValue == 3)
        #expect(harness.grid.physicalSurfaceCount == 4)
        #expect(harness.grid.snapshotSectionCountsForDiag == [1, 2, 2, 2])
    }

    // MARK: - Default surface & goToPage physical mapping

    @Test("default surface is physical 1; goToPage(0) offset = pageWidth, not 0")
    func defaultSurfaceIsPhysicalOneAndGoToPageZeroLandsOnPageWidth() throws {
        let harness = makeGrid(pages: makeThreePages())
        let grid = harness.grid
        let pageWidth = grid.geometry.pageWidth

        #expect(grid.currentSurfaceValue == .layoutPage(0))
        #expect(grid.physicalSurfaceIndex == 1)
        #expect(clipOffsetX(grid) == pageWidth)

        grid.goToPage(0, animated: false)
        #expect(grid.currentPageValue == 0)
        #expect(grid.currentSurfaceValue == .layoutPage(0))
        #expect(grid.physicalSurfaceIndex == 1)
        #expect(clipOffsetX(grid) == pageWidth)
    }

    @Test("goToPage(2) is semantic 2 physical 3; previous Page0 enters Library; next returns")
    func goToPageMappingAndLibraryBoundaryNavigation() throws {
        let harness = makeGrid(pages: makeThreePages())
        let grid = harness.grid
        let pageWidth = grid.geometry.pageWidth

        grid.goToPage(2, animated: false)
        #expect(grid.currentPageValue == 2)
        #expect(grid.currentSurfaceValue == .layoutPage(2))
        #expect(grid.physicalSurfaceIndex == 3)
        #expect(clipOffsetX(grid) == 3 * pageWidth)

        grid.goToPage(0, animated: false)
        #expect(grid.physicalSurfaceIndex == 1)
        grid.previousPage()
        #expect(grid.currentSurfaceValue == .appLibrary)
        #expect(grid.physicalSurfaceIndex == 0)
        #expect(grid.currentPageValue == 0)

        grid.nextPage()
        #expect(grid.currentSurfaceValue == .layoutPage(0))
        #expect(grid.physicalSurfaceIndex == 1)
        #expect(grid.currentPageValue == 0)
    }

    // MARK: - Paging engine physical count & document width

    @Test("paging engine reads physical count; document width = physical count x pageWidth")
    func pagingPhysicalCountAndDocumentWidth() throws {
        let harness = makeGrid(pages: makeThreePages())
        let grid = harness.grid
        let layout = try #require(grid.collectionViewRef.collectionViewLayout as? PagingGridLayout)
        let pageWidth: CGFloat = grid.geometry.pageWidth

        #expect(grid.physicalSurfaceCount == 4)
        #expect(grid.pageCountValue == 3)
        #expect(layout.collectionViewContentSize.width == 4 * pageWidth)
        #expect(grid.collectionViewRef.frame.width == 4 * pageWidth)
        #expect(layout.collectionViewContentSize.width == CGFloat(grid.pageCountValue + 1) * pageWidth)
    }

    // MARK: - Page dots

    @Test("page dots count only ordinary pages; Library occupies no dot")
    func pageDotsCountOrdinaryPagesOnly() throws {
        let grid = makeGrid(pages: makeThreePages()).grid
        #expect(grid.pageDotCountForDiag == 3)

        grid.goToPage(2, animated: false)
        #expect(grid.pageDotCountForDiag == 3)

        grid.goToPage(0, animated: false)
        grid.previousPage()
        #expect(grid.currentSurfaceValue == .appLibrary)
        #expect(grid.pageDotCountForDiag == 0)

        grid.nextPage()
        #expect(grid.pageDotCountForDiag == 3)
    }

    @Test("single ordinary page shows no dots (pageCount > 1 required)")
    func singlePageShowsNoDots() throws {
        let grid = makeGrid(pages: [[.app(makeApp(1)), .app(makeApp(2))]]).grid
        #expect(grid.pageCountValue == 1)
        #expect(grid.pageDotCountForDiag == 0)
    }

    // MARK: - Search restore

    @Test("search from Library restores Library; search from Page2 restores Page2")
    func searchRestoresLibraryAndPageSurfaces() throws {
        let harness = makeGrid(pages: makeThreePages())
        let grid = harness.grid
        let store = harness.store

        // Library → Search → clear → Library
        grid.previousPage()
        #expect(grid.currentSurfaceValue == .appLibrary)
        store.searchResultsValue = [.app(makeApp(9))]
        store.revision &+= 1
        grid.refresh()
        #expect(grid.isSearchMode)
        store.searchResultsValue = nil
        store.revision &+= 1
        grid.refresh()
        #expect(!grid.isSearchMode)
        #expect(grid.currentSurfaceValue == .appLibrary)
        #expect(grid.physicalSurfaceIndex == 0)

        // Page2 → Search → clear → Page2
        grid.nextPage()
        grid.goToPage(2, animated: false)
        #expect(grid.currentSurfaceValue == .layoutPage(2))
        store.searchResultsValue = [.app(makeApp(9))]
        store.revision &+= 1
        grid.refresh()
        #expect(grid.isSearchMode)
        store.searchResultsValue = nil
        store.revision &+= 1
        grid.refresh()
        #expect(!grid.isSearchMode)
        #expect(grid.currentSurfaceValue == .layoutPage(2))
        #expect(grid.currentPageValue == 2)
        #expect(grid.physicalSurfaceIndex == 3)
    }

    @Test("search mode hides page dots")
    func searchModeHidesPageDots() throws {
        let harness = makeGrid(pages: makeThreePages())
        let grid = harness.grid
        #expect(grid.pageDotCountForDiag == 3)
        harness.store.searchResultsValue = [.app(makeApp(9))]
        harness.store.revision &+= 1
        grid.refresh()
        #expect(grid.isSearchMode)
        #expect(grid.pageDotCountForDiag == 0)
    }

    // MARK: - Leading-offset coordinate mapping

    @Test("ordinary frame/flatIndex/indexPath map through leading pageWidth, not off by one")
    func leadingOffsetFrameAndIndexMapping() throws {
        let grid = makeGrid(pages: makeThreePages()).grid
        let g = grid.geometry
        let pageWidth = g.pageWidth

        #expect(grid.flatIndex(of: .app(makeApp(1))) == 0)
        #expect(grid.flatIndex(of: .app(makeApp(6))) == 5)

        #expect(grid.indexPath(atFlatIndex: 0) == IndexPath(item: 0, section: 1))
        #expect(grid.indexPath(atFlatIndex: 3) == IndexPath(item: 1, section: 2))
        #expect(grid.indexPath(atFlatIndex: 5) == IndexPath(item: 1, section: 3))

        #expect(grid.frame(atFlatIndex: 0).minX == pageWidth + g.frame(forSlot: 0, in: 0).minX)
        #expect(grid.frame(atFlatIndex: 2).minX == pageWidth + g.frame(forSlot: 0, in: 1).minX)
        #expect(grid.frame(atFlatIndex: 5).minX == pageWidth + g.frame(forSlot: 1, in: 2).minX)

        // dragDestination: 文档点(含 leading offset) → 普通 Layout page/slot 不偏一页。
        let docPoint = NSPoint(
            x: pageWidth + g.frame(forSlot: 1, in: 1).midX,
            y: g.frame(forSlot: 1, in: 1).midY
        )
        let destination = grid.dragDestination(from: windowPoint(docPoint, on: grid))
        #expect(destination == LayoutTransaction.Destination(page: 1, slot: 1))

        // currentPageRect 包含 leading 文档偏移(与图标 frame 无关)。
        grid.goToPage(1, animated: false)
        #expect(grid.currentPageRect.minX == 2 * pageWidth)
    }

    @Test("Library host is not a drop target; hit tests return nil/.none over physical page 0")
    func libraryHostIsNotDropTarget() throws {
        let grid = makeGrid(pages: makeThreePages()).grid
        let pageWidth = grid.geometry.pageWidth
        let libraryWindowPoint = windowPoint(
            NSPoint(x: pageWidth / 2, y: 100), on: grid
        )

        #expect(grid.itemAt(point: libraryWindowPoint) == nil)
        #expect(grid.hoveredFolder(at: libraryWindowPoint) == nil)
        #expect(grid.dragHitTarget(at: libraryWindowPoint) == .none)

        // 拖拽中指针进入 Library 区域 → 源项自身槽位(自落点 no-op)。
        let source: DisplayModel.DisplayItem = .app(makeApp(1))
        grid.beginDragSource(for: source)
        let destination = grid.dragDestination(from: libraryWindowPoint)
        #expect(destination == LayoutTransaction.Destination(page: 0, slot: 0))
        grid.endDragSource(for: source)
        #expect(!grid.hasHiddenDragSourceForDiag)

        // Library active 时同样拒绝普通落点。
        grid.previousPage()
        #expect(grid.currentSurfaceValue == .appLibrary)
        let ordinaryWindowPoint = windowPoint(
            NSPoint(x: pageWidth + pageWidth / 2, y: 100), on: grid
        )
        #expect(
            grid.dragDestination(from: ordinaryWindowPoint)
                == LayoutTransaction.Destination(page: 0, slot: 0)
        )
    }

    @Test("hit tests over ordinary pages still resolve apps")
    func ordinaryHitTestsStillResolve() throws {
        let grid = makeGrid(pages: makeThreePages()).grid
        let g = grid.geometry
        let pageWidth = g.pageWidth

        let appDocPoint = NSPoint(
            x: pageWidth + g.frame(forSlot: 0, in: 0).midX,
            y: g.frame(forSlot: 0, in: 0).midY
        )
        let appWindowPoint = windowPoint(appDocPoint, on: grid)
        #expect(grid.itemAt(point: appWindowPoint) == .app(makeApp(1)))
        #expect(grid.dragHitTarget(at: appWindowPoint) == .app(makeApp(1)))
    }

    // MARK: - Ordinary Folder/App regression

    @Test("allItems returns ordinary DisplayItems only; folder hit-test/indexPath/drag regression")
    func ordinaryFolderAndAppRegression() throws {
        let grid = makeGrid(pages: [
            [.app(makeApp(1)), .folder(makeFolder(1))],
            [.app(makeApp(2)), .app(makeApp(3))],
        ]).grid
        let g = grid.geometry
        let pageWidth = g.pageWidth

        // allItems 只含普通 DisplayItem(host 不进入, 无 wrapper 泄漏)。
        #expect(
            grid.allItems()
                == [
                    .app(makeApp(1)),
                    .folder(makeFolder(1)),
                    .app(makeApp(2)),
                    .app(makeApp(3)),
                ]
        )

        // Folder 身份 / flat / indexPath 正常(物理 section = 普通页 + 1)。
        #expect(grid.flatIndex(of: .folder(makeFolder(1))) == 1)
        #expect(grid.indexPath(atFlatIndex: 1) == IndexPath(item: 1, section: 1))

        // hoveredFolder 在 leading offset 下命中普通文件夹。
        let folderDocPoint = NSPoint(
            x: pageWidth + g.frame(forSlot: 1, in: 0).midX,
            y: g.frame(forSlot: 1, in: 0).midY
        )
        #expect(grid.hoveredFolder(at: windowPoint(folderDocPoint, on: grid)) == makeFolder(1))

        // 可见普通项(物理 section 1)存在; 无 icon provider 时拖拽表示可为 nil,
        // 只断言源登记/释放路径安全。
        let appCell = try #require(
            grid.cellView(at: IndexPath(item: 0, section: 1)) as? AppCellView
        )
        _ = appCell
        let folderSource = try #require(
            grid.folderTransitionSource(for: makeFolder(1), in: grid.view)
        )
        #expect(folderSource.folderID == makeFolder(1))

        // 拖拽源身份登记/释放安全。
        grid.beginDragSource(for: .app(makeApp(1)))
        #expect(grid.hasHiddenDragSourceForDiag)
        grid.endDragSource(for: .app(makeApp(1)))
        #expect(!grid.hasHiddenDragSourceForDiag)
        grid.beginDragSource(for: .folder(makeFolder(1)))
        #expect(grid.hasHiddenDragSourceForDiag)
        grid.endDragSource(for: .folder(makeFolder(1)))
        #expect(!grid.hasHiddenDragSourceForDiag)
    }

    // MARK: - No layout persistence mutation

    @Test("grid never mutates LayoutSnapshot/LayoutStore/AppRecord state")
    func noLayoutStateMutation() throws {
        let grid = try codeOnly(source(named: "GridViewController.swift"))
        #expect(!grid.contains("LayoutSnapshot("))
        #expect(!grid.contains("LayoutStore"))
        #expect(!grid.contains("AppRecord"))
    }

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

    /// 去掉行/块注释后再匹配: 文档注释提及类型名不构成误报,
    /// 检查目标仍是生产代码而非注释文本。
    private func codeOnly(_ source: String) -> String {
        var result = ""
        var index = source.startIndex
        while index < source.endIndex {
            let rest = source[index...]
            if rest.hasPrefix("//") {
                if let newline = rest.firstIndex(of: "\n") {
                    index = newline
                } else {
                    break
                }
            } else if rest.hasPrefix("/*") {
                if let end = rest.range(of: "*/")?.upperBound {
                    index = end
                } else {
                    break
                }
            } else {
                result.append(rest.first!)
                index = source.index(after: index)
            }
        }
        return result
    }
}

@MainActor
private struct GridSurfaceHarness {
    let store: LibraryNavTestStore
    let grid: GridViewController
    let window: NSWindow
}

@MainActor
private final class LibraryNavTestStore: LauncherStoring, AppLibraryDataProviding {
    var pages: [[DisplayModel.DisplayItem]]
    var searchResultsValue: [DisplayModel.DisplayItem]?
    var revision: UInt64 = 1

    var onDataChange: (() -> Void)?
    var searchQuery = ""
    let gridColumns = 2
    let gridRows = 1
    let iconSize = 64
    let wallpaperBlurRadius = 30
    let searchBarWidth = 320
    var displayRevision: UInt64 { revision }

    init(pages: [[DisplayModel.DisplayItem]]) {
        self.pages = pages
    }

    @discardableResult
    func addDataObserver(_ observer: @escaping () -> Void) -> UUID { UUID() }

    func removeDataObserver(_ token: UUID) {}

    func displayModel() -> DisplayModel {
        DisplayModel(pages: pages, pageCapacity: gridColumns * gridRows)
    }

    func searchResults() -> [DisplayModel.DisplayItem]? { searchResultsValue }
    func displayName(for appID: AppID) -> String { appID.rawValue }
    func folderName(for folderID: FolderID) -> String { folderID.rawValue }
    func launch(_ appID: AppID) {}
    func createFolder(name: String, appIDs: [AppID]) {}
    func renameFolder(_ id: FolderID, to name: String) {}
    func dissolveFolder(_ id: FolderID) {}
    func addToFolder(app: AppID, folder: FolderID) {}
    func moveOutOfFolder(
        app: AppID,
        from folder: FolderID,
        toDisplayIndex: Int,
        completion: @escaping (Bool) -> Void
    ) { completion(false) }
    func reorderFolderApp(app: AppID, in folder: FolderID, toIndex: Int) {}
    func folderNames() -> [FolderID: String] { [:] }
    func folderChildren(_ id: FolderID) -> [AppID]? { nil }
    func applyDragDrop(_ mutation: LayoutTransaction.LayoutMutation) {}
    func setHidden(_ appID: AppID, hidden: Bool) {}
    func setCustomName(_ appID: AppID, name: String?) {}
    func moveToTrash(_ appID: AppID) {}
    func isHidden(_ appID: AppID) -> Bool { false }

    func appLibraryModel() -> AppLibraryModel {
        AppLibraryModel(cards: [], categoryDetail: [:])
    }
}
