import AppKit
import LaunchCore
import Testing
@testable import LaunchUI

/// A2/A3: source-cell hiding is identity-owned (per-frame setDragSourceHidden removed),
/// and the drag hot path performs exactly one hit-test classification per frame.
@Suite("Drag hot path: source hiding + single hit-test")
@MainActor
struct DragHotPathTests {
    // MARK: - A2: source hiding

    @Test("source is hidden immediately at beginDrag and no other cell is hidden")
    func sourceHiddenImmediatelyAndOnlySource() throws {
        let first = AppID("/Applications/HotPathA.app")!
        let second = AppID("/Applications/HotPathB.app")!
        let third = AppID("/Applications/HotPathC.app")!
        let (window, grid, drag) = try makeDragSession(
            items: [.app(first), .app(second), .app(third)]
        )
        defer {
            drag.cancelDrag()
            window.orderOut(nil)
            window.contentView = nil
        }

        let sourcePoint = try gridPoint(grid, atFlatIndex: 0)
        drag.beginDrag(item: .app(first), at: sourcePoint)
        #expect(drag.isDragging)

        let sourceCell = try #require(
            grid.cellView(at: IndexPath(item: 0, section: 0)) as? AppCellView
        )
        let otherCell = try #require(
            grid.cellView(at: IndexPath(item: 1, section: 0)) as? AppCellView
        )
        let otherCell2 = try #require(
            grid.cellView(at: IndexPath(item: 2, section: 0)) as? AppCellView
        )
        #expect(sourceCell.view.layer?.opacity == 0)
        #expect(otherCell.view.layer?.opacity == 1)
        #expect(otherCell2.view.layer?.opacity == 1)
    }

    @Test("source stays hidden after cross-page navigation and reconfiguration")
    func sourceHiddenSurvivesCrossPage() throws {
        let store = DragHotPathTestStore(items: pageItems(4))
        let grid = GridViewController(store: store, iconProvider: nil)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        window.contentView = grid.view
        window.layoutIfNeeded()
        grid.view.layoutSubtreeIfNeeded()
        grid.forceRefresh()
        grid.view.layoutSubtreeIfNeeded()
        #expect(grid.pageCountValue == 2)

        let first = try #require(store.item(at: 0))
        let drag = DragController(grid: grid, store: store)
        defer { drag.cancelDrag() }

        let sourcePoint = try gridPoint(grid, atFlatIndex: 0)
        drag.beginDrag(item: first, at: sourcePoint)
        let sourceCell = try #require(
            grid.cellView(at: IndexPath(item: 0, section: 0)) as? AppCellView
        )
        #expect(sourceCell.view.layer?.opacity == 0)

        grid.goToPage(1, animated: false)
        grid.view.layoutSubtreeIfNeeded()
        grid.goToPage(0, animated: false)
        grid.view.layoutSubtreeIfNeeded()

        let backOnSource = try #require(
            grid.cellView(at: IndexPath(item: 0, section: 0)) as? AppCellView
        )
        #expect(backOnSource.view.layer?.opacity == 0)
        let page0Other = try #require(
            grid.cellView(at: IndexPath(item: 1, section: 0)) as? AppCellView
        )
        #expect(page0Other.view.layer?.opacity == 1)
    }

    @Test("cancel restores the source cell opacity")
    func cancelRestoresSource() throws {
        let first = AppID("/Applications/CancelSource.app")!
        let second = AppID("/Applications/CancelTarget.app")!
        let (window, grid, drag) = try makeDragSession(
            items: [.app(first), .app(second)]
        )
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        let sourcePoint = try gridPoint(grid, atFlatIndex: 0)
        drag.beginDrag(item: .app(first), at: sourcePoint)
        let sourceCell = try #require(
            grid.cellView(at: IndexPath(item: 0, section: 0)) as? AppCellView
        )
        #expect(sourceCell.view.layer?.opacity == 0)

        drag.cancelDrag()
        #expect(!drag.isDragging)
        #expect(sourceCell.view.layer?.opacity == 1)
    }

    @Test("successful drop restores the source cell opacity after persistence")
    func successfulDropRestoresSource() throws {
        let first = AppID("/Applications/SuccessSource.app")!
        let second = AppID("/Applications/SuccessTarget.app")!
        let store = CompletingDragHotPathStore(items: [.app(first), .app(second)])
        let grid = GridViewController(store: store, iconProvider: nil)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        window.contentView = grid.view
        window.layoutIfNeeded()
        grid.view.layoutSubtreeIfNeeded()
        grid.forceRefresh()
        grid.view.layoutSubtreeIfNeeded()

        let drag = DragController(grid: grid, store: store)
        let sourcePoint = try gridPoint(grid, atFlatIndex: 0)
        let targetPoint = try gridPoint(grid, atFlatIndex: 1)
        drag.beginDrag(item: .app(first), at: sourcePoint)
        drag.endDrag(at: targetPoint)
        let sourceCell = try #require(
            grid.cellView(at: IndexPath(item: 0, section: 0)) as? AppCellView
        )
        #expect(drag.isDragging)
        #expect(sourceCell.view.layer?.opacity == 0)

        let completion = try #require(store.pendingApplyDragDrop)
        completion(true)
        #expect(!drag.isDragging)
        #expect(sourceCell.view.layer?.opacity == 1)
    }

    // MARK: - A3: single hit-test per frame

    @Test("one processTick performs exactly one dragHitTarget classification")
    func oneHitTestPerTick() throws {
        let first = AppID("/Applications/HitCountA.app")!
        let second = AppID("/Applications/HitCountB.app")!
        let third = AppID("/Applications/HitCountC.app")!
        let (window, grid, drag) = try makeDragSession(
            items: [.app(first), .app(second), .app(third)]
        )
        defer {
            drag.cancelDrag()
            window.orderOut(nil)
            window.contentView = nil
        }

        let sourcePoint = try gridPoint(grid, atFlatIndex: 0)
        drag.beginDrag(item: .app(first), at: sourcePoint)
        let before = grid.dragHitTargetQueryCount

        let gapPoint = try #require(grid.dragCacheProbePoint())
        drag.probeProcessTick(gapPoint)

        #expect(grid.dragHitTargetQueryCount - before == 1)
    }

    @Test("dragHitTarget classifies app, folder and none correctly")
    func dragHitTargetClassification() throws {
        let first = AppID("/Applications/ClassifyA.app")!
        let folderID = FolderID("folder://classify")!
        let second = AppID("/Applications/ClassifyB.app")!
        let (window, grid, _) = try makeDragSession(
            items: [
                .app(first),
                .folder(folderID, visibleChildren: [second]),
                .app(second),
            ]
        )
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        let appPoint = try gridPoint(grid, atFlatIndex: 0)
        #expect(grid.dragHitTarget(at: appPoint) == .app(first))

        let folderPoint = try gridPoint(grid, atFlatIndex: 1)
        #expect(grid.dragHitTarget(at: folderPoint) == .folder(folderID))

        let gapPoint = try #require(grid.dragCacheProbePoint())
        #expect(grid.dragHitTarget(at: gapPoint) == .none)
    }

    @Test("dropping an app onto a folder derives the folder from the single hit-test")
    func dropDerivesFolderFromSingleHitTest() throws {
        let first = AppID("/Applications/FolderDropSource.app")!
        let folderID = FolderID("folder://drop")!
        let child = AppID("/Applications/FolderDropChild.app")!
        let store = DragHotPathTestStore(
            items: [.app(first), .folder(folderID, visibleChildren: [child])]
        )
        let grid = GridViewController(store: store, iconProvider: nil)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        window.contentView = grid.view
        window.layoutIfNeeded()
        grid.view.layoutSubtreeIfNeeded()
        grid.forceRefresh()
        grid.view.layoutSubtreeIfNeeded()

        let drag = DragController(grid: grid, store: store)
        let sourcePoint = try gridPoint(grid, atFlatIndex: 0)
        let folderPoint = try gridPoint(grid, atFlatIndex: 1)
        drag.beginDrag(item: .app(first), at: sourcePoint)
        drag.endDrag(at: folderPoint)

        #expect(!drag.isDragging)
        #expect(store.lastAddToFolderApp == first)
        #expect(store.lastAddToFolderFolder == folderID)
    }

    // MARK: - Helpers

    private func makeDragSession(
        items: [DisplayModel.DisplayItem]
    ) throws -> (NSWindow, GridViewController, DragController) {
        let store = DragHotPathTestStore(items: items)
        let grid = GridViewController(store: store, iconProvider: nil)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = grid.view
        window.layoutIfNeeded()
        grid.view.layoutSubtreeIfNeeded()
        grid.forceRefresh()
        grid.view.layoutSubtreeIfNeeded()
        return (window, grid, DragController(grid: grid, store: store))
    }

    private func gridPoint(
        _ grid: GridViewController,
        atFlatIndex index: Int
    ) throws -> NSPoint {
        let frame = grid.frame(atFlatIndex: index)
        return grid.collectionViewRef.convert(
            NSPoint(x: frame.midX, y: frame.midY),
            to: nil
        )
    }

    private func pageItems(_ count: Int) -> [DisplayModel.DisplayItem] {
        (0..<count).map {
            .app(AppID("/Applications/Page\($0).app")!)
        }
    }
}

@MainActor
private class DragHotPathTestStore: LauncherStoring {
    var items: [DisplayModel.DisplayItem]
    var revision: UInt64 = 1
    var onDataChange: (() -> Void)?
    var searchQuery = ""
    let gridColumns = 3
    let gridRows = 1
    let iconSize = 64
    var lastAddToFolderApp: AppID?
    var lastAddToFolderFolder: FolderID?

    init(items: [DisplayModel.DisplayItem]) {
        self.items = items
    }

    @discardableResult
    func addDataObserver(_ observer: @escaping () -> Void) -> UUID { UUID() }

    func removeDataObserver(_ token: UUID) {}

    var displayRevision: UInt64 { revision }

    func displayModel() -> DisplayModel {
        let capacity = gridColumns * gridRows
        var pages: [[DisplayModel.DisplayItem]] = []
        var index = 0
        while index < items.count {
            let end = min(index + capacity, items.count)
            pages.append(Array(items[index..<end]))
            index = end
        }
        return DisplayModel(pages: pages, pageCapacity: capacity)
    }

    func searchResults() -> [DisplayModel.DisplayItem]? { nil }
    func displayName(for appID: AppID) -> String { appID.rawValue }
    func folderName(for folderID: FolderID) -> String { folderID.rawValue }
    func launch(_ appID: AppID) {}
    func createFolder(name: String, appIDs: [AppID]) {}
    func renameFolder(_ id: FolderID, to name: String) {}
    func dissolveFolder(_ id: FolderID) {}
    func addToFolder(app: AppID, folder: FolderID) {
        lastAddToFolderApp = app
        lastAddToFolderFolder = folder
    }
    func moveOutOfFolder(
        app: AppID,
        from folder: FolderID,
        toDisplayIndex: Int,
        completion: @escaping (Bool) -> Void
    ) {
        completion(false)
    }
    func reorderFolderApp(app: AppID, in folder: FolderID, toIndex: Int) {}
    func folderNames() -> [FolderID: String] { [:] }
    func folderChildren(_ id: FolderID) -> [AppID]? { nil }
    func applyDragDrop(_ mutation: LayoutTransaction.LayoutMutation) {}
    func setHidden(_ appID: AppID, hidden: Bool) {}
    func setCustomName(_ appID: AppID, name: String?) {}
    func moveToTrash(_ appID: AppID) {}
    func isHidden(_ appID: AppID) -> Bool { false }

    func item(at index: Int) -> DisplayModel.DisplayItem? {
        items.indices.contains(index) ? items[index] : nil
    }
}

@MainActor
private final class CompletingDragHotPathStore: DragHotPathTestStore, LayoutMutationCompleting {
    var pendingApplyDragDrop: ((Bool) -> Void)?

    override init(items: [DisplayModel.DisplayItem]) {
        super.init(items: items)
    }

    func applyDragDrop(
        _ mutation: LayoutTransaction.LayoutMutation,
        completion: @escaping (Bool) -> Void
    ) {
        pendingApplyDragDrop = completion
    }

    func createFolder(
        name: String,
        appIDs: [AppID],
        completion: @escaping (Bool) -> Void
    ) {
        completion(false)
    }

    func renameFolder(_ id: FolderID, to name: String, completion: @escaping (Bool) -> Void) {
        completion(false)
    }

    func dissolveFolder(_ id: FolderID, completion: @escaping (Bool) -> Void) {
        completion(false)
    }

    func addToFolder(app: AppID, folder: FolderID, completion: @escaping (Bool) -> Void) {
        completion(false)
    }

    func reorderFolderApp(
        app: AppID,
        in folder: FolderID,
        toIndex: Int,
        completion: @escaping (Bool) -> Void
    ) {
        completion(false)
    }
}
