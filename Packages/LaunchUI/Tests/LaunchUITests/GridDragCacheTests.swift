import AppKit
import LaunchCore
import Testing
@testable import LaunchUI

@Suite("Grid drag cache mapping")
@MainActor
struct GridDragCacheTests {
    @Test("maps flat indexes across cached sections")
    func mapsFlatIndexesAcrossCachedSections() throws {
        let first = AppID("/Applications/CacheFirst.app")!
        let folder = FolderID("folder://cache")!
        let second = AppID("/Applications/CacheSecond.app")!
        let third = AppID("/Applications/CacheThird.app")!
        let fourth = AppID("/Applications/CacheFourth.app")!
        let pages: [[DisplayModel.DisplayItem]] = [
            [.app(first), .folder(folder)],
            [.app(second)],
            [.app(third), .app(fourth)],
        ]
        let store = GridDragCacheTestStore(pages: pages)
        let grid = GridViewController(store: store, iconProvider: nil)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
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

        let expected: [(DisplayModel.DisplayItem, Int, IndexPath)] = [
            (.app(first), 0, IndexPath(item: 0, section: 0)),
            (.folder(folder), 1, IndexPath(item: 1, section: 0)),
            (.app(second), 2, IndexPath(item: 0, section: 1)),
            (.app(third), 3, IndexPath(item: 0, section: 2)),
            (.app(fourth), 4, IndexPath(item: 1, section: 2)),
        ]

        for (item, flatIndex, indexPath) in expected {
            #expect(grid.flatIndex(of: item) == flatIndex)
            #expect(grid.indexPath(atFlatIndex: flatIndex) == indexPath)
        }
        #expect(grid.indexPath(atFlatIndex: -1) == nil)
        #expect(grid.indexPath(atFlatIndex: expected.count) == nil)
    }
}

@MainActor
private final class GridDragCacheTestStore: LauncherStoring {
    let pages: [[DisplayModel.DisplayItem]]
    var onDataChange: (() -> Void)?
    var searchQuery = ""
    let gridColumns = 2
    let gridRows = 1
    let iconSize = 64
    let wallpaperBlurRadius = 30
    let searchBarWidth = 320
    let displayRevision: UInt64 = 1

    init(pages: [[DisplayModel.DisplayItem]]) {
        self.pages = pages
    }

    @discardableResult
    func addDataObserver(_ observer: @escaping () -> Void) -> UUID { UUID() }

    func removeDataObserver(_ token: UUID) {}

    func displayModel() -> DisplayModel {
        DisplayModel(pages: pages, pageCapacity: gridColumns * gridRows)
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
    ) { completion(false) }
    func reorderFolderApp(app: AppID, in folder: FolderID, toIndex: Int) {}
    func folderNames() -> [FolderID: String] { [:] }
    func folderChildren(_ id: FolderID) -> [AppID]? { nil }
    func applyDragDrop(_ mutation: LayoutTransaction.LayoutMutation) {}
    func setHidden(_ appID: AppID, hidden: Bool) {}
    func setCustomName(_ appID: AppID, name: String?) {}
    func moveToTrash(_ appID: AppID) {}
    func isHidden(_ appID: AppID) -> Bool { false }
}
