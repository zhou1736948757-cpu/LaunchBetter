import AppKit
import LaunchCore
import Testing
@testable import LaunchUI

@Suite("Context menu (Reveal in Finder / Get Info)", .serialized)
@MainActor
struct ContextMenuTests {
    private func makeGrid(_ items: [DisplayModel.DisplayItem]) throws -> (GridViewController, NSWindow, ContextMenuTestStore) {
        let store = ContextMenuTestStore(items: items)
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
        return (grid, window, store)
    }

    private func menuPoint(grid: GridViewController) throws -> NSPoint {
        let frame = grid.frame(atFlatIndex: 0)
        return grid.collectionViewRef.convert(
            NSPoint(x: frame.midX, y: frame.midY),
            to: nil
        )
    }

    @Test("app menu contains Reveal in Finder and Get Info alongside existing items")
    func appMenuContainsNewAndExistingItems() throws {
        let previous = L10n.currentLanguage
        defer { L10n.configure(language: previous) }
        L10n.configure(language: .english)

        let appID = AppID("/Applications/MenuApp.app")!
        let (grid, window, _) = try makeGrid([.app(appID)])
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        let menu = try #require(grid.contextMenu(at: try menuPoint(grid: grid)))
        let titles = menu.items.map(\.title)
        #expect(titles.contains(L10n.t(.revealInFinder)))
        #expect(titles.contains(L10n.t(.getInfo)))
        #expect(titles.contains(L10n.t(.addToFolder)))
        #expect(titles.contains(L10n.t(.renameApp)))
        #expect(titles.contains(L10n.t(.moveToTrash)))

        let reveal = try #require(menu.items.first { $0.title == L10n.t(.revealInFinder) })
        let getInfo = try #require(menu.items.first { $0.title == L10n.t(.getInfo) })
        for item in [reveal, getInfo] {
            #expect(item.representedObject as? AppID == appID)
            #expect(item.target === grid)
            #expect(item.action != nil)
            #expect(item.target?.responds(to: item.action) == true)
        }
    }

    @Test("folder menu keeps rename/dissolve and has no Reveal or Get Info")
    func folderMenuKeepsExistingActions() throws {
        let previous = L10n.currentLanguage
        defer { L10n.configure(language: previous) }
        L10n.configure(language: .english)

        let folderID = FolderID("folder://menu-test")!
        let (grid, window, _) = try makeGrid([.folder(folderID)])
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        let menu = try #require(grid.contextMenu(at: try menuPoint(grid: grid)))
        let titles = menu.items.map(\.title)
        #expect(titles.contains(L10n.t(.rename)))
        #expect(titles.contains(L10n.t(.dissolveFolder)))
        #expect(!titles.contains(L10n.t(.revealInFinder)))
        #expect(!titles.contains(L10n.t(.getInfo)))
    }

    @Test("fileURL derives from the canonical AppID path")
    func fileURLDerivesFromCanonicalPath() throws {
        let appID = AppID("/Applications/Quote\"Back\\slash.app")!
        let store = ContextMenuTestStore(items: [.app(appID)])
        let grid = GridViewController(store: store, iconProvider: nil)
        let url = grid.fileURL(for: appID)
        #expect(url.isFileURL)
        #expect(url.path == appID.rawValue)
    }

    @Test("Get Info AppleScript source escapes quotes and backslashes")
    func getInfoAppleScriptSourceIsEscaped() throws {
        let appID = AppID("/Applications/Quote\"Back\\slash.app")!
        let store = ContextMenuTestStore(items: [.app(appID)])
        let grid = GridViewController(store: store, iconProvider: nil)
        let source = grid.getInfoAppleScriptSource(for: appID)
        let expectedEscaped = appID.rawValue
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        #expect(
            source
                == "tell application \"Finder\" to open information window of (POSIX file \"\(expectedEscaped)\")"
        )
    }
}

@MainActor
private final class ContextMenuTestStore: LauncherStoring {
    var items: [DisplayModel.DisplayItem]
    var onDataChange: (() -> Void)?
    var searchQuery = ""
    let gridColumns = 2
    let gridRows = 1
    let iconSize = 64
    let displayRevision: UInt64 = 1

    init(items: [DisplayModel.DisplayItem]) {
        self.items = items
    }

    @discardableResult
    func addDataObserver(_ observer: @escaping () -> Void) -> UUID {
        UUID()
    }

    func removeDataObserver(_ token: UUID) {}

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
    func setHidden(_ appID: AppID, hidden: Bool) {}
    func setCustomName(_ appID: AppID, name: String?) {}
    func moveToTrash(_ appID: AppID) {}
    func isHidden(_ appID: AppID) -> Bool { false }
}
