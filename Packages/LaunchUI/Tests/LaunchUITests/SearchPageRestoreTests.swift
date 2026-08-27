import AppKit
import LaunchCore
import Testing
@testable import LaunchUI

@Suite("Search page restore", .serialized)
@MainActor
struct SearchPageRestoreTests {
    @Test("恢复 clamp: before 0/1/2 × pageCount 1/2/3")
    func restoreClampMatrix() {
        // pageCount 1
        #expect(GridViewController.clampedPage(0, pageCount: 1) == 0)
        #expect(GridViewController.clampedPage(1, pageCount: 1) == 0)
        #expect(GridViewController.clampedPage(2, pageCount: 1) == 0)
        // pageCount 2
        #expect(GridViewController.clampedPage(0, pageCount: 2) == 0)
        #expect(GridViewController.clampedPage(1, pageCount: 2) == 1)
        #expect(GridViewController.clampedPage(2, pageCount: 2) == 1)
        // pageCount 3
        #expect(GridViewController.clampedPage(0, pageCount: 3) == 0)
        #expect(GridViewController.clampedPage(1, pageCount: 3) == 1)
        #expect(GridViewController.clampedPage(2, pageCount: 3) == 2)
    }

    @Test("负数与超界页的确定性 clamp")
    func negativeAndOutOfBoundsClamp() {
        #expect(GridViewController.clampedPage(-1, pageCount: 3) == 0)
        #expect(GridViewController.clampedPage(-100, pageCount: 2) == 0)
        #expect(GridViewController.clampedPage(3, pageCount: 3) == 2)
        #expect(GridViewController.clampedPage(100, pageCount: 2) == 1)
        #expect(GridViewController.clampedPage(Int.max, pageCount: 1) == 0)
    }

    @Test("pageCount 至少按 1 处理")
    func pageCountAtLeastOne() {
        #expect(GridViewController.clampedPage(0, pageCount: 0) == 0)
        #expect(GridViewController.clampedPage(2, pageCount: 0) == 0)
        #expect(GridViewController.clampedPage(1, pageCount: -3) == 0)
    }

    @Test("清空搜索后恢复到搜索前的普通页(第 3 页)")
    func exitingSearchRestoresPriorPagedPage() throws {
        let store = SearchRestoreTestStore(pages: makeThreePages())
        let grid = GridViewController(store: store, iconProvider: nil)
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        #expect(!grid.isSearchMode)
        #expect(grid.pageCountValue == 3)

        grid.goToPage(2, animated: false)
        #expect(grid.currentPageValue == 2)

        store.searchResultsValue = [.app(makeApp(1))]
        store.revision &+= 1
        grid.searchQuery = "photo"
        grid.refresh()
        #expect(grid.isSearchMode)
        #expect(grid.currentPageValue == 0)
        #expect(grid.pageCountValue == 1)

        store.searchResultsValue = nil
        store.revision &+= 1
        grid.searchQuery = ""
        grid.refresh()
        #expect(!grid.isSearchMode)
        #expect(grid.pageCountValue == 3)
        #expect(grid.currentPageValue == 2)
    }

    @Test("搜索期间普通页数收缩: 恢复页按新 pageCount 重新 clamp")
    func exitingSearchClampsToShrunkPageCount() throws {
        let store = SearchRestoreTestStore(pages: makeThreePages())
        let grid = GridViewController(store: store, iconProvider: nil)
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        grid.goToPage(2, animated: false)
        #expect(grid.currentPageValue == 2)

        store.searchResultsValue = [.app(makeApp(1))]
        store.revision &+= 1
        grid.searchQuery = "photo"
        grid.refresh()
        #expect(grid.isSearchMode)

        store.pages = [[.app(makeApp(1))]]
        store.searchResultsValue = nil
        store.revision &+= 1
        grid.searchQuery = ""
        grid.refresh()
        #expect(!grid.isSearchMode)
        #expect(grid.pageCountValue == 1)
        #expect(grid.currentPageValue == 0)
    }

    private func makeApp(_ n: Int) -> AppID {
        AppID("/Applications/PageRestore\(n).app")!
    }

    private func makeThreePages() -> [[DisplayModel.DisplayItem]] {
        [
            [.app(makeApp(1)), .app(makeApp(2))],
            [.app(makeApp(3)), .app(makeApp(4))],
            [.app(makeApp(5)), .app(makeApp(6))],
        ]
    }

    private func makeWindow(for controller: GridViewController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.view
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        return window
    }
}

@MainActor
private final class SearchRestoreTestStore: LauncherStoring {
    var pages: [[DisplayModel.DisplayItem]]
    var searchResultsValue: [DisplayModel.DisplayItem]?
    var revision: UInt64 = 1

    var onDataChange: (() -> Void)?
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

    func searchResults(for query: String) -> [DisplayModel.DisplayItem]? { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : searchResultsValue }
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
