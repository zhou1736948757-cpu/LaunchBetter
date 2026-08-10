import AppKit
import LaunchCore
import Testing
@testable import LaunchUI

@Suite("Drag representation and source ownership")
@MainActor
struct DragRepresentationTests {
    @Test("folder representation is rendered in memory at the current backing scale")
    func folderRepresentationUsesPixelScale() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 180),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        let cell = AppCellView()
        window.contentView = cell.view
        window.layoutIfNeeded()
        cell.view.layoutSubtreeIfNeeded()
        cell.configureFolder(
            displayName: "Folder",
            accessibilityHint: "Folder",
            folderID: FolderID("folder://representation-test")!,
            children: [],
            pointSize: 64,
            iconProvider: nil
        )
        cell.view.layoutSubtreeIfNeeded()

        let representation = try #require(cell.dragRepresentation())
        let scale = max(1, window.backingScaleFactor)
        #expect(representation.rasterScale == scale)
        #expect(representation.logicalSize.width > 0)
        #expect(representation.logicalSize.height > 0)
        #expect(
            representation.image.width
                == Int(ceil(representation.logicalSize.width * representation.rasterScale))
        )
        #expect(
            representation.image.height
                == Int(ceil(representation.logicalSize.height * representation.rasterScale))
        )

        let overlay = DragOverlayLayer()
        overlay.configure(label: "Folder", representation: representation)
        #expect(overlay.layer.contentsScale == representation.rasterScale)
        #expect(overlay.layer.sublayers?.first?.contentsScale == representation.rasterScale)
    }

    @Test("active source identity is reapplied when cells are reconfigured")
    func sourceIdentitySurvivesReconfiguration() throws {
        let first = AppID("/Applications/DragSourceA.app")!
        let second = AppID("/Applications/DragSourceB.app")!
        let store = DragSourceTestStore(items: [.app(first), .app(second)])
        let grid = GridViewController(store: store, iconProvider: nil)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        defer {
            grid.endDragSource(for: .app(first))
            window.orderOut(nil)
            window.contentView = nil
        }

        window.contentView = grid.view
        window.layoutIfNeeded()
        grid.view.layoutSubtreeIfNeeded()
        grid.forceRefresh()
        grid.view.layoutSubtreeIfNeeded()

        _ = grid.beginDragSource(for: .app(first))
        let initialCell = try #require(
            grid.cellView(at: IndexPath(item: 0, section: 0)) as? AppCellView
        )
        #expect(initialCell.view.layer?.opacity == 0)

        store.items = [.app(second), .app(first)]
        store.revision &+= 1
        grid.applyGeometryConfig(
            columns: store.gridColumns,
            rows: store.gridRows,
            iconSize: store.iconSize
        )
        grid.view.layoutSubtreeIfNeeded()

        let reconfiguredOther = try #require(
            grid.cellView(at: IndexPath(item: 0, section: 0)) as? AppCellView
        )
        let reconfiguredSource = try #require(
            grid.cellView(at: IndexPath(item: 1, section: 0)) as? AppCellView
        )
        #expect(reconfiguredOther.view.layer?.opacity == 1)
        #expect(reconfiguredSource.view.layer?.opacity == 0)

        grid.endDragSource(for: .app(first))
        #expect(reconfiguredSource.view.layer?.opacity == 1)
    }

    @Test("root drop waits for persistence result and restores source on failure")
    func rootDropWaitsForPersistence() throws {
        let first = AppID("/Applications/PendingSource.app")!
        let second = AppID("/Applications/PendingTarget.app")!
        let store = DragSourceTestStore(items: [.app(first), .app(second)])
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
        let sourceFrame = grid.frame(atFlatIndex: 0)
        let targetFrame = grid.frame(atFlatIndex: 1)
        let sourcePoint = grid.collectionViewRef.convert(
            NSPoint(x: sourceFrame.midX, y: sourceFrame.midY),
            to: nil
        )
        let targetPoint = grid.collectionViewRef.convert(
            NSPoint(x: targetFrame.midX, y: targetFrame.midY),
            to: nil
        )

        drag.beginDrag(item: .app(first), at: sourcePoint)
        drag.endDrag(at: targetPoint)

        #expect(drag.isDragging)
        let sourceCell = try #require(
            grid.cellView(at: IndexPath(item: 0, section: 0)) as? AppCellView
        )
        #expect(sourceCell.view.layer?.opacity == 0)
        let pending = try #require(store.pendingMutationCompletion)
        pending(false)
        #expect(!drag.isDragging)
        #expect(sourceCell.view.layer?.opacity == 1)
    }

    @Test("cancelling a pending root drop permits a new drag and rejects the late result")
    func cancelledPendingRootDropDoesNotPoisonNextSession() throws {
        let first = AppID("/Applications/CancelledSource.app")!
        let second = AppID("/Applications/CancelledTarget.app")!
        let store = DragSourceTestStore(items: [.app(first), .app(second)])
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
        let sourceFrame = grid.frame(atFlatIndex: 0)
        let targetFrame = grid.frame(atFlatIndex: 1)
        let sourcePoint = grid.collectionViewRef.convert(
            NSPoint(x: sourceFrame.midX, y: sourceFrame.midY),
            to: nil
        )
        let targetPoint = grid.collectionViewRef.convert(
            NSPoint(x: targetFrame.midX, y: targetFrame.midY),
            to: nil
        )

        drag.beginDrag(item: .app(first), at: sourcePoint)
        drag.endDrag(at: targetPoint)
        let staleCompletion = try #require(store.pendingMutationCompletion)
        drag.cancelDrag()
        #expect(!drag.isDragging)

        drag.beginDrag(item: .app(first), at: sourcePoint)
        drag.endDrag(at: targetPoint)
        let currentCompletion = try #require(store.pendingMutationCompletion)
        #expect(drag.isDragging)

        staleCompletion(true)
        #expect(drag.isDragging)
        currentCompletion(false)
        #expect(!drag.isDragging)
    }
}

@MainActor
private final class DragSourceTestStore: LauncherStoring, LayoutMutationCompleting {
    var items: [DisplayModel.DisplayItem]
    var revision: UInt64 = 1
    var onDataChange: (() -> Void)?
    var searchQuery = ""
    let gridColumns = 2
    let gridRows = 1
    let iconSize = 64
    var wallpaperBlurRadius: Int { 30 }
    var searchBarWidth: Int { 320 }
    var pendingMutationCompletion: ((Bool) -> Void)?

    init(items: [DisplayModel.DisplayItem]) {
        self.items = items
    }

    @discardableResult
    func addDataObserver(_ observer: @escaping () -> Void) -> UUID {
        UUID()
    }

    func removeDataObserver(_ token: UUID) {}

    var displayRevision: UInt64 { revision }

    func displayModel() -> DisplayModel {
        DisplayModel(pages: [items], pageCapacity: gridColumns * gridRows)
    }

    func searchResults() -> [DisplayModel.DisplayItem]? { nil }
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
    ) {
        completion(false)
    }
    func reorderFolderApp(app: AppID, in folder: FolderID, toIndex: Int) {}
    func folderNames() -> [FolderID: String] { [:] }
    func folderChildren(_ id: FolderID) -> [AppID]? { nil }
    func applyDragDrop(_ mutation: LayoutTransaction.LayoutMutation) {}
    func createFolder(
        name: String,
        appIDs: [AppID],
        completion: @escaping (Bool) -> Void
    ) {
        pendingMutationCompletion = completion
    }
    func renameFolder(
        _ id: FolderID,
        to name: String,
        completion: @escaping (Bool) -> Void
    ) {
        completion(false)
    }
    func dissolveFolder(_ id: FolderID, completion: @escaping (Bool) -> Void) {
        completion(false)
    }
    func addToFolder(
        app: AppID,
        folder: FolderID,
        completion: @escaping (Bool) -> Void
    ) {
        pendingMutationCompletion = completion
    }
    func reorderFolderApp(
        app: AppID,
        in folder: FolderID,
        toIndex: Int,
        completion: @escaping (Bool) -> Void
    ) {
        completion(false)
    }
    func applyDragDrop(
        _ mutation: LayoutTransaction.LayoutMutation,
        completion: @escaping (Bool) -> Void
    ) {
        pendingMutationCompletion = completion
    }
    func setHidden(_ appID: AppID, hidden: Bool) {}
    func setCustomName(_ appID: AppID, name: String?) {}
    func moveToTrash(_ appID: AppID) {}
    func isHidden(_ appID: AppID) -> Bool { false }
}
