import AppKit
import LaunchCore
import Testing
@testable import LaunchUI

/// A4 measurement: quantify the O(N) snapshot construction inside
/// GridViewController.flatIndex(of:) / indexPath(atFlatIndex:) during drag.
@Suite("Snapshot index measurement", .serialized)
@MainActor
struct SnapshotIndexMeasurementTests {
    private static let appCount = 87

    @Test("report drag-path index costs")
    func measure() throws {
        let store = SnapshotIndexTestStore(itemCount: Self.appCount)
        let grid = GridViewController(store: store, iconProvider: nil)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
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

        _ = try #require(store.item(at: 0))
        let midItem = try #require(store.item(at: 40))
        let clock = ContinuousClock()

        // Warm up layout/caches.
        _ = grid.flatIndex(of: midItem)
        _ = grid.indexPath(atFlatIndex: 40)
        _ = grid.frame(atFlatIndex: 40)

        let iterations = 1_000
        let flatStart = clock.now
        for _ in 0..<iterations { _ = grid.flatIndex(of: midItem) }
        let flatUs = nanoseconds(clock.now - flatStart) / Double(iterations) / 1_000

        let pathStart = clock.now
        for _ in 0..<iterations { _ = grid.indexPath(atFlatIndex: 40) }
        let pathUs = nanoseconds(clock.now - pathStart) / Double(iterations) / 1_000

        // Realistic drag: move from slot 0 toward slot 86 across 3 pages.
        // Each destination change recomputes preview moves via indexPath(atFlatIndex:).
        var pathCalls = 0
        let dragStart = clock.now
        for gapIndex in 1..<Self.appCount {
            for move in DragPreviewPlan.moves(sourceIndex: 0, gapIndex: gapIndex) {
                _ = grid.indexPath(atFlatIndex: move.itemIndex)
                pathCalls += 1
            }
        }
        let dragMs = nanoseconds(clock.now - dragStart) / 1_000_000

        print("[A4-MEASURE] flatIndex(of:) 1 call = \(flatUs) µs; "
            + "indexPath(atFlatIndex:) 1 call = \(pathUs) µs; "
            + "full 3-page drag \(pathCalls) indexPath calls = \(dragMs) ms")
    }

    /// Duration → 纳秒(measurement only)。
    private func nanoseconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) * 1_000_000_000 + Double(c.attoseconds) / 1_000_000_000
    }
}

@MainActor
private final class SnapshotIndexTestStore: LauncherStoring {
    let gridColumns = 7
    let gridRows = 6
    let iconSize = 64
    var wallpaperBlurRadius: Int { 30 }
    var searchBarWidth: Int { 320 }
    let displayRevision: UInt64 = 1
    var onDataChange: (() -> Void)?

    private let items: [DisplayModel.DisplayItem]

    init(itemCount: Int) {
        items = (0..<itemCount).map {
            .app(AppID("/Applications/App\($0).app")!)
        }
    }

    func item(at index: Int) -> DisplayModel.DisplayItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    @discardableResult
    func addDataObserver(_ observer: @escaping () -> Void) -> UUID { UUID() }

    func removeDataObserver(_ token: UUID) {}

    func displayModel() -> DisplayModel {
        DisplayModel(pages: [items], pageCapacity: gridColumns * gridRows)
    }

    func searchResults(for query: String) -> [DisplayModel.DisplayItem]? { nil }
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
