import AppKit
import LaunchCore
import Testing
@testable import LaunchUI

@Suite("Folder exit mouse session")
@MainActor
struct FolderExitMouseSessionTests {
    @Test("handoff keeps the original collection-view event chain alive until mouse-up")
    func handoffDoesNotHideMouseOwnerAncestor() throws {
        let store = FolderExitTestStore()
        let folder = FolderViewController(store: store, iconProvider: nil, folderID: store.folderID)
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

        window.contentView = folder.view
        window.layoutIfNeeded()
        folder.view.layoutSubtreeIfNeeded()

        let collectionView = try #require(descendant(of: folder.view, as: ClickableCollectionView.self))
        collectionView.layoutSubtreeIfNeeded()
        let layout = try #require(collectionView.collectionViewLayout as? PagingGridLayout)
        layout.prepare()
        let attributes = try #require(
            layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))
        )
        let start = collectionView.convert(
            NSPoint(x: attributes.frame.midX, y: attributes.frame.midY), to: nil
        )
        let outside = NSPoint(x: 20, y: 300)

        var handoffCount = 0
        var moveCount = 0
        var endCount = 0
        var pendingResult: ((Bool) -> Void)?
        folder.onDragExit = { app, folderID, _, _ in
            handoffCount += 1
            return app == store.appID && folderID == store.folderID
        }
        folder.onDragExitMove = { _ in
            moveCount += 1
        }
        folder.onDragExitEnd = { _, completion in
            endCount += 1
            pendingResult = completion
        }

        collectionView.mouseDown(with: mouseEvent(.leftMouseDown, at: start, window: window))
        collectionView.mouseDragged(
            with: mouseEvent(
                .leftMouseDragged,
                at: NSPoint(x: start.x + 8, y: start.y),
                window: window
            )
        )
        collectionView.mouseDragged(
            with: mouseEvent(.leftMouseDragged, at: outside, window: window)
        )
        collectionView.mouseUp(with: mouseEvent(.leftMouseUp, at: outside, window: window))

        #expect(handoffCount == 1)
        #expect(moveCount == 1)
        #expect(endCount == 1)

        let ancestors = ancestorChain(of: collectionView)
        #expect(ancestors.allSatisfy { !$0.isHidden })
        let transparentAncestor = ancestors.first { $0.alphaValue == 0 }
        #expect(transparentAncestor != nil)
        #expect(transparentAncestor?.isHidden == false)

        // Resolve the held result so the test leaves the folder session clean.
        pendingResult?(false)
    }

    @Test("folder-exit handoff defers the first full tick to the display link")
    func handoffDefersFirstFullTick() throws {
        let store = FolderExitTestStore()
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

        let drag = DragController(grid: grid, store: store)
        defer {
            drag.cancelDrag()
            window.orderOut(nil)
            window.contentView = nil
        }

        #expect(
            drag.beginFolderExitDrag(
                app: store.appID,
                from: store.folderID,
                representation: nil,
                at: NSPoint(x: 400, y: 300)
            )
        )
        #expect(drag.destinationChangeCount == 0)

        drag.probeProcessTick(NSPoint(x: 400, y: 300))
        #expect(drag.destinationChangeCount == 1)
    }

    @Test("three-finger handoff accepts mouse move and mouse-up")
    func handoffAcceptsMouseContinuation() {
        let store = FolderExitTestStore()
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

        let drag = DragController(grid: grid, store: store)
        defer {
            drag.cancelDrag()
            window.orderOut(nil)
            window.contentView = nil
        }

        let point = NSPoint(x: 120, y: 180)
        drag.beginDrag(
            item: .folder(store.folderID),
            at: point,
            inputSource: .threeFinger
        )
        #expect(drag.isDragging)
        #expect(drag.activeInputSource == .threeFinger)

        drag.endDrag(
            at: point,
            inputSource: .threeFinger,
            leftMouseButtonPressed: true
        )
        #expect(drag.isDragging)
        #expect(drag.activeInputSource == .mouse)
        #expect(drag.updateDrag(at: NSPoint(x: 160, y: 200), inputSource: .mouse))

        drag.endDrag(at: NSPoint(x: 160, y: 200), inputSource: .mouse)
        #expect(!drag.isDragging)
    }
}

@MainActor
private final class FolderExitTestStore: LauncherStoring {
    let appID = AppID("/Applications/FolderChild.app")!
    let folderID = FolderID("folder://test")!

    var onDataChange: (() -> Void)?
    var searchQuery = ""
    let gridColumns = 7
    let gridRows = 6
    let iconSize = 64
    var wallpaperBlurRadius: Int { 30 }
    var searchBarWidth: Int { 320 }
    let displayRevision: UInt64 = 1

    private var observers: [UUID: () -> Void] = [:]

    @discardableResult
    func addDataObserver(_ observer: @escaping () -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    func removeDataObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    func displayModel() -> DisplayModel {
        DisplayModel(
            pages: [[.folder(folderID)]],
            pageCapacity: gridColumns * gridRows,
            folderChildrenPayload: [folderID: [appID]]
        )
    }

    func searchResults() -> [DisplayModel.DisplayItem]? { nil }
    func displayName(for appID: AppID) -> String { appID == self.appID ? "Folder Child" : appID.rawValue }
    func folderName(for folderID: FolderID) -> String { folderID == self.folderID ? "Test Folder" : folderID.rawValue }
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
    func folderNames() -> [FolderID: String] { [folderID: "Test Folder"] }
    func folderChildren(_ id: FolderID) -> [AppID]? { id == folderID ? [appID] : nil }
    func applyDragDrop(_ mutation: LayoutTransaction.LayoutMutation) {}
    func setHidden(_ appID: AppID, hidden: Bool) {}
    func setCustomName(_ appID: AppID, name: String?) {}
    func moveToTrash(_ appID: AppID) {}
    func isHidden(_ appID: AppID) -> Bool { false }
}

@MainActor
private func descendant<T: NSView>(of view: NSView, as type: T.Type) -> T? {
    if let match = view as? T {
        return match
    }
    for subview in view.subviews {
        if let match = descendant(of: subview, as: type) {
            return match
        }
    }
    return nil
}

@MainActor
private func ancestorChain(of view: NSView) -> [NSView] {
    var result: [NSView] = []
    var current: NSView? = view
    while let view = current {
        result.append(view)
        current = view.superview
    }
    return result
}

@MainActor
private func mouseEvent(
    _ type: NSEvent.EventType,
    at point: NSPoint,
    window: NSWindow
) -> NSEvent {
    NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
    )!
}
