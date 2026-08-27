import AppKit
import LaunchCore
import Testing
@testable import LaunchUI

/// L10: GridViewController 内存压力 purge 生命周期测试。
///
/// macOS 无 AppKit 内存警告通知, 真实机制是 `DispatchSourceMemoryPressure`:
/// loadView 时注册(main 队列)、回调 purgePageVisuals、deinit 取消源(不泄漏)。
@Suite("GridViewController memory pressure purge", .serialized)
@MainActor
struct MemoryPressurePurgeTests {
    @Test("memory pressure source registers on load and purges page visuals (L10)")
    func memoryPressurePurgesPageVisuals() {
        let store = MemoryPressureTestStore()
        let grid = GridViewController(store: store, iconProvider: nil)
        _ = grid.view
        #expect(grid.memoryPressureObserverRegisteredForDiag)

        let baseline = grid.memoryPressurePurgeCountForDiag
        grid.triggerMemoryPressurePurgeForDiag()
        #expect(grid.memoryPressurePurgeCountForDiag == baseline + 1)
    }

    @Test("memory pressure source is torn down on deinit (L10)")
    func observerRemovedOnDeinit() {
        weak var weakGrid: GridViewController?
        var grid: GridViewController? = GridViewController(
            store: MemoryPressureTestStore(), iconProvider: nil
        )
        _ = grid?.view
        #expect(grid?.memoryPressureObserverRegisteredForDiag == true)
        weakGrid = grid
        grid = nil
        #expect(weakGrid == nil, "事件源弱引用 self, 不形成保留环")
    }

    @Test("teardownMemoryPressureObserver is idempotent and clears registration (F10)")
    func teardownIsIdempotent() {
        let store = MemoryPressureTestStore()
        let grid = GridViewController(store: store, iconProvider: nil)
        _ = grid.view
        #expect(grid.memoryPressureObserverRegisteredForDiag)

        grid.teardownMemoryPressureObserver()
        #expect(!grid.memoryPressureObserverRegisteredForDiag)

        // 再次调用不崩溃、保持未注册。
        grid.teardownMemoryPressureObserver()
        grid.teardownMemoryPressureObserver()
        #expect(!grid.memoryPressureObserverRegisteredForDiag)

        // teardown 后显式 purge 路径仍可用(仅事件源被关闭)。
        let baseline = grid.memoryPressurePurgeCountForDiag
        grid.triggerMemoryPressurePurgeForDiag()
        #expect(grid.memoryPressurePurgeCountForDiag == baseline + 1)
    }
}

@MainActor
private final class MemoryPressureTestStore: LauncherStoring {
    var onDataChange: (() -> Void)?
    let gridColumns = 2
    let gridRows = 1
    let iconSize = 64
    let wallpaperBlurRadius = 30
    let searchBarWidth = 320
    let displayRevision: UInt64 = 1

    @discardableResult
    func addDataObserver(_ observer: @escaping () -> Void) -> UUID { UUID() }

    func removeDataObserver(_ token: UUID) {}

    func displayModel() -> DisplayModel {
        DisplayModel(
            pages: [[.app(AppID(normalized: "/Applications/MemoryPressure.app"))]],
            pageCapacity: gridColumns * gridRows
        )
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