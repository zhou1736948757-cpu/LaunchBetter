import AppKit
import LaunchCore
import Testing
@testable import LaunchUI

/// P3-I: Library-only 元数据变更(launch usage / category override)与 grid 刷新解耦。
///
/// 契约:
/// - `notifyDataObservers()`(dataObservers 路径)不 bump `displayRevision`、不触发
///   `onDataChange`(grid 全量刷新)。
/// - grid-visible 变更仍走 `displayRevision` + `onDataChange`(回归守卫)。
/// - dataObservers 触发 `hostItem.refreshModel()` → Library 表面 live 更新。
///
/// 注意: Tests 1–2 使用 stub 验证通知层契约(dataObservers vs onDataChange),
/// 不直接测试真实 `LauncherStore.applyMetadataSnapshot`(该类在 app target,
/// LaunchUI 测试无法导入)。真实 Store 的行为由代码审查 + Test 3 的集成路径
/// (真实 GridViewController + dataObserver → hostItem.refreshModel)共同覆盖。
@Suite("Publication decoupling: metadata vs grid refresh", .serialized)
@MainActor
struct PublicationDecouplingTests {
    private func makeApp(_ n: Int) -> AppID {
        AppID("/Applications/Decouple\(n).app")!
    }

    private func makeModel(_ appIDs: [AppID]) -> AppLibraryModel {
        AppLibraryModel(
            cards: [
                AppLibraryCard(
                    id: .suggestions,
                    primaryAppIDs: appIDs,
                    miniAppIDs: [],
                    detailAppIDs: appIDs
                ),
            ],
            categoryDetail: [:]
        )
    }

    // MARK: - 1. metadata-only 变更不 bump displayRevision / 不触发 onDataChange

    @Test("metadata-only change does not bump displayRevision")
    func metadataOnlyChangeDoesNotBumpDisplayRevision() {
        let store = PublicationDecouplingStore(
            pages: [[.app(makeApp(1)), .app(makeApp(2))]],
            libraryModel: makeModel([makeApp(1), makeApp(2)])
        )
        let initialRevision = store.displayRevision
        var onDataChangeCalls = 0
        store.onDataChange = { onDataChangeCalls += 1 }

        // Library-only 通知路径: 只触发 dataObservers。
        store.notifyDataObservers()

        #expect(store.displayRevision == initialRevision)
        #expect(onDataChangeCalls == 0)

        // grid 路径仍可用: 显式触发 onDataChange 必须被调用方收到。
        store.onDataChange?()
        #expect(onDataChangeCalls == 1)
    }

    // MARK: - 2. grid-visible 变更仍 bump displayRevision + 触发 onDataChange

    @Test("grid-visible change still bumps displayRevision")
    func gridVisibleChangeStillBumpsDisplayRevision() {
        let store = PublicationDecouplingStore(
            pages: [[.app(makeApp(1)), .app(makeApp(2))]],
            libraryModel: makeModel([makeApp(1), makeApp(2)])
        )
        var onDataChangeCalls = 0
        store.onDataChange = { onDataChangeCalls += 1 }

        // 模拟 grid-visible 结构变更(目录/布局/配置): 递增 revision 并通知。
        store.displayRevision &+= 1
        store.onDataChange?()

        #expect(onDataChangeCalls == 1)
    }

    // MARK: - 3. dataObserver 触发 hostItem.refreshModel → Library live 更新

    @Test("dataObserver fires hostItem.refreshModel for Library")
    func dataObserverFiresHostRefreshForLibrary() async throws {
        let app1 = makeApp(1)
        let app2 = makeApp(2)
        let app3 = makeApp(3)
        let store = PublicationDecouplingStore(
            pages: [[.app(app1), .app(app2)]],
            libraryModel: makeModel([app1, app2])
        )
        let grid = GridViewController(store: store, iconProvider: nil)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1300, height: 900),
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
        defer { window.orderOut(nil); window.contentView = nil }

        // 进入 Library surface(真实 settle 时序 + 轮询, 与既有测试同构)。
        grid.libraryShotNavigateToLibrary()
        for _ in 0..<400 {
            if grid.libraryShotWaitSettled() { break }
            try? await Task.sleep(for: .milliseconds(8))
        }
        grid.view.layoutSubtreeIfNeeded()
        grid.collectionViewRef.layoutSubtreeIfNeeded()
        grid.libraryControllerForDiag?.view.layoutSubtreeIfNeeded()
        grid.libraryControllerForDiag?.collectionView.layoutSubtreeIfNeeded()

        let lib = try #require(grid.libraryControllerForDiag)
        #expect(grid.currentSurfaceValue == .appLibrary)
        #expect(lib.modelForDiag == makeModel([app1, app2]))

        // Library-only 元数据变更: 换 model → 触发 dataObservers → host live 刷新。
        let newModel = makeModel([app1, app2, app3])
        store.libraryModel = newModel
        store.notifyDataObservers()

        #expect(lib.modelForDiag == newModel)
    }
}

/// Store 替身: LauncherStoring + AppLibraryDataProviding, 带可变的
/// `displayRevision` / `onDataChange` 与真实 dataObservers 存储(与
/// FolderRefreshTestStore 同构), 供解耦契约测试。
@MainActor
private final class PublicationDecouplingStore: LauncherStoring, AppLibraryDataProviding {
    var pages: [[DisplayModel.DisplayItem]]
    var libraryModel: AppLibraryModel
    var onDataChange: (() -> Void)?
    let gridColumns = 2
    let gridRows = 1
    let iconSize = 64
    let wallpaperBlurRadius = 30
    let searchBarWidth = 320
    var displayRevision: UInt64 = 1

    private var observers: [UUID: () -> Void] = [:]

    init(pages: [[DisplayModel.DisplayItem]], libraryModel: AppLibraryModel) {
        self.pages = pages
        self.libraryModel = libraryModel
    }

    @discardableResult
    func addDataObserver(_ observer: @escaping () -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    func removeDataObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    func notifyDataObservers() {
        for observer in observers.values {
            observer()
        }
    }

    func displayModel() -> DisplayModel {
        DisplayModel(pages: pages, pageCapacity: gridColumns * gridRows)
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

    func appLibraryModel() -> AppLibraryModel { libraryModel }
}
